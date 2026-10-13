import Foundation

/// Mirrors one phone with the scrcpy server, tunneled through adb, into a VideoSink.
/// Written against scrcpy v5.0.1's server protocol, which is internal and changes between versions.
final class ScrcpySession: @unchecked Sendable {
  static let serverVersion = "5.0.1"

  private static let deviceServerPath = "/data/local/tmp/scrcpy-server.jar"
  private static let deviceNameLength = 64
  private static let headerLength = 12
  private static let h264CodecID: UInt32 = 0x6832_3634
  private static let maxPacketSize = 16 * 1024 * 1024
  private static let connectAttempts = 100
  private static let connectRetryDelay = Duration.milliseconds(100)
  /// How long any read can wait until the first frame, from connecting on. After that there's no
  /// timeout: phones may send nothing on a still screen, and adb reports a lost phone gone.
  private static let firstFrameTimeoutSeconds = 10
  /// Caps the stream's long side, so very high-resolution devices don't overwhelm their encoder
  /// or the Wi-Fi. Common 1080p-class devices (like a 1080x2340 Pixel) stay native.
  private static let maxVideoSize = 2400
  /// Every Remi server ID starts with this byte so stale Remi servers can be found and killed.
  private static let scidPrefix: UInt32 = 0x5C00_0000

  let serial: String
  let sink = VideoSink()

  private let adb: Adb
  private let lock = NSLock()
  private var serverProcess: Process?
  private var socket: LoopbackSocket?
  private var forwardPort: UInt16?
  private var scid: String?
  private var isStopped = false
  /// Every way of stopping shares this one cleanup, so waiting on it waits for all of it.
  private var cleanupTask: Task<Void, Never>?
  /// Cleanup waits for startup to give up, since startup may still create a forward or a server.
  private var isStartingUp = false
  private var startupWaiters: [CheckedContinuation<Void, Never>] = []

  init(serial: String, adb: Adb) {
    self.serial = serial
    self.adb = adb
  }

