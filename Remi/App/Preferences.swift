import Foundation

enum Preferences {
  private enum Key {
    static let airPlayHardwareAddress = "airPlayHardwareAddress"
    static let hasDeclinedMoveToApplications = "hasDeclinedMoveToApplications"
    static let isAirPlayEnabled = "isAirPlayEnabled"
    static let isAndroidEnabled = "isAndroidEnabled"
    static let isFloatOnTopEnabled = "isFloatOnTopEnabled"
    static let isShowInDockEnabled = "isShowInDockEnabled"
    static let recordingTestFailure = "recordingTestFailure"
    static let windowFrames = "windowFrames"
  }

  private static var defaults: UserDefaults { .standard }

  static var isAirPlayEnabled: Bool {
    get { defaults.object(forKey: Key.isAirPlayEnabled) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.isAirPlayEnabled) }
  }

  static var isAndroidEnabled: Bool {
    get { defaults.object(forKey: Key.isAndroidEnabled) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.isAndroidEnabled) }
  }

  /// Keeps Remi in the Dock and ⌘Tab even with no mirror window open.
  static var isShowInDockEnabled: Bool {
    get { defaults.bool(forKey: Key.isShowInDockEnabled) }
    set { defaults.set(newValue, forKey: Key.isShowInDockEnabled) }
  }

  /// Set by "Don't ask again" on the Move to Applications prompt.
  static var hasDeclinedMoveToApplications: Bool {
    get { defaults.bool(forKey: Key.hasDeclinedMoveToApplications) }
    set { defaults.set(newValue, forKey: Key.hasDeclinedMoveToApplications) }
  }

  static var isFloatOnTopEnabled: Bool {
    get { defaults.bool(forKey: Key.isFloatOnTopEnabled) }
    set { defaults.set(newValue, forKey: Key.isFloatOnTopEnabled) }
  }

  /// Fakes a recording failure, to see how Remi handles it. Set it with
  /// `defaults write com.jstayton.remi recordingTestFailure -string <start|write|finish|letterbox>`.
  static var recordingTestFailure: Recording.TestFailure? {
    defaults.string(forKey: Key.recordingTestFailure).flatMap(Recording.TestFailure.init(rawValue:))
  }

  /// Each device's last mirror window frame, keyed by device, so its window reopens there.
  static func windowFrame(forDevice key: String) -> NSRect? {
    guard let string = defaults.dictionary(forKey: Key.windowFrames)?[key] as? String else {
      return nil
    }
    let frame = NSRectFromString(string)
    return frame.width > 0 && frame.height > 0 ? frame : nil
  }

  static func setWindowFrame(_ frame: NSRect?, forDevice key: String) {
    var frames = defaults.dictionary(forKey: Key.windowFrames) ?? [:]
    frames[key] = frame.map(NSStringFromRect)
    defaults.set(frames, forKey: Key.windowFrames)
  }

  /// A stable, random, locally administered MAC address, so iPhones see Remi as the same
  /// receiver across launches without exposing the Mac's real hardware address.
  static var airPlayHardwareAddress: String {
    if let address = defaults.string(forKey: Key.airPlayHardwareAddress), isValidHardwareAddress(address) {
      return address
    }
    var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
    bytes[0] = (bytes[0] & 0b1111_1100) | 0b0000_0010
    let address = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    defaults.set(address, forKey: Key.airPlayHardwareAddress)
    return address
  }

  private static func isValidHardwareAddress(_ address: String) -> Bool {
    address.wholeMatch(of: /[0-9a-f]{2}(:[0-9a-f]{2}){5}/) != nil
  }

  /// ~/Library/Application Support/Remi, created on first use.
  static func supportDirectory() throws -> URL {
    let directory = URL.applicationSupportDirectory.appending(path: "Remi", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
