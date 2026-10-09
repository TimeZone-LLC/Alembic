import Cocoa
import FlutterMacOS
import os.log

private extension OSLog {
    static let alembicTray: OSLog = OSLog(
        subsystem: "art.arcane.alembic.tray",
        category: "lifecycle"
    )
    static let alembicTrayVerbose: OSLog = OSLog(
        subsystem: "art.arcane.alembic.tray",
        category: "verbose"
    )
}

final class AlembicTrayController: NSObject {
    static let shared: AlembicTrayController = AlembicTrayController()

    private var statusItem: NSStatusItem?
    private weak var window: NSWindow?
    private var eventChannel: FlutterMethodChannel?
    private var isInstalled: Bool = false
    private var installAttempt: Int = 0
    private var pollTimer: Timer?
    private let pollIntervalsSeconds: [Double] = [0.5, 2.0, 8.0]
    private var pollScheduled: Set<Double> = []

    private override init() {
        super.init()
        self.startObservingSystemEvents()
    }

    func attach(window: NSWindow, channel: FlutterMethodChannel) {
        self.window = window
        self.eventChannel = channel
        verbose(
            "attach: window=%@ channel=alembic_tray",
            String(describing: window)
        )
        dumpProcessAndAppContext(label: "attach")
    }

    func install() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.install()
            }
            return
        }
        installAttempt += 1
        verbose("install: attempt=%d isInstalled=%@", installAttempt, isInstalled ? "yes" : "no")
        dumpProcessAndAppContext(label: "install#\(installAttempt) pre")
        dumpAllScreens(label: "install#\(installAttempt) pre")
        dumpStatusBarSystem(label: "install#\(installAttempt) pre")

        if isInstalled, statusItem != nil {
            info("install: already installed, skipping (attempt=%d)", installAttempt)
            schedulePolls()
            return
        }

        performOneTimeMigration()

        verbose("install: calling NSStatusBar.system.statusItem(withLength: variableLength) ...")
        let item: NSStatusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        item.autosaveName = NSStatusItem.AutosaveName(AlembicTrayController.autosaveName)
        verbose(
            "install: got NSStatusItem instance=%@ length=%.1f isVisible=%@ behavior=%lu autosaveName=%@",
            String(describing: item),
            item.length,
            item.isVisible ? "yes" : "no",
            UInt(item.behavior.rawValue),
            item.autosaveName ?? "<nil>"
        )

        item.behavior = []
        item.isVisible = true
        verbose(
            "install: forced behavior=[] isVisible=true; nowVisible=%@ length=%.1f",
            item.isVisible ? "yes" : "no",
            item.length
        )

        statusItem = item
        configureButton(on: item)
        isInstalled = true
        info(
            "install: status item created visible=%@ length=%.1f autosave=%@",
            item.isVisible ? "yes" : "no",
            item.length,
            item.autosaveName ?? "<nil>"
        )
        dumpStatusItem(item: item, label: "install#\(installAttempt) post-configure")
        dumpStatusBarSystem(label: "install#\(installAttempt) post-configure")
        schedulePolls()
    }

    static let autosaveName: String = "AlembicTray"
    static let migrationCompletedKey: String = "AlembicTray.MigrationCompleted.v1"

    private func performOneTimeMigration() {
        let userDefaults: UserDefaults = UserDefaults.standard
        if userDefaults.bool(forKey: AlembicTrayController.migrationCompletedKey) {
            verbose("migration: already completed, skipping")
            return
        }
        info("migration: starting (current bundle=%@ -> autosave=%@)",
             Bundle.main.bundleIdentifier ?? "<nil>",
             AlembicTrayController.autosaveName)

        let newVisibleKey: String = "NSStatusItem Visible \(AlembicTrayController.autosaveName)"
        userDefaults.set(true, forKey: newVisibleKey)
        info("migration: set %@=true", newVisibleKey)

        userDefaults.set(true, forKey: AlembicTrayController.migrationCompletedKey)
        userDefaults.synchronize()
        info("migration: completed")
    }

    func dispose() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.dispose()
            }
            return
        }
        info("dispose: removing status item, was=%@", statusItem == nil ? "nil" : "non-nil")
        if let item: NSStatusItem = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        isInstalled = false
        pollTimer?.invalidate()
        pollTimer = nil
        pollScheduled.removeAll()
    }

    func recreate(activate: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.recreate(activate: activate)
            }
            return
        }
        info("recreate: activate=%@ disposing existing item", activate ? "yes" : "no")
        dispose()
        if activate {
            info("recreate: calling NSApp.activate(ignoringOtherApps: true)")
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.install()
        }
    }

    func setTooltip(_ tooltip: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.setTooltip(tooltip)
            }
            return
        }
        guard let button: NSStatusBarButton = statusItem?.button else {
            warn("setTooltip: button missing, cannot set %@", tooltip)
            return
        }
        button.toolTip = tooltip
        info("setTooltip: %@", tooltip)
    }

    func setActivationPolicy(_ mode: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.setActivationPolicy(mode)
            }
            return
        }
        let policy: NSApplication.ActivationPolicy
        switch mode {
        case "regular":
            policy = .regular
        case "accessory":
            policy = .accessory
        case "prohibited":
            policy = .prohibited
        default:
            warn("setActivationPolicy: unknown mode %@", mode)
            return
        }
        let prior: NSApplication.ActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(policy)
        info(
            "setActivationPolicy: mode=%@ prior=%d new=%d",
            mode,
            prior.rawValue,
            policy.rawValue
        )
    }

    func bounds() -> [String: Double]? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                self.bounds()
            }
        }
        guard let item: NSStatusItem = statusItem,
              let button: NSStatusBarButton = item.button,
              let buttonWindow: NSWindow = button.window else {
            warn("bounds: status item not yet ready")
            return nil
        }
        let frame: NSRect = buttonWindow.frame
        let screen: NSScreen
        if let buttonScreen: NSScreen = buttonWindow.screen {
            screen = buttonScreen
        } else if let firstScreen: NSScreen = NSScreen.screens.first {
            screen = firstScreen
        } else if let mainScreen: NSScreen = NSScreen.main {
            screen = mainScreen
        } else {
            warn("bounds: no screens available")
            return nil
        }
        let screenFrame: NSRect = screen.frame
        let flippedY: CGFloat =
            screenFrame.origin.y + screenFrame.height - frame.origin.y - frame.height
        let result: [String: Double] = [
            "x": Double(frame.origin.x),
            "y": Double(flippedY),
            "width": Double(frame.width),
            "height": Double(frame.height),
        ]
        info(
            "bounds: x=%.2f y=%.2f w=%.2f h=%.2f screen=%@",
            result["x"] ?? 0,
            result["y"] ?? 0,
            result["width"] ?? 0,
            result["height"] ?? 0,
            screen.localizedName
        )
        return result
    }

    func dumpFullDebug() -> [String: Any] {
        verbose("dumpFullDebug: requested via channel")
        var output: [String: Any] = [:]
        output["macosVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        output["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? "<nil>"
        output["bundlePath"] = Bundle.main.bundlePath
        output["activationPolicy"] = NSApp.activationPolicy().rawValue
        output["isActive"] = NSApp.isActive
        output["isHidden"] = NSApp.isHidden
        output["windows"] = NSApp.windows.count
        output["installAttempt"] = installAttempt
        output["isInstalled"] = isInstalled
        output["statusItemPresent"] = statusItem != nil
        if let item: NSStatusItem = statusItem {
            output["statusItem.length"] = item.length
            output["statusItem.isVisible"] = item.isVisible
            output["statusItem.behavior"] = item.behavior.rawValue
            if let button: NSStatusBarButton = item.button {
                output["button.frame"] = NSStringFromRect(button.frame)
                output["button.bounds"] = NSStringFromRect(button.bounds)
                output["button.alphaValue"] = button.alphaValue
                output["button.isHidden"] = button.isHidden
                output["button.isEnabled"] = button.isEnabled
                output["button.appearsDisabled"] = button.appearsDisabled
                output["button.title"] = button.title
                output["button.toolTip"] = button.toolTip ?? "<nil>"
                output["button.image.size"] = button.image.map {
                    NSStringFromSize($0.size)
                } ?? "<nil>"
                output["button.image.isTemplate"] = button.image?.isTemplate ?? false
                if let bw: NSWindow = button.window {
                    output["button.window.frame"] = NSStringFromRect(bw.frame)
                    output["button.window.isVisible"] = bw.isVisible
                    output["button.window.alphaValue"] = bw.alphaValue
                    output["button.window.level"] = bw.level.rawValue
                    output["button.window.screen"] = bw.screen?.localizedName ?? "<nil>"
                }
            }
        }
        let screens: [NSScreen] = NSScreen.screens
        var screenList: [[String: Any]] = []
        for (index, screen) in screens.enumerated() {
            screenList.append([
                "index": index,
                "name": screen.localizedName,
                "frame": NSStringFromRect(screen.frame),
                "visibleFrame": NSStringFromRect(screen.visibleFrame),
                "backingScaleFactor": screen.backingScaleFactor,
                "isMain": screen == NSScreen.main,
            ])
        }
        output["screens"] = screenList
        output["statusBarThickness"] = NSStatusBar.system.thickness
        output["NSScreen.main"] = NSScreen.main?.localizedName ?? "<nil>"
        output["NSScreen.screens.first"] = NSScreen.screens.first?.localizedName ?? "<nil>"
        verbose("dumpFullDebug: produced %d keys", output.count)
        return output
    }

    private func configureButton(on item: NSStatusItem) {
        guard let button: NSStatusBarButton = item.button else {
            warn("configureButton: status item button missing")
            return
        }
        verbose("configureButton: starting; button=%@", String(describing: button))
        let icon: NSImage = loadIconImage()
        verbose(
            "configureButton: icon size=%.1fx%.1f isTemplate=%@",
            icon.size.width,
            icon.size.height,
            icon.isTemplate ? "yes" : "no"
        )
        button.image = icon
        button.alternateImage = icon
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.imageHugsTitle = false
        button.toolTip = "Alembic"
        button.isEnabled = true
        button.isHidden = false
        button.appearsDisabled = false
        button.alphaValue = 1.0
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.menu = nil
        verbose(
            "configureButton: completed; button.image=%@ title=%@ frame=%@",
            String(describing: button.image),
            button.title,
            NSStringFromRect(button.frame)
        )
    }

    private func loadIconImage() -> NSImage {
        verbose("loadIconImage: starting waterfall")
        if let bundled: NSImage = Bundle.main.image(forResource: NSImage.Name("tray")) {
            bundled.isTemplate = true
            bundled.size = NSSize(width: 18, height: 18)
            info(
                "loadIconImage: using bundled tray.png size=%.1fx%.1f",
                bundled.size.width,
                bundled.size.height
            )
            return bundled
        }
        warn("loadIconImage: bundled tray.png not found, trying SF Symbol")
        if #available(macOS 11.0, *),
           let symbol: NSImage = NSImage(
               systemSymbolName: "shippingbox.fill",
               accessibilityDescription: "Alembic"
           ) {
            let configuration: NSImage.SymbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 14,
                weight: .medium
            )
            let configured: NSImage = symbol.withSymbolConfiguration(configuration) ?? symbol
            configured.isTemplate = true
            info("loadIconImage: using SF Symbol shippingbox.fill")
            return configured
        }
        warn("loadIconImage: SF Symbol unavailable, using drawn fallback monogram")
        return drawnFallbackImage()
    }

    private func drawnFallbackImage() -> NSImage {
        let size: NSSize = NSSize(width: 18, height: 18)
        let image: NSImage = NSImage(size: size)
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let drawRect: NSRect = NSRect(x: 4, y: 1, width: 14, height: 16)
        NSString(string: "A").draw(in: drawRect, withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event: NSEvent? = NSApp.currentEvent
        let isRight: Bool = event?.type == .rightMouseUp
        let isControlClick: Bool =
            event?.type == .leftMouseUp
            && event?.modifierFlags.contains(.control) == true
        info(
            "handleStatusItemClick: type=%d modifiers=%lu isRight=%@ isControl=%@",
            event?.type.rawValue ?? -1,
            UInt(event?.modifierFlags.rawValue ?? 0),
            isRight ? "yes" : "no",
            isControlClick ? "yes" : "no"
        )
        if isRight || isControlClick {
            popUpContextMenu(with: event, for: sender)
        } else {
            eventChannel?.invokeMethod("onLeftClick", arguments: nil)
        }
    }

    private func popUpContextMenu(with event: NSEvent?, for sender: NSStatusBarButton) {
        info("popUpContextMenu: building menu")
        let menu: NSMenu = makeMenu()
        if let trigger: NSEvent = event {
            NSMenu.popUpContextMenu(menu, with: trigger, for: sender)
            return
        }
        guard let item: NSStatusItem = statusItem else {
            warn("popUpContextMenu: no status item available")
            return
        }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu: NSMenu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(title: "Show Alembic", key: "show"))
        menu.addItem(menuItem(
            title: "Hide Window",
            key: "hide",
            enabled: window?.isVisible == true
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Refresh Repositories", key: "refresh"))
        menu.addItem(menuItem(title: "Import Repositories...", key: "import"))
        menu.addItem(menuItem(title: "Settings...", key: "settings"))
        menu.addItem(menuItem(
            title: "Reset Window Position",
            key: "resetPosition",
            symbolName: "arrow.counterclockwise"
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Restart Alembic", key: "restart"))
        menu.addItem(menuItem(title: "Quit Alembic", key: "quit"))
        return menu
    }

    private func menuItem(
        title: String,
        key: String,
        enabled: Bool = true,
        symbolName: String? = nil
    ) -> NSMenuItem {
        let item: NSMenuItem = NSMenuItem(
            title: title,
            action: #selector(handleMenuItemClick(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = key
        item.isEnabled = enabled
        if let symbolName: String = symbolName,
           #available(macOS 11.0, *),
           let symbol: NSImage = NSImage(
               systemSymbolName: symbolName,
               accessibilityDescription: title
           ) {
            item.image = symbol
        }
        return item
    }

    @objc private func handleMenuItemClick(_ sender: NSMenuItem) {
        let key: String = (sender.representedObject as? String) ?? ""
        info("handleMenuItemClick: key=%@", key)
        sendMenuAction(key)
    }

    func sendMenuAction(_ key: String) {
        eventChannel?.invokeMethod("onMenuItem", arguments: ["key": key])
    }

    private func schedulePolls() {
        for delay: Double in pollIntervalsSeconds {
            if pollScheduled.contains(delay) {
                continue
            }
            pollScheduled.insert(delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pollDiagnostic(at: delay)
            }
        }
    }

    private func pollDiagnostic(at delay: Double) {
        verbose("poll +%.2fs ============================================", delay)
        guard let item: NSStatusItem = statusItem else {
            warn("poll +%.2fs: statusItem nil!", delay)
            return
        }
        if !item.isVisible {
            warn("poll +%.2fs: isVisible flipped false, restoring", delay)
            item.isVisible = true
        }
        if item.button?.image == nil {
            warn("poll +%.2fs: button image lost, reapplying", delay)
            item.button?.image = loadIconImage()
        }
        dumpStatusItem(item: item, label: "poll +\(delay)s")
        dumpStatusBarSystem(label: "poll +\(delay)s")
    }

    private func dumpProcessAndAppContext(label: String) {
        let pid: Int32 = ProcessInfo.processInfo.processIdentifier
        let bundle: String = Bundle.main.bundleIdentifier ?? "<nil>"
        let isActive: Bool = NSApp.isActive
        let isHidden: Bool = NSApp.isHidden
        let policy: Int = NSApp.activationPolicy().rawValue
        let osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
        let mainThread: Bool = Thread.isMainThread
        verbose(
            "%@ context: pid=%d bundle=%@ os=%@ policy=%d active=%@ hidden=%@ thread=%@",
            label,
            pid,
            bundle,
            osVersion,
            policy,
            isActive ? "yes" : "no",
            isHidden ? "yes" : "no",
            mainThread ? "main" : "background"
        )
        verbose(
            "%@ context: NSApp.windows=%d NSApp.keyWindow=%@ NSApp.mainWindow=%@",
            label,
            NSApp.windows.count,
            String(describing: NSApp.keyWindow),
            String(describing: NSApp.mainWindow)
        )
        if let frontApp: NSRunningApplication = NSWorkspace.shared.frontmostApplication {
            verbose(
                "%@ context: frontmostApp=%@ pid=%d ours=%@",
                label,
                frontApp.localizedName ?? "<nil>",
                frontApp.processIdentifier,
                frontApp.processIdentifier == pid ? "yes" : "no"
            )
        }
    }

    private func dumpAllScreens(label: String) {
        let screens: [NSScreen] = NSScreen.screens
        verbose("%@ screens: count=%d main=%@ first=%@",
                label,
                screens.count,
                NSScreen.main?.localizedName ?? "<nil>",
                NSScreen.screens.first?.localizedName ?? "<nil>")
        for (index, screen) in screens.enumerated() {
            let frame: NSRect = screen.frame
            let visibleFrame: NSRect = screen.visibleFrame
            let isMain: Bool = screen == NSScreen.main
            let scale: CGFloat = screen.backingScaleFactor
            let deviceDescription: [NSDeviceDescriptionKey: Any] = screen.deviceDescription
            let displayID: CGDirectDisplayID =
                (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let isActive: Bool = CGDisplayIsActive(displayID) != 0
            let isAsleep: Bool = CGDisplayIsAsleep(displayID) != 0
            let isOnline: Bool = CGDisplayIsOnline(displayID) != 0
            let isMainCG: Bool = displayID == CGMainDisplayID()
            let mirrored: CGDirectDisplayID = CGDisplayMirrorsDisplay(displayID)
            verbose(
                "%@ screen[%d]: name=%@ cocoaMain=%@ cgMain=%@ cgActive=%@ cgAsleep=%@ cgOnline=%@ cgMirrored=%u displayID=%u scale=%.2f frame=%@ visible=%@",
                label,
                index,
                screen.localizedName,
                isMain ? "yes" : "no",
                isMainCG ? "yes" : "no",
                isActive ? "yes" : "no",
                isAsleep ? "yes" : "no",
                isOnline ? "yes" : "no",
                mirrored,
                displayID,
                scale,
                NSStringFromRect(frame),
                NSStringFromRect(visibleFrame)
            )
        }
        dumpCGActiveDisplays(label: label)
    }

    private func dumpCGActiveDisplays(label: String) {
        var activeCount: UInt32 = 0
        let activeQueryStatus: CGError = CGGetActiveDisplayList(0, nil, &activeCount)
        verbose("%@ CGGetActiveDisplayList: queryStatus=%d count=%u",
                label, Int(activeQueryStatus.rawValue), activeCount)
        if activeQueryStatus == .success && activeCount > 0 {
            var activeDisplays: [CGDirectDisplayID] = Array(repeating: 0, count: Int(activeCount))
            CGGetActiveDisplayList(activeCount, &activeDisplays, &activeCount)
            for (i, did) in activeDisplays.enumerated() {
                let bounds: CGRect = CGDisplayBounds(did)
                verbose(
                    "%@ CG-active[%d]: id=%u bounds=%@ main=%@ asleep=%@",
                    label, i, did, NSStringFromRect(bounds),
                    did == CGMainDisplayID() ? "yes" : "no",
                    CGDisplayIsAsleep(did) != 0 ? "yes" : "no"
                )
            }
        }
        var onlineCount: UInt32 = 0
        let onlineQueryStatus: CGError = CGGetOnlineDisplayList(0, nil, &onlineCount)
        verbose("%@ CGGetOnlineDisplayList: queryStatus=%d count=%u",
                label, Int(onlineQueryStatus.rawValue), onlineCount)
        if onlineQueryStatus == .success && onlineCount > 0 {
            var onlineDisplays: [CGDirectDisplayID] = Array(repeating: 0, count: Int(onlineCount))
            CGGetOnlineDisplayList(onlineCount, &onlineDisplays, &onlineCount)
            for (i, did) in onlineDisplays.enumerated() {
                let bounds: CGRect = CGDisplayBounds(did)
                verbose(
                    "%@ CG-online[%d]: id=%u bounds=%@ active=%@ main=%@ asleep=%@ inHWMirrorSet=%@",
                    label, i, did, NSStringFromRect(bounds),
                    CGDisplayIsActive(did) != 0 ? "yes" : "no",
                    did == CGMainDisplayID() ? "yes" : "no",
                    CGDisplayIsAsleep(did) != 0 ? "yes" : "no",
                    CGDisplayIsInHWMirrorSet(did) != 0 ? "yes" : "no"
                )
            }
        }
    }

    private func dumpStatusBarSystem(label: String) {
        let bar: NSStatusBar = NSStatusBar.system
        verbose(
            "%@ statusBar: thickness=%.1f isVertical=%@",
            label,
            bar.thickness,
            bar.isVertical ? "yes" : "no"
        )
    }

    private func dumpStatusItem(item: NSStatusItem, label: String) {
        let isVisible: Bool = item.isVisible
        let length: CGFloat = item.length
        let behavior: UInt = UInt(item.behavior.rawValue)
        let menuPresent: Bool = item.menu != nil
        verbose(
            "%@ statusItem: visible=%@ length=%.1f behavior=%lu menu=%@",
            label,
            isVisible ? "yes" : "no",
            length,
            behavior,
            menuPresent ? "yes" : "no"
        )
        guard let button: NSStatusBarButton = item.button else {
            warn("%@ statusItem: button is nil!", label)
            return
        }
        let bw: NSWindow? = button.window
        let buttonScreen: String = bw?.screen?.localizedName ?? "<nil>"
        let buttonFrame: NSRect = button.frame
        let buttonBounds: NSRect = button.bounds
        let windowFrame: NSRect = bw?.frame ?? .zero
        let windowVisible: Bool = bw?.isVisible ?? false
        let windowLevel: Int = bw?.level.rawValue ?? -1
        let windowAlpha: CGFloat = bw?.alphaValue ?? 0
        let imageSize: NSSize = button.image?.size ?? .zero
        let imageTemplate: Bool = button.image?.isTemplate ?? false
        let alphaValue: CGFloat = button.alphaValue
        let isHidden: Bool = button.isHidden
        let isEnabled: Bool = button.isEnabled
        let appearsDisabled: Bool = button.appearsDisabled
        let title: String = button.title
        verbose(
            "%@ button: frame=%@ bounds=%@ alpha=%.2f hidden=%@ enabled=%@ appearsDisabled=%@ title=[%@]",
            label,
            NSStringFromRect(buttonFrame),
            NSStringFromRect(buttonBounds),
            alphaValue,
            isHidden ? "yes" : "no",
            isEnabled ? "yes" : "no",
            appearsDisabled ? "yes" : "no",
            title
        )
        verbose(
            "%@ button.image: size=%.1fx%.1f isTemplate=%@",
            label,
            imageSize.width,
            imageSize.height,
            imageTemplate ? "yes" : "no"
        )
        verbose(
            "%@ button.window: frame=%@ visible=%@ level=%d alpha=%.2f screen=%@",
            label,
            NSStringFromRect(windowFrame),
            windowVisible ? "yes" : "no",
            windowLevel,
            windowAlpha,
            buttonScreen
        )
        if let bw: NSWindow = bw, let buttonScreenObj: NSScreen = bw.screen {
            let sf: NSRect = buttonScreenObj.frame
            let onScreenLeft: Bool = windowFrame.minX >= sf.minX && windowFrame.minX < sf.maxX
            let onScreenRight: Bool = windowFrame.maxX > sf.minX && windowFrame.maxX <= sf.maxX
            let onScreenTop: Bool = windowFrame.maxY <= sf.maxY
            let onScreenBottom: Bool = windowFrame.minY >= sf.minY
            let fullyOnScreen: Bool = onScreenLeft && onScreenRight && onScreenTop && onScreenBottom
            verbose(
                "%@ visibility: fullyOnScreen=%@ left=%@ right=%@ top=%@ bottom=%@ (windowFrame=%@ screenFrame=%@)",
                label,
                fullyOnScreen ? "yes" : "no",
                onScreenLeft ? "yes" : "no",
                onScreenRight ? "yes" : "no",
                onScreenTop ? "yes" : "no",
                onScreenBottom ? "yes" : "no",
                NSStringFromRect(windowFrame),
                NSStringFromRect(sf)
            )
        }
    }

    private func startObservingSystemEvents() {
        let workspace: NotificationCenter = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(onActiveSpaceChanged(_:)),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(onScreensChanged(_:)),
                              name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func onActiveSpaceChanged(_ note: Notification) {
        info("notification: activeSpaceDidChange")
        if let item: NSStatusItem = statusItem {
            dumpStatusItem(item: item, label: "activeSpaceDidChange")
        }
    }

    @objc private func onScreensChanged(_ note: Notification) {
        info("notification: didChangeScreenParameters")
        dumpAllScreens(label: "didChangeScreenParameters")
        if let item: NSStatusItem = statusItem {
            dumpStatusItem(item: item, label: "didChangeScreenParameters")
        }
    }

    private func info(_ format: StaticString, _ args: CVarArg...) {
        let message: String = withVaList(args) { argList in
            NSString(format: format.description, arguments: argList) as String
        }
        os_log(.info, log: .alembicTray, "%{public}@", message)
        forwardToFlutter(level: "info", message: message)
        FileHandle.standardError.write(Data(("[alembic-tray INFO] " + message + "\n").utf8))
    }

    private func warn(_ format: StaticString, _ args: CVarArg...) {
        let message: String = withVaList(args) { argList in
            NSString(format: format.description, arguments: argList) as String
        }
        os_log(.error, log: .alembicTray, "%{public}@", message)
        forwardToFlutter(level: "warn", message: message)
        FileHandle.standardError.write(Data(("[alembic-tray WARN] " + message + "\n").utf8))
    }

    private func verbose(_ format: StaticString, _ args: CVarArg...) {
        let message: String = withVaList(args) { argList in
            NSString(format: format.description, arguments: argList) as String
        }
        os_log(.debug, log: .alembicTrayVerbose, "%{public}@", message)
        forwardToFlutter(level: "verbose", message: message)
        FileHandle.standardError.write(Data(("[alembic-tray VERB] " + message + "\n").utf8))
    }

    private func forwardToFlutter(level: String, message: String) {
        guard let channel: FlutterMethodChannel = eventChannel else {
            return
        }
        DispatchQueue.main.async {
            channel.invokeMethod(
                "log",
                arguments: ["level": level, "message": message]
            )
        }
    }
}
