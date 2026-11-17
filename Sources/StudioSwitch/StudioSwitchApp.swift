import AppKit
import Combine
import SwiftUI

@main
struct StudioSwitchApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // The menu-bar popover and Settings share one model. macOS can open this
    // scene when activating the app, so it must expose the real controls.
    Settings {
      StudioSwitchView(model: appDelegate.model)
        .frame(width: 400)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  private let popover = NSPopover()
  private var statusItem: NSStatusItem?
  private var cancellables: Set<AnyCancellable> = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    configurePopover()
    configureStatusItem()
    observeStatus()
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.stop()
  }

  private func configurePopover() {
    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = NSSize(width: 400, height: 560)
    popover.contentViewController = NSHostingController(
      rootView: StudioSwitchView(model: model)
        .frame(width: 400)
    )
  }

  private func configureStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = item.button else { return }

    button.image = NSImage(
      systemSymbolName: "display",
      accessibilityDescription: "Studio Switch"
    )
    button.image?.isTemplate = true
    button.imagePosition = .imageLeading
    button.target = self
    button.action = #selector(togglePopover(_:))
    button.sendAction(on: [.leftMouseUp])
    button.setAccessibilityLabel("Studio Switch")

    statusItem = item
    updateStatusItem()
  }

  private func observeStatus() {
    model.$phase
      .combineLatest(model.$displayAttached, model.$idleSleepError, model.$displayWakeError)
      .receive(on: RunLoop.main)
      .sink { [weak self] _, _, _, _ in self?.updateStatusItem() }
      .store(in: &cancellables)
  }

  private func updateStatusItem() {
    guard let button = statusItem?.button else { return }

    let dotColor: NSColor
    if model.phase == .needsAttention || !model.sleepProtectionAvailable
      || model.idleSleepError != nil || model.displayWakeError != nil
    {
      dotColor = .systemRed
    } else if model.isSwitching {
      dotColor = .systemOrange
    } else if model.phase == .connected {
      dotColor = .systemGreen
    } else {
      dotColor = .secondaryLabelColor
    }

    button.attributedTitle = NSAttributedString(
      string: " ●",
      attributes: [
        .foregroundColor: dotColor,
        .font: NSFont.systemFont(ofSize: 7, weight: .bold),
      ]
    )
    button.toolTip = model.menuBarStatusText
    button.setAccessibilityValue(model.menuBarStatusText)
  }

  @objc private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
    } else {
      model.refreshLoginStatus()
      model.refreshDevices()
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
