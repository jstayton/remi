import AppKit

/// The menu bar menus shown while Remi is frontmost, which only happens while a mirror
/// window is open or Show in Dock is on (see DockPresence). They also supply ⌘W, ⌘M, and ⌘Q.
@MainActor
enum MainMenu {
  static func make() -> NSMenu {
    let mainMenu = NSMenu()
    mainMenu.addItem(submenuItem(appMenu()))
    mainMenu.addItem(submenuItem(fileMenu()))
    let windowMenu = windowMenu()
    mainMenu.addItem(submenuItem(windowMenu))
    NSApp.windowsMenu = windowMenu
    return mainMenu
  }

  private static func appMenu() -> NSMenu {
    let menu = NSMenu(title: "Remi")
    menu.addItem(item("Hide Remi", #selector(NSApplication.hide(_:)), "h"))
    let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(hideOthers)
    menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
    menu.addItem(.separator())
    menu.addItem(item("Quit Remi", #selector(NSApplication.terminate(_:)), "q"))
    return menu
  }

  /// The actions go to the frontmost mirror window (MirrorWindowController).
  private static func fileMenu() -> NSMenu {
    let menu = NSMenu(title: "File")
    menu.addItem(item("Save Screenshot", #selector(MirrorWindowController.saveScreenshot(_:)), "s"))
    menu.addItem(item("Copy Screenshot", #selector(MirrorWindowController.copyScreenshot(_:)), "c"))
    menu.addItem(.separator())
    menu.addItem(item("Start Recording", #selector(MirrorWindowController.toggleRecording(_:)), "r"))
    return menu
  }

  private static func windowMenu() -> NSMenu {
    let menu = NSMenu(title: "Window")
    menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
    menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
    menu.addItem(item("Reset Size", #selector(MirrorWindowController.resetSize(_:)), "0"))
    menu.addItem(.separator())
    menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
    menu.addItem(.separator())
    menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
    return menu
  }

  private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
    item.submenu = menu
    return item
  }

  /// Items without a target go to the first responder: the key window, then the app.
  private static func item(_ title: String, _ action: Selector, _ keyEquivalent: String) -> NSMenuItem {
    NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
  }
}
