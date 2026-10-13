import Foundation

/// Advertises Remi as an AirPlay receiver named "Remi" and turns a screen
/// mirroring session into video packets. UxPlay supports one client at a time.
@MainActor
final class AirPlayReceiver {
  enum Event: Sendable {
    case sessionStarted(name: String, deviceID: String, sink: VideoSink)
    case sessionEnded
    case connectionLost
    case codeRequested(String)
    case clientPaired(name: String)
  }

  private static let serviceName = "Remi"

  let clientStore: AirPlayClientStore
  var onEvent: ((Event) -> Void)?

  private var handle: OpaquePointer?
  private var context: Unmanaged<AirPlayCallbackContext>?
  /// Changes on every start and stop. Events reach the main actor later, so one from a receiver
  /// that has since stopped (AirPlay turned off, or restarted) is recognized and dropped.
  private var generation = 0

  init(clientStore: AirPlayClientStore) {
    self.clientStore = clientStore
  }

  var isRunning: Bool { handle != nil }

  func start() throws {
    guard handle == nil else {
      return
    }
    let keyfile = try Preferences.supportDirectory().appending(path: "airplay-key.pem").path(percentEncoded: false)
    generation += 1
    let startedGeneration = generation
    let callbackContext = AirPlayCallbackContext(clientStore: clientStore) { [weak self] event in
      Task { @MainActor in
        guard let self, self.generation == startedGeneration else {
          return
        }
        self.onEvent?(event)
      }
    }
    let retainedContext = Unmanaged.passRetained(callbackContext)
    var error = [CChar](repeating: 0, count: 256)
    let started = remi_airplay_start(
      Self.serviceName, Preferences.airPlayHardwareAddress, keyfile,
      AirPlayCallbackContext.callbacks(context: retainedContext.toOpaque()), &error, error.count)
    guard let started else {
      retainedContext.release()
      let reason = String(decoding: error.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
      throw RemiError(.airPlayStartFailed, "Failed to start the AirPlay receiver: \(reason)")
    }
    handle = started
    context = retainedContext
    Log.airPlay.info("AirPlay receiver started")
  }

  /// Stopping drops any connected iPhone, which is also how Remi ends a session from the Mac.
  func stop() {
    guard let handle else {
      return
    }
    remi_airplay_stop(handle)
    self.handle = nil
    generation += 1
    context?.release()
    context = nil
    Log.airPlay.info("AirPlay receiver stopped")
  }

  func restart() throws {
    stop()
    try start()
  }
}

/// Bridges UxPlay's C callbacks, which arrive on UxPlay's threads, to Swift.
private final class AirPlayCallbackContext: @unchecked Sendable {
  private let lock = NSLock()
  private let clientStore: AirPlayClientStore
  private let post: @Sendable (AirPlayReceiver.Event) -> Void
  private var clientName = "iOS Device"
  private var clientDeviceID = ""
  private var sink: VideoSink?

  init(clientStore: AirPlayClientStore, post: @escaping @Sendable (AirPlayReceiver.Event) -> Void) {
    self.clientStore = clientStore
    self.post = post
  }

  static func callbacks(context: UnsafeMutableRawPointer) -> remi_airplay_callbacks {
    remi_airplay_callbacks(
      context: context,
      log: { context, level, message in
        AirPlayCallbackContext.from(context).log(level: level, message: AirPlayCallbackContext.string(message))
      },
      client_requested: { context, deviceID, _, name in
        AirPlayCallbackContext.from(context).clientRequested(
          deviceID: AirPlayCallbackContext.string(deviceID), name: AirPlayCallbackContext.string(name))
      },
      mirroring_changed: { context, isRunning in
        AirPlayCallbackContext.from(context).mirroringChanged(isRunning: isRunning)
      },
      video: { context, data, length in
        guard let data, length > 0 else {
          return
        }
        AirPlayCallbackContext.from(context).video(UnsafeRawBufferPointer(start: data, count: Int(length)))
      },
      connection_lost: { context in
        AirPlayCallbackContext.from(context).connectionLost()
      },
      pin_requested: { context, pin in
        AirPlayCallbackContext.from(context).post(.codeRequested(AirPlayCallbackContext.string(pin)))
      },
      client_paired: { context, deviceID, publicKey, name in
        AirPlayCallbackContext.from(context).clientPaired(
          deviceID: AirPlayCallbackContext.string(deviceID), publicKey: AirPlayCallbackContext.string(publicKey),
          name: AirPlayCallbackContext.string(name))
      },
      is_client_paired: { context, publicKey in
        AirPlayCallbackContext.from(context).clientStore.contains(publicKey: AirPlayCallbackContext.string(publicKey))
      })
  }

  private static func from(_ context: UnsafeMutableRawPointer?) -> AirPlayCallbackContext {
    Unmanaged<AirPlayCallbackContext>.fromOpaque(context!).takeUnretainedValue()
  }

  private static func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
  }

  /// UxPlay's messages carry local IP addresses and device IDs, so they're private.
  private func log(level: Int32, message: String) {
    // UxPlay logs the AirPlay password as it's issued. Remi shows it on screen instead.
    guard !message.contains("MUST NOW ENTER PIN") else {
      return
    }
    switch level {
    case ...3: Log.airPlay.error("\(message, privacy: .private)")
    case 4: Log.airPlay.warning("\(message, privacy: .private)")
    case 5...6: Log.airPlay.info("\(message, privacy: .private)")
    default: Log.airPlay.debug("\(message, privacy: .private)")
    }
  }

  private func clientRequested(deviceID: String, name: String) {
    lock.withLock {
      clientDeviceID = deviceID
      clientName = name.isEmpty ? "iOS Device" : name
    }
  }

  private func mirroringChanged(isRunning: Bool) {
    let event: AirPlayReceiver.Event = lock.withLock {
      if isRunning {
        let newSink = VideoSink()
        sink = newSink
        return .sessionStarted(name: clientName, deviceID: clientDeviceID, sink: newSink)
      }
      sink = nil
      return .sessionEnded
    }
    post(event)
  }

  private func video(_ bytes: UnsafeRawBufferPointer) {
    lock.withLock { sink }?.receive(bytes)
  }

  private func connectionLost() {
    lock.withLock { sink = nil }
    post(.connectionLost)
  }

  private func clientPaired(deviceID: String, publicKey: String, name: String) {
    do {
      try clientStore.add(.init(deviceID: deviceID, name: name, publicKey: publicKey))
      post(.clientPaired(name: name))
    } catch {
      Log.airPlay.error("Failed to save a paired device: \(error, privacy: .private)")
    }
  }
}
