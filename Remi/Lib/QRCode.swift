import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCode {
  /// A crisp, black-on-white QR code of `message`, about `size` points square, rendered for Retina.
  static func image(for message: String, size: CGFloat) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(message.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else {
      return nil
    }
    // Whole-pixel scaling keeps every module's edges sharp.
    let scale = max(1, (size * 2 / output.extent.width).rounded(.down))
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
  }
}
