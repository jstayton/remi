import Foundation

struct AndroidDevice: Equatable, Sendable {
  let serial: String
  let model: String

  /// Wireless debugging serials are either mDNS service names or host:port.
  static func isWireless(serial: String) -> Bool {
    serial.contains("._adb-tls-connect._tcp") || serial.wholeMatch(of: /.+:\d{1,5}/) != nil
  }

  /// The host of a "host:port" address or serial.
  static func host(ofAddress address: String) -> String {
    address.lastIndex(of: ":").map { String(address[..<$0]) } ?? address
  }
}

/// Follows `adb track-devices` and reports the wirelessly connected devices that are ready
/// (state "device"). Emulators on this Mac are skipped; USB never reaches Remi's server (see Adb).
@MainActor
final class AndroidDeviceTracker {
  private static let restartDelay = Duration.seconds(2)

  var onChange: (([AndroidDevice]) -> Void)?
  private(set) var devices: [AndroidDevice] = []

  private let adb: Adb
  private var process: Process?
  private var isRunning = false

  init(adb: Adb) {
    self.adb = adb
  }

  func start() {
    guard !isRunning else {
      return
    }
    isRunning = true
    launch()
  }

  func stop() {
    isRunning = false
    process?.terminate()
    process = nil
    connectedDevicesChanged([])
  }

  private func launch() {
    let pipe = Pipe()
    let parser = TrackDevicesParser { [weak self] devices in
      Task { @MainActor in self?.connectedDevicesChanged(devices) }
    }
    pipe.fileHandleForReading.readabilityHandler = { handle in
      parser.append(handle.availableData)
    }
    do {
      let process = try adb.spawn(["track-devices", "-l"], standardOutput: pipe)
      process.terminationHandler = { [weak self] exited in
        pipe.fileHandleForReading.readabilityHandler = nil
        Task { @MainActor in self?.relaunchAfterExit(of: exited) }
      }
      self.process = process
    } catch {
      Log.android.error("Failed to start adb track-devices: \(error, privacy: .public)")
    }
  }

  /// adb exits when its server restarts (another adb version, for example), so keep following.
  private func relaunchAfterExit(of exited: Process) {
    // A process stopped by stop() can exit after start() launched its replacement.
    guard process === exited else {
      return
    }
    process = nil
    connectedDevicesChanged([])
    guard isRunning else {
      return
    }
    Task {
      try? await Task.sleep(for: Self.restartDelay)
      if isRunning && process == nil {
        launch()
      }
    }
  }

  private func connectedDevicesChanged(_ devices: [AndroidDevice]) {
    guard devices != self.devices else {
      return
    }
    self.devices = devices
    onChange?(devices)
  }
}

/// `adb track-devices` writes messages of a 4-hex-digit length followed by that
/// many bytes of `adb devices -l` output.
final class TrackDevicesParser: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let onDevices: @Sendable ([AndroidDevice]) -> Void

  init(onDevices: @escaping @Sendable ([AndroidDevice]) -> Void) {
    self.onDevices = onDevices
  }

  func append(_ data: Data) {
    let messages: [String] = lock.withLock {
      buffer.append(data)
      var messages: [String] = []
      while buffer.count >= 4,
        let length = Int(String(decoding: buffer.prefix(4), as: UTF8.self), radix: 16),
        buffer.count >= 4 + length
      {
        messages.append(String(decoding: buffer.dropFirst(4).prefix(length), as: UTF8.self))
        buffer = Data(buffer.dropFirst(4 + length))
      }
      return messages
    }
    if let latest = messages.last {
      onDevices(Self.parse(latest))
    }
  }

  /// Lines look like: `serial  device product:x model:Pixel_8 device:y transport_id:3`.
  private static func parse(_ message: String) -> [AndroidDevice] {
    message.split(separator: "\n").compactMap { line in
      let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard fields.count >= 2, fields[1] == "device", AndroidDevice.isWireless(serial: fields[0]) else {
        return nil
      }
      let model = fields.first { $0.hasPrefix("model:") }.map { $0.dropFirst("model:".count) } ?? ""
      let name = model.replacingOccurrences(of: "_", with: " ")
      return AndroidDevice(serial: fields[0], model: name.isEmpty ? fields[0] : name)
    }
  }
}
