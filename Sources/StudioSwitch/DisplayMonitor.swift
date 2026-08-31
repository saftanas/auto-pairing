import AppKit
import CoreGraphics

private func displayReconfigurationCallback(
  _ display: CGDirectDisplayID,
  _ flags: CGDisplayChangeSummaryFlags,
  _ userInfo: UnsafeMutableRawPointer?
) {
  guard let userInfo else { return }
  let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  DispatchQueue.main.async { monitor.refresh() }
}

@MainActor
final class DisplayMonitor {
  var match = "Studio Display"
  var onChange: ((Bool) -> Void)?

  private var lastValue: Bool?
  private var notificationToken: NSObjectProtocol?
  private var started = false

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
      Task { @MainActor in self?.refresh() }
    }
    refresh()
  }

  func refresh() {
    let needle = match.trimmingCharacters(in: .whitespacesAndNewlines)
    let attached =
      !needle.isEmpty
      && NSScreen.screens.contains {
        $0.localizedName.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
          != nil
      }
    guard attached != lastValue else { return }
    lastValue = attached
    onChange?(attached)
  }

  deinit {
    if let notificationToken { NotificationCenter.default.removeObserver(notificationToken) }
    if started {
      let context = Unmanaged.passUnretained(self).toOpaque()
      CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)
    }
  }
}
