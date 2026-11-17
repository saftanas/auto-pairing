import Foundation
import IOKit
import IOKit.pwr_mgt
import Testing

@testable import StudioSwitch

struct DisplayWakePolicyTests {
  @Test func launchingWithAnAttachedDisplayDoesNotInventAnEdge() {
    var policy = DisplayWakePolicy()
    let initial = policy.observe(true, isSleeping: false)
    let repeated = policy.observe(true, isSleeping: false)
    #expect(!initial)
    #expect(!repeated)
  }

  @Test func anAttachmentRequestsExactlyOnce() {
    var policy = DisplayWakePolicy()
    let absent = policy.observe(false, isSleeping: false)
    let attached = policy.observe(true, isSleeping: false)
    let repeated = policy.observe(true, isSleeping: false)
    #expect(!absent)
    #expect(attached)
    #expect(!repeated)
  }

  @Test func failedQueriesCannotInventAnAttachment() {
    var policy = DisplayWakePolicy()
    _ = policy.observe(true, isSleeping: false)
    let unknown = policy.observe(nil, isSleeping: false)
    let recovered = policy.observe(true, isSleeping: false)
    #expect(!unknown)
    #expect(!recovered)
    #expect(policy.lastConfirmedPresence == true)
  }

  @Test func attachmentDuringSleepWaitsForConfirmedPresenceAfterWake() {
    var policy = DisplayWakePolicy()
    _ = policy.observe(false, isSleeping: false)
    let sleeping = policy.observe(true, isSleeping: true)
    let unknownAfterWake = policy.observe(nil, isSleeping: false)
    #expect(!sleeping)
    #expect(!unknownAfterWake)
    #expect(policy.attachmentPending)
    let confirmedAfterWake = policy.observe(true, isSleeping: false)
    let repeated = policy.observe(true, isSleeping: false)
    #expect(confirmedAfterWake)
    #expect(!repeated)
    #expect(!policy.attachmentPending)
  }

  @Test func detachmentDuringSleepCancelsTheDeferredRequest() {
    var policy = DisplayWakePolicy()
    _ = policy.observe(false, isSleeping: false)
    _ = policy.observe(true, isSleeping: true)
    let detached = policy.observe(false, isSleeping: true)
    let wokeWithoutDisplay = policy.observe(false, isSleeping: false)
    #expect(!detached)
    #expect(!wokeWithoutDisplay)
    #expect(!policy.attachmentPending)
  }

  @Test func screenSleepWithTheSameDisplayDoesNotRequestActivity() {
    var policy = DisplayWakePolicy()
    _ = policy.observe(false, isSleeping: false)
    _ = policy.observe(true, isSleeping: false)
    let sleeping = policy.observe(true, isSleeping: false)
    let woke = policy.observe(true, isSleeping: false)
    #expect(!sleeping)
    #expect(!woke)
  }

  @Test func actualSystemResumeRequestsOnceWithUnchangedDisplayPresence() {
    var policy = DisplayWakePolicy()
    _ = policy.observe(true, isSleeping: false)
    policy.prepareForSleep()
    policy.didWake(actualResume: true)
    let resumed = policy.observe(true, isSleeping: false)
    let repeated = policy.observe(true, isSleeping: false)
    policy.didWake(actualResume: true)
    let duplicateResume = policy.observe(true, isSleeping: false)
    #expect(resumed)
    #expect(!repeated)
    #expect(!duplicateResume)
  }

  @Test func canceledSleepDoesNotRequestOrLeaveResumeEligibility() {
    var policy = DisplayWakePolicy()
    _ = policy.observe(true, isSleeping: false)
    policy.prepareForSleep()
    policy.didWake(actualResume: false)
    let canceled = policy.observe(true, isSleeping: false)
    policy.didWake(actualResume: true)
    let unarmedResume = policy.observe(true, isSleeping: false)
    #expect(!canceled)
    #expect(!unarmedResume)
  }

  @Test func unknownResumePresenceDefersUntilConfirmed() {
    var policy = DisplayWakePolicy()
    _ = policy.observe(true, isSleeping: false)
    policy.prepareForSleep()
    policy.didWake(actualResume: true)
    let unknown = policy.observe(nil, isSleeping: false)
    #expect(!unknown)
    #expect(policy.resumePending)
    let confirmed = policy.observe(true, isSleeping: false)
    #expect(confirmed)
    #expect(!policy.resumePending)
  }

