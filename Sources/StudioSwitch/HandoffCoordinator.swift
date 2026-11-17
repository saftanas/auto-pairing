import Foundation
import OSLog

enum HandoffPhase: Equatable {
  case unconfigured, waiting, settling, acquiring, connected, releasing, sleeping, needsAttention
}

struct HandoffStatus {
  let phase: HandoffPhase
  let message: String
  var isSwitching: Bool { [.settling, .acquiring, .releasing].contains(phase) }
}

struct HandoffTiming {
  // Cable attachment can give us only a short notification-wake window.
  // Attempt immediately; Bluetooth readiness is handled by retries.
  var settle: TimeInterval = 0
  var retry: TimeInterval = 0.65
  var acquisition: TimeInterval = 45
  var release: TimeInterval = 5
  var verification: TimeInterval = 0.2
  var maintenance: TimeInterval = 3
  var idleReleaseTimeout: TimeInterval = 8
}

/// Owns intent, independently of display-notification ordering. Bluetooth work is
/// fenced synchronously before an old asynchronous operation can complete.
@MainActor
final class HandoffCoordinator {
  var onChange: ((HandoffStatus) -> Void)?
  var onKeepSystemAwakeChange: ((Bool) -> Void)?
  private(set) var status = HandoffStatus(
    phase: .unconfigured, message: "Choose your keyboard and trackpad")
  private(set) var isSleeping = false
  private(set) var keepSystemAwake = false

  private let bluetooth: BluetoothOperating
  private let timing: HandoffTiming
  private let logger = Logger(subsystem: "com.saftanas.studioswitch", category: "handoff")
  private var addresses: Set<String> = []
  private var attached = false
  private var epoch: UInt64 = 0
  private var task: Task<Void, Never>?
  private var idleReleaseTask: Task<Void, Never>?
  private var idleReleaseEpoch: UInt64 = 0
  private var sleepCompletions: [() -> Void] = []

  init(bluetooth: BluetoothOperating, timing: HandoffTiming = HandoffTiming()) {
    self.bluetooth = bluetooth
    self.timing = timing
  }

  func configure(addresses: Set<String>) {
    guard addresses != self.addresses else { return }
    self.addresses = addresses
    reconcile()
  }

  func displayChanged(attached: Bool) {
    guard attached != self.attached else { return }
    logger.info("Display attachment changed: \(attached)")
    self.attached = attached
    // A late screen callback must never restart acquisition during forced sleep.
    guard !isSleeping else { return }
    reconcile()
  }

  func retry() {
    guard !isSleeping else { return }
    reconcile()
  }

  func prepareForSleep(completion: @escaping () -> Void) {
    logger.info("Preparing for system sleep; display attached: \(self.attached)")
    isSleeping = true
    sleepCompletions.append(completion)
    // Release even if the unplug callback has not arrived (or never arrives).
    reconcile()
  }

  func didWake(attached: Bool) {
    logger.info("System wake reconciliation; display attached: \(attached)")
    finishSleep()
    isSleeping = false
    self.attached = attached
    // Unconditional: the display may have stayed attached throughout sleep.
    reconcile()
  }

  func stop() {
    epoch &+= 1
    task?.cancel()
    task = nil
    _ = bluetooth.setTarget(addresses: addresses, shouldConnect: false)
    releaseIdleSleepHold()
    finishSleep()
  }

  private func reconcile() {
    epoch &+= 1
    let currentEpoch = epoch
    let shouldConnect = attached && !isSleeping
    // setTarget is synchronous, so cancellation is not the safety boundary.
    let generation = bluetooth.setTarget(addresses: addresses, shouldConnect: shouldConnect)
    task?.cancel()
    task = nil
    updateIdleSleepHold(shouldConnect: shouldConnect)

    guard !addresses.isEmpty else {
      if !shouldConnect { releaseIdleSleepHold() }
      publish(
        isSleeping ? .sleeping : .unconfigured,
        isSleeping ? "Sleeping — no peripherals selected" : "Choose your keyboard and trackpad")
      finishSleep()
      return
    }

    if shouldConnect {
      publish(
        timing.settle > 0 ? .settling : .acquiring,
        timing.settle > 0
          ? "Waiting for the display and Bluetooth to settle…"
          : "Requesting keyboard and trackpad connections…")
    } else {
      publish(.releasing, "Releasing peripherals before sleep or standby…")
    }
    task = Task { [weak self] in
      await self?.run(generation: generation, epoch: currentEpoch, shouldConnect: shouldConnect)
    }
  }

