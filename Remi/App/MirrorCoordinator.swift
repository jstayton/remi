import AppKit

/// What the status menu talks to: it combines the iOS and Android sides, so the menu
/// never deals with either directly.
@MainActor
final class MirrorCoordinator {
  /// Runs when a device connects or disconnects, or Android stops searching for them.
  var onDevicesChange: (() -> Void)?

  private let airPlay: AirPlayMirroring
  /// Nil when adb is missing from the app bundle.
  private let android: AndroidMirroring?

  init() throws {
    let supportDirectory = try Preferences.supportDirectory()
    airPlay = AirPlayMirroring(supportDirectory: supportDirectory)
    do {
      android = AndroidMirroring(adb: try Adb.bundled(), supportDirectory: supportDirectory)
    } catch {
      Log.android.error("Android mirroring is unavailable: \(error, privacy: .public)")
      android = nil
    }
    airPlay.onDevicesChange = { [weak self] in self?.onDevicesChange?() }
    android?.onDevicesChange = { [weak self] in self?.onDevicesChange?() }
  }

  /// Whether the receiver is running, so one that failed to start shows as off.
  var isAirPlayEnabled: Bool { airPlay.isRunning }
  var isAndroidAvailable: Bool { android != nil }
  var isAndroidEnabled: Bool { android?.isEnabled ?? false }
  var isAndroidSearching: Bool { android?.isSearching ?? false }

  var devices: [MirrorDevice] {
    airPlay.devices + (android?.devices ?? [])
  }

  func start() {
    airPlay.start()
    android?.start()
  }

  func shutdown() {
    airPlay.shutdown()
    android?.shutdown()
  }

  func setAirPlayEnabled(_ isEnabled: Bool) {
    airPlay.setEnabled(isEnabled)
  }

  func setAndroidEnabled(_ isEnabled: Bool) {
    android?.setEnabled(isEnabled)
  }

  func setFloatOnTop(_ isEnabled: Bool) {
    Preferences.isFloatOnTopEnabled = isEnabled
    airPlay.setFloatsOnTop(isEnabled)
    android?.setFloatsOnTop(isEnabled)
  }

  func select(_ device: MirrorDevice) {
    switch device.source {
    case .airPlay:
      airPlay.bringToFront()
    case .android(let serial?, _):
      android?.select(serial: serial)
    case .android(nil, _):
      break
    }
  }

  func forget(_ device: MirrorDevice) {
    switch device.source {
    case .airPlay(let deviceID):
      airPlay.forget(deviceID: deviceID, name: device.name)
    case .android(_, let hardwareSerial?):
      android?.forget(hardwareSerial: hardwareSerial)
    case .android(_, nil):
      break
    }
  }

  func pairAndroidDevice() {
    android?.pair()
  }
}