  @Test func resumingWithoutDisplayCancelsResumeRequest() {
    var policy = DisplayWakePolicy()
    _ = policy.observe(true, isSleeping: false)
    policy.prepareForSleep()
    policy.didWake(actualResume: true)
    let absent = policy.observe(false, isSleeping: false)
    let unknown = policy.observe(nil, isSleeping: false)
    #expect(!absent)
    #expect(!unknown)
    #expect(!policy.resumePending)
  }
}

@MainActor
struct DisplayWakeRequestTests {
  @Test func failureDoesNotRetryOnPollOrOrdinaryWake() {
    let operations = FakeDisplayActivity(statuses: [kIOReturnError, kIOReturnSuccess])
    let request = operations.makeRequest()
    defer { request.stop() }
    request.observePresence(false, isSleeping: false)
    request.observePresence(true, isSleeping: false)
    request.observePresence(true, isSleeping: false)
    request.observePresence(nil, isSleeping: false)
    request.didWake(presence: true, actualResume: false)
    #expect(operations.requestCount == 1)
    #expect(request.lastError != nil)

    request.observePresence(false, isSleeping: false)
    request.observePresence(true, isSleeping: false)
    #expect(operations.requestCount == 2)
    #expect(request.lastError == nil)
  }

  @Test func sleepReleasesActivityAndActualResumeRequestsOnce() {
    let operations = FakeDisplayActivity()
    let request = operations.makeRequest()
    defer { request.stop() }
    request.observePresence(false, isSleeping: false)
    request.observePresence(true, isSleeping: false)
    request.prepareForSleep()
    request.observePresence(true, isSleeping: true)
    #expect(operations.requestCount == 1)
    #expect(operations.releasedIDs == [42])
    request.didWake(presence: true, actualResume: true)
    request.didWake(presence: true, actualResume: true)
    #expect(operations.requestCount == 2)
  }

  @Test func deferredAttachmentRequestsOnlyAfterWake() {
    let operations = FakeDisplayActivity()
    let request = operations.makeRequest()
    defer { request.stop() }
    request.observePresence(false, isSleeping: false)
    request.prepareForSleep()
    request.observePresence(true, isSleeping: true)
    #expect(operations.requestCount == 0)
    request.didWake(presence: nil, actualResume: true)
    #expect(operations.requestCount == 0)
    request.observePresence(true, isSleeping: false)
    request.didWake(presence: true, actualResume: true)
    #expect(operations.requestCount == 1)
  }

  @Test func detachAndStopReleaseActivityOnce() {
    let operations = FakeDisplayActivity()
    let request = operations.makeRequest()
    request.observePresence(false, isSleeping: false)
    request.observePresence(true, isSleeping: false)
    request.observePresence(false, isSleeping: false)
    request.stop()
    #expect(operations.releasedIDs == [42])
  }

  @Test func changingConfigurationStartsANewBaseline() {
    let operations = FakeDisplayActivity()
    let request = operations.makeRequest()
    defer { request.stop() }
    request.observePresence(false, isSleeping: false)
    request.reset()
    request.observePresence(true, isSleeping: false)
    #expect(operations.requestCount == 0)
  }
}

private final class FakeDisplayActivity: @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [IOReturn]
  private var requests = 0
  private var releases: [IOPMAssertionID] = []

  init(statuses: [IOReturn] = []) { self.statuses = statuses }

  var requestCount: Int { lock.withLock { requests } }
  var releasedIDs: [IOPMAssertionID] { lock.withLock { releases } }

  @MainActor
  func makeRequest() -> DisplayWakeRequest {
    DisplayWakeRequest(
      declare: { _ in
        self.lock.withLock {
          self.requests += 1
          let status = self.statuses.isEmpty ? kIOReturnSuccess : self.statuses.removeFirst()
          return (status, status == kIOReturnSuccess ? 42 : IOPMAssertionID(kIOPMNullAssertionID))
        }
      },
      release: { id in
        self.lock.withLock { self.releases.append(id) }
        return kIOReturnSuccess
      })
  }
}
