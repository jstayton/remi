import AppKit

/// The Android side of Remi: Remi's adb server, finding and connecting phones,
/// remembered phones, and one mirror window per phone that's mirroring.
@MainActor
final class AndroidMirroring {
  @MainActor
  private final class Mirror {
    let session: ScrcpySession
    var window: MirrorWindowController?
    /// Shows while the session starts, until the window shows its first frame.
    var prompt: ProgressPrompt?

    init(session: ScrcpySession) {
      self.session = session
    }

    func closePrompt() {
      prompt?.close()
      prompt = nil
    }
  }

  private static let connectAttempts = 5
  private static let connectRetryDelay = Duration.seconds(3)
  /// How long a newly paired device has to connect before Remi says to look for it in the menu.
  private static let pairedConnectTimeout = Duration.seconds(30)
  /// Most phones start mirroring faster than this, so their connecting prompt never shows.
  private static let connectingPromptDelay = Duration.seconds(1)
  /// Long enough for adb to start, Bonjour to find paired phones, and adb to connect to them.
  private static let searchDuration = Duration.seconds(10)

  /// Runs when a device connects or disconnects.
  var onDevicesChange: (() -> Void)?

  private let adb: Adb
  private let tracker: AndroidDeviceTracker
  private let browser = AndroidServiceBrowser()
  private let store: AndroidDeviceStore
  private var connectingAddresses: Set<String> = []
  /// adb serial ("ip:port") => the phone's hardware serial, from its Bonjour name.
  private var hardwareSerials: [String: String] = [:]
  /// Turning Android on and off is asynchronous, so each change waits for the previous one.
  private var transition: Task<Void, Never>?
  /// Keyed by adb serial.
  private var mirrors: [String: Mirror] = [:]
  private var pairingPrompt: AndroidQRPairingPrompt?
  private var pairingTask: Task<Void, Never>?
  /// Sessions still cleaning up after their window closed. Turning Android off waits for them too.
  private var retiringSessions: [ObjectIdentifier: ScrcpySession] = [:]
  /// A device just paired starts mirroring as soon as it connects from here, like an iPhone does
  /// after its AirPlay password.
  private var pairedHost: String?
  /// Shows while waiting for a device that just paired to connect.
  private var pairedConnectPrompt: ProgressPrompt?
  private var pairedConnectTimeoutTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?

  init(adb: Adb, supportDirectory: URL) {
    self.adb = adb
    tracker = AndroidDeviceTracker(adb: adb)
    store = AndroidDeviceStore(fileURL: supportDirectory.appending(path: "android-devices.json"))
    tracker.onChange = { [weak self] devices in self?.connectedDevicesChanged(devices) }
    browser.onServiceFound = { [weak self] service in self?.connect(service) }
  }

  var isEnabled: Bool { Preferences.isAndroidEnabled }
  /// True for a while after discovery starts, so a menu without devices reads as still looking.
  private(set) var isSearching = false

