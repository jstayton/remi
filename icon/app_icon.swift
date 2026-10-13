import CoreGraphics
import Foundation
import ImageIO

// Renders Remi's 1024px app icon on the standard macOS icon grid: an 824px
// rounded square centered on a 1024px canvas. Run through bin/render-app-icon.
//
// A phone-shaped retro TV with rabbit ears, split into cyan and magenta edges
// like a misaligned CRT, with a mirror's shine across its screen. Flat colors
// only: no gradients or shadows.

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

let tileColor: UInt32 = 0x0B0B0B
let bodyColor: UInt32 = 0xF4F0E6
let cyan: UInt32 = 0x00E5FF
let magenta: UInt32 = 0xFF2BD6
/// How far each color channel is shifted, as a fraction of the drawing box.
let glitchOffset: CGFloat = 0.025

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
  data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0, space: space,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// A rect in `box`, given as fractions of its size (y up).
func rect(_ box: CGRect, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
  CGRect(
    x: box.minX + x0 * box.width, y: box.minY + y0 * box.height, width: (x1 - x0) * box.width,
    height: (y1 - y0) * box.height)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The TV's antennas, feet, and body in one color. The menu bar icon in
/// StatusIcon.swift draws the same shape.
func drawSilhouette(in box: CGRect, color fill: CGColor) {
  let size = box.width
  context.setStrokeColor(fill)
  context.setLineWidth(0.05 * size)
  context.setLineCap(.round)
  for end in [CGPoint(x: 0.36, y: 0.94), CGPoint(x: 0.64, y: 0.97)] {
    context.move(to: CGPoint(x: box.minX + 0.5 * size, y: box.minY + 0.76 * size))
    context.addLine(to: CGPoint(x: box.minX + end.x * size, y: box.minY + end.y * size))
  }
  context.strokePath()
  context.setFillColor(fill)
  for x in [0.37, 0.63] as [CGFloat] {
    context.addPath(rounded(rect(box, x - 0.045, 0.04, x + 0.045, 0.10), 0.012 * size))
  }
  context.addPath(rounded(rect(box, 0.27, 0.09, 0.73, 0.78), 0.06 * size))
  context.fillPath()
}

context.addPath(rounded(tile, tileRadius))
context.clip()
context.setFillColor(color(tileColor))
context.fill(tile)

let box = tile.insetBy(dx: tile.width * 0.11, dy: tile.height * 0.11)

// The color channels, shifted apart. Screen blending keeps them bright where they overlap.
context.setBlendMode(.screen)
drawSilhouette(in: box.offsetBy(dx: -glitchOffset * box.width, dy: 0), color: color(cyan))
drawSilhouette(in: box.offsetBy(dx: glitchOffset * box.width, dy: 0), color: color(magenta))
context.setBlendMode(.normal)

drawSilhouette(in: box, color: color(bodyColor))

// The screen and knobs are cut out in the tile color.
let screen = rounded(rect(box, 0.335, 0.25, 0.665, 0.71), 0.036 * box.width)
context.setFillColor(color(tileColor))
context.addPath(screen)
for x in [0.43, 0.57] as [CGFloat] {
  context.addEllipse(in: rect(box, x - 0.03, 0.14, x + 0.03, 0.20))
}
context.fillPath()

/// A diagonal glare streak across the screen, from and to points given as fractions of `box`.
func drawShine(from start: CGPoint, to end: CGPoint, width: CGFloat) {
  context.setLineWidth(width * box.width)
  context.move(to: CGPoint(x: box.minX + start.x * box.width, y: box.minY + start.y * box.height))
  context.addLine(to: CGPoint(x: box.minX + end.x * box.width, y: box.minY + end.y * box.height))
  context.strokePath()
}

// Two streaks of glare, the classic sign of a mirror.
context.saveGState()
context.addPath(screen)
context.clip()
context.setStrokeColor(color(bodyColor))
context.setLineCap(.round)
drawShine(from: CGPoint(x: 0.40, y: 0.50), to: CGPoint(x: 0.52, y: 0.65), width: 0.035)
drawShine(from: CGPoint(x: 0.42, y: 0.40), to: CGPoint(x: 0.59, y: 0.61), width: 0.018)
context.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
