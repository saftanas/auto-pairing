import AppKit
import CoreGraphics
import IOKit
import IOKit.usb

/// WindowServer can stop presenting a screen while its cable remains connected.
/// Prefer a learned physical USB identity; otherwise use the online display list,
/// which includes sleeping displays. Failed queries never grant stale ownership.
struct DisplayPresencePolicy {
  private(set) var hasObservedUSBDisplay = false

  mutating func attached(usb: Bool?, online: Bool?) -> Bool {
    if usb == true { hasObservedUSBDisplay = true }
    return hasObservedUSBDisplay ? usb == true : online == true
  }
}

/// NSScreen supplies names, but is not the authority on physical attachment.
/// Keep a name while its display remains online, even when its screen is dark.
struct OnlineDisplayNames {
  private var names: [CGDirectDisplayID: String] = [:]

  mutating func contains(
    _ needle: String, online: Set<CGDirectDisplayID>,
    visibleNames: [CGDirectDisplayID: String], builtIn: Set<CGDirectDisplayID>
  ) -> Bool {
    names = names.filter { online.contains($0.key) }
    names.merge(visibleNames.filter { online.contains($0.key) }) { _, latest in latest }
    return online.contains { display in
      !builtIn.contains(display)
        && names[display]?.range(
          of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }
}

private func displayReconfigurationCallback(
  _ display: CGDirectDisplayID,
  _ flags: CGDisplayChangeSummaryFlags,
  _ userInfo: UnsafeMutableRawPointer?
) {
  // A configuration-begin callback is not evidence that the cable was removed.
  guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
  let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  DispatchQueue.main.async { monitor.refreshIfStarted() }
}

private func usbDisplayChanged(
  _ userInfo: UnsafeMutableRawPointer?, _ iterator: io_iterator_t
) {
  // Notification iterators must be drained to arm the next notification.
  while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
    IOObjectRelease(service)
  }
  guard let userInfo else { return }
  let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  DispatchQueue.main.async { monitor.refreshIfStarted() }
}

@MainActor
final class DisplayMonitor {
  var match = "Studio Display" {
    didSet {
      guard match != oldValue else { return }
      presencePolicy = DisplayPresencePolicy()
    }
  }
  var onChange: ((Bool) -> Void)?
  /// Unlike ownership, wake requests must distinguish absence from a failed
  /// query. Report every observation so a transient failure cannot invent a
  /// new cable-attachment edge and light an intentionally sleeping screen.
  var onPresenceObservation: ((Bool?) -> Void)?

  private var lastValue: Bool?
  private var notificationToken: NSObjectProtocol?
  private var started = false
  private var usbNotificationPort: IONotificationPortRef?
  private var usbIterators: [io_iterator_t] = []
  private var presencePolicy = DisplayPresencePolicy()
  private var displayNames = OnlineDisplayNames()

  func start() {
    guard !started else { return }
    started = true
    let context = Unmanaged.passUnretained(self).toOpaque()
    CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
    notificationToken = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshIfStarted() }
    }

    if let port = IONotificationPortCreate(kIOMainPortDefault) {
      usbNotificationPort = port
      IONotificationPortSetDispatchQueue(port, .main)
      for event in [kIOFirstMatchNotification, kIOTerminatedNotification] {
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
          port, event, IOServiceMatching("IOUSBHostDevice"), usbDisplayChanged,
          context, &iterator)
        if result == KERN_SUCCESS {
          usbIterators.append(iterator)
          usbDisplayChanged(nil, iterator)
        }
      }
    }
    refresh()
  }

  func refresh(force: Bool = false) {
    let needle = match.trimmingCharacters(in: .whitespacesAndNewlines)
    let attached: Bool
    let observation: Bool?
    if needle.isEmpty {
      attached = false
      observation = false
    } else {
      let usbAttached = matchingUSBDisplay(needle)
      // Avoid asking WindowServer for names when the physical identity is known.
      let onlineAttached =
        presencePolicy.hasObservedUSBDisplay || usbAttached == true
        ? nil : matchingOnlineDisplay(needle)
      attached = presencePolicy.attached(usb: usbAttached, online: onlineAttached)
      observation = presencePolicy.hasObservedUSBDisplay ? usbAttached : onlineAttached
    }
    onPresenceObservation?(observation)
    guard force || attached != lastValue else { return }
    lastValue = attached
    onChange?(attached)
  }

  fileprivate func refreshIfStarted() {
    guard started else { return }
    refresh()
  }

  func stop() {
    guard started else { return }
    started = false
    if let notificationToken {
      NotificationCenter.default.removeObserver(notificationToken)
      self.notificationToken = nil
    }
    CGDisplayRemoveReconfigurationCallback(
      displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    for iterator in usbIterators { IOObjectRelease(iterator) }
    usbIterators.removeAll()
    if let usbNotificationPort {
      IONotificationPortDestroy(usbNotificationPort)
      self.usbNotificationPort = nil
    }
    lastValue = nil
  }

  private func matchingUSBDisplay(_ needle: String) -> Bool? {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator
      ) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }

    var found = false
    while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
      defer { IOObjectRelease(service) }
      let vendor =
        IORegistryEntryCreateCFProperty(
          service, kUSBVendorID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        as? NSNumber
      guard vendor?.uint16Value == 0x05ac else { continue }  // Apple's USB vendor ID.
      // The SDK renamed this key in 10.15; older drivers may expose the old key.
      let product = [kUSBProductString, "USB Product Name"].compactMap { key in
        IORegistryEntryCreateCFProperty(
          service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
      }.first
      if let product,
        product.range(
          of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      {
        found = true
      }
    }
    return found
  }

  private func matchingOnlineDisplay(_ needle: String) -> Bool? {
    var visibleNames: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
      if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
      {
        visibleNames[number.uint32Value] = screen.localizedName
      }
    }
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
    guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success
    else { return nil }
    let online = Set(displays.prefix(Int(count)))
    let builtIn = Set(online.filter { CGDisplayIsBuiltin($0) != 0 })
    return displayNames.contains(
      needle, online: online, visibleNames: visibleNames, builtIn: builtIn)
  }

  deinit {
    if let notificationToken { NotificationCenter.default.removeObserver(notificationToken) }
    if started {
      CGDisplayRemoveReconfigurationCallback(
        displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }
    for iterator in usbIterators { IOObjectRelease(iterator) }
    if let usbNotificationPort { IONotificationPortDestroy(usbNotificationPort) }
  }
}
