import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

private let powerLogger = Logger(subsystem: "com.saftanas.studioswitch", category: "Power")

// IOMessage.h's function-like macros are not imported into Swift. These are
// their public values: iokit_common_msg(code) = 0xe0000000 | code.
private enum PowerMessage {
  static let canSleep: natural_t = 0xe000_0270
  static let willSleep: natural_t = 0xe000_0280
  static let willNotSleep: natural_t = 0xe000_0290
  static let hasPoweredOn: natural_t = 0xe000_0300
}

private func systemPowerCallback(
  _ context: UnsafeMutableRawPointer?,
  _ service: io_service_t,
  _ messageType: natural_t,
  _ messageArgument: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
  // The notification source is installed exclusively on the main run loop.
  MainActor.assumeIsolated {
    monitor.receive(messageType, token: Int(bitPattern: messageArgument))
  }
}

/// Owns a single kernel sleep token. The watchdog runs independently of the UI
/// and Bluetooth work, so an unresponsive device cannot delay sleep indefinitely.
final class SleepAcknowledgment: @unchecked Sendable {
  private let lock = NSLock()
  private let timeout: TimeInterval
  private let acknowledge: @Sendable () -> IOReturn
  private var finished = false
  private var watchdog: DispatchWorkItem?
  private let started = ProcessInfo.processInfo.systemUptime

  convenience init(connection: io_connect_t, token: Int) {
    self.init {
      IOAllowPowerChange(connection, token)
    }
  }

  init(timeout: TimeInterval = 8, acknowledge: @escaping @Sendable () -> IOReturn) {
    self.timeout = timeout
    self.acknowledge = acknowledge
  }

  func scheduleWatchdog() {
    let work = DispatchWorkItem { [weak self] in
      self?.allowSleep(timedOut: true)
    }
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    watchdog = work
    lock.unlock()
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: work)
  }

  func allowSleep(timedOut: Bool = false) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    finished = true
    watchdog?.cancel()
    watchdog = nil
    if timedOut {
      powerLogger.error(
        "Pre-sleep release exceeded \(self.timeout) seconds; allowing sleep without verified release"
      )
    }
    // Keep the call inside the lock: stop() must not close connection while a
    // concurrent watchdog is still acknowledging this token.
    let result = acknowledge()
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    powerLogger.info("Sleep acknowledgment after \(elapsed) seconds; result \(result)")
    if result != kIOReturnSuccess {
      powerLogger.error("Could not acknowledge sleep: \(result)")
    }
  }

  func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    finished = true
    watchdog?.cancel()
    watchdog = nil
  }
}

/// Releases devices while macOS is still executing user code, then allows
/// sleep. This cannot run during sleep or veto a forced clamshell sleep.
@MainActor
final class PowerMonitor {
  var onWillSleep: ((@escaping () -> Void) -> Void)?
  /// true for a completed system resume; false for a canceled sleep request.
  var onDidWake: ((Bool) -> Void)?

  private var connection: io_connect_t = 0
  private var notificationPort: IONotificationPortRef?
  private var notifier: io_object_t = 0
  private var runLoopSource: CFRunLoopSource?
  private var pending: [UUID: SleepAcknowledgment] = [:]

  @discardableResult
  func start() -> Bool {
    guard connection == 0 else { return true }
    connection = IORegisterForSystemPower(
      Unmanaged.passUnretained(self).toOpaque(),
      &notificationPort,
      systemPowerCallback,
      &notifier
    )
    guard connection != 0,
      let notificationPort,
      let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue()
    else {
      powerLogger.error("Could not register for system sleep and wake notifications")
      stop()
      return false
    }
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    powerLogger.info("Registered system sleep and wake monitoring")
    return true
  }

  /// Call before releasing the monitor. Its C callback holds an unretained
  /// reference for the lifetime of the registered notification source.
  func stop() {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      self.runLoopSource = nil
    }
    for acknowledgment in pending.values { acknowledgment.allowSleep() }
    pending.removeAll()
    if notifier != 0 {
      IODeregisterForSystemPower(&notifier)
      notifier = 0
    }
    if connection != 0 {
      IOServiceClose(connection)
      connection = 0
    }
    if let notificationPort {
      IONotificationPortDestroy(notificationPort)
      self.notificationPort = nil
    }
  }

  fileprivate func receive(_ messageType: natural_t, token: Int) {
    switch messageType {
    case PowerMessage.canSleep:
      // The actual release belongs to WillSleep. An idle sleep request can be
      // vetoed by another process, and should never disconnect input early.
      IOAllowPowerChange(connection, token)

    case PowerMessage.willSleep:
      powerLogger.info("Received SystemWillSleep")
      let id = UUID()
      let acknowledgment = SleepAcknowledgment(connection: connection, token: token)
      pending[id] = acknowledgment
      acknowledgment.scheduleWatchdog()
      guard let onWillSleep else {
        acknowledgment.allowSleep()
        pending.removeValue(forKey: id)
        return
      }
      onWillSleep { [weak self, acknowledgment] in
        acknowledgment.allowSleep()
        Task { @MainActor [weak self] in
          self?.pending.removeValue(forKey: id)
        }
      }

    case PowerMessage.hasPoweredOn, PowerMessage.willNotSleep:
      powerLogger.info(
        "Received \(messageType == PowerMessage.hasPoweredOn ? "SystemHasPoweredOn" : "SystemWillNotSleep", privacy: .public)"
      )
      // Never acknowledge a wake message, nor a stale token after the system
      // has already completed the sleep epoch (for example after a long stall).
      for acknowledgment in pending.values { acknowledgment.invalidate() }
      pending.removeAll()
      onDidWake?(messageType == PowerMessage.hasPoweredOn)

    default:
      // WillPowerOn is too early: drivers and hardware may still be asleep.
      break
    }
  }
}
