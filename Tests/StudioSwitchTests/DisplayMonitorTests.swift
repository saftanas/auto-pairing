import CoreGraphics
import Testing

@testable import StudioSwitch

struct DisplayMonitorTests {
  @Test func screenSleepKeepsPhysicallyAttachedDisplayOwned() {
    var policy = DisplayPresencePolicy()
    let initiallyAttached = policy.attached(usb: true, online: true)
    #expect(initiallyAttached)
    // Screen and WindowServer availability are irrelevant while USB remains.
    let attachedWithScreenDark = policy.attached(usb: true, online: false)
    #expect(attachedWithScreenDark)
    let attachedWithoutScreenQuery = policy.attached(usb: true, online: nil)
    #expect(attachedWithoutScreenQuery)
  }

  @Test func physicalDetachOverridesStaleVisibleDisplay() {
    var policy = DisplayPresencePolicy()
    let initiallyAttached = policy.attached(usb: true, online: true)
    #expect(initiallyAttached)
    let attachedAfterDetach = policy.attached(usb: false, online: true)
    #expect(!attachedAfterDetach)
    let attachedWithStaleScreen = policy.attached(usb: false, online: true)
    #expect(!attachedWithStaleScreen)
    let reattached = policy.attached(usb: true, online: true)
    #expect(reattached)
  }

  @Test func sleepingOnlineDisplayRetainsItsNameWithoutNSScreen() {
    var names = OnlineDisplayNames()
    var policy = DisplayPresencePolicy()
    let display: CGDirectDisplayID = 42
    let awake = names.contains(
      "Studio Display", online: [display],
      visibleNames: [display: "Studio Display"], builtIn: [])
    let attachedWhileAwake = policy.attached(usb: false, online: awake)
    #expect(attachedWhileAwake)

    let screenAsleep = names.contains(
      "Studio Display", online: [display], visibleNames: [:], builtIn: [])
    #expect(screenAsleep)
    let attachedWhileScreenAsleep = policy.attached(usb: false, online: screenAsleep)
    #expect(attachedWhileScreenAsleep)

    let unplugged = names.contains(
      "Studio Display", online: [], visibleNames: [:], builtIn: [])
    let attachedAfterUnplug = policy.attached(usb: false, online: unplugged)
    #expect(!attachedAfterUnplug)
  }

  @Test func failedQueriesCannotReusePhysicalOwnership() {
    var policy = DisplayPresencePolicy()
    let initiallyAttached = policy.attached(usb: true, online: true)
    #expect(initiallyAttached)
    let attachedWithoutUSBQuery = policy.attached(usb: nil, online: true)
    #expect(!attachedWithoutUSBQuery)
    let attachedWithoutQueries = policy.attached(usb: nil, online: nil)
    #expect(!attachedWithoutQueries)
    let attachedAfterRecovery = policy.attached(usb: true, online: nil)
    #expect(attachedAfterRecovery)
  }

  @Test func failedOnlineQueryCannotReuseFallbackOwnership() {
    var policy = DisplayPresencePolicy()
    let initiallyAttached = policy.attached(usb: false, online: true)
    #expect(initiallyAttached)
    let attachedWithoutOnlineQuery = policy.attached(usb: false, online: nil)
    #expect(!attachedWithoutOnlineQuery)
    let attachedWithoutQueries = policy.attached(usb: nil, online: nil)
    #expect(!attachedWithoutQueries)
  }

  @Test func fallbackSupportsNamesWithoutMatchingUSBProduct() {
    var policy = DisplayPresencePolicy()
    var names = OnlineDisplayNames()
    let online = names.contains(
      "studio display", online: [42], visibleNames: [42: "Studio Display"], builtIn: [])
    let attachedByFallback = policy.attached(usb: false, online: online)
    #expect(attachedByFallback)
    #expect(!policy.hasObservedUSBDisplay)
  }

  @Test func disconnectedDisplayCannotLeaveANameOnReusedIdentifier() {
    var names = OnlineDisplayNames()
    let initiallyMatches = names.contains(
      "Studio Display", online: [42], visibleNames: [42: "Studio Display"], builtIn: [])
    #expect(initiallyMatches)
    let matchesAfterUnplug = names.contains(
      "Studio Display", online: [], visibleNames: [:], builtIn: [])
    #expect(!matchesAfterUnplug)
    let matchesReusedIdentifier = names.contains(
      "Studio Display", online: [42], visibleNames: [:], builtIn: [])
    #expect(!matchesReusedIdentifier)
  }

  @Test func builtInDisplayCannotAcquirePeripherals() {
    var names = OnlineDisplayNames()
    let matchesBuiltIn = names.contains(
      "Display", online: [1], visibleNames: [1: "Built-in Display"], builtIn: [1])
    #expect(!matchesBuiltIn)
  }
}
