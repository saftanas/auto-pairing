import AppKit
import SwiftUI

@main
struct StudioSwitchApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      StudioSwitchView(model: model)
        .frame(width: 360)
    } label: {
      StudioSwitchMenuBarIcon(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}

private struct StudioSwitchMenuBarIcon: View {
  @ObservedObject var model: AppModel

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(systemName: "display")
        .symbolRenderingMode(.monochrome)

      Circle()
        .fill(statusColor)
        .frame(width: 5, height: 5)
        .overlay {
          Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5)
        }
        .offset(x: 1, y: 1)
    }
    .help(model.menuBarStatusText)
    .accessibilityLabel("Studio Switch")
    .accessibilityValue(Text(model.menuBarStatusText))
  }

  private var statusColor: Color {
    if model.isSwitching { return .orange }
    return model.displayAttached ? .green : .secondary
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
