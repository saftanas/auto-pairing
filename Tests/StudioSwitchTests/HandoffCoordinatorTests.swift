import Foundation
import Testing

@testable import StudioSwitch

private final class FakeBluetooth: BluetoothOperating, @unchecked Sendable {
  struct Call: Sendable {
    let generation: UInt64
    let addresses: Set<String>
    let shouldConnect: Bool
  }
  private let lock = NSLock()
  private var targets: [Call] = []
  private var calls: [Call] = []
  typealias Response = @Sendable (Call) async -> [BluetoothOperationResult]
  private var storedResponse: Response?
  private var failures: Set<String> = []
  private var connectedAddresses: Set<String> = []

  var response: Response? {
    get { lock.withLock { storedResponse } }
    set { lock.withLock { storedResponse = newValue } }
  }

  func fail(addresses: Set<String>) { lock.withLock { failures = addresses } }
  func simulateConnection(to address: String) {
    lock.withLock { _ = connectedAddresses.insert(address) }
  }
  func isConnected(_ address: String) -> Bool {
    lock.withLock { connectedAddresses.contains(address) }
  }

  var history: [Call] { lock.withLock { calls } }
  var target: Call? { lock.withLock { targets.last } }
  func pairedDevices() async -> [BluetoothPeripheral] { [] }

  func setTarget(addresses: Set<String>, shouldConnect: Bool) -> UInt64 {
    lock.withLock {
      let generation = UInt64(targets.count + 1)
      targets.append(
        Call(generation: generation, addresses: addresses, shouldConnect: shouldConnect))
      return generation
    }
  }

  func reconcile(generation: UInt64) async -> [BluetoothOperationResult] {
    let call = lock.withLock { () -> Call in
      let call = targets.first { $0.generation == generation }!
      calls.append(call)
      return call
    }
    if let response { return await response(call) }
    return lock.withLock {
      call.addresses.sorted().map { address in
        let success = !failures.contains(address)
        if success {
          if call.shouldConnect {
            connectedAddresses.insert(address)
          } else {
            connectedAddresses.remove(address)
          }
        }
        return BluetoothOperationResult(
          address: address, name: address, success: success,
          detail: success ? "Verified" : "Device unavailable")
      }
    }
  }

  static func results(_ call: Call, success: Bool = true) -> [BluetoothOperationResult] {
    call.addresses.sorted().map {
      BluetoothOperationResult(
        address: $0, name: $0, success: success,
        detail: success ? "Verified" : "Device unavailable")
    }
  }
}

private actor Gate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var opened = false
  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuations.append($0) }
  }
  func open() {
    opened = true
    for continuation in continuations { continuation.resume() }
    continuations.removeAll()
  }
}

@MainActor
struct HandoffCoordinatorTests {
  private let addresses: Set<String> = ["keyboard", "trackpad"]

  private func makeCoordinator(
    _ bluetooth: FakeBluetooth, settle: Double = 0.001,
    budget: Double = 0.1, idleReleaseTimeout: Double = 8
  ) -> HandoffCoordinator {
    HandoffCoordinator(
      bluetooth: bluetooth,
      timing: HandoffTiming(
        settle: settle, retry: 0.001, acquisition: budget, release: budget,
        verification: 0.001, maintenance: 0.01, idleReleaseTimeout: idleReleaseTimeout))
  }

