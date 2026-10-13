import AppKit

/// Shows progress while a rotated recording is re-encoded (see Letterboxer), which takes a
/// while for a long one. It only appears if re-encoding outlasts a moment, and Skip saves the
/// recording as it arrived instead.
@MainActor
final class RecordingSavePrompt: NSObject {
  private static let delay = Duration.seconds(1)

  var onSkip: () -> Void = {}

  private let progressIndicator = NSProgressIndicator()
  private var alert: NSAlert?
  private var delayTask: Task<Void, Never>?
  private var isClosed = false

  /// From 0 to 1. The first update starts the delay before the prompt appears.
  func update(_ fraction: Double) {
    guard !isClosed else {
      return
    }
    progressIndicator.doubleValue = fraction
    guard delayTask == nil else {
      return
    }
    delayTask = Task {
      try? await Task.sleep(for: Self.delay)
      if !Task.isCancelled {
        show()
      }
    }
  }

  func close() {
    isClosed = true
    delayTask?.cancel()
    alert?.window.orderOut(nil)
    alert = nil
  }

  @objc private func skip() {
    onSkip()
    close()
  }

  /// A standard alert, shown without blocking. It doesn't activate Remi: a save can start
  /// without a click (the device disconnected), and shouldn't take focus from another app.
  private func show() {
    let alert = NSAlert()
    alert.messageText = "Saving Recording"
    alert.informativeText =
      "The device rotated during the recording, so it's being re-encoded to play correctly everywhere. "
      + "Skip to save it as is."
    progressIndicator.isIndeterminate = false
    progressIndicator.minValue = 0
    progressIndicator.maxValue = 1
    progressIndicator.frame.size.width = Alert.accessoryWidth
    alert.accessoryView = progressIndicator
    let button = alert.addButton(withTitle: "Skip")
    button.target = self
    button.action = #selector(skip)
    alert.layout()
    // Alert windows are panels, which hide whenever their app isn't active, and Remi usually isn't.
    alert.window.hidesOnDeactivate = false
    alert.window.level = .floating
    alert.window.center()
    alert.window.orderFrontRegardless()
    self.alert = alert
  }
}
