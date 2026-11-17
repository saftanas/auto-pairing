import Foundation
@preconcurrency import IOBluetooth
import OSLog

struct BluetoothPeripheral: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let connected: Bool
}

struct BluetoothOperationResult: Sendable {
  let address: String
  let name: String
  let success: Bool
  let detail: String
}

protocol BluetoothOperating: AnyObject {
  func pairedDevices() async -> [BluetoothPeripheral]
  func setTarget(addresses: Set<String>, shouldConnect: Bool) -> UInt64
  func reconcile(generation: UInt64) async -> [BluetoothOperationResult]
}

protocol BluetoothDeviceTransport: AnyObject {
  var name: String? { get }
  func isConnected() -> Bool
  func isPaired() -> Bool
  /// Returns submission status only. Completion may arrive much later.
  func beginConnection(
    pageTimeout: UInt16, authenticationRequired: Bool,
    completion: @escaping @Sendable (IOReturn) -> Void
  ) -> IOReturn
  func closeConnection() -> IOReturn
}

protocol BluetoothBackend {
  var isPoweredOn: Bool { get }
  func pairedDevices() -> [BluetoothPeripheral]
  func device(address: String) -> BluetoothDeviceTransport?
}

/// IOBluetooth requires a live run loop for asynchronous callbacks. One process-
/// lifetime thread serializes reads, command submission, and callback handling.
/// It never waits for a connection attempt to finish. The main/power loop stays free.
private final class BluetoothRunLoop: @unchecked Sendable {
  static let shared = BluetoothRunLoop()
  private let runLoop: CFRunLoop

  private final class Startup: @unchecked Sendable {
    var runLoop: CFRunLoop?
    let ready = DispatchSemaphore(value: 0)
  }

  private init() {
    let startup = Startup()
    let thread = Thread {
      autoreleasepool {
        let runLoop = CFRunLoopGetCurrent()!
        var context = CFRunLoopSourceContext()
        let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)!
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        startup.runLoop = runLoop
        startup.ready.signal()
        CFRunLoopRun()
        withExtendedLifetime(source) {}
      }
    }
    thread.name = "com.saftanas.studioswitch.bluetooth"
    thread.qualityOfService = .userInitiated
    thread.start()
    startup.ready.wait()
    runLoop = startup.runLoop!
  }

  func perform(_ body: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
      autoreleasepool { body() }
    }
    CFRunLoopWakeUp(runLoop)
  }
}

/// Keep the Objective-C target alive until the real callback, including after a
/// reporting timeout. Dropping it at our timeout would leave a dangling native
/// callback. Only one native attempt per address is permitted by the controller.
final class SystemConnectionCallback: NSObject, IOBluetoothDeviceAsyncCallbacks {
  private let lock = NSLock()
  private var completion: (@Sendable (IOReturn) -> Void)?
  private var keepAlive: SystemConnectionCallback?

  init(completion: @escaping @Sendable (IOReturn) -> Void) {
    self.completion = completion
    super.init()
    keepAlive = self
  }

  @objc(connectionComplete:status:)
  func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
    let callback = lock.withLock { () -> (@Sendable (IOReturn) -> Void)? in
      let callback = completion
      completion = nil
      keepAlive = nil
      return callback
    }
    callback?(status)
  }

  // Required by the native callback protocol. This target submits only a
  // connection request, so name/SDP completions must not complete that request.
  func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
  func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

  func submissionFailed() {
    lock.withLock {
      completion = nil
      keepAlive = nil
    }
  }
}

private struct SystemBluetoothBackend: BluetoothBackend {
  var isPoweredOn: Bool {
    IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
  }

  func pairedDevices() -> [BluetoothPeripheral] {
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return paired.compactMap { device in
      guard let address = device.addressString else { return nil }
      return BluetoothPeripheral(
        id: address, name: device.name ?? "Unnamed Bluetooth device",
        connected: device.isConnected())
    }
  }

