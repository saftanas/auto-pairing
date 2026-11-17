import Foundation
import IOKit
import Testing

@testable import StudioSwitch

struct PowerMonitorTests {
  @Test
  func testRepeatedReleaseAndWatchdogCompletionsAcknowledgeOnlyOnce() {
    let calls = RecordedCalls()
    let acknowledgment = SleepAcknowledgment {
      calls.record("ack")
      return kIOReturnSuccess
    }

    acknowledgment.allowSleep()
    acknowledgment.allowSleep()
    acknowledgment.allowSleep(timedOut: true)

    #expect(calls.values == ["ack"])
  }

  @Test
  func testWatchdogAllowsSleepWhenReleaseNeverCompletes() {
    let acknowledged = DispatchSemaphore(value: 0)
    let calls = RecordedCalls()
    let acknowledgment = SleepAcknowledgment(timeout: 0.01) {
      calls.record("ack")
      acknowledged.signal()
      return kIOReturnSuccess
    }

    acknowledgment.scheduleWatchdog()
    #expect(acknowledged.wait(timeout: .now() + 2) == .success)
    acknowledgment.allowSleep()  // A late Bluetooth completion must be harmless.

    #expect(calls.values == ["ack"])
  }

  @Test
  func testCompletionWatchdogAndStopRaceAcknowledgeOnlyOnce() {
    let calls = RecordedCalls()
    let acknowledgment = SleepAcknowledgment(timeout: 0) {
      calls.record("ack")
      return kIOReturnSuccess
    }

    acknowledgment.scheduleWatchdog()
    DispatchQueue.concurrentPerform(iterations: 100) { index in
      // Both a release completion and stop() use allowSleep(); a watchdog uses
      // the same operation with timedOut set. Exercise all of them concurrently.
      acknowledgment.allowSleep(timedOut: index.isMultiple(of: 3))
    }

    #expect(calls.values == ["ack"])
  }

  @Test
  func testWakeInvalidationSuppressesScheduledAndLateAcknowledgments() {
    let deadlinePassed = DispatchSemaphore(value: 0)
    let calls = RecordedCalls()
    let acknowledgment = SleepAcknowledgment(timeout: 0.01) {
      calls.record("ack")
      return kIOReturnSuccess
    }

    acknowledgment.scheduleWatchdog()
    acknowledgment.invalidate()
    acknowledgment.allowSleep()
    acknowledgment.allowSleep(timedOut: true)
    acknowledgment.scheduleWatchdog()  // A finished token must stay finished.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
      deadlinePassed.signal()
    }
    #expect(deadlinePassed.wait(timeout: .now() + 2) == .success)

    #expect(calls.values.isEmpty)
  }

  @Test
  func testStopStyleAcknowledgmentWaitsForInflightKernelCall() {
    let entered = DispatchSemaphore(value: 0)
    let stopStarted = DispatchSemaphore(value: 0)
    let completed = DispatchGroup()
    let releaseKernelCall = DispatchSemaphore(value: 0)
    let calls = RecordedCalls()
    let acknowledgment = SleepAcknowledgment {
      calls.record("ack started")
      entered.signal()
      _ = releaseKernelCall.wait(timeout: .now() + 2)
      calls.record("ack finished")
      return kIOReturnSuccess
    }

    completed.enter()
    DispatchQueue.global().async {
      acknowledgment.allowSleep(timedOut: true)
      completed.leave()
    }
    #expect(entered.wait(timeout: .now() + 2) == .success)
    completed.enter()
    DispatchQueue.global().async {
      stopStarted.signal()
      acknowledgment.allowSleep()
      calls.record("stop can close connection")
      completed.leave()
    }
    #expect(stopStarted.wait(timeout: .now() + 2) == .success)
    releaseKernelCall.signal()
    #expect(completed.wait(timeout: .now() + 2) == .success)

    #expect(calls.values == ["ack started", "ack finished", "stop can close connection"])
  }

  @Test
  func testInvalidationWaitsForInflightAcknowledgment() {
    let entered = DispatchSemaphore(value: 0)
    let invalidationStarted = DispatchSemaphore(value: 0)
    let completed = DispatchGroup()
    let releaseKernelCall = DispatchSemaphore(value: 0)
    let calls = RecordedCalls()
    let acknowledgment = SleepAcknowledgment {
      entered.signal()
      _ = releaseKernelCall.wait(timeout: .now() + 2)
      calls.record("ack finished")
      return kIOReturnSuccess
    }

    completed.enter()
    DispatchQueue.global().async {
      acknowledgment.allowSleep()
      completed.leave()
    }
    #expect(entered.wait(timeout: .now() + 2) == .success)
    completed.enter()
    DispatchQueue.global().async {
      invalidationStarted.signal()
      acknowledgment.invalidate()
      calls.record("invalidated")
      completed.leave()
    }
    #expect(invalidationStarted.wait(timeout: .now() + 2) == .success)
    releaseKernelCall.signal()
    #expect(completed.wait(timeout: .now() + 2) == .success)
    acknowledgment.allowSleep(timedOut: true)

    #expect(calls.values == ["ack finished", "invalidated"])
  }
}

private final class RecordedCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func record(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(value)
  }
}
