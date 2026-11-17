import Foundation
import IOKit
import IOKit.pwr_mgt
import Testing

@testable import StudioSwitch

@MainActor
struct IdleSleepGuardTests {
  @Test
  func repeatedRequirementsCreateAndReleaseOneAssertion() {
    let operations = FakeIdleAssertions()
    let guardState = operations.makeGuard()

    #expect(guardState.setRequired(false))
    #expect(operations.createdCount == 0)
    #expect(guardState.setRequired(true))
    #expect(guardState.setRequired(true))
    #expect(guardState.isActive)
    #expect(operations.createdCount == 1)

    #expect(guardState.setRequired(false))
    #expect(guardState.setRequired(false))
    #expect(!guardState.isActive)
    #expect(guardState.lastError == nil)
    #expect(operations.releasedIDs == [42])
  }

  @Test
  func failedCreationIsReportedAndRetried() {
    let operations = FakeIdleAssertions(createStatuses: [kIOReturnError, kIOReturnSuccess])
    let guardState = operations.makeGuard()

    #expect(!guardState.setRequired(true))
    #expect(!guardState.isActive)
    #expect(guardState.lastError != nil)
    #expect(operations.releasedIDs.isEmpty)

    #expect(guardState.setRequired(true))
    #expect(guardState.isActive)
    #expect(guardState.lastError == nil)
    #expect(operations.createdCount == 2)
    #expect(guardState.stop())
    #expect(operations.releasedIDs == [42])
  }

  @Test
  func failedReleaseRetainsAssertionForRetry() {
    let operations = FakeIdleAssertions(releaseStatuses: [kIOReturnError, kIOReturnSuccess])
    let guardState = operations.makeGuard()
    #expect(guardState.setRequired(true))

    #expect(!guardState.stop())
    #expect(guardState.isActive)
    #expect(guardState.lastError != nil)

    #expect(guardState.stop())
    #expect(!guardState.isActive)
    #expect(guardState.lastError == nil)
    #expect(operations.releasedIDs == [42, 42])
  }

  @Test
  func explicitStopDoesNotReleaseAgainDuringDeinitialization() {
    let operations = FakeIdleAssertions()
    var guardState: IdleSleepGuard? = operations.makeGuard()
    #expect(guardState?.setRequired(true) == true)
    #expect(guardState?.stop() == true)
    #expect(guardState?.stop() == true)

    guardState = nil

    #expect(operations.releasedIDs == [42])
  }

  @Test
  func deinitializationReleasesActiveAssertion() {
    let operations = FakeIdleAssertions()
    var guardState: IdleSleepGuard? = operations.makeGuard()
    #expect(guardState?.setRequired(true) == true)

    guardState = nil

    #expect(operations.releasedIDs == [42])
  }

  @Test
  func guardCanBeReacquiredAfterStop() {
    let operations = FakeIdleAssertions()
    let guardState = operations.makeGuard()
    #expect(guardState.setRequired(true))
    #expect(guardState.stop())
    #expect(guardState.setRequired(true))
    #expect(guardState.isActive)
    #expect(operations.createdCount == 2)
    #expect(guardState.stop())
    #expect(operations.releasedIDs == [42, 42])
  }
}

private final class FakeIdleAssertions: @unchecked Sendable {
  private let lock = NSLock()
  private var createStatuses: [IOReturn]
  private var releaseStatuses: [IOReturn]
  private var creations = 0
  private var releases: [IOPMAssertionID] = []

  init(
    createStatuses: [IOReturn] = [],
    releaseStatuses: [IOReturn] = []
  ) {
    self.createStatuses = createStatuses
    self.releaseStatuses = releaseStatuses
  }

  @MainActor
  func makeGuard() -> IdleSleepGuard {
    IdleSleepGuard(create: { self.create() }, release: { self.release($0) })
  }

  var createdCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return creations
  }

  var releasedIDs: [IOPMAssertionID] {
    lock.lock()
    defer { lock.unlock() }
    return releases
  }

  private func create() -> (status: IOReturn, id: IOPMAssertionID) {
    lock.lock()
    defer { lock.unlock() }
    creations += 1
    let status = createStatuses.isEmpty ? kIOReturnSuccess : createStatuses.removeFirst()
    return (status, status == kIOReturnSuccess ? 42 : IOPMAssertionID(kIOPMNullAssertionID))
  }

  private func release(_ id: IOPMAssertionID) -> IOReturn {
    lock.lock()
    defer { lock.unlock() }
    releases.append(id)
    return releaseStatuses.isEmpty ? kIOReturnSuccess : releaseStatuses.removeFirst()
  }
}
