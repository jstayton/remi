import AppKit

/// The iOS side of Remi: the AirPlay receiver, PIN pairing, paired devices, and the
/// mirror window for the one device UxPlay lets connect at a time.
@MainActor
final class AirPlayMirroring {
  private struct Client {
    let name: String
    let deviceID: String
  }

  private let receiver: AirPlayReceiver
  private let passwordPrompt = AirPlayPasswordPrompt()
  private var window: MirrorWindowController?
  private var client: Client?

  init(supportDirectory: URL) {
    let clientStore = AirPlayClientStore(fileURL: supportDirectory.appending(path: "airplay-clients.json"))
    receiver = AirPlayReceiver(clientStore: clientStore)
    receiver.onEvent = { [weak self] event in self?.handle(event) }
  }

  var isRunning: Bool { receiver.isRunning }

  /// Paired devices, plus the connected one if it somehow isn't saved.
  var devices: [MirrorDevice] {
    var devices = receiver.clientStore.pairedClients.map { paired in
      let isConnected = paired.deviceID == client?.deviceID
      return MirrorDevice(
        name: isConnected ? client?.name ?? paired.name : paired.name, source: .airPlay(deviceID: paired.deviceID),
        isConnected: isConnected, isMirroring: isConnected)
    }
    if let client, !devices.contains(where: \.isConnected) {
      devices.append(
        MirrorDevice(
          name: client.name, source: .airPlay(deviceID: client.deviceID), isConnected: true, isMirroring: true))
    }
    return devices
  }

  func start() {
    if Preferences.isAirPlayEnabled {
      startReceiver()
    }
  }

  func shutdown() {
    receiver.stop()
  }

  func setEnabled(_ isEnabled: Bool) {
    Preferences.isAirPlayEnabled = isEnabled
    if isEnabled {
      startReceiver()
    } else {
      receiver.stop()
      endSession()
    }
  }

  func setFloatsOnTop(_ floatsOnTop: Bool) {
    window?.mirrorWindow?.setFloatsOnTop(floatsOnTop)
  }

  func bringToFront() {
    window?.bringToFront()
  }

  /// Removes the device's pairing, ending its session if it's mirroring.
  func forget(deviceID: String, name: String) {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Forget \u{201C}\(name)\u{201D}?"
    alert.informativeText = "It will need a new AirPlay password the next time it mirrors to Remi."
    alert.addButton(withTitle: "Forget")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }
    do {
      try receiver.clientStore.remove(deviceID: deviceID)
      Preferences.setWindowFrame(nil, forDevice: Self.windowKey(deviceID: deviceID))
      if client?.deviceID == deviceID {
        endSession()
        try receiver.restart()
      }
    } catch {
      Alert.show(error, title: "Couldn't Forget Device")
    }
  }

  private func startReceiver() {
    do {
      try receiver.start()
    } catch {
      Preferences.isAirPlayEnabled = false
      Alert.show(error, title: "Couldn't Start AirPlay")
    }
  }

  private static func windowKey(deviceID: String) -> String {
    "airplay:\(deviceID)"
  }

  private func handle(_ event: AirPlayReceiver.Event) {
    switch event {
    case .sessionStarted(let name, let deviceID, let sink):
      endSession()
      client = Client(name: name, deviceID: deviceID)
      window = MirrorWindowController(
        title: name, deviceKey: Self.windowKey(deviceID: deviceID), sink: sink,
        floatsOnTop: Preferences.isFloatOnTopEnabled
      ) { [weak self] in
        self?.windowClosedByUser()
      }
    case .sessionEnded:
      endSession()
    case .connectionLost:
      endSession()
      // UxPlay restarts its server after a lost connection to clear the stale state.
      restartReceiver()
    case .codeRequested(let code):
      passwordPrompt.show(code: code)
    case .clientPaired(let name):
      passwordPrompt.close()
      Log.airPlay.info("Paired with \(name, privacy: .private)")
    }
  }

  private func endSession() {
    window?.closeForSource()
    window = nil
    client = nil
  }

  /// There's no way to ask the device to stop, so dropping the connection is how Remi ends it.
  private func windowClosedByUser() {
    window = nil
    client = nil
    restartReceiver()
  }

  private func restartReceiver() {
    guard receiver.isRunning else {
      return
    }
    do {
      try receiver.restart()
    } catch {
      Alert.show(error, title: "Couldn't Restart AirPlay")
    }
  }
}
