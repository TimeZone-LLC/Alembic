import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var alembicActivity: NSObjectProtocol?

  override func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.disableRelaunchOnLogin()
    alembicActivity = ProcessInfo.processInfo.beginActivity(
      options: [.automaticTerminationDisabled],
      reason: "Alembic menu bar"
    )
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    installWorkspaceMenus()
    if let settingsItem: NSMenuItem = applicationMenu?.items.first(where: {
      $0.keyEquivalent == ","
    }) {
      settingsItem.title = "Settings…"
      settingsItem.target = self
      settingsItem.action = #selector(openSettings(_:))
    }
    if Thread.isMainThread {
      AlembicTrayController.shared.install()
    } else {
      DispatchQueue.main.async {
        AlembicTrayController.shared.install()
      }
    }
  }

  @objc private func openSettings(_ sender: NSMenuItem) {
    sendWorkspaceAction("settings")
  }

  private func installWorkspaceMenus() {
    guard let menu: NSMenu = NSApp.mainMenu else { return }
    let fileMenu: NSMenu = NSMenu(title: "File")
    fileMenu.autoenablesItems = false
    fileMenu.addItem(workspaceItem("Clone Repository…", key: "clone", shortcut: "n"))
    fileMenu.addItem(workspaceItem("Import Repositories…", key: "import", shortcut: "i", modifiers: [.command, .shift]))
    fileMenu.addItem(NSMenuItem.separator())
    fileMenu.addItem(workspaceItem("Refresh Repositories", key: "refresh", shortcut: "r"))
    let fileItem: NSMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileItem.submenu = fileMenu
    menu.insertItem(fileItem, at: 1)

    let viewMenu: NSMenu = NSMenu(title: "View")
    viewMenu.autoenablesItems = false
    viewMenu.addItem(workspaceItem("Quick Switcher…", key: "quickSwitcher", shortcut: "k"))
    viewMenu.addItem(NSMenuItem.separator())
    viewMenu.addItem(workspaceItem("Show or Hide Sidebar", key: "toggleSidebar", shortcut: "s", modifiers: [.command, .option]))
    let viewItem: NSMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    viewItem.submenu = viewMenu
    let windowIndex: Int = menu.items.firstIndex(where: { $0.title == "Window" }) ?? menu.numberOfItems
    menu.insertItem(viewItem, at: windowIndex)

    if let editMenu: NSMenu = menu.items.first(where: { $0.title == "Edit" })?.submenu,
       let findItem: NSMenuItem = editMenu.items.first(where: { $0.title == "Find" }) {
      let findMenu: NSMenu = NSMenu(title: "Find")
      findMenu.autoenablesItems = false
      findMenu.addItem(workspaceItem("Find Repositories…", key: "search", shortcut: "f"))
      findItem.submenu = findMenu
    }
  }

  private func workspaceItem(
    _ title: String,
    key: String,
    shortcut: String,
    modifiers: NSEvent.ModifierFlags = [.command]
  ) -> NSMenuItem {
    let item: NSMenuItem = NSMenuItem(title: title, action: #selector(handleWorkspaceAction(_:)), keyEquivalent: shortcut)
    item.target = self
    item.representedObject = key
    item.keyEquivalentModifierMask = modifiers
    return item
  }

  @objc private func handleWorkspaceAction(_ sender: NSMenuItem) {
    guard let key: String = sender.representedObject as? String else { return }
    sendWorkspaceAction(key)
  }

  private func sendWorkspaceAction(_ key: String) {
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    AlembicTrayController.shared.sendMenuAction(key)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