  private func eventually(
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    for _ in 0..<1_000 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    try #require(
      condition(), "Expected handoff state was not reached", sourceLocation: sourceLocation)
  }

  @Test func startupWithoutDisplayReleasesAndVerifiesTwice() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .waiting }
    #expect(bluetooth.history.count >= 2)
    #expect(bluetooth.history.allSatisfy { !$0.shouldConnect })
  }

  @Test func defaultAttachmentStartsAcquisitionWithoutASettlingWindow() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = HandoffCoordinator(bluetooth: bluetooth)
    defer { coordinator.stop() }
    coordinator.configure(addresses: addresses)
    coordinator.displayChanged(attached: true)
    // The observed notification wake lasted only 356 ms after attachment.
    // Production defaults must not intentionally spend that window settling.
    #expect(coordinator.status.phase == .acquiring)
    try await eventually { bluetooth.history.contains { $0.shouldConnect } }
  }

  @Test func sleepBeforeDetachReleasesDespiteStaleAttachedDisplay() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .connected }
    #expect(coordinator.keepSystemAwake)
    var acknowledgments = 0
    coordinator.prepareForSleep { acknowledgments += 1 }
    #expect(!coordinator.keepSystemAwake)
    #expect(bluetooth.target?.shouldConnect == false)
    #expect(acknowledgments == 0)
    try await eventually { acknowledgments == 1 }
    #expect(coordinator.status.phase == .sleeping)
    let releaseCalls = bluetooth.history.filter { !$0.shouldConnect }
    #expect(releaseCalls.count >= 2)
  }

  @Test func lateAttachDuringSleepCannotAcquire() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.configure(addresses: addresses)
    coordinator.prepareForSleep {}
    coordinator.displayChanged(attached: true)
    coordinator.retry()
    try await eventually { coordinator.status.phase == .sleeping }
    #expect(bluetooth.history.allSatisfy { !$0.shouldConnect })
    #expect(bluetooth.target?.shouldConnect == false)
  }

  @Test func wakeReacquiresWhenDisplayBooleanDidNotChange() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .connected }
    coordinator.prepareForSleep {}
    try await eventually { coordinator.status.phase == .sleeping }
    #expect(!coordinator.keepSystemAwake)
    let oldGeneration = bluetooth.target?.generation
    coordinator.didWake(attached: true)
    #expect(coordinator.keepSystemAwake)
    try await eventually { coordinator.status.phase == .connected }
    #expect(bluetooth.target?.generation != oldGeneration)
    #expect(bluetooth.target?.shouldConnect == true)
  }

  @Test func wakeWithoutDisplayNeverAcquires() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.configure(addresses: addresses)
    coordinator.prepareForSleep {}
    coordinator.didWake(attached: false)
    try await eventually { coordinator.status.phase == .waiting }
    #expect(bluetooth.history.allSatisfy { !$0.shouldConnect })
  }

  @Test func detachDuringSettleCancelsAcquisition() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth, settle: 0.1)
    defer { coordinator.stop() }
    coordinator.configure(addresses: addresses)
    coordinator.displayChanged(attached: true)
    coordinator.displayChanged(attached: false)
    try await eventually { coordinator.status.phase == .waiting }
    #expect(bluetooth.history.allSatisfy { !$0.shouldConnect })
  }

  @Test func staleConnectCompletionCannotOverwriteReleaseState() async throws {
    let gate = Gate()
    let bluetooth = FakeBluetooth()
    bluetooth.response = { call in
      if call.shouldConnect { await gate.wait() }
      return FakeBluetooth.results(call)
    }
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { bluetooth.history.contains { $0.shouldConnect } }
    coordinator.displayChanged(attached: false)
    #expect(bluetooth.target?.shouldConnect == false)
    await gate.open()
    try await eventually { coordinator.status.phase == .waiting }
    #expect(bluetooth.target?.shouldConnect == false)
  }

  @Test func partialFailureIsNotReportedAsConnectedAndRecoversLater() async throws {
    let bluetooth = FakeBluetooth()
    bluetooth.fail(addresses: ["trackpad"])
    let coordinator = makeCoordinator(bluetooth, budget: 0)
    defer { coordinator.stop() }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .needsAttention }
    #expect(coordinator.status.message.contains("trackpad"))
    #expect(bluetooth.isConnected("keyboard"))
    #expect(!bluetooth.isConnected("trackpad"))
    bluetooth.fail(addresses: [])
    try await eventually { coordinator.status.phase == .connected }
    #expect(bluetooth.isConnected("trackpad"))
  }

  @Test func failedSleepReleaseAcknowledgesWithoutClaimingSuccess() async throws {
    let bluetooth = FakeBluetooth()
    bluetooth.response = { FakeBluetooth.results($0, success: false) }
    let coordinator = makeCoordinator(bluetooth, budget: 0)
    defer { coordinator.stop() }
    coordinator.configure(addresses: addresses)
    var acknowledgments = 0
    coordinator.prepareForSleep { acknowledgments += 1 }
    try await eventually { acknowledgments == 1 }
    #expect(coordinator.status.phase == .needsAttention)
    #expect(coordinator.status.message.contains("Release incomplete"))
    coordinator.stop()
    #expect(acknowledgments == 1)
  }

  @Test func unconfiguredSleepAcknowledgesImmediately() {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    var acknowledgments = 0
    coordinator.prepareForSleep { acknowledgments += 1 }
    #expect(acknowledgments == 1)
    #expect(bluetooth.history.isEmpty)
  }

  @Test func inactiveMacReleasesAnUnsolicitedReconnection() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .waiting }
    let previousCalls = bluetooth.history.count
    bluetooth.simulateConnection(to: "trackpad")
    #expect(bluetooth.isConnected("trackpad"))
    try await eventually { !bluetooth.isConnected("trackpad") }
    #expect(bluetooth.history.count > previousCalls)
    #expect(bluetooth.history.allSatisfy { !$0.shouldConnect })
  }

  @Test func changingSelectionInvalidatesAnInFlightAcquisition() async throws {
    let gate = Gate()
    let bluetooth = FakeBluetooth()
    bluetooth.response = { call in
      if call.addresses.contains("trackpad") { await gate.wait() }
      return FakeBluetooth.results(call)
    }
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { bluetooth.history.contains { $0.addresses == addresses } }
    let oldGeneration = bluetooth.target?.generation
    coordinator.configure(addresses: ["keyboard"])
    #expect(bluetooth.target?.generation != oldGeneration)
    #expect(bluetooth.target?.addresses == ["keyboard"])
    await gate.open()
    try await eventually { coordinator.status.phase == .connected }
    #expect(bluetooth.target?.addresses == ["keyboard"])
  }

  @Test func repeatedSleepCallbacksAreEachAcknowledgedOnce() async throws {
    let gate = Gate()
    let bluetooth = FakeBluetooth()
    bluetooth.response = { call in
      await gate.wait()
      return FakeBluetooth.results(call)
    }
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    coordinator.configure(addresses: addresses)
    var firstAcknowledgments = 0
    var secondAcknowledgments = 0
    coordinator.prepareForSleep { firstAcknowledgments += 1 }
    try await eventually { !bluetooth.history.isEmpty }
    coordinator.prepareForSleep { secondAcknowledgments += 1 }
    #expect(firstAcknowledgments == 0)
    #expect(secondAcknowledgments == 0)
    await gate.open()
    try await eventually { firstAcknowledgments == 1 && secondAcknowledgments == 1 }
    #expect(coordinator.status.phase == .sleeping)
    coordinator.stop()
    #expect(firstAcknowledgments == 1)
    #expect(secondAcknowledgments == 1)
  }

  @Test func attachedDisplayKeepsSystemAwakeWithoutSelectedDevicesOrScreenChanges() {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer { coordinator.stop() }
    var holds: [Bool] = []
    coordinator.onKeepSystemAwakeChange = { holds.append($0) }

    coordinator.displayChanged(attached: true)
    #expect(coordinator.keepSystemAwake)
    #expect(coordinator.status.phase == .unconfigured)
    coordinator.displayChanged(attached: true)
    coordinator.retry()
    #expect(coordinator.keepSystemAwake)
    #expect(holds == [true])
    #expect(bluetooth.history.isEmpty)

    coordinator.stop()
    #expect(!coordinator.keepSystemAwake)
    #expect(holds == [true, false])
  }

  @Test func detachKeepsIdleSleepHoldUntilBothReleaseSamplesAreVerified() async throws {
    let gate = Gate()
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth)
    defer {
      coordinator.stop()
      Task { await gate.open() }
    }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .connected }
    bluetooth.response = { call in
      if !call.shouldConnect,
        bluetooth.history.filter({ !$0.shouldConnect }).count >= 2
      {
        await gate.wait()
      }
      return FakeBluetooth.results(call)
    }

    coordinator.displayChanged(attached: false)
    #expect(coordinator.keepSystemAwake)
    try await eventually { bluetooth.history.filter { !$0.shouldConnect }.count >= 2 }
    #expect(coordinator.keepSystemAwake)
    await gate.open()
    try await eventually { coordinator.status.phase == .waiting }
    #expect(!coordinator.keepSystemAwake)
  }

  @Test func failedReleaseDropsIdleSleepHoldAtReleaseDeadline() async throws {
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth, budget: 0)
    defer { coordinator.stop() }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .connected }
    bluetooth.fail(addresses: addresses)

    coordinator.displayChanged(attached: false)
    #expect(coordinator.keepSystemAwake)
    try await eventually { coordinator.status.phase == .needsAttention }
    #expect(!coordinator.keepSystemAwake)
  }

  @Test func stalledReleaseCannotHoldIdleSleepPastWatchdog() async throws {
    let gate = Gate()
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth, idleReleaseTimeout: 0.02)
    defer {
      coordinator.stop()
      Task { await gate.open() }
    }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .connected }
    bluetooth.response = { call in
      if !call.shouldConnect { await gate.wait() }
      return FakeBluetooth.results(call)
    }

    coordinator.displayChanged(attached: false)
    #expect(coordinator.keepSystemAwake)
    try await eventually { !coordinator.keepSystemAwake }
    #expect(coordinator.status.phase == .needsAttention)
    #expect(coordinator.status.message.contains("release is still pending"))
  }

  @Test func quickReattachCancelsOldReleaseWatchdogAndKeepsNewHold() async throws {
    let gate = Gate()
    let bluetooth = FakeBluetooth()
    let coordinator = makeCoordinator(bluetooth, idleReleaseTimeout: 0.02)
    defer {
      coordinator.stop()
      Task { await gate.open() }
    }
    coordinator.displayChanged(attached: true)
    coordinator.configure(addresses: addresses)
    try await eventually { coordinator.status.phase == .connected }
    bluetooth.response = { call in
      if !call.shouldConnect { await gate.wait() }
      return FakeBluetooth.results(call)
    }

    coordinator.displayChanged(attached: false)
    try await eventually { bluetooth.history.contains { !$0.shouldConnect } }
    coordinator.displayChanged(attached: true)
    try await eventually { coordinator.status.phase == .connected }
    try await Task.sleep(nanoseconds: 40_000_000)
    #expect(coordinator.keepSystemAwake)
    await gate.open()
    try await Task.sleep(nanoseconds: 5_000_000)
    #expect(coordinator.keepSystemAwake)
    #expect(coordinator.status.phase == .connected)
  }
}
