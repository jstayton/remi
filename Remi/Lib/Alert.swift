import AppKit

/// A modal alert brought to the front. Remi has no main window, so it activates first.
@MainActor
enum Alert {
  /// The width of an alert's extra content (a form, a QR code), so every alert with some is
  /// the same width. Narrower switches NSAlert to a side-by-side layout that's actually wider.
  static let accessoryWidth: CGFloat = 300

  static func show(title: String, message: String) {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }

  /// Logs the error with its code and cause, and shows its friendly message.
  static func show(_ error: any Error, title: String) {
    // Errors can name a device, an address, or a path, so only the title is public.
    Log.app.error("\(title, privacy: .public): \(error, privacy: .private)")
    show(title: title, message: error.localizedDescription)
  }
}
