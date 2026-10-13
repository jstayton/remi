import AppKit

/// Shows the code an iOS device enters as its "AirPlay password" the first time it mirrors to
/// Remi. It's non-modal, so mirroring and the menu keep working, and closes once pairing succeeds.
@MainActor
final class AirPlayPasswordPrompt: NSObject {
  /// UxPlay can't tell when a code stops working (a cancel on the device, or too many wrong
  /// tries), so an unused code is put away after this long. A new request shows a new one.
  private static let expiry = Duration.seconds(120)

  private var alert: NSAlert?
  private var expiryTask: Task<Void, Never>?

  func show(code: String) {
    close()
    let alert = NSAlert()
    alert.messageText = "Pair iOS Device"
    alert.informativeText = "When the device asks for the AirPlay password, enter this code."
    alert.accessoryView = makeAccessory(code: code)
    let button = alert.addButton(withTitle: "Close")
    button.target = self
    button.action = #selector(closeAction)
    alert.layout()
    // Alert windows are panels, which hide whenever their app isn't active, and Remi usually isn't.
    alert.window.hidesOnDeactivate = false
    alert.window.level = .floating
    alert.window.center()
    NSApp.activate()
    alert.window.makeKeyAndOrderFront(nil)
    self.alert = alert
    expiryTask = Task {
      try? await Task.sleep(for: Self.expiry)
      if !Task.isCancelled {
        close()
      }
    }
  }

  func close() {
    expiryTask?.cancel()
    expiryTask = nil
    alert?.window.orderOut(nil)
    alert = nil
  }

  @objc private func closeAction() {
    close()
  }

  /// The code, with a status line under it like the Android pairing prompt's. UxPlay doesn't
  /// report a wrong code, only success, which closes the prompt, so the status only waits.
  private func makeAccessory(code: String) -> NSView {
    let codeLabel = NSTextField(labelWithString: code.map(String.init).joined(separator: " "))
    codeLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
    codeLabel.alignment = .center
    codeLabel.isSelectable = true
    let statusLabel = NSTextField(wrappingLabelWithString: "Waiting for the device to enter the code…")
    statusLabel.preferredMaxLayoutWidth = Alert.accessoryWidth
    statusLabel.alignment = .center
    statusLabel.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [codeLabel, statusLabel])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.alignment = .centerX
    stack.widthAnchor.constraint(equalToConstant: Alert.accessoryWidth).isActive = true
    // NSAlert sizes its accessory view from the view's frame.
    stack.frame.size = stack.fittingSize
    return stack
  }
}
