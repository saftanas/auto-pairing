import Foundation
@preconcurrency import IOBluetooth

struct BluetoothOperationResult: Sendable {
  let address: String
  let name: String
  let success: Bool
}

final class BluetoothController: @unchecked Sendable {
  func pairedDevices() -> [BluetoothPeripheral] {
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return paired.compactMap { device in
      guard let address = device.addressString else { return nil }
      return BluetoothPeripheral(
        id: address,
        name: device.name ?? "Unnamed Bluetooth device",
        connected: device.isConnected()
      )
    }
    .sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  func disconnect(addresses: Set<String>) async -> [BluetoothOperationResult] {
    await Task.detached(priority: .userInitiated) {
      addresses.map { address in
        guard let device = IOBluetoothDevice(addressString: address) else {
          return BluetoothOperationResult(address: address, name: address, success: false)
        }
        let name = device.name ?? address
        if !device.isConnected() {
          return BluetoothOperationResult(address: address, name: name, success: true)
        }
        let status = device.closeConnection()
        return BluetoothOperationResult(
          address: address, name: name, success: status == kIOReturnSuccess)
      }
    }.value
  }

  func connect(addresses: Set<String>, attempts: Int) async -> [BluetoothOperationResult] {
    await withTaskGroup(of: BluetoothOperationResult.self) { group in
      for address in addresses {
        group.addTask {
          guard let device = IOBluetoothDevice(addressString: address) else {
            return BluetoothOperationResult(address: address, name: address, success: false)
          }
          let name = device.name ?? address
          if device.isConnected() {
            return BluetoothOperationResult(address: address, name: name, success: true)
          }

          for attempt in 0..<attempts {
            guard !Task.isCancelled else {
              return BluetoothOperationResult(address: address, name: name, success: false)
            }
            _ = device.openConnection()
            if device.isConnected() {
              return BluetoothOperationResult(address: address, name: name, success: true)
            }
            if attempt + 1 < attempts {
              try? await Task.sleep(for: .milliseconds(650))
            }
          }
          return BluetoothOperationResult(address: address, name: name, success: false)
        }
      }

      var results: [BluetoothOperationResult] = []
      for await result in group { results.append(result) }
      return results
    }
  }
}
