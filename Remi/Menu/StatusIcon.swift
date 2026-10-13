import AppKit

/// The app icon's TV as a one-color template image, so macOS tints it for light mode,
/// dark mode, and highlighting. The glitch colors only exist in icon/app_icon.swift.
@MainActor
enum StatusIcon {
  private static let size = NSSize(width: 18, height: 18)

  static func make() -> NSImage {
    let image = NSImage(size: size, flipped: false) { bounds in
      draw(in: bounds)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Remi"
    return image
  }

  /// Same proportions as the app icon, with thicker antennas so they hold up at 18pt.
  private static func draw(in box: NSRect) {
    NSColor.black.set()

    let antennas = NSBezierPath()
    antennas.lineWidth = 0.09 * box.width
    antennas.lineCapStyle = .round
    for end in [NSPoint(x: 0.36, y: 0.94), NSPoint(x: 0.64, y: 0.97)] {
      antennas.move(to: point(in: box, x: 0.5, y: 0.76))
      antennas.line(to: point(in: box, x: end.x, y: end.y))
    }
    antennas.stroke()

    for x in [0.37, 0.63] as [CGFloat] {
      NSBezierPath(rect: rect(in: box, x - 0.05, 0.03, x + 0.05, 0.10)).fill()
    }

    // The body, with the screen and knobs cut out by the even-odd rule.
    let body = NSBezierPath(
      roundedRect: rect(in: box, 0.24, 0.09, 0.76, 0.78), xRadius: 0.08 * box.width, yRadius: 0.08 * box.width)
    body.append(
      NSBezierPath(
        roundedRect: rect(in: box, 0.33, 0.27, 0.67, 0.69), xRadius: 0.04 * box.width, yRadius: 0.04 * box.width))
    for x in [0.42, 0.58] as [CGFloat] {
      body.append(NSBezierPath(ovalIn: rect(in: box, x - 0.04, 0.14, x + 0.04, 0.22)))
    }
    body.windingRule = .evenOdd
    body.fill()
  }

  private static func point(in box: NSRect, x: CGFloat, y: CGFloat) -> NSPoint {
    NSPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
  }

  private static func rect(in box: NSRect, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> NSRect {
    NSRect(
      x: box.minX + x0 * box.width, y: box.minY + y0 * box.height, width: (x1 - x0) * box.width,
      height: (y1 - y0) * box.height)
  }
}
