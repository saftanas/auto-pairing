import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

/// Request once for a confirmed attachment or an actual system resume with an
/// attached display. Screen sleep, failed queries, and repeated polls do not arm
/// requests. Resume handling covers cable changes missed while fully asleep.
struct DisplayWakePolicy {
  private(set) var lastConfirmedPresence: Bool?
  private(set) var attachmentPending = false
  private(set) var resumePending = false
  private var resumeArmed = false

  mutating func prepareForSleep() {
    resumeArmed = true
    resumePending = false
  }

  mutating func didWake(actualResume: Bool) {
    if actualResume && resumeArmed { resumePending = true }
    if !actualResume { resumePending = false }
    resumeArmed = false
  }

  mutating func observe(_ presence: Bool?, isSleeping: Bool) -> Bool {
    guard let presence else { return false }
    if lastConfirmedPresence == false && presence {
      attachmentPending = true
    }
    lastConfirmedPresence = presence
    if !presence {
      attachmentPending = false
      resumePending = false
    }
    guard !isSleeping, attachmentPending || resumePending else { return false }
    attachmentPending = false
    resumePending = false
    return true
  }
}

/// Requests a visible wake after display attachment or actual system resume.
/// This does not override forced sleep or keep resetting the display timeout.
@MainActor
final class DisplayWakeRequest {
  typealias DeclareActivity = @Sendable (IOPMAssertionID) -> (status: IOReturn, id: IOPMAssertionID)
  typealias ReleaseActivity = @Sendable (IOPMAssertionID) -> IOReturn

  private(set) var lastError: String?

  private let declareActivity: DeclareActivity
  private let releaseActivity: ReleaseActivity
  private let logger = Logger(subsystem: "com.saftanas.studioswitch", category: "DisplayWake")
  private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
  private var policy = DisplayWakePolicy()

  init(
    declare: @escaping DeclareActivity = { previousID in
      var id = previousID
      let status = IOPMAssertionDeclareUserActivity(
        "Studio Display attached for a wireless input handoff" as CFString,
        kIOPMUserActiveLocal,
        &id
      )
      return (status, id)
    },
    release: @escaping ReleaseActivity = { IOPMAssertionRelease($0) }
  ) {
    declareActivity = declare
    releaseActivity = release
  }

  func observePresence(_ presence: Bool?, isSleeping: Bool) {
    let previous = policy.lastConfirmedPresence
    let reason =
      policy.resumePending ? "system resume with an attached display" : "display attachment"
    let shouldRequest = policy.observe(presence, isSleeping: isSleeping)
    if let presence, presence != previous {
      let event = previous == nil ? "Initial display presence" : "Display attachment changed"
      logger.info(
        "\(event, privacy: .public): attached=\(presence), sleeping=\(isSleeping), uptime=\(ProcessInfo.processInfo.systemUptime)"
      )
    }
    if presence == false { releaseAssertion() }
    if shouldRequest { requestVisibleWake(reason: reason) }
  }

  func didWake(presence: Bool?, actualResume: Bool) {
    policy.didWake(actualResume: actualResume)
    // Confirm the display after resuming: an entire detach/attach cycle may
    // have been missed while asleep. Unknown leaves the request pending, and a
    // confirmed absence cancels it. WillNotSleep never arms a resume request.
    observePresence(presence, isSleeping: false)
  }

  func prepareForSleep() {
    policy.prepareForSleep()
    releaseAssertion()
  }

  func reset() {
    releaseAssertion()
    policy = DisplayWakePolicy()
    lastError = nil
  }

  func stop() {
    reset()
  }

  private func requestVisibleWake(reason: String) {
    // Eligibility is already consumed, even if this request fails. Polling must
    // never repeatedly declare activity and defeat the user's display timeout.
    let result = declareActivity(assertionID)
    let status = String(format: "0x%08X", UInt32(bitPattern: result.status))
    if result.status == kIOReturnSuccess, result.id != kIOPMNullAssertionID {
      assertionID = result.id
      lastError = nil
      logger.info(
        "Requested visible wake for \(reason, privacy: .public); status=\(status, privacy: .public), uptime=\(ProcessInfo.processInfo.systemUptime)"
      )
    } else {
      lastError = "Could not request display wake (IOKit status \(status))."
      logger.error(
        "Visible-wake request failed; status=\(status, privacy: .public), assertion=\(result.id), uptime=\(ProcessInfo.processInfo.systemUptime). Waiting for a new attachment or system resume before retrying."
      )
    }
  }

  private func releaseAssertion() {
    guard assertionID != kIOPMNullAssertionID else { return }
    let id = assertionID
    assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    let status = releaseActivity(id)
    if status != kIOReturnSuccess && status != kIOReturnNotFound {
      lastError = "Could not release display wake activity (IOKit status \(status))."
      logger.error("Could not release display activity assertion: \(status)")
    }
  }

  deinit {
    if assertionID != kIOPMNullAssertionID { _ = releaseActivity(assertionID) }
  }
}
