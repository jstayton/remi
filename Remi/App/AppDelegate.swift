import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var coordinator: MirrorCoordinator?
  private var statusMenu: StatusMenuController?

  static func main() {
    let application = NSApplication.shared
    // When hosting RemiTests, run without the delegate so tests never start AirPlay or adb.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      application.run()
      return
    }
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
      application.run()
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Nothing starts until Remi is settled where it will run.
    if ApplicationsMover.moveIfNeeded() {
      return
    }
    NSApp.mainMenu = MainMenu.make()
    do {
      let coordinator = try MirrorCoordinator()
      statusMenu = StatusMenuController(coordinator: coordinator)
      DockPresence.update()
      coordinator.start()
      self.coordinator = coordinator
    } catch {
      Alert.show(error, title: "Couldn't Start Remi")
      NSApp.terminate(nil)
    }
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    statusMenu?.makeDockMenu()
  }

  /// With no mirror window to bring back, a click on the Dock icon shows Remi's menu.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    guard !DockPresence.hasMirrorWindow else {
      return true
    }
    statusMenu?.showMenuAtPointer()
    return false
  }

  /// Recordings are only playable once they're saved, so quitting waits for them.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard MirrorWindowController.hasRecordings else {
      return .terminateNow
    }
    Task {
      await MirrorWindowController.finishRecordings()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    coordinator?.shutdown()
  }
}
