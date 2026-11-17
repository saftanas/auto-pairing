import AppKit
import SwiftUI

struct StudioSwitchView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          Image(systemName: model.displayAttached ? "display.and.arrow.down" : "display")
            .font(.title2)
            .foregroundStyle(model.displayAttached ? .green : .secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(model.displayAttached ? "Studio Display attached" : "Studio Display not attached")
              .font(.headline)
            Text(model.activity)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          if model.isSwitching { ProgressView().controlSize(.small) }
        }

        Divider()

        if !model.sleepProtectionAvailable {
          Text(
            "Sleep monitoring is unavailable. Restart Studio Switch before switching with closed lids."
          )
          .font(.caption)
          .foregroundStyle(.red)
        }

        Text(model.idleSleepStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)

        if let error = model.idleSleepError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        if let error = model.displayWakeError {
          Text(error).font(.caption).foregroundStyle(.red)
        }

        Text("Choosing Sleep still releases peripherals before system sleep.")
          .font(.caption)
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Text("Peripherals").font(.headline)
            Spacer()
            Button {
              model.refreshDevices()
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh paired Bluetooth devices")
          }

          if model.devices.isEmpty {
            Text(
              "No paired Bluetooth devices found. Pair them with this Mac in System Settings first."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            ForEach(model.devices) { device in
              Button {
                model.toggle(device)
              } label: {
                HStack {
                  Image(
                    systemName: model.selectedAddresses.contains(device.id)
                      ? "checkmark.circle.fill" : "circle"
                  )
                  .foregroundStyle(
                    model.selectedAddresses.contains(device.id) ? Color.accentColor : .secondary)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                    Text(device.id)
                      .font(.caption2.monospaced())
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Circle()
                    .fill(device.connected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
          Text("Display name contains").font(.caption).foregroundStyle(.secondary)
          TextField("Studio Display", text: $model.displayMatch)
            .textFieldStyle(.roundedBorder)
        }

        Toggle("Launch at login", isOn: $model.launchAtLogin)

        if let message = model.loginStatusMessage {
          Text(message).font(.caption).foregroundStyle(.orange)
          if model.loginApprovalRequired {
            Button("Open Login Items") { model.openLoginItems() }
          }
        }

        HStack {
          Button("Retry handoff") { model.switchNow() }
            .disabled(model.selectedAddresses.isEmpty)
          Button("Bluetooth Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
              NSWorkspace.shared.open(url)
            }
          }
          Spacer()
          Button("Quit") { NSApplication.shared.terminate(nil) }
        }

        Text(
          "Studio Switch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"))"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      .padding(16)
    }
    .frame(height: 560)
  }
}
