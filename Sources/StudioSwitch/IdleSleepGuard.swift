import Foundation
import IOKit
import IOKit.pwr_mgt

/// Keeps the handoff coordinator running while this Mac owns the display.
/// Display sleep remains enabled; forced sleep still uses PowerMonitor's
/// bounded release window. This assertion does not change any system settings.
@MainActor
final class IdleSleepGuard {
  typealias CreateAssertion = @Sendable () -> (status: IOReturn, id: IOPMAssertionID)
  typealias ReleaseAssertion = @Sendable (IOPMAssertionID) -> IOReturn

  var isActive: Bool { assertionID != nil }
  private(set) var lastError: String?

  private let createAssertion: CreateAssertion
  private let releaseAssertion: ReleaseAssertion
  private var assertionID: IOPMAssertionID?

  init(
    create: @escaping CreateAssertion = {
      var id = IOPMAssertionID(kIOPMNullAssertionID)
      let status = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "Studio Switch is keeping wireless input ready for a display handoff" as CFString,
        &id
      )
      return (status, id)
    },
    release: @escaping ReleaseAssertion = { IOPMAssertionRelease($0) }
  ) {
    createAssertion = create
    releaseAssertion = release
  }

  /// Returns whether the requested assertion state was reached. Failed creates
  /// and releases remain retryable on the next call with the same requirement.
  @discardableResult
  func setRequired(_ required: Bool) -> Bool {
    if required {
      guard assertionID == nil else {
        lastError = nil
        return true
      }
      let result = createAssertion()
      guard result.status == kIOReturnSuccess else {
        lastError = "Could not prevent idle system sleep (IOKit status \(result.status))."
        return false
      }
      guard result.id != kIOPMNullAssertionID else {
        lastError = "macOS did not return an idle sleep assertion identifier."
        return false
      }
      assertionID = result.id
    } else if let id = assertionID {
      let status = releaseAssertion(id)
      guard status == kIOReturnSuccess else {
        lastError = "Could not release idle sleep protection (IOKit status \(status))."
        return false
      }
      assertionID = nil
    }
    lastError = nil
    return true
  }

  @discardableResult
  func stop() -> Bool {
    setRequired(false)
  }

  deinit {
    // The injected release operation is Sendable and does not require the main
    // actor. Explicit stop() remains preferable so a failure can be reported.
    if let assertionID { _ = releaseAssertion(assertionID) }
  }
}
