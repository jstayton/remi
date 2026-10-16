import AppKit

/// The menu bar item, which is Remi's only UI besides mirror windows. The menu is
/// rebuilt each time it opens, and while it's open whenever devices come and go, so it
/// always reflects the current devices. The Dock icon, when there is one, offers the same menu.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
  private let coordinator: MirrorCoordinator
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  /// The menu bar menu or the menu at the pointer, whichever is open.
  private var openMenu: NSMenu?
  private var shownDevices: [MirrorDevice] = []
  private var shownIsAndroidSearching = false

  init(coordinator: MirrorCoordinator) {
    self.coordinator = coordinator
    super.init()
    statusItem.button?.image = StatusIcon.make()
    menu.delegate = self
    menu.autoenablesItems = false
    statusItem.menu = menu
    coordinator.onDevicesChange = { [weak self] in self?.devicesChanged() }
  }

  func menuWillOpen(_ menu: NSMenu) {
    openMenu = menu
  }

  func menuDidClose(_ menu: NSMenu) {
    if openMenu === menu {
      openMenu = nil
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    shownDevices = coordinator.devices
    shownIsAndroidSearching = coordinator.isAndroidSearching
    menu.removeAllItems()
    addItems(to: menu)
    // The menu at the pointer stands in for the Dock menu, which has no Quit.
    guard menu === self.menu else {
      return
    }
    menu.addItem(.separator())
    let quitItem = item("Quit Remi", action: #selector(quit))
    quitItem.keyEquivalent = "q"
    menu.addItem(quitItem)
  }

  /// Only a real change rebuilds the open menu, since rebuilding closes an open submenu.
  private func devicesChanged() {
    guard let openMenu,
      coordinator.devices != shownDevices || coordinator.isAndroidSearching != shownIsAndroidSearching
    else {
      return
    }
    menuNeedsUpdate(openMenu)
  }

  /// The menu without Quit, which the Dock adds itself.
  func makeDockMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    addItems(to: menu)
    return menu
  }

  /// For a click on the Dock icon with no mirror window, such as when the menu bar icon is
  /// hidden behind the notch.
  func showMenuAtPointer() {
    let menu = makeDockMenu()
    // Kept current while it's open, like the menu bar menu.
    menu.delegate = self
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  private func addItems(to menu: NSMenu) {
    let devices = coordinator.devices
    let iOSDevices = devices.filter { !$0.isAndroid }
    let androidDevices = devices.filter(\.isAndroid)
    addIOSSection(iOSDevices, to: menu)
    menu.addItem(.separator())
    addAndroidSection(androidDevices, to: menu)
    menu.addItem(.separator())
    menu.addItem(item("Float on Top", action: #selector(toggleFloatOnTop), isOn: Preferences.isFloatOnTopEnabled))
    menu.addItem(settingsItem(iOSDevices: iOSDevices, androidDevices: androidDevices))
  }

  private func addIOSSection(_ devices: [MirrorDevice], to menu: NSMenu) {
    menu.addItem(.sectionHeader(title: "iOS"))
    menu.addItem(
      toggleItem(isOn: coordinator.isAirPlayEnabled, action: #selector(toggleAirPlay)))
    // Like the Wi-Fi and Bluetooth menus, devices are only listed while the section is on.
    if coordinator.isAirPlayEnabled {
      addDeviceItems(devices, to: menu, awayTip: "Start Screen Mirroring on the device to connect.")
    }
  }

  private func addAndroidSection(_ devices: [MirrorDevice], to menu: NSMenu) {
    menu.addItem(.sectionHeader(title: "Android"))
    let onOffItem = toggleItem(isOn: coordinator.isAndroidEnabled, action: #selector(toggleAndroid))
    onOffItem.isEnabled = coordinator.isAndroidAvailable
    menu.addItem(onOffItem)
    if coordinator.isAndroidEnabled {
      addDeviceItems(devices, to: menu, awayTip: "Turn on Wireless debugging on the device to connect.")
      if coordinator.isAndroidSearching {
        let searchingItem = NSMenuItem(title: "Searching…", action: nil, keyEquivalent: "")
        searchingItem.isEnabled = false
        menu.addItem(searchingItem)
      }
    }
    let pairItem = item("Pair Device…", action: #selector(pairAndroidDevice))
    pairItem.isEnabled = coordinator.isAndroidAvailable && coordinator.isAndroidEnabled
    menu.addItem(pairItem)
  }

  private func addDeviceItems(_ devices: [MirrorDevice], to menu: NSMenu, awayTip: String) {
    for device in devices {
      let deviceItem = item(device.name, action: #selector(selectDevice), isOn: device.isMirroring)
      deviceItem.representedObject = DeviceBox(device)
      deviceItem.isEnabled = device.isConnected
      deviceItem.toolTip = device.isConnected ? nil : awayTip
      // An icon sets devices apart from the section's actions.
      deviceItem.image = NSImage(
        systemSymbolName: device.isAndroid ? "smartphone" : "iphone", accessibilityDescription: nil)
      // macOS 27 hides menu item images unless an item asks for them. The macOS 26 SDK
      // (Xcode 26) doesn't have the property.
      #if compiler(>=6.4)
        if #available(macOS 27, *) {
          deviceItem.preferredImageVisibility = .visible
        }
      #endif
      menu.addItem(deviceItem)
    }
  }

  /// Things set once or rarely, kept out of the main menu.
  private func settingsItem(iOSDevices: [MirrorDevice], androidDevices: [MirrorDevice]) -> NSMenuItem {
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    submenu.addItem(item("Launch at Login", action: #selector(toggleLaunchAtLogin), isOn: LoginItem.isEnabled))
    submenu.addItem(item("Show in Dock", action: #selector(toggleShowInDock), isOn: Preferences.isShowInDockEnabled))
    submenu.addItem(.separator())
    let forgetItem = NSMenuItem(title: "Forget Device", action: nil, keyEquivalent: "")
    forgetItem.submenu = forgetDeviceMenu(iOSDevices: iOSDevices, androidDevices: androidDevices)
    submenu.addItem(forgetItem)

    let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    settingsItem.submenu = submenu
    return settingsItem
  }

  private func forgetDeviceMenu(iOSDevices: [MirrorDevice], androidDevices: [MirrorDevice]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(.sectionHeader(title: "iOS"))
    // Forgetting asks first, because the device will need a new AirPlay password.
    addForgetItems(iOSDevices, titleSuffix: "…", emptyTitle: "No Paired Devices", to: menu)
    menu.addItem(.sectionHeader(title: "Android"))
    // A connected device would reappear right away, so only devices that are away can be forgotten.
    addForgetItems(
      androidDevices.filter { !$0.isConnected }, titleSuffix: "", emptyTitle: "No Disconnected Devices", to: menu)
    return menu
  }

  private func addForgetItems(_ devices: [MirrorDevice], titleSuffix: String, emptyTitle: String, to menu: NSMenu) {
    guard !devices.isEmpty else {
      let placeholder = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
      placeholder.isEnabled = false
      menu.addItem(placeholder)
      return
    }
    for device in devices {
      let deviceItem = item(device.name + titleSuffix, action: #selector(forgetDevice))
      deviceItem.representedObject = DeviceBox(device)
      menu.addItem(deviceItem)
    }
  }

  /// Says what clicking does, like the classic "Turn Wi-Fi Off", since a checkmark next to
  /// "Enabled" reads oddly when it's off.
  private func toggleItem(isOn: Bool, action: Selector) -> NSMenuItem {
    item(isOn ? "Turn Off" : "Turn On", action: action)
  }

  private func item(_ title: String, action: Selector, isOn: Bool = false) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.state = isOn ? .on : .off
    return item
  }

  @objc private func toggleAirPlay() {
    coordinator.setAirPlayEnabled(!coordinator.isAirPlayEnabled)
  }

  @objc private func toggleAndroid() {
    coordinator.setAndroidEnabled(!coordinator.isAndroidEnabled)
  }

  @objc private func selectDevice(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? DeviceBox else {
      return
    }
    coordinator.select(box.device)
  }

  @objc private func pairAndroidDevice() {
    coordinator.pairAndroidDevice()
  }

  @objc private func forgetDevice(_ sender: NSMenuItem) {
    guard let box = sender.representedObject as? DeviceBox else {
      return
    }
    coordinator.forget(box.device)
  }

  @objc private func toggleFloatOnTop() {
    coordinator.setFloatOnTop(!Preferences.isFloatOnTopEnabled)
  }

  @objc private func toggleLaunchAtLogin() {
    LoginItem.setEnabled(!LoginItem.isEnabled)
  }

  @objc private func toggleShowInDock() {
    Preferences.isShowInDockEnabled.toggle()
    DockPresence.update()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}

/// NSMenuItem.representedObject needs an object.
private final class DeviceBox {
  let device: MirrorDevice

  init(_ device: MirrorDevice) {
    self.device = device
  }
}
