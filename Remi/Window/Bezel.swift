import AppKit

/// The thin frame around the mirror window's screen.
enum Bezel {
  static let width: CGFloat = 6
  /// What AppKit uses for titled windows on macOS 26 and 27 (it has no public API for it).
  static let windowCornerRadius: CGFloat = 16
  /// Concentric with the window's corners, so the bezel is the same width all the way around.
  static let screenCornerRadius = windowCornerRadius - width
  static let color = NSColor(white: 0.08, alpha: 1)
  static let edgeColor = NSColor(white: 0.16, alpha: 1)

  /// The space between the window's edges and its screen. The top is the title bar, so the
  /// window buttons sit on the bezel.
  static func insets(titleBarHeight: CGFloat) -> NSEdgeInsets {
    NSEdgeInsets(top: titleBarHeight, left: width, bottom: width, right: width)
  }

  /// Makes `layer` the black screen with its rounded grey edge.
  static func styleScreen(_ layer: CALayer) {
    layer.backgroundColor = NSColor.black.cgColor
    layer.cornerRadius = screenCornerRadius
    // macOS draws window corners as continuous curves, not circular arcs.
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    layer.borderWidth = 1
    layer.borderColor = edgeColor.cgColor
  }
}