  func device(address: String) -> BluetoothDeviceTransport? {
    guard let device = IOBluetoothDevice(addressString: address) else { return nil }
    return SystemBluetoothDevice(device)
  }
}

private final class SystemBluetoothDevice: BluetoothDeviceTransport {
  private let device: IOBluetoothDevice
  init(_ device: IOBluetoothDevice) { self.device = device }
  var name: String? { device.name }
  func isConnected() -> Bool { device.isConnected() }
  func isPaired() -> Bool { device.isPaired() }
  func beginConnection(
    pageTimeout: UInt16, authenticationRequired: Bool,
    completion: @escaping @Sendable (IOReturn) -> Void
  ) -> IOReturn {
    let callback = SystemConnectionCallback(completion: completion)
    // A non-nil target selects the documented asynchronous API. Never replace
    // this with nil: its synchronous wait delayed release by ~17 s in a trial.
    let status = device.openConnection(
      callback, withPageTimeout: pageTimeout, authenticationRequired: authenticationRequired)
    if status != kIOReturnSuccess { callback.submissionFailed() }
    return status
  }
  func closeConnection() -> IOReturn { device.closeConnection() }
}

final class BluetoothController: BluetoothOperating, @unchecked Sendable {
  private struct Target {
    var generation: UInt64 = 0
    var addresses: Set<String> = []
    var shouldConnect = false
    func wantsConnection(to address: String) -> Bool {
      shouldConnect && addresses.contains(address)
    }
  }

  private final class Attempt {
    let id = UUID()
    let generation: UInt64
    let device: BluetoothDeviceTransport
    let name: String
    let started = ProcessInfo.processInfo.systemUptime
    var timedOut = false
    var cancellationRequested = false
    var timer: Timer?
    init(generation: UInt64, device: BluetoothDeviceTransport, name: String) {
      self.generation = generation
      self.device = device
      self.name = name
    }
    deinit { timer?.invalidate() }
  }

  private struct Completion {
    let generation: UInt64
    let status: IOReturn
  }

  private let targetLock = NSLock()
  private var target = Target()
  private let backend: BluetoothBackend
  private let executor = BluetoothRunLoop.shared
  private let reportTimeout: TimeInterval
  private let logger = Logger(subsystem: "com.saftanas.studioswitch", category: "Bluetooth")
  // Accessed exclusively on executor, unlike target which is fenced synchronously.
  private var pending: [String: Attempt] = [:]
  private var completions: [String: Completion] = [:]

  init(backend: BluetoothBackend = SystemBluetoothBackend(), reportTimeout: TimeInterval = 3) {
    self.backend = backend
    self.reportTimeout = reportTimeout
  }

