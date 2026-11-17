import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var devices: [BluetoothPeripheral] = []
  @Published var selectedAddresses: Set<String> {
    didSet {
      defaults.set(Array(selectedAddresses), forKey: Keys.selectedAddresses)
      coordinator.configure(addresses: selectedAddresses)
    }
  }
  @Published var displayMatch: String {
    didSet {
      guard displayMatch != oldValue else { return }
      defaults.set(displayMatch, forKey: Keys.displayMatch)
      displayWakeRequest.reset()
      displayWakeError = nil
      latestDisplayPresence = nil
      displayMonitor.match = displayMatch
      displayMonitor.refresh()
    }
  }
  @Published private(set) var displayAttached = false
  @Published private(set) var activity = "Choose your keyboard and trackpad"
  @Published private(set) var phase: HandoffPhase = .unconfigured
  @Published private(set) var sleepProtectionAvailable = false
  @Published private(set) var keepingSystemAwake = false
  @Published private(set) var idleSleepError: String?
  @Published private(set) var displayWakeError: String?
  @Published private(set) var loginStatusMessage: String?
  @Published private(set) var loginApprovalRequired = false
  @Published var launchAtLogin: Bool {
    didSet {
      if !updatingLoginStatus { updateLaunchAtLogin() }
    }
  }

  var isSwitching: Bool { [.settling, .acquiring, .releasing].contains(phase) }
  var menuBarStatusText: String { "Studio Switch: \(activity)" }

  var idleSleepStatusText: String {
    if keepingSystemAwake {
      return displayAttached
        ? "Keeping this Mac awake for the display. The screen can sleep, and your keyboard and trackpad stay connected."
        : "Finishing peripheral release before allowing system sleep."
    }
    return displayAttached
      ? "Studio Display attached; waiting for idle sleep protection."
      : "Waiting for Studio Display. Connecting it keeps this Mac awake while allowing the screen to sleep."
  }

  private enum Keys {
    static let selectedAddresses = "selectedBluetoothAddresses"
    static let displayMatch = "displayNameMatch"
  }

  private let defaults = UserDefaults.standard
  private let bluetooth: BluetoothController
  private let coordinator: HandoffCoordinator
  private let displayMonitor = DisplayMonitor()
  private let powerMonitor = PowerMonitor()
  private let idleSleepGuard = IdleSleepGuard()
  private let displayWakeRequest = DisplayWakeRequest()
  private var latestDisplayPresence: Bool?
  private var updatingLoginStatus = false
  private var refreshTimer: Timer?
  private var deviceRefreshTask: Task<Void, Never>?

  init() {
    let bluetooth = BluetoothController()
    self.bluetooth = bluetooth
    coordinator = HandoffCoordinator(bluetooth: bluetooth)
    selectedAddresses = Set(defaults.stringArray(forKey: Keys.selectedAddresses) ?? [])
    displayMatch = defaults.string(forKey: Keys.displayMatch) ?? "Studio Display"
    launchAtLogin = SMAppService.mainApp.status == .enabled
    refreshLoginStatus()

    coordinator.onKeepSystemAwakeChange = { [weak self] required in
      self?.updateIdleSleepProtection(required)
    }
    coordinator.onChange = { [weak self] status in
      self?.phase = status.phase
      self?.activity = status.message
      if status.phase == .connected || status.phase == .waiting {
        self?.refreshDevices()
      }
    }
    powerMonitor.onWillSleep = { [weak self] completion in
      guard let self else {
        completion()
        return
      }
      self.displayWakeRequest.prepareForSleep()
      self.displayWakeError = self.displayWakeRequest.lastError
      self.coordinator.prepareForSleep(completion: completion)
    }
    powerMonitor.onDidWake = { [weak self] actualResume in
      guard let self else { return }
      self.displayMonitor.refresh(force: true)
      self.displayWakeRequest.didWake(
        presence: self.latestDisplayPresence, actualResume: actualResume)
      self.displayWakeError = self.displayWakeRequest.lastError
      self.coordinator.didWake(attached: self.displayAttached)
    }
    // Register before starting any display-triggered acquisition.
    sleepProtectionAvailable = powerMonitor.start()
    displayMonitor.match = displayMatch
    displayMonitor.onPresenceObservation = { [weak self] presence in
      guard let self else { return }
      self.latestDisplayPresence = presence
      // Runs before onChange starts acquisition. While preparing for actual
      // sleep, retain the edge and wait for the fresh wake-time query instead.
      self.displayWakeRequest.observePresence(presence, isSleeping: self.coordinator.isSleeping)
      self.displayWakeError = self.displayWakeRequest.lastError
    }
    displayMonitor.onChange = { [weak self] attached in
      self?.displayAttached = attached
      self?.coordinator.displayChanged(attached: attached)
    }
    displayMonitor.start()
    coordinator.configure(addresses: selectedAddresses)
    refreshDevices()

    // Reconcile missed display notifications and delayed enumeration after wake.
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.coordinator.isSleeping else { return }
        self.displayMonitor.refresh()
        // A failed assertion call is retryable; never silently assume protection.
        self.updateIdleSleepProtection(self.coordinator.keepSystemAwake)
      }
    }
  }

  func refreshDevices() {
    guard !coordinator.isSleeping, deviceRefreshTask == nil else { return }
    deviceRefreshTask = Task { [weak self, bluetooth] in
      let devices = await bluetooth.pairedDevices()
      guard let self else { return }
      self.deviceRefreshTask = nil
      guard !Task.isCancelled, !self.coordinator.isSleeping else { return }
      self.devices = devices
    }
  }

  func toggle(_ device: BluetoothPeripheral) {
    if selectedAddresses.contains(device.id) {
      selectedAddresses.remove(device.id)
    } else {
      selectedAddresses.insert(device.id)
    }
  }

  func switchNow() {
    displayMonitor.refresh()
    coordinator.retry()
  }

  func stop() {
    deviceRefreshTask?.cancel()
    deviceRefreshTask = nil
    refreshTimer?.invalidate()
    refreshTimer = nil
    displayMonitor.stop()
    displayWakeRequest.stop()
    coordinator.stop()
    idleSleepGuard.stop()
    powerMonitor.stop()
  }

  private func updateIdleSleepProtection(_ required: Bool) {
    idleSleepGuard.setRequired(required)
    keepingSystemAwake = idleSleepGuard.isActive
    idleSleepError = idleSleepGuard.lastError
  }

  func refreshLoginStatus() {
    let status = SMAppService.mainApp.status
    let wasAwaitingApproval = loginApprovalRequired
    updatingLoginStatus = true
    launchAtLogin = status == .enabled
    updatingLoginStatus = false
    loginApprovalRequired = status == .requiresApproval
    if loginApprovalRequired {
      loginStatusMessage = "Allow Studio Switch in Login Items to launch automatically."
    } else if status == .enabled || wasAwaitingApproval {
      loginStatusMessage = nil
    }
  }

  func openLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private func updateLaunchAtLogin() {
    loginStatusMessage = nil
    do {
      if launchAtLogin {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      loginStatusMessage = "Launch at login: \(error.localizedDescription)"
    }
    refreshLoginStatus()
  }
}
