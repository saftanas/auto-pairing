import Foundation
import IOBluetooth
import ObjectiveC
import Testing

@testable import StudioSwitch

private final class CommandLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String] = []
  private var threadNames: Set<String> = []
  func append(_ entry: String) {
    lock.withLock {
      entries.append(entry)
      threadNames.insert(Thread.current.name ?? "unnamed")
    }
  }
  var values: [String] { lock.withLock { entries } }
  var threads: Set<String> { lock.withLock { threadNames } }
}

private final class FakeDeviceTransport: BluetoothDeviceTransport, @unchecked Sendable {
  let name: String?
  private let lock = NSLock()
  private var connected: Bool
  private var openArguments: [(UInt16, Bool)] = []
  private var callbacks: [@Sendable (Int32) -> Void] = []
  private let paired: Bool
  private let disconnectsOnClose: Bool
  private let submissionStatus: Int32
  private let log: CommandLog

  init(
    _ name: String, log: CommandLog, connected: Bool = false, paired: Bool = true,
    disconnectsOnClose: Bool = true, submissionStatus: Int32 = 0
  ) {
    self.name = name
    self.log = log
    self.connected = connected
    self.paired = paired
    self.disconnectsOnClose = disconnectsOnClose
    self.submissionStatus = submissionStatus
  }

  var opens: [(UInt16, Bool)] { lock.withLock { openArguments } }
  func isConnected() -> Bool { lock.withLock { connected } }
  func isPaired() -> Bool { paired }
  func beginConnection(
    pageTimeout: UInt16, authenticationRequired: Bool,
    completion: @escaping @Sendable (Int32) -> Void
  ) -> Int32 {
    log.append("open \(name!)")
    lock.withLock {
      openArguments.append((pageTimeout, authenticationRequired))
      callbacks.append(completion)
    }
    // Submission returns without invoking the callback, like a slow real radio.
    return submissionStatus
  }
  func closeConnection() -> Int32 {
    log.append("close \(name!)")
    lock.withLock { if disconnectsOnClose { connected = false } }
    return 0
  }
  func complete(_ index: Int = 0, status: Int32 = 0, connected: Bool) {
    let callback = lock.withLock {
      self.connected = connected
      return callbacks[index]
    }
    callback(status)
  }
  func repeatCallback(_ index: Int, status: Int32) {
    let callback = lock.withLock { callbacks[index] }
    callback(status)
  }
}

private struct FakeBluetoothBackend: BluetoothBackend {
  var isPoweredOn = true
  let devices: [String: FakeDeviceTransport]
  let log: CommandLog
  func pairedDevices() -> [BluetoothPeripheral] {
    log.append("snapshot")
    return devices.map { address, device in
      BluetoothPeripheral(
        id: address, name: device.name ?? address, connected: device.isConnected())
    }
  }
  func device(address: String) -> BluetoothDeviceTransport? { devices[address] }
}

struct BluetoothControllerTests {
  private let timeout = Int32(bitPattern: 0xE000_02D6)

  @Test func nativeCallbackConformsAndReceivesObjectiveCSelectorExactlyOnce() throws {
    let log = CommandLog()
    let callback = SystemConnectionCallback { log.append(String($0)) }
    let nativeProtocol = try #require(objc_getProtocol("IOBluetoothDeviceAsyncCallbacks"))
    #expect(callback.conforms(to: nativeProtocol))
    let selector = NSSelectorFromString("connectionComplete:status:")
    #expect(callback.responds(to: selector))
    let method = try #require(class_getInstanceMethod(SystemConnectionCallback.self, selector))
    #expect(method_getNumberOfArguments(method) == 4)
    let implementation = method_getImplementation(method)
    typealias NativeCallback =
      @convention(c) (AnyObject, Selector, IOBluetoothDevice?, Int32) -> Void
    let invoke = unsafeBitCast(implementation, to: NativeCallback.self)

    callback.remoteNameRequestComplete(nil, status: 0)
    callback.sdpQueryComplete(nil, status: 0)
    #expect(log.values.isEmpty)
    invoke(callback, selector, nil, 6)
    invoke(callback, selector, nil, 0)
    #expect(log.values == ["6"])
  }

  @Test func nativeCallbackRetainsItselfUntilCompletionOrFailedSubmission() {
    let log = CommandLog()
    weak var completed: SystemConnectionCallback?
    do {
      let callback = SystemConnectionCallback { log.append(String($0)) }
      completed = callback
    }
    #expect(completed != nil)
    completed?.connectionComplete(nil, status: 0)
    #expect(completed == nil)
    #expect(log.values == ["0"])

    weak var rejected: SystemConnectionCallback?
    do {
      let callback = SystemConnectionCallback { log.append(String($0)) }
      rejected = callback
    }
    #expect(rejected != nil)
    rejected?.submissionFailed()
    #expect(rejected == nil)
    #expect(log.values == ["0"])
  }

