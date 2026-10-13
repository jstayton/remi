import AppKit

/// Remi is a menu bar app, but while a mirror window is open it becomes a regular
/// app, so the window shows up in ⌘Tab and the Dock. Show in Dock keeps it regular.
@MainActor
enum DockPresence {
  static var hasMirrorWindow: Bool {
    NSApp.windows.contains { $0 is MirrorWindow && ($0.isVisible || $0.isMiniaturized) }
  }

  static func update() {
    let policy: NSApplication.ActivationPolicy =
      hasMirrorWindow || Preferences.isShowInDockEnabled ? .regular : .accessory
    guard NSApp.activationPolicy() != policy else {
      return
    }
    let wasActive = NSApp.isActive
    NSApp.setActivationPolicy(policy)
    // An app that turns regular while it's already active gets a menu bar that won't respond
    // until it's activated again, so hand activation to the Dock and take it right back.
    if policy == .regular && wasActive {
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
      DispatchQueue.main.async {
        NSApp.activate()
      }
    }
  }
}
