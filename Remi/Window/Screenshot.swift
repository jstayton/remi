import AppKit
import UniformTypeIdentifiers

/// Saves or copies a mirror window's current frame as a PNG, the way macOS screenshots work:
/// same folder (see CaptureFile), similar names, same sound.
@MainActor
enum Screenshot {
  private static let soundPath =
    "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
  private static let sound = NSSound(contentsOfFile: soundPath, byReference: true)

  static func playSound() {
    sound?.stop()
    sound?.play()
  }

  /// Saves into the folder macOS uses for its own screenshots and returns the file's URL.
  static func save(_ image: CGImage, deviceName: String) throws -> URL {
    let url = CaptureFile.newURL(deviceName: deviceName, pathExtension: "png")
    do {
      try pngData(image).write(to: url, options: .withoutOverwriting)
    } catch {
      throw RemiError(
        .screenshotFailed, "Couldn't save the screenshot to \(url.deletingLastPathComponent().path)", cause: error)
    }
    return url
  }

  static func copy(_ image: CGImage) throws {
    let item = NSPasteboardItem()
    item.setData(try pngData(image), forType: .png)
    if let tiff = NSImage(cgImage: image, size: .zero).tiffRepresentation {
      item.setData(tiff, forType: .tiff)
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([item])
  }

  private static func pngData(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      throw RemiError(.screenshotFailed, "Couldn't encode the screenshot")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw RemiError(.screenshotFailed, "Couldn't encode the screenshot")
    }
    return data as Data
  }
}
