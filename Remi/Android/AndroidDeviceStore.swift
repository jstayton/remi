import Foundation

/// Phones that have connected before, so the menu can list them while they're away.
/// Forgetting one only removes it from the list until it connects again.
@MainActor
final class AndroidDeviceStore {
  struct Device: Codable, Equatable {
    let hardwareSerial: String
    let model: String
  }

  private let file: JSONFile<Device>
  private var storedDevices: [Device]

  init(fileURL: URL) {
    file = JSONFile(url: fileURL, isValid: Self.isValid)
    storedDevices = file.load()
  }

  /// Sorted by model name.
  var devices: [Device] {
    storedDevices.sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
  }

  func remember(_ device: Device) {
    guard Self.isValid(device), !storedDevices.contains(device) else {
      return
    }
    save(storedDevices.filter { $0.hardwareSerial != device.hardwareSerial } + [device])
  }

  func forget(hardwareSerial: String) {
    save(storedDevices.filter { $0.hardwareSerial != hardwareSerial })
  }

  /// The list is a convenience, so a failed save is logged rather than shown.
  private func save(_ devices: [Device]) {
    storedDevices = devices
    do {
      try file.save(devices)
    } catch {
      Log.android.error("Failed to save remembered Android devices: \(error, privacy: .private)")
    }
  }

  @Sendable private nonisolated static func isValid(_ device: Device) -> Bool {
    (1...128).contains(device.hardwareSerial.count) && (1...255).contains(device.model.count)
  }
}
