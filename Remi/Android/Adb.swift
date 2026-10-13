import Foundation

/// Runs the bundled adb, always with argument arrays. It uses Remi's own server on a private
/// port (see the README) with adb's auto-connect off, since AndroidServiceBrowser finds phones.
/// The server leaves USB alone too: a phone plugged in can only be claimed by one adb server, and
/// Remi ignores USB anyway, so another adb (like Android Studio's) keeps it.
struct Adb: Sendable {
  private static let environment = [
    "ANDROID_ADB_SERVER_PORT": "15037", "ADB_MDNS_AUTO_CONNECT": "0",
    // Read by the adb server at startup (client/main.cpp in AOSP), but undocumented.
    "ADB_USB": "0",
  ]
  private static let killGracePeriod = Duration.seconds(2)

  let executableURL: URL

  static func bundled() throws -> Adb {
    guard let url = Bundle.main.url(forAuxiliaryExecutable: "adb") else {
      throw RemiError(.adbNotBundled, "adb is missing from Remi.app. Run bin/fetch-android-tools and rebuild.")
    }
    return Adb(executableURL: url)
  }

  /// Runs adb to completion and returns its standard output. Output is read while adb
  /// runs, so a large output can't fill the pipe and stall it. Cancelling the task stops adb.
  func run(_ arguments: [String], input: String? = nil, timeout: Duration = .seconds(30)) async throws -> String {
    let process = makeProcess(arguments)
    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = stdin
    let exit = ExitSignal()
    process.terminationHandler = { _ in exit.signal() }
    try Task.checkCancellation()
    try process.run()

    async let output = Self.readToEnd(stdout.fileHandleForReading)
    async let errorOutput = Self.readToEnd(stderr.fileHandleForReading)
    if let input {
      // adb can exit before reading its input (a pairing that fails fast). Writing to a pipe with
      // no reader then has to fail with an error, rather than kill Remi with SIGPIPE.
      let writer = stdin.fileHandleForWriting
      _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
      try? writer.write(contentsOf: Data((input + "\n").utf8))
    }
    try? stdin.fileHandleForWriting.close()

    let watchdog = Task {
      try await Task.sleep(for: timeout)
      exit.markTimedOut()
      process.terminate()
      // adb normally exits on SIGTERM; SIGKILL makes sure the timeout always returns.
      try await Task.sleep(for: Self.killGracePeriod)
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
    await withTaskCancellationHandler {
      await exit.wait()
    } onCancel: {
      process.terminate()
    }
    watchdog.cancel()

    let stdoutText = String(decoding: await output, as: UTF8.self)
    let stderrText = String(decoding: await errorOutput, as: UTF8.self)
    guard !exit.didTimeOut else {
      throw RemiError(.adbTimedOut, "adb \(arguments.first ?? "") timed out")
    }
    guard process.terminationStatus == 0 else {
      let detail = stderrText.isEmpty ? stdoutText : stderrText
      throw RemiError(
        .adbCommandFailed,
        "adb \(arguments.first ?? "") failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return stdoutText
  }

  /// Starts a long-running adb command. The caller owns the process and terminates it.
  func spawn(_ arguments: [String], standardOutput: Pipe? = nil) throws -> Process {
    let process = makeProcess(arguments)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutput ?? FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  /// Stops a server left behind by an earlier Remi, so the next command starts one owned by this launch.
  func restartServer() async {
    _ = try? await run(["kill-server"], timeout: .seconds(5))
    _ = try? await run(["start-server"], timeout: .seconds(15))
  }

  func stopServer() {
    runWhileTerminating(["kill-server"])
  }

  /// Blocks for at most a few seconds, for cleanup while the app is terminating.
  func runWhileTerminating(_ arguments: [String], timeout: TimeInterval = 3) {
    let process = makeProcess(arguments)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else {
      return
    }
    let deadline = Date.now.addingTimeInterval(timeout)
    while process.isRunning && Date.now < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
    }
  }

  private func makeProcess(_ arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(Self.environment) { $1 }
    return process
  }

  private static func readToEnd(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: handle.readDataToEndOfFile())
      }
    }
  }
}

/// Lets an async caller wait for a process's termination handler.
private final class ExitSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var hasExited = false
  private var timedOut = false
  private var continuation: CheckedContinuation<Void, Never>?

  var didTimeOut: Bool { lock.withLock { timedOut } }

  func markTimedOut() {
    lock.withLock { timedOut = true }
  }

  func signal() {
    let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
      hasExited = true
      defer { continuation = nil }
      return continuation
    }
    waiting?.resume()
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let hasAlreadyExited = lock.withLock {
        if !hasExited {
          self.continuation = continuation
        }
        return hasExited
      }
      if hasAlreadyExited {
        continuation.resume()
      }
    }
  }
}