  /// Connected phones, plus remembered ones that are away, sorted by name.
  var devices: [MirrorDevice] {
    let connected = tracker.devices
    let connectedHardwareSerials = Set(connected.compactMap { hardwareSerials[$0.serial] })
    let away = store.devices.filter { !connectedHardwareSerials.contains($0.hardwareSerial) }.map { remembered in
      MirrorDevice(
        name: remembered.model, source: .android(serial: nil, hardwareSerial: remembered.hardwareSerial),
        isConnected: false, isMirroring: false)
    }
    let present = connected.map { device in
      MirrorDevice(
        name: device.model, source: .android(serial: device.serial, hardwareSerial: hardwareSerials[device.serial]),
        isConnected: true, isMirroring: mirrors[device.serial]?.window != nil)
    }
    return (away + present).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func start() {
    if isEnabled {
      startDiscovery()
    }
  }

  func shutdown() {
    tracker.stop()
    browser.stop()
    for mirror in mirrors.values {
      mirror.session.stopWhileTerminating()
    }
    adb.stopServer()
  }

  func setEnabled(_ isEnabled: Bool) {
    Preferences.isAndroidEnabled = isEnabled
    if isEnabled {
      startDiscovery()
    } else {
      stopDiscovery()
    }
  }

  func setFloatsOnTop(_ floatsOnTop: Bool) {
    for mirror in mirrors.values {
      mirror.window?.mirrorWindow?.setFloatsOnTop(floatsOnTop)
    }
  }

  /// Brings the phone's window to the front, or starts mirroring it.
  func select(serial: String) {
    select(serial: serial, prompt: nil)
  }

  /// `prompt`, when there is one, takes over as the connecting prompt.
  private func select(serial: String, prompt: ProgressPrompt?) {
    if let window = mirrors[serial]?.window {
      prompt?.close()
      window.bringToFront()
      return
    }
    guard tracker.devices.contains(where: { $0.serial == serial }) else {
      prompt?.close()
      return
    }
    // Activate while the click still counts as the user's, since the window takes a moment to appear.
    NSApp.activate()
    startMirroring(serial: serial, prompt: prompt)
  }

  /// Only removes the phone from the menu. It comes back the next time it connects.
  func forget(hardwareSerial: String) {
    store.forget(hardwareSerial: hardwareSerial)
    Preferences.setWindowFrame(nil, forDevice: Self.windowKey(hardwareSerial: hardwareSerial))
  }

  /// One pairing at a time, so turning Android off can stop it.
  func pair() {
    if let pairingPrompt {
      pairingPrompt.bringToFront()
      return
    }
    guard pairingTask == nil else {
      return
    }
    let prompt = AndroidQRPairingPrompt(adb: adb)
    pairingPrompt = prompt
    pairingTask = Task {
      defer { pairingTask = nil }
      let outcome = await prompt.run()
      pairingPrompt = nil
      guard isEnabled, !Task.isCancelled else {
        return
      }
      let progress = ProgressPrompt(title: "Pair Android Device", status: "Pairing…")
      progress.onCancel = { self.pairingTask?.cancel() }
      let pairedHost: String?
      switch outcome {
      case .paired(let host): pairedHost = host
      case .useCode: pairedHost = await AndroidPairingPrompt.present(adb: adb, progress: progress)
      case .cancelled: pairedHost = nil
      }
      guard let pairedHost, isEnabled, !Task.isCancelled else {
        progress.close()
        return
      }
      mirrorWhenConnected(host: pairedHost, prompt: progress)
    }
  }

  private func mirrorWhenConnected(host: String, prompt: ProgressPrompt) {
    // Another device can pair while one is still being waited for, and the newest wins.
    stopWaitingForPairedDevice()
    pairedHost = host
    prompt.status = "Waiting for the device to connect…"
    prompt.onCancel = { [weak self] in self?.stopWaitingForPairedDevice() }
    prompt.show()
    pairedConnectPrompt = prompt
    mirrorPairedDevice(among: tracker.devices)
    guard pairedHost != nil else {
      return
    }
    // The device was already visible but refused Remi before pairing, so look again.
    browser.rediscover()
    pairedConnectTimeoutTask = Task {
      try? await Task.sleep(for: Self.pairedConnectTimeout)
      guard !Task.isCancelled, isEnabled else {
        return
      }
      stopWaitingForPairedDevice()
      Alert.show(
        title: "Paired",
        message: "The device will appear in Remi's menu once it connects. Click it there to start mirroring.")
    }
  }

  /// Starts mirroring the device that just paired, if it's among `devices`.
  private func mirrorPairedDevice(among devices: [AndroidDevice]) {
    guard let pairedHost, let device = devices.first(where: { AndroidDevice.host(ofAddress: $0.serial) == pairedHost })
    else {
      return
    }
    let prompt = pairedConnectPrompt
    pairedConnectPrompt = nil
    stopWaitingForPairedDevice()
    select(serial: device.serial, prompt: prompt)
  }

  private func stopWaitingForPairedDevice() {
    pairedHost = nil
    pairedConnectTimeoutTask?.cancel()
    pairedConnectTimeoutTask = nil
    pairedConnectPrompt?.close()
    pairedConnectPrompt = nil
  }

  // MARK: - Discovery and connections

  private func startDiscovery() {
    startSearching()
    let previous = transition
    transition = Task {
      await previous?.value
      await adb.restartServer()
      guard isEnabled else {
        return
      }
      tracker.start()
      browser.start()
    }
  }

  /// The timer starts here rather than once adb is up, so turning Android off and on quickly
  /// can't leave an older timer running.
  private func startSearching() {
    searchTask?.cancel()
    searchTask = Task {
      try? await Task.sleep(for: Self.searchDuration)
      if !Task.isCancelled {
        stopSearching()
      }
    }
    isSearching = true
    onDevicesChange?()
  }

  private func stopSearching() {
    searchTask?.cancel()
    searchTask = nil
    guard isSearching else {
      return
    }
    isSearching = false
    onDevicesChange?()
  }

  /// Ends mirroring, stops discovery, and stops Remi's adb server, which disconnects every
  /// phone (and clears the phone's "Wireless debugging connected" notification).
  private func stopDiscovery() {
    stopWaitingForPairedDevice()
    stopSearching()
    // Anything still using adb would start its server again, so all of it ends before kill-server.
    let qrPairing = pairingPrompt?.close()
    let pairing = pairingTask
    pairing?.cancel()
    tracker.stop()
    browser.stop()
    let sessions = mirrors.values.map(\.session) + retiringSessions.values
    for mirror in mirrors.values {
      mirror.closePrompt()
      mirror.window?.closeForSource()
    }
    mirrors.removeAll()
    let previous = transition
    transition = Task {
      await previous?.value
      await qrPairing?.value
      await pairing?.value
      for session in sessions {
        await session.stopAndWait()
      }
      _ = try? await adb.run(["kill-server"], timeout: .seconds(5))
    }
  }

  /// Unpaired phones refuse the connection, so this only connects phones paired with this Mac.
  /// Only "No route to host" (Local Network access not granted yet) is worth retrying.
  private func connect(_ service: AndroidServiceBrowser.Service) {
    let address = service.address
    if let hardwareSerial = service.hardwareSerial {
      hardwareSerials[address] = hardwareSerial
    }
    guard !connectingAddresses.contains(address) else {
      return
    }
    connectingAddresses.insert(address)
    Task {
      defer { connectingAddresses.remove(address) }
      for attempt in 1...Self.connectAttempts {
        guard isEnabled else {
          return
        }
        let result: String
        do {
          result = try await adb.run(["connect", address], timeout: .seconds(15))
          if result.contains("connected to") && !result.contains("failed") {
            Log.android.info("Connected to \(address, privacy: .private)")
            return
          }
        } catch {
          result = error.localizedDescription
        }
        Log.android.info("adb connect \(address, privacy: .private) attempt \(attempt): \(result, privacy: .private)")
        guard result.contains("No route to host") else {
          return
        }
        try? await Task.sleep(for: Self.connectRetryDelay)
      }
    }
  }

  /// Only phones Remi connected itself are remembered, since only they have a known hardware serial.
  private func connectedDevicesChanged(_ devices: [AndroidDevice]) {
    for device in devices {
      if let hardwareSerial = hardwareSerials[device.serial] {
        store.remember(.init(hardwareSerial: hardwareSerial, model: device.model))
      }
    }
    if !devices.isEmpty {
      stopSearching()
    }
    let serials = Set(devices.map(\.serial))
    for (serial, mirror) in mirrors where !serials.contains(serial) {
      retire(mirror.session)
    }
    mirrorPairedDevice(among: devices)
    onDevicesChange?()
  }

  // MARK: - Mirroring

  private func startMirroring(serial: String, prompt: ProgressPrompt?) {
    guard mirrors[serial] == nil else {
      prompt?.close()
      return
    }
    let mirror = Mirror(session: ScrcpySession(serial: serial, adb: adb))
    mirrors[serial] = mirror
    let model = tracker.devices.first { $0.serial == serial }?.model ?? "the device"
    let status = "Connecting to \(model)…"
    let prompt = prompt ?? ProgressPrompt(title: "Starting Mirroring", status: status)
    prompt.status = status
    prompt.onCancel = { [weak self, weak mirror] in
      guard let self, let mirror, mirrors[serial] === mirror else {
        return
      }
      mirrors[serial] = nil
      mirror.window?.closeForSource()
      retire(mirror.session)
    }
    // A prompt carried over from pairing is already showing, so this only delays a new one.
    prompt.show(after: Self.connectingPromptDelay)
    mirror.prompt = prompt
    Task { await run(mirror, serial: serial) }
  }

  private func run(_ mirror: Mirror, serial: String) async {
    let session = mirror.session
    do {
      let name = try await session.start { [weak self] failure in
        Task { @MainActor in self?.sessionEnded(serial: serial, session: session, failure: failure) }
      }
      guard mirrors[serial] === mirror else {
        mirror.closePrompt()
        retire(session)
        return
      }
      // A device Remi didn't connect itself has no known hardware serial, so its adb serial stands in.
      mirror.window = MirrorWindowController(
        title: name, deviceKey: Self.windowKey(hardwareSerial: hardwareSerials[serial] ?? serial), sink: session.sink,
        floatsOnTop: Preferences.isFloatOnTopEnabled
      ) { [weak self] in
        guard let self, let mirror = mirrors.removeValue(forKey: serial) else {
          return
        }
        retire(mirror.session)
        onDevicesChange?()
      }
      mirror.window?.onFirstFrame = { [weak mirror] in mirror?.closePrompt() }
      onDevicesChange?()
    } catch {
      // A mirror that's no longer current was stopped on purpose (Android turned off, or the
      // phone disconnected), so its failure isn't worth an alert.
      mirror.closePrompt()
      retire(session)
      guard mirrors[serial] === mirror else {
        return
      }
      mirrors[serial] = nil
      Alert.show(error, title: "Couldn't Start Mirroring")
    }
  }

  private static func windowKey(hardwareSerial: String) -> String {
    "android:\(hardwareSerial)"
  }

  /// Stops the session, keeping track of it until its cleanup on the device finishes.
  private func retire(_ session: ScrcpySession) {
    let id = ObjectIdentifier(session)
    retiringSessions[id] = session
    Task {
      await session.stopAndWait()
      retiringSessions[id] = nil
    }
  }

  private func sessionEnded(serial: String, session: ScrcpySession, failure: (any Error)?) {
    guard let mirror = mirrors[serial], mirror.session === session else {
      return
    }
    mirror.closePrompt()
    mirror.window?.closeForSource()
    mirrors[serial] = nil
    retire(session)
    onDevicesChange?()
    if let failure {
      Alert.show(failure, title: "Couldn't Start Mirroring")
    }
  }

}
