import AppKit

/// A non-modal alert with an indeterminate progress bar and a status line, for a wait the user
/// started, like pairing or connecting. It can wait a moment before appearing, so a quick wait
/// never flashes on screen.
@MainActor
final class ProgressPrompt: NSObject {
  var onCancel: () -> Void = {}

  private let alert = NSAlert()
  private let progressIndicator = NSProgressIndicator()
  private let statusLabel = NSTextField(labelWithString: "")
  private var showTask: Task<Void, Never>?
  private var isClosed = false

  init(title: String, status: String) {
    super.init()
    alert.messageText = title
    statusLabel.stringValue = status
    alert.accessoryView = makeAccessory()
    let button = alert.addButton(withTitle: "Cancel")
    button.target = self
    button.action = #selector(cancel)
    // Return shouldn't cancel by accident, so only Escape does.
    button.keyEquivalent = "\u{1b}"
  }

  var status: String {
    get { statusLabel.stringValue }
    set { statusLabel.stringValue = newValue }
  }

  func show(after delay: Duration = .zero) {
    guard !isClosed, showTask == nil else {
      return
    }
    showTask = Task {
      try? await Task.sleep(for: delay)
      if !Task.isCancelled && !isClosed {
        present()
      }
    }
  }

  func close() {
    isClosed = true
    showTask?.cancel()
    progressIndicator.stopAnimation(nil)
    alert.window.orderOut(nil)
  }

  @objc private func cancel() {
    close()
    onCancel()
  }

  private func present() {
    progressIndicator.startAnimation(nil)
    alert.layout()
    // Alert windows are panels, which hide whenever their app isn't active, and Remi usually isn't.
    alert.window.hidesOnDeactivate = false
    alert.window.level = .floating
    alert.window.center()
    NSApp.activate()
    alert.window.makeKeyAndOrderFront(nil)
  }

  /// The status line sits under the bar, like the pairing prompts' waiting lines. It's one line,
  /// since the alert doesn't resize once it's showing.
  private func makeAccessory() -> NSView {
    progressIndicator.isIndeterminate = true
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.alignment = .center
    statusLabel.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [progressIndicator, statusLabel])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.alignment = .centerX
    stack.widthAnchor.constraint(equalToConstant: Alert.accessoryWidth).isActive = true
    progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    // NSAlert sizes its accessory view from the view's frame.
    stack.frame.size = stack.fittingSize
    return stack
  }
}
