import AppKit

/// Pairs a phone for Wireless debugging by QR code, the way Android Studio does: the code
/// names a pairing service and a one-time password, and once the phone scans it and
/// advertises that service, Remi runs `adb pair` against it.
@MainActor
final class AndroidQRPairingPrompt: NSObject {
  enum Outcome {
    /// With the host the device paired from, which it connects from next.
    case paired(host: String)
    case useCode
    case cancelled
  }

  private static let pairingServiceType = "_adb-tls-pairing._tcp"
  /// The code holds about 45 characters (a small, 29-module QR code), so this scans easily.
  private static let qrSize: CGFloat = 140
  /// The white margin a scanner needs around a QR code.
  private static let qrMargin: CGFloat = 12
  private static let retryDelay = Duration.seconds(3)

  private let adb: Adb
  private let serviceName = "remi-" + AndroidQRPairingPrompt.randomString(length: 8)
  private let password = AndroidQRPairingPrompt.randomString(length: 12)
  private let resolver = BonjourResolver()
  private let statusLabel = NSTextField(wrappingLabelWithString: "Waiting for the device to scan the code…")
  private var alert: NSAlert?
  private var continuation: CheckedContinuation<Outcome, Never>?
  private var waitTask: Task<Void, Never>?
  /// Closing can come before the prompt has even shown, and then it shouldn't show at all.
  private var isClosed = false

  init(adb: Adb) {
    self.adb = adb
  }

  /// Returns once the prompt is closed and any pairing it started has finished.
  func run() async -> Outcome {
    guard !isClosed else {
      return .cancelled
    }
    let outcome = await withCheckedContinuation { continuation in
      self.continuation = continuation
      show()
      waitTask = Task { await waitForDevice() }
    }
    await waitTask?.value
    return outcome
  }

  /// Closes the prompt as if cancelled, stopping a pairing that's underway. Await the returned
  /// task to know the pairing's adb has exited.
  @discardableResult
  func close() -> Task<Void, Never>? {
    isClosed = true
    finish(.cancelled)
    return waitTask
  }

  func bringToFront() {
    NSApp.activate()
    alert?.window.makeKeyAndOrderFront(nil)
  }

  /// If pairing fails, the device shows an error and can scan the same code again. A rescan
  /// advertises a new port, so the failed address (which macOS may still have cached) is skipped.
  private func waitForDevice() async {
    var failedAddress: String?
    while continuation != nil {
      guard let address = await resolver.resolve(name: serviceName, type: Self.pairingServiceType) else {
        // Nil after the prompt closes ends the loop; nil after a DNS-SD error means look again.
        try? await Task.sleep(for: Self.retryDelay)
        continue
      }
      guard continuation != nil, !Task.isCancelled else {
        return
      }
      guard address != failedAddress else {
        try? await Task.sleep(for: Self.retryDelay)
        continue
      }
      statusLabel.stringValue = "Pairing…"
      do {
        // The password goes in on stdin so it never shows up in the process list.
        _ = try await adb.run(["pair", address], input: password)
        finish(.paired(host: AndroidDevice.host(ofAddress: address)))
        return
      } catch {
        // adb's output names the device's address.
        Log.android.error("QR pairing failed: \(error, privacy: .private)")
        statusLabel.stringValue = "Couldn't pair. Scan the code again."
        failedAddress = address
      }
    }
  }

  private func finish(_ outcome: Outcome) {
    guard let continuation else {
      return
    }
    self.continuation = nil
    resolver.cancel()
    waitTask?.cancel()
    alert?.window.orderOut(nil)
    alert = nil
    continuation.resume(returning: outcome)
  }

  @objc private func useCode() {
    finish(.useCode)
  }

  @objc private func cancel() {
    finish(.cancelled)
  }

  /// A standard alert, like the pairing-code form, but shown without blocking so it can
  /// stay open while Remi waits for the scan and close itself once pairing succeeds.
  private func show() {
    let alert = NSAlert()
    alert.messageText = "Pair Android Device"
    alert.informativeText =
      "On the device, open Developer options > Wireless debugging > Pair device with QR code, then scan this code."
    alert.accessoryView = makeAccessory()
    let cancelButton = alert.addButton(withTitle: "Cancel")
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    let useCodeButton = alert.addButton(withTitle: "Use Pairing Code…")
    useCodeButton.target = self
    useCodeButton.action = #selector(useCode)
    alert.layout()
    // Alert windows are panels, which hide whenever their app isn't active, and Remi usually isn't.
    alert.window.hidesOnDeactivate = false
    alert.window.level = .floating
    alert.window.center()
    NSApp.activate()
    alert.window.makeKeyAndOrderFront(nil)
    self.alert = alert
  }

  private func makeAccessory() -> NSView {
    statusLabel.preferredMaxLayoutWidth = Alert.accessoryWidth
    statusLabel.alignment = .center
    statusLabel.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [makeQRView(), statusLabel])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.alignment = .centerX
    stack.widthAnchor.constraint(equalToConstant: Alert.accessoryWidth).isActive = true
    // NSAlert sizes its accessory view from the view's frame.
    stack.frame.size = stack.fittingSize
    return stack
  }

  /// QR codes need a light background with a margin to scan, even in dark mode.
  private func makeQRView() -> NSView {
    let message = "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
    let imageView = NSImageView(image: QRCode.image(for: message, size: Self.qrSize) ?? NSImage())
    imageView.imageScaling = .scaleNone
    let box = NSView()
    box.wantsLayer = true
    box.layer?.backgroundColor = NSColor.white.cgColor
    box.layer?.cornerRadius = 8
    box.addSubview(imageView)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: box.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: box.centerYAnchor),
      box.widthAnchor.constraint(equalToConstant: Self.qrSize + 2 * Self.qrMargin),
      box.heightAnchor.constraint(equalToConstant: Self.qrSize + 2 * Self.qrMargin),
    ])
    return box
  }

  /// Letters and digits only, so nothing needs escaping in the QR code's WIFI: format.
  private static func randomString(length: Int) -> String {
    let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    return String((0..<length).map { _ in characters.randomElement()! })
  }
}
