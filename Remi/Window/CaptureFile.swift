import Foundation

/// Where screenshots and recordings go: the folder macOS uses for its own screenshots, with
/// names like its "Screenshot 2026-10-11 at 15.04.06".
enum CaptureFile {
  /// A URL in `folder` (the capture folder by default) that doesn't exist yet, named for `date`.
  static func newURL(deviceName: String, date: Date = .now, pathExtension: String, in folder: URL? = nil) -> URL {
    let folder = folder ?? self.folder()
    let baseName = baseName(deviceName: deviceName, date: date)
    var url = folder.appending(path: "\(baseName).\(pathExtension)")
    var number = 2
    while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      url = folder.appending(path: "\(baseName) (\(number)).\(pathExtension)")
      number += 1
    }
    return url
  }

  /// macOS stores a custom screenshot folder in com.apple.screencapture; it's the Desktop otherwise.
  static func folder() -> URL {
    if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
      let folder = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return folder
      }
    }
    return URL.desktopDirectory
  }

  /// "/" and ":" are made safe for Finder.
  private static func baseName(deviceName: String, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let safeName = deviceName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    return "Remi \(safeName) \(formatter.string(from: date))"
  }
}