  /// Starts the server and returns the device's name once the video stream is ready. `onEnd`
  /// runs on the reading thread when the stream stops, with an error if video never arrived.
  func start(onEnd: @escaping @Sendable ((any Error)?) -> Void) async throws -> String {
    guard let serverURL = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) else {
      throw RemiError(.scrcpyServerNotBundled, "scrcpy-server is missing from Remi.app. Run bin/fetch-android-tools.")
    }
    let scid = String(format: "%08x", Self.scidPrefix | UInt32.random(in: 0...0x00FF_FFFF))
    lock.withLock {
      self.scid = scid
      isStartingUp = true
    }
    defer { endStartup() }
    do {
      await killServers(matching: Self.scidPattern(prefixOnly: true))
      try throwIfStopped()
      _ = try await adb.run(["-s", serial, "push", serverURL.path(percentEncoded: false), Self.deviceServerPath])
      let port = try await forward(to: "scrcpy_\(scid)")
      try startServer(scid: scid)
      let socket = try await connect(port: port)
      let name = try readStreamHeader(from: socket)
      startReading(from: socket, onEnd: onEnd)
      return name
    } catch {
      stop()
      throw error
    }
  }

  /// Ending the local `adb shell` doesn't reliably end the server on the phone, and a
  /// server left running keeps the phone's video encoder busy, so it's killed explicitly.
  func stop() {
    _ = stopOnce()
  }

  /// Stops the session and waits until the server on the phone is killed, however it was stopped.
  func stopAndWait() async {
    await stopOnce().value
  }

  private struct DeviceCleanup: Sendable {
    let scid: String?
    let forwardPort: UInt16?
  }

  private func stopOnce() -> Task<Void, Never> {
    let (task, socket) = lock.withLock { () -> (Task<Void, Never>, LoopbackSocket?) in
      if let cleanupTask {
        return (cleanupTask, nil)
      }
      isStopped = true
      let task = Task.detached { [self] in
        await waitForStartupToEnd()
        await cleanUpDevice(takeDeviceResources())
      }
      cleanupTask = task
      defer { self.socket = nil }
      return (task, self.socket)
    }
    // Closing the socket ends a blocked read, so startup or the reading thread finishes.
    socket?.close()
    return task
  }

  private func takeDeviceResources() -> DeviceCleanup {
    let (process, cleanup) = lock.withLock { () -> (Process?, DeviceCleanup) in
      defer {
        serverProcess = nil
        forwardPort = nil
      }
      return (serverProcess, DeviceCleanup(scid: scid, forwardPort: forwardPort))
    }
    process?.terminate()
    return cleanup
  }

  private func waitForStartupToEnd() async {
    await withCheckedContinuation { continuation in
      let hasEnded = lock.withLock {
        if isStartingUp {
          startupWaiters.append(continuation)
        }
        return !isStartingUp
      }
      if hasEnded {
        continuation.resume()
      }
    }
  }

  private func endStartup() {
    let waiters = lock.withLock {
      isStartingUp = false
      defer { startupWaiters = [] }
      return startupWaiters
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func throwIfStopped() throws {
    if lock.withLock({ isStopped }) {
      throw CancellationError()
    }
  }

  private func cleanUpDevice(_ cleanup: DeviceCleanup) async {
    if let scid = cleanup.scid {
      await killServers(matching: Self.scidPattern(scid))
    }
    if let port = cleanup.forwardPort {
      _ = try? await adb.run(["-s", serial, "forward", "--remove", "tcp:\(port)"])
    }
  }

  /// Stops the session and waits for the server on the phone to be killed, for app termination.
  func stopWhileTerminating() {
    let scid = lock.withLock { self.scid }
    stop()
    if let scid {
      adb.runWhileTerminating(["-s", serial, "shell", "pkill", "-f", "'\(Self.scidPattern(scid))'"])
    }
  }

  private static func scidPattern(_ scid: String = "", prefixOnly: Bool = false) -> String {
    let prefix = String(format: "%02x", scidPrefix >> 24)
    return "com.genymobile.scrcpy.Server .* scid=" + (prefixOnly ? prefix : scid)
  }

  private func killServers(matching pattern: String) async {
    // pkill exits 1 when nothing matched, which is the usual case.
    _ = try? await adb.run(["-s", serial, "shell", "pkill", "-f", "'\(pattern)'"], timeout: .seconds(10))
  }

  private func forward(to socketName: String) async throws -> UInt16 {
    let output = try await adb.run(["-s", serial, "forward", "tcp:0", "localabstract:\(socketName)"])
    guard let port = UInt16(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw RemiError(.scrcpyConnectFailed, "adb forward returned an unexpected port: \(output)")
    }
    // Recorded even once stopped, so cleanup removes it.
    lock.withLock { forwardPort = port }
    try throwIfStopped()
    return port
  }

  private func startServer(scid: String) throws {
    try throwIfStopped()
    let process = try adb.spawn([
      "-s", serial, "shell",
      "CLASSPATH=\(Self.deviceServerPath)", "app_process", "/", "com.genymobile.scrcpy.Server", Self.serverVersion,
      "scid=\(scid)", "log_level=info", "tunnel_forward=true", "audio=false", "control=false", "cleanup=true",
      "video_codec=h264", "max_size=\(Self.maxVideoSize)",
    ])
    let isStopped = lock.withLock {
      if !self.isStopped {
        serverProcess = process
      }
      return self.isStopped
    }
    if isStopped {
      process.terminate()
      throw CancellationError()
    }
  }

  /// adb accepts the forwarded connection even before the server listens, so the
  /// server's dummy byte is what proves the tunnel is really connected. The socket is
  /// registered before reading, so stopping can close it, and every read has a deadline.
  private func connect(port: UInt16) async throws -> LoopbackSocket {
    for _ in 0..<Self.connectAttempts {
      try Task.checkCancellation()
      if lock.withLock({ isStopped }) {
        break
      }
      if let socket = try? LoopbackSocket.connect(port: port) {
        socket.setReadTimeout(seconds: Self.firstFrameTimeoutSeconds)
        let isRegistered = lock.withLock {
          if !isStopped {
            self.socket = socket
          }
          return !isStopped
        }
        guard isRegistered else {
          socket.close()
          break
        }
        if (try? socket.read(count: 1)) != nil {
          return socket
        }
        lock.withLock {
          if self.socket === socket {
            self.socket = nil
          }
        }
        socket.close()
      }
      try await Task.sleep(for: Self.connectRetryDelay)
    }
    throw RemiError(.scrcpyConnectFailed, "Couldn't connect to the scrcpy server on \(serial)")
  }

  private func readStreamHeader(from socket: LoopbackSocket) throws -> String {
    let nameBytes = try socket.read(count: Self.deviceNameLength)
    let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
    let codecID = Self.uint32(try socket.read(count: 4), at: 0)
    switch codecID {
    case Self.h264CodecID:
      return name.isEmpty ? serial : name
    case 0, 1:
      throw RemiError(.scrcpyStreamUnavailable, "\(name) couldn't start screen capture")
    default:
      throw RemiError(.scrcpyProtocolInvalid, "Unexpected video codec ID 0x\(String(codecID, radix: 16))")
    }
  }

  private func startReading(from socket: LoopbackSocket, onEnd: @escaping @Sendable ((any Error)?) -> Void) {
    let thread = Thread { [self] in
      var hasReceivedVideo = false
      var failure: (any Error)?
      do {
        try readPackets(from: socket) {
          hasReceivedVideo = true
        }
      } catch {
        if !lock.withLock({ isStopped }) {
          Log.android.info("Stream from \(self.serial, privacy: .private) ended: \(error, privacy: .public)")
          if !hasReceivedVideo {
            failure = RemiError(
              .scrcpyStreamUnavailable, "The device didn't send any video. Try again, or restart Wireless debugging.",
              cause: error)
          }
        }
      }
      stop()
      onEnd(failure)
    }
    thread.name = "scrcpy \(serial)"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  /// 12-byte headers: a set top bit marks a session packet (flags, width, height) sent on
  /// rotation; otherwise it's an 8-byte PTS with flags and a 4-byte payload length. The next
  /// bit marks codec configuration (SPS/PPS), which isn't video yet.
  private func readPackets(from socket: LoopbackSocket, onFirstVideo: () -> Void) throws {
    var hasReceivedVideo = false
    while true {
      let header = try socket.read(count: Self.headerLength)
      if header[0] & 0x80 != 0 {
        continue
      }
      let isConfiguration = header[0] & 0x40 != 0
      let size = Int(Self.uint32(header, at: 8))
      guard size > 0, size <= Self.maxPacketSize else {
        throw RemiError(.scrcpyProtocolInvalid, "Invalid packet size \(size)")
      }
      let payload = try socket.read(count: size)
      payload.withUnsafeBytes { sink.receive($0) }
      if !hasReceivedVideo && !isConfiguration {
        hasReceivedVideo = true
        socket.setReadTimeout(seconds: 0)
        onFirstVideo()
      }
    }
  }

  private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
  }
}