  func pairedDevices() async -> [BluetoothPeripheral] {
    await withCheckedContinuation { continuation in
      executor.perform { [self] in
        continuation.resume(
          returning: backend.pairedDevices().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
          })
      }
    }
  }

  @discardableResult
  func setTarget(addresses: Set<String>, shouldConnect: Bool) -> UInt64 {
    let generation = targetLock.withLock {
      target.generation &+= 1
      target.addresses = addresses
      target.shouldConnect = shouldConnect
      return target.generation
    }
    // This is not queued behind connection completion: native opens return at
    // submission. Also covers devices removed from selection and coordinator.stop().
    executor.perform { [weak self] in self?.cancelUnwantedAttempts() }
    return generation
  }

  func reconcile(generation: UInt64) async -> [BluetoothOperationResult] {
    await withCheckedContinuation { continuation in
      executor.perform { [self] in
        let requested = currentTarget()
        guard requested.generation == generation else {
          continuation.resume(returning: [])
          return
        }
        continuation.resume(
          returning: requested.addresses.sorted().map {
            reconcile(address: $0, target: requested)
          })
      }
    }
  }

  private func currentTarget() -> Target { targetLock.withLock { target } }

  private func reconcile(address: String, target requested: Target) -> BluetoothOperationResult {
    guard currentTarget().generation == requested.generation else {
      return result(address, address, false, "Superseded by a newer handoff")
    }
    guard let device = pending[address]?.device ?? backend.device(address: address) else {
      return result(address, address, false, "Bluetooth device is unavailable")
    }
    let name = device.name ?? address

    if !requested.shouldConnect {
      if let attempt = pending[address], !attempt.cancellationRequested {
        cancelAttempt(address: address, attempt: attempt)
      } else if device.isConnected() {
        guard currentTarget().generation == requested.generation else {
          return result(address, name, false, "Superseded before release")
        }
        _ = close(device, name: name, reason: "release")
      }
      // A disconnected snapshot cannot certify release while a native attempt
      // can still connect later. Keep its delegate alive and clean up its callback.
      if pending[address] != nil {
        return result(
          address, name, false, "Connection cancellation pending; release is not verified")
      }
      let disconnected = !device.isConnected()
      return result(
        address, name, disconnected,
        disconnected ? "Bluetooth link is disconnected" : "Bluetooth link is still connected")
    }

    guard backend.isPoweredOn else {
      return result(address, name, false, "Bluetooth is off or not ready after wake")
    }
    guard device.isPaired() else {
      return result(address, name, false, "Not paired with this Mac; pair in Bluetooth settings")
    }
    if let attempt = pending[address] {
      return result(
        address, name, false,
        attempt.timedOut
          ? "Connection timed out; waiting for macOS to finish before retrying"
          : "Connection request pending")
    }
    if let completion = completions[address] {
      if completion.generation != requested.generation {
        completions.removeValue(forKey: address)
        // Retry after failure must authenticate again, not turn a leftover ACL
        // link green merely because the user pressed Retry handoff.
        if completion.status != kIOReturnSuccess, device.isConnected() {
          _ = close(device, name: name, reason: "retry after failed connection")
          if device.isConnected() {
            completions[address] = Completion(
              generation: requested.generation, status: completion.status)
            return result(address, name, false, statusDetail(completion.status))
          }
        }
      } else if completion.status != kIOReturnSuccess {
        // Failed authentication/HID setup can leave an ACL link. A failed
        // callback must override isConnected(), until an explicit fresh retry.
        // Ordinary page timeouts can retry automatically when no link remains.
        if !isPairingFailure(completion.status), !device.isConnected() {
          completions.removeValue(forKey: address)
        }
        return result(address, name, false, statusDetail(completion.status))
      } else {
        completions.removeValue(forKey: address)
        guard device.isConnected() else {
          return result(
            address, name, false,
            "Connection completion reported success, but the Bluetooth link is disconnected; 0x00000000"
          )
        }
      }
    }
    if device.isConnected() {
      return result(
        address, name, true, "Bluetooth link is connected; input readiness is not verified")
    }
    guard currentTarget().generation == requested.generation else {
      return result(address, name, false, "Superseded before connection")
    }

    let attempt = Attempt(generation: requested.generation, device: device, name: name)
    pending[address] = attempt
    let id = attempt.id
    logger.info(
      "Connect submit: \(name, privacy: .public), attempt \(id.uuidString, privacy: .public), generation \(requested.generation)"
    )
    // 1600 HCI slots is a one-second paging request, not an end-to-end timeout.
    let status = device.beginConnection(pageTimeout: 1600, authenticationRequired: true) {
      [weak self] status in
      self?.executor.perform { [weak self] in
        self?.connectionCompleted(address: address, id: id, status: status)
      }
    }
    logger.info(
      "Connect submission returned: \(name, privacy: .public), \(self.statusText(status), privacy: .public)"
    )
    if status != kIOReturnSuccess {
      pending.removeValue(forKey: address)
      completions[address] = Completion(generation: requested.generation, status: status)
      return result(address, name, false, statusDetail(status))
    }
    attempt.timer = Timer.scheduledTimer(
      withTimeInterval: max(0.001, reportTimeout), repeats: false
    ) {
      [weak self] _ in
      guard let self, let pending = self.pending[address], pending.id == id else { return }
      pending.timedOut = true
      self.logger.error(
        "Connect deadline exceeded: \(pending.name, privacy: .public), attempt \(id.uuidString, privacy: .public); native callback still pending, duplicate request suppressed"
      )
    }
    // A target can change while the short native submission call is executing.
    if !currentTarget().wantsConnection(to: address) {
      cancelAttempt(address: address, attempt: attempt)
    }
    return result(address, name, false, "Connection request pending")
  }

  private func cancelUnwantedAttempts() {
    for address in pending.keys.sorted() {
      guard !currentTarget().wantsConnection(to: address), let attempt = pending[address],
        !attempt.cancellationRequested
      else { continue }
      cancelAttempt(address: address, attempt: attempt)
    }
  }

  private func cancelAttempt(address: String, attempt: Attempt) {
    guard !currentTarget().wantsConnection(to: address) else { return }
    attempt.cancellationRequested = true
    // closeConnection is the public disconnect request. It is not documented as
    // canceling an outstanding create request, so keep pending until its callback.
    _ = close(attempt.device, name: attempt.name, reason: "cancel pending acquisition")
  }

  private func connectionCompleted(address: String, id: UUID, status: IOReturn) {
    guard let attempt = pending[address], attempt.id == id else {
      logger.debug("Ignoring obsolete connection callback: \(id.uuidString, privacy: .public)")
      return
    }
    pending.removeValue(forKey: address)
    attempt.timer?.invalidate()
    let duration = ProcessInfo.processInfo.systemUptime - attempt.started
    logger.info(
      "Connect completion: \(attempt.name, privacy: .public), attempt \(id.uuidString, privacy: .public), \(self.statusDetail(status), privacy: .public), elapsed \(duration) s"
    )
    let latest = currentTarget()
    if !latest.wantsConnection(to: address) {
      completions.removeValue(forKey: address)
      if attempt.device.isConnected() {
        _ = close(attempt.device, name: attempt.name, reason: "late connection after release")
      }
    } else {
      // Preserve origin: an explicit Retry while this request was pending must
      // not inherit its stale authentication failure as a new sticky error.
      completions[address] = Completion(generation: attempt.generation, status: status)
    }
  }

  @discardableResult
  private func close(_ device: BluetoothDeviceTransport, name: String, reason: String) -> IOReturn {
    let started = ProcessInfo.processInfo.systemUptime
    logger.info("Disconnect submit: \(name, privacy: .public), \(reason, privacy: .public)")
    let status = device.closeConnection()
    let duration = ProcessInfo.processInfo.systemUptime - started
    logger.info(
      "Disconnect returned: \(name, privacy: .public), \(self.statusText(status), privacy: .public), connected \(device.isConnected()), elapsed \(duration) s"
    )
    return status
  }

  private func isPairingFailure(_ status: IOReturn) -> Bool {
    status == kBluetoothHCIErrorAuthenticationFailure || status == kBluetoothHCIErrorKeyMissing
      // bluetoothd used this explicit invalid-link-key code in the failed trial.
      // Recognize it only if the framework actually propagates that same value.
      || status == 310151
  }

  private func statusDetail(_ status: IOReturn) -> String {
    if isPairingFailure(status) {
      return
        "Pairing authentication failed; repair this device's pairing in Bluetooth settings, then retry; \(statusText(status))"
    }
    if status == kIOReturnTimeout || status == kBluetoothHCIErrorPageTimeout {
      return "Bluetooth connection timed out; \(statusText(status))"
    }
    if status == kIOReturnNotPermitted || status == kIOReturnNotPrivileged {
      return "macOS denied the Bluetooth request; check Bluetooth access; \(statusText(status))"
    }
    return "Bluetooth connection completion \(statusText(status))"
  }

  private func statusText(_ status: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: status))
  }

  private func result(_ address: String, _ name: String, _ success: Bool, _ detail: String)
    -> BluetoothOperationResult
  {
    BluetoothOperationResult(address: address, name: name, success: success, detail: detail)
  }
}