  private func run(generation: UInt64, epoch: UInt64, shouldConnect: Bool) async {
    if shouldConnect {
      if timing.settle > 0 {
        guard await pause(timing.settle), isCurrent(epoch) else { return }
      }
      guard isCurrent(epoch) else { return }
      publish(.acquiring, "Requesting keyboard and trackpad connections…")
    }
    var deadline =
      ProcessInfo.processInfo.systemUptime + (shouldConnect ? timing.acquisition : timing.release)
    var verifiedRelease = false
    var wasComplete = false
    while isCurrent(epoch) {
      let results = await bluetooth.reconcile(generation: generation)
      guard isCurrent(epoch) else { return }
      let complete = results.count == addresses.count && results.allSatisfy(\.success)

      if complete {
        if !shouldConnect && !verifiedRelease {
          // A close request succeeding is not proof of release. Require a second
          // observed disconnected sample, including during the pre-sleep window.
          verifiedRelease = true
          guard await pause(timing.verification) else { return }
          continue
        }
        if isSleeping {
          publish(.sleeping, "Peripherals released; allowing sleep")
          finishSleep()
          return
        }
        if !shouldConnect { releaseIdleSleepHold() }
        publish(
          shouldConnect ? .connected : .waiting,
          shouldConnect
            ? "Bluetooth links connected — check typing and gestures"
            : "Peripherals released; waiting for Studio Display")
        wasComplete = true
        // Reconcile while awake: a peripheral or macOS may reconnect on its own,
        // and a temporarily unavailable destination may become ready later.
        guard await pause(timing.maintenance) else { return }
      } else {
        if wasComplete {
          deadline =
            ProcessInfo.processInfo.systemUptime
            + (shouldConnect ? timing.acquisition : timing.release)
          wasComplete = false
        }
        verifiedRelease = false
        let failures = results.filter { !$0.success }.map { "\($0.name): \($0.detail)" }.joined(
          separator: "; ")
        let detail = failures.isEmpty ? "Connection state unavailable" : failures
        if ProcessInfo.processInfo.systemUptime >= deadline {
          if !shouldConnect { releaseIdleSleepHold() }
          publish(
            .needsAttention, "\(shouldConnect ? "Connection" : "Release") incomplete. \(detail)")
          if isSleeping {
            // PowerMonitor also has an independent watchdog for a stuck OS call.
            // Never hold sleep indefinitely or describe a failed release as success.
            finishSleep()
            return
          }
          guard await pause(timing.maintenance) else { return }
        } else {
          publish(
            shouldConnect ? .acquiring : .releasing,
            "\(shouldConnect ? "Connecting" : "Releasing")… \(detail)")
          guard await pause(timing.retry) else { return }
        }
      }
    }
  }

  private func isCurrent(_ value: UInt64) -> Bool {
    !Task.isCancelled && value == epoch
  }

  private func updateIdleSleepHold(shouldConnect: Bool) {
    if shouldConnect {
      cancelIdleReleaseWatchdog()
      setKeepSystemAwake(true)
    } else if isSleeping {
      // This assertion only prevents idle sleep. Never hold it to oppose a real
      // system sleep request; PowerMonitor separately bounds pre-sleep release.
      releaseIdleSleepHold()
    } else if keepSystemAwake && idleReleaseTask == nil {
      // Preserve the existing hold during detach cleanup, but do not acquire a
      // new hold on a Mac without the display. Retries must not extend this cap.
      idleReleaseEpoch &+= 1
      let watchdogEpoch = idleReleaseEpoch
      let timeout = timing.idleReleaseTimeout
      idleReleaseTask = Task { [weak self] in
        do {
          try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        } catch { return }
        guard !Task.isCancelled, let self,
          self.idleReleaseEpoch == watchdogEpoch, !self.attached, !self.isSleeping
        else { return }
        self.releaseIdleSleepHold()
        self.publish(.needsAttention, "Idle sleep allowed; peripheral release is still pending")
      }
    }
  }

  private func releaseIdleSleepHold() {
    cancelIdleReleaseWatchdog()
    setKeepSystemAwake(false)
  }

  private func cancelIdleReleaseWatchdog() {
    idleReleaseEpoch &+= 1
    idleReleaseTask?.cancel()
    idleReleaseTask = nil
  }

  private func setKeepSystemAwake(_ value: Bool) {
    guard value != keepSystemAwake else { return }
    keepSystemAwake = value
    onKeepSystemAwakeChange?(value)
  }

  private func pause(_ seconds: TimeInterval) async -> Bool {
    do {
      try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      return !Task.isCancelled
    } catch { return false }
  }

  private func finishSleep() {
    let completions = sleepCompletions
    sleepCompletions.removeAll()
    for completion in completions { completion() }
  }

  private func publish(_ phase: HandoffPhase, _ message: String) {
    guard status.phase != phase || status.message != message else { return }
    status = HandoffStatus(phase: phase, message: message)
    logger.info("\(message, privacy: .public)")
    onChange?(status)
  }
}
