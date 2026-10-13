import AppKit

/// A titled window with a transparent title bar over the mirror view's bezel, so
/// it has the standard window buttons but no visible title or title bar.
final class MirrorWindow: NSWindow {
  init(contentView: NSView) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    self.contentView = contentView
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isMovableByWindowBackground = true
    backgroundColor = .black
    isReleasedWhenClosed = false
    tabbingMode = .disallowed
  }

  override var canBecomeKey: Bool { true }

  func setFloatsOnTop(_ floatsOnTop: Bool) {
    level = floatsOnTop ? .floating : .normal
    // The green button zooms rather than entering full screen.
    collectionBehavior = floatsOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenNone]
  }
}