  @Test func releaseRunsWhileConnectIsPendingAndLateSuccessIsClosed() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let acquiring = controller.setTarget(addresses: ["a"], shouldConnect: true)
    let pending = await controller.reconcile(generation: acquiring)
    #expect(pending.count == 1)
    #expect(pending.allSatisfy { !$0.success })
    #expect(keyboard.opens.count == 1)

    // No completion has fired. The old implementation would still be blocked here.
    let releasing = controller.setTarget(addresses: ["a"], shouldConnect: false)
    let release = await controller.reconcile(generation: releasing)
    #expect(log.values == ["open keyboard", "close keyboard"])
    #expect(release.first?.success == false)
    #expect(release.first?.detail.contains("release is not verified") == true)

    keyboard.complete(connected: true)
    let released = await controller.reconcile(generation: releasing)
    #expect(released.first?.success == true)
    #expect(!keyboard.isConnected())
    #expect(log.values == ["open keyboard", "close keyboard", "close keyboard"])
    #expect(keyboard.opens.first?.0 == 1600)
    #expect(keyboard.opens.first?.1 == true)
  }

  @Test func bothDevicesProgressWithoutWaitingForEitherCallback() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let trackpad = FakeDeviceTransport("trackpad", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(
        devices: ["a": keyboard, "b": trackpad], log: log))
    let generation = controller.setTarget(addresses: ["a", "b"], shouldConnect: true)
    let pending = await controller.reconcile(generation: generation)
    #expect(pending.count == 2)
    #expect(pending.allSatisfy { !$0.success })
    #expect(keyboard.opens.count == 1)
    #expect(trackpad.opens.count == 1)

    trackpad.complete(connected: true)
    let partial = await controller.reconcile(generation: generation)
    #expect(partial.first { $0.address == "a" }?.success == false)
    #expect(partial.first { $0.address == "b" }?.success == true)
    #expect(keyboard.opens.count == 1)
    keyboard.complete(connected: true)
    let complete = await controller.reconcile(generation: generation)
    #expect(complete.allSatisfy { $0.success })
  }

  @Test func reportingTimeoutDoesNotDiscardCallbackOrStartOverlappingAttempts() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log), reportTimeout: 0.01)
    let generation = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: generation)
    try await Task.sleep(nanoseconds: 30_000_000)
    let timedOut = await controller.reconcile(generation: generation)
    #expect(timedOut.first?.success == false)
    #expect(timedOut.first?.detail.contains("timed out") == true)
    #expect(keyboard.opens.count == 1)

    let retry = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: retry)
    #expect(keyboard.opens.count == 1)
    keyboard.complete(status: timeout, connected: false)
    let restarted = await controller.reconcile(generation: retry)
    #expect(restarted.first?.detail == "Connection request pending")
    #expect(keyboard.opens.count == 2)
    keyboard.complete(1, connected: true)
    let recovered = await controller.reconcile(generation: retry)
    #expect(recovered.first?.success == true)
  }

  @Test func explicitRetryDuringPendingAttemptDoesNotInheritOldAuthenticationError() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let original = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: original)
    let retry = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: retry)
    #expect(keyboard.opens.count == 1)

    keyboard.complete(status: 6, connected: false)
    let fresh = await controller.reconcile(generation: retry)
    #expect(fresh.first?.detail == "Connection request pending")
    #expect(keyboard.opens.count == 2)
    keyboard.complete(1, connected: true)
    let recovered = await controller.reconcile(generation: retry)
    #expect(recovered.first?.success == true)
  }

  @Test func nativeTimeoutIsReportedBeforeAutomaticRetryWhenDisconnected() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let generation = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: generation)
    keyboard.complete(status: timeout, connected: false)
    let failure = await controller.reconcile(generation: generation)
    #expect(failure.first?.success == false)
    #expect(failure.first?.detail.contains("0xE00002D6") == true)
    #expect(keyboard.opens.count == 1)
    _ = await controller.reconcile(generation: generation)
    #expect(keyboard.opens.count == 2)
    keyboard.complete(1, connected: true)
    _ = await controller.reconcile(generation: generation)
  }

  @Test func obsoleteDuplicateCallbackCannotFailOrCloseNewConnection() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let first = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: first)
    let release = controller.setTarget(addresses: ["a"], shouldConnect: false)
    _ = await controller.reconcile(generation: release)
    keyboard.complete(status: timeout, connected: false)
    _ = await controller.reconcile(generation: release)

    let second = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: second)
    #expect(keyboard.opens.count == 2)
    keyboard.repeatCallback(0, status: 5)
    let stillPending = await controller.reconcile(generation: second)
    #expect(stillPending.first?.detail == "Connection request pending")
    keyboard.complete(1, connected: true)
    _ = await controller.reconcile(generation: second)
    keyboard.repeatCallback(0, status: 5)
    let connected = await controller.reconcile(generation: second)
    #expect(connected.first?.success == true)
    #expect(keyboard.isConnected())
    #expect(log.values == ["open keyboard", "close keyboard", "open keyboard"])
  }

  @Test(arguments: [Int32(5), Int32(6), Int32(310151)])
  func pairingFailureIsStickyAndExplicitRetryAuthenticatesAgain(status: Int32) async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let generation = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: generation)
    keyboard.complete(status: status, connected: true)
    let failed = await controller.reconcile(generation: generation)
    #expect(failed.first?.success == false)
    #expect(failed.first?.detail.contains("Pairing authentication failed") == true)
    let again = await controller.reconcile(generation: generation)
    #expect(again.first?.success == false)
    #expect(keyboard.opens.count == 1)

    let retry = controller.setTarget(addresses: ["a"], shouldConnect: true)
    let pending = await controller.reconcile(generation: retry)
    #expect(pending.first?.success == false)
    #expect(log.values == ["open keyboard", "close keyboard", "open keyboard"])
    keyboard.complete(1, connected: true)
    let recovered = await controller.reconcile(generation: retry)
    #expect(recovered.first?.success == true)
  }

  @Test func genericFailureAlsoOverridesStillConnectedBaseband() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let generation = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: generation)
    keyboard.complete(status: timeout, connected: true)
    let first = await controller.reconcile(generation: generation)
    let second = await controller.reconcile(generation: generation)
    #expect(first.first?.success == false)
    #expect(second.first?.success == false)
    #expect(keyboard.opens.count == 1)
  }

  @Test func successfulCallbackWithoutConnectionIsNotSuccess() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let generation = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: generation)
    keyboard.complete(connected: false)
    let results = await controller.reconcile(generation: generation)
    #expect(results.first?.success == false)
    #expect(results.first?.detail.contains("0x00000000") == true)
  }

  @Test func successfulCloseReturnWithoutDisconnectionIsNotSuccess() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport(
      "keyboard", log: log, connected: true, disconnectsOnClose: false)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let generation = controller.setTarget(addresses: ["a"], shouldConnect: false)
    let results = await controller.reconcile(generation: generation)
    #expect(results.first?.success == false)
    #expect(results.first?.detail.contains("still connected") == true)
  }

  @Test func removingSelectionCancelsPendingAttemptAndCleansUpLateCallback() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let generation = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: generation)
    let empty = controller.setTarget(addresses: [], shouldConnect: true)
    _ = await controller.reconcile(generation: empty)
    #expect(log.values == ["open keyboard", "close keyboard"])
    keyboard.complete(connected: true)
    _ = await controller.pairedDevices()
    #expect(!keyboard.isConnected())
    #expect(log.values == ["open keyboard", "close keyboard", "close keyboard", "snapshot"])
  }

  @Test func staleReconciliationCannotIssueCommandsAndAllIOUsesOneLiveRunLoop() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let old = controller.setTarget(addresses: ["a"], shouldConnect: true)
    let latest = controller.setTarget(addresses: ["a"], shouldConnect: false)
    let stale = await controller.reconcile(generation: old)
    #expect(stale.isEmpty)
    #expect(log.values.isEmpty)
    _ = await controller.reconcile(generation: latest)
    _ = await controller.pairedDevices()
    let acquire = controller.setTarget(addresses: ["a"], shouldConnect: true)
    _ = await controller.reconcile(generation: acquire)
    keyboard.complete(connected: true)
    _ = await controller.reconcile(generation: acquire)
    let release = controller.setTarget(addresses: ["a"], shouldConnect: false)
    _ = await controller.reconcile(generation: release)
    #expect(log.threads == ["com.saftanas.studioswitch.bluetooth"])
  }

  @Test func immediateSubmissionErrorDoesNotLeaveAPendingAttempt() async throws {
    let log = CommandLog()
    let keyboard = FakeDeviceTransport("keyboard", log: log, submissionStatus: timeout)
    let controller = BluetoothController(
      backend: FakeBluetoothBackend(devices: ["a": keyboard], log: log))
    let generation = controller.setTarget(addresses: ["a"], shouldConnect: true)
    let failed = await controller.reconcile(generation: generation)
    #expect(failed.first?.success == false)
    #expect(failed.first?.detail.contains("0xE00002D6") == true)
    let release = controller.setTarget(addresses: ["a"], shouldConnect: false)
    let released = await controller.reconcile(generation: release)
    #expect(released.first?.success == true)
    #expect(log.values == ["open keyboard"])
  }

  @Test func unavailablePowerAndMissingPairingNeverAttemptConnection() async throws {
    for poweredOn in [false, true] {
      let log = CommandLog()
      let keyboard = FakeDeviceTransport("keyboard", log: log, paired: false)
      let controller = BluetoothController(
        backend: FakeBluetoothBackend(
          isPoweredOn: poweredOn, devices: ["a": keyboard], log: log))
      let generation = controller.setTarget(addresses: ["a"], shouldConnect: true)
      let result = await controller.reconcile(generation: generation)
      #expect(result.first?.success == false)
      #expect(result.first?.detail.contains(poweredOn ? "Not paired" : "off or not ready") == true)
      #expect(log.values.isEmpty)
    }
  }
}
