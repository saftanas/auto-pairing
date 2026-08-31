import Combine
import Foundation
import IOBluetooth
import ServiceManagement

struct BluetoothPeripheral: Identifiable, Hashable {
  let id: String
  let name: String
  let connected: Bool
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var devices: [BluetoothPeripheral] = []
  @Published var selectedAddresses: Set<String> {
    didSet { defaults.set(Array(selectedAddresses), forKey: Keys.selectedAddresses) }
  }
  @Published var displayMatch: String {
    didSet {
      defaults.set(displayMatch, forKey: Keys.displayMatch)
      displayMonitor.match = displayMatch
      displayMonitor.refresh()
    }
  }
  @Published private(set) var displayAttached = false
  @Published private(set) var activity = "Starting…"
  @Published private(set) var isSwitching = false
  @Published var launchAtLogin: Bool {
    didSet { updateLaunchAtLogin() }
  }

  var menuBarStatusText: String {
    if isSwitching { return "Studio Switch: switching peripherals" }
    if displayAttached { return "Studio Switch: Studio Display attached" }
    return "Studio Switch: waiting for Studio Display"
  }

  private enum Keys {
    static let selectedAddresses = "selectedBluetoothAddresses"
    static let displayMatch = "displayNameMatch"
  }

  private let defaults = UserDefaults.standard
  private let bluetooth = BluetoothController()
  private let displayMonitor = DisplayMonitor()
  private var switchTask: Task<Void, Never>?

  init() {
    let savedAddresses = defaults.stringArray(forKey: Keys.selectedAddresses) ?? []
    selectedAddresses = Set(savedAddresses)
    displayMatch = defaults.string(forKey: Keys.displayMatch) ?? "Studio Display"
    launchAtLogin = SMAppService.mainApp.status == .enabled

    displayMonitor.match = displayMatch
    displayMonitor.onChange = { [weak self] attached in
      self?.displayStateChanged(attached)
    }
    displayMonitor.start()
    refreshDevices()
  }

  func refreshDevices() {
    devices = bluetooth.pairedDevices()
  }

  func toggle(_ device: BluetoothPeripheral) {
    if selectedAddresses.contains(device.id) {
      selectedAddresses.remove(device.id)
    } else {
      selectedAddresses.insert(device.id)
    }
  }

  func switchNow() {
    runSwitch(shouldConnect: displayAttached)
  }

  private func displayStateChanged(_ attached: Bool) {
    displayAttached = attached
    runSwitch(shouldConnect: attached)
  }

  private func runSwitch(shouldConnect: Bool) {
    switchTask?.cancel()

    guard !selectedAddresses.isEmpty else {
      isSwitching = false
      activity = "Choose a keyboard and pointing device"
      return
    }

    let addresses = selectedAddresses
    isSwitching = true
    activity = shouldConnect ? "Taking control of peripherals…" : "Releasing peripherals…"

    switchTask = Task { [weak self, bluetooth] in
      let results: [BluetoothOperationResult]
      if shouldConnect {
        // Give the Mac losing the display a brief head start to release its devices.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        results = await bluetooth.connect(addresses: addresses, attempts: 12)
      } else {
        results = await bluetooth.disconnect(addresses: addresses)
      }

      guard !Task.isCancelled, let self else { return }
      self.isSwitching = false
      self.refreshDevices()

      let failures = results.filter { !$0.success }
      if failures.isEmpty {
        self.activity = shouldConnect ? "Peripherals connected" : "Peripherals released"
      } else {
        let names = failures.map(\.name).joined(separator: ", ")
        self.activity = "Could not \(shouldConnect ? "connect" : "release"): \(names)"
      }
    }
  }

  private func updateLaunchAtLogin() {
    do {
      if launchAtLogin {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      activity = "Launch at login: \(error.localizedDescription)"
    }
  }
}
