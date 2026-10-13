import AppKit

/// Offers to move Remi into /Applications when it's opened from anywhere else, like Downloads.
/// Run from there, an unsigned download is translocated (run from a hidden, read-only copy),
/// and Launch at Login would point somewhere temporary.
@MainActor
enum ApplicationsMover {
  /// Quitting can wait for a recording to save, but not forever.
  private static let quitTimeoutSeconds: TimeInterval = 30

  /// Returns true if Remi is relaunching from /Applications, so this launch should stop.
  static func moveIfNeeded() -> Bool {
    // Debug builds run from Xcode's build folder.
    #if DEBUG
      return false
    #else
      let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
      guard !isInApplicationsFolder(current), !Preferences.hasDeclinedMoveToApplications,
        askToMove()
      else {
        return false
      }
      do {
        let destination = try move(current)
        relaunch(from: destination)
        return true
      } catch {
        Alert.show(error, title: "Couldn't Move Remi to Applications")
        return false
      }
    #endif
  }

  /// Anywhere under /Applications or ~/Applications, like /Applications/Utilities.
  private static func isInApplicationsFolder(_ url: URL) -> Bool {
    let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
    return folders.contains { url.path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
  }

  private static func askToMove() -> Bool {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Move Remi to Applications?"
    alert.informativeText =
      "Remi works best from the Applications folder. From anywhere else, like Downloads, some features may not work."
    alert.addButton(withTitle: "Move to Applications")
    alert.addButton(withTitle: "Not Now")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask again"
    let response = alert.runModal()
    if alert.suppressionButton?.state == .on {
      Preferences.hasDeclinedMoveToApplications = true
    }
    return response == .alertFirstButtonReturn
  }

  /// Puts Remi in /Applications, replacing an older copy, and returns where it went.
  private static func move(_ current: URL) throws -> URL {
    let fileManager = FileManager.default
    let destination = URL.applicationDirectory.appending(path: current.lastPathComponent)
    var replaced: NSURL?
    do {
      if fileManager.fileExists(atPath: destination.path) {
        try quitOtherInstances()
        try fileManager.trashItem(at: destination, resultingItemURL: &replaced)
      }
      if let original = translocatedOriginal(of: current) {
        // The translocated copy is read-only, so copy it and send the download to the Trash.
        try fileManager.copyItem(at: current, to: destination)
        // macOS asks before Remi can touch Downloads. If that's denied, the download just stays.
        try? fileManager.trashItem(at: original, resultingItemURL: nil)
      } else {
        try fileManager.moveItem(at: current, to: destination)
      }
    } catch {
      // Put the replaced copy back, so a failed move doesn't leave Applications without Remi.
      if let replaced = replaced as URL? {
        try? fileManager.removeItem(at: destination)
        try? fileManager.moveItem(at: replaced, to: destination)
      }
      if let error = error as? RemiError {
        throw error
      }
      throw RemiError(.moveToApplicationsFailed, "Remi couldn't be moved to \(destination.path).", cause: error)
    }
    // The user already allowed Remi in Privacy & Security. Still quarantined, the copy would be
    // translocated again, since macOS only lifts that for apps moved in Finder.
    removeQuarantine(from: destination)
    return destination
  }

  /// An older Remi still running from /Applications would fight this one over the adb server,
  /// so one that won't quit stops the move.
  private static func quitOtherInstances() throws {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
      .filter { $0 != .current }
    for other in others {
      other.terminate()
    }
    let deadline = Date.now.addingTimeInterval(quitTimeoutSeconds)
    while others.contains(where: { !$0.isTerminated }) && Date.now < deadline {
      RunLoop.current.run(until: .now.addingTimeInterval(0.1))
    }
    guard others.allSatisfy(\.isTerminated) else {
      throw RemiError(
        .moveToApplicationsFailed, "The copy of Remi in Applications didn't quit. Quit it, then try again.")
    }
  }

  /// Where a translocated Remi was opened from. Translocation mounts the original read-only,
  /// and the mount remembers its source. Only an app with the same bundle ID counts.
  private static func translocatedOriginal(of url: URL) -> URL? {
    guard url.path.contains("/AppTranslocation/") else {
      return nil
    }
    var stats = statfs()
    guard statfs(url.path, &stats) == 0 else {
      return nil
    }
    let source = withUnsafeBytes(of: &stats.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    var original = URL(filePath: source)
    if original.pathExtension != "app" {
      original.append(path: url.lastPathComponent)
    }
    guard Bundle(url: original)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
      return nil
    }
    return original
  }

  private static func removeQuarantine(from url: URL) {
    let paths = [url.path] + (FileManager.default.subpaths(atPath: url.path) ?? []).map { url.appending(path: $0).path }
    for path in paths {
      removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
    }
  }

  private static func relaunch(from url: URL) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
      Task { @MainActor in
        if let error {
          Log.app.error("Relaunching from Applications failed: \(error, privacy: .public)")
        }
        NSApp.terminate(nil)
      }
    }
  }
}
