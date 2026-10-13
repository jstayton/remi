import AppKit
import ServiceManagement

/// Launching Remi at login. The system owns this setting (System Settings > General >
/// Login Items), so it's read from there rather than stored in Preferences.
@MainActor
enum LoginItem {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static func setEnabled(_ isEnabled: Bool) {
    do {
      if isEnabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      Alert.show(error, title: "Couldn't Change Launch at Login")
      return
    }
    // macOS can require the user to approve a new login item in System Settings.
    if isEnabled && SMAppService.mainApp.status == .requiresApproval {
      SMAppService.openSystemSettingsLoginItems()
    }
  }
}
