import AppKit
import SwiftUI

struct StudioSwitchView: View {
  @ObservedObject var model: AppModel

  var body: some View {
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
            .lineLimit(2)
        }
        Spacer()
        if model.isSwitching { ProgressView().controlSize(.small) }
      }

      Divider()

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

      HStack {
        Button("Switch now") { model.switchNow() }
          .disabled(model.selectedAddresses.isEmpty || model.isSwitching)
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
      }
    }
    .padding(16)
  }
}
