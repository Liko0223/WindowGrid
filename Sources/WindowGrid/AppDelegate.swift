import AppKit
import Carbon.HIToolbox
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, LayoutPanelDelegate {
    private var statusItem: NSStatusItem!
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var overlayWindows: [NSScreen: OverlayWindow] = [:]
    private var desktopToastWindows: [UInt32: DesktopToastWindow] = [:]
    private var activationModifierKey: ActivationModifierKey = .control
    private var layoutPanel: LayoutPanel?
    private var layoutPanelContextScreen: NSScreen?

    // Drag state
    private var isDragging = false
    private var isActivationModifierHeld = false
    private var draggedWindow: AXUIElement?
    private var dragStartLocation: NSPoint = .zero
    private var dragSourceZoneIndex: Int = -1

    // Event monitors
    private var globalMouseDown: Any?
    private var globalMouseDragged: Any?
    private var globalMouseUp: Any?
    private var flagsChangedMonitor: Any?
    private var localFlagsMonitor: Any?
    private var activeSpaceObserver: NSObjectProtocol?
    private var spacePollingTimer: Timer?
    private var arrangeHotKeyRef: EventHotKeyRef?
    private var newBrowserHotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var adaptiveArrangeCycleKey: String?
    private var adaptiveArrangeCycleIndex = 0
    private var adaptiveArrangeCycleWindowOrder: [(window: AXUIElement, appName: String)] = []
    private var lastAdaptiveArrangeLayouts: [String: GridLayout] = [:]
    private var lastSeenSpaceKeys: [UInt32: String] = [:]
    private var desktopToastRefreshGeneration = 0

    private let dragThreshold: CGFloat = 8
    private let arrangeHotKeySignature = OSType(0x57475244) // WGRD
    private let arrangeHotKeyID = UInt32(1)
    private let newBrowserHotKeyID = UInt32(2)
    private let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/windowgrid/debug.log")

    private func debugLog(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let fh = try? FileHandle(forWritingTo: logFile) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load config
        activationModifierKey = ConfigStore.shared.activationModifierKey

        setupStatusBar()
        setupEventMonitors()
        setupHotKeyHandler()
        registerArrangeHotKey()
        registerNewBrowserHotKey()

        if !WindowSnapper.isAccessibilityTrusted {
            _ = WindowSnapper.checkAccessibility()
        }

        debugLog("START: accessibility=\(WindowSnapper.isAccessibilityTrusted), modifier=\(activationModifierKey.rawValue)")
        NSLog("WindowGrid: Started with \(activationModifierKey.displayName) drag modifier")

        scheduleStartupUpdateCheck()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventMonitors()
        unregisterArrangeHotKey()
        unregisterNewBrowserHotKey()
        if let hotKeyHandlerRef = hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func scheduleStartupUpdateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.updaterController.updater.canCheckForUpdates else { return }
            self.updaterController.updater.checkForUpdatesInBackground()
        }
    }

    // MARK: - Accessibility Alert

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.text("WindowGrid Needs Accessibility Access", "WindowGrid 需要辅助功能权限")
        alert.informativeText = L10n.text(
            "Grant access in System Settings → Privacy & Security → Accessibility, then relaunch WindowGrid.",
            "请在系统设置 → 隐私与安全性 → 辅助功能中允许 WindowGrid，然后重新启动。"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("Open Settings", "打开系统设置"))
        alert.addButton(withTitle: L10n.text("Quit", "退出"))

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.toolTip = "WindowGrid"
            button.image = fourGridStatusIcon()
            button.imagePosition = .imageLeft
            updateStatusBarTitle()
        }
        rebuildMenu()
    }

    private func desktopToastWindow(for screen: NSScreen) -> DesktopToastWindow {
        let displayID = LayoutContext.displayID(for: screen)
        if let toast = desktopToastWindows[displayID] {
            return toast
        }
        let toast = DesktopToastWindow()
        toast.toastDelegate = self
        desktopToastWindows[displayID] = toast
        return toast
    }

    private func currentContextScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func updateStatusBarTitle() {
        guard let button = statusItem?.button else { return }
        guard NSScreen.screens.count == 1 else {
            button.title = ""
            button.toolTip = "WindowGrid"
            return
        }

        let name = currentContextScreen().flatMap { ConfigStore.shared.desktopName(for: $0) }
        if let name = name, !name.isEmpty {
            button.title = " \(shortDesktopName(name))"
            button.toolTip = "WindowGrid: \(name)"
        } else {
            button.title = ""
            button.toolTip = "WindowGrid"
        }
    }

    private func fourGridStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.labelColor.setFill()
        let cell: CGFloat = 6
        let gap: CGFloat = 2
        let origin = NSPoint(x: 2, y: 2)

        for row in 0..<2 {
            for col in 0..<2 {
                let rect = NSRect(
                    x: origin.x + CGFloat(col) * (cell + gap),
                    y: origin.y + CGFloat(row) * (cell + gap),
                    width: cell,
                    height: cell
                )
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func shortDesktopName(_ name: String) -> String {
        let limit = 12
        if name.count <= limit { return name }
        return String(name.prefix(limit)) + "…"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let contextScreen = currentContextScreen()
        let contextLayout = contextScreen.map { effectiveLayout(for: $0) } ?? ConfigStore.shared.activeLayout
        let savedContextLayout = contextScreen.map { ConfigStore.shared.layout(for: $0) } ?? ConfigStore.shared.activeLayout
        let contextLabel = contextScreen.map { ConfigStore.shared.contextLabel(for: $0) } ?? L10n.text("Current Desktop", "当前桌面")
        let desktopName = contextScreen.flatMap { ConfigStore.shared.desktopName(for: $0) }

        updateStatusBarTitle()

        let status = NSMenuItem(
            title: WindowSnapper.isAccessibilityTrusted
                ? L10n.text("Accessibility: Granted", "辅助功能：已授权")
                : L10n.text("Accessibility: Missing", "辅助功能：未授权"),
            action: WindowSnapper.isAccessibilityTrusted ? nil : #selector(requestAccessibilityAccess),
            keyEquivalent: ""
        )
        status.target = self
        status.isEnabled = true
        menu.addItem(status)
        menu.addItem(.separator())

        let header = NSMenuItem(title: L10n.text("This Desktop: \(contextLabel)", "此桌面：\(contextLabel)"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if ConfigStore.shared.adaptiveArrangeEnabled || ConfigStore.shared.liveAdaptiveGridEnabled {
            let adaptiveGridItem = NSMenuItem(
                title: L10n.text("Current Grid: \(L10n.layoutName(contextLayout.name))", "当前网格：\(L10n.layoutName(contextLayout.name))"),
                action: nil,
                keyEquivalent: ""
            )
            adaptiveGridItem.isEnabled = false
            menu.addItem(adaptiveGridItem)
        }

        let nameItem = NSMenuItem(
            title: L10n.text(
                "Desktop Name: \(desktopName ?? "Not Set")",
                "桌面名称：\(desktopName ?? "未设置")"
            ),
            action: nil,
            keyEquivalent: ""
        )
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        let setName = NSMenuItem(title: L10n.text("Name This Desktop…", "命名此桌面…"), action: #selector(nameCurrentDesktop), keyEquivalent: "")
        setName.target = self
        menu.addItem(setName)

        if desktopName != nil {
            let clearName = NSMenuItem(title: L10n.text("Clear Desktop Name", "清除桌面名称"), action: #selector(clearCurrentDesktopName), keyEquivalent: "")
            clearName.target = self
            menu.addItem(clearName)
        }

        menu.addItem(.separator())

        let arrange = NSMenuItem(
            title: L10n.text("Arrange All Windows", "排列所有窗口"),
            action: #selector(arrangeAllWindows),
            keyEquivalent: ""
        )
        arrange.target = self
        if let arrangeShortcut = ConfigStore.shared.arrangeShortcut {
            arrange.keyEquivalent = arrangeShortcut.menuKeyEquivalent
            arrange.keyEquivalentModifierMask = arrangeShortcut.menuModifierMask
        }
        menu.addItem(arrange)

        let adaptiveArrange = NSMenuItem(
            title: L10n.text("Adaptive Arrange by Window Count", "按窗口数量自适应排列"),
            action: #selector(toggleAdaptiveArrange(_:)),
            keyEquivalent: ""
        )
        adaptiveArrange.target = self
        adaptiveArrange.state = ConfigStore.shared.adaptiveArrangeEnabled ? .on : .off
        menu.addItem(adaptiveArrange)

        let liveAdaptiveGrid = NSMenuItem(
            title: L10n.text("Live Adaptive Grid by Window Count", "拖拽时按窗口数量显示自适应网格"),
            action: #selector(toggleLiveAdaptiveGrid(_:)),
            keyEquivalent: ""
        )
        liveAdaptiveGrid.target = self
        liveAdaptiveGrid.state = ConfigStore.shared.liveAdaptiveGridEnabled ? .on : .off
        menu.addItem(liveAdaptiveGrid)

        menu.addItem(.separator())

        let manualLayoutItem = NSMenuItem(title: L10n.text("Manual Layouts", "手动布局"), action: nil, keyEquivalent: "")
        let manualLayoutMenu = NSMenu()

        let manualHint = NSMenuItem(
            title: L10n.text("Saved for this desktop only", "只保存到当前桌面"),
            action: nil,
            keyEquivalent: ""
        )
        manualHint.isEnabled = false
        manualLayoutMenu.addItem(manualHint)
        manualLayoutMenu.addItem(.separator())

        for layout in ConfigStore.shared.allLayouts {
            let item = NSMenuItem(title: L10n.layoutName(layout.name), action: #selector(switchLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout
            item.state = layout.name == savedContextLayout.name && !ConfigStore.shared.adaptiveArrangeEnabled && !ConfigStore.shared.liveAdaptiveGridEnabled ? .on : .off
            manualLayoutMenu.addItem(item)
        }

        manualLayoutMenu.addItem(.separator())

        let setDefault = NSMenuItem(
            title: L10n.text(
                "Set \"\(L10n.layoutName(savedContextLayout.name))\" as Default",
                "将“\(L10n.layoutName(savedContextLayout.name))”设为默认"
            ),
            action: #selector(setCurrentLayoutAsDefault),
            keyEquivalent: ""
        )
        setDefault.target = self
        manualLayoutMenu.addItem(setDefault)

        let clearOverride = NSMenuItem(
            title: L10n.text("Use Default Layout on This Desktop", "此桌面使用默认布局"),
            action: #selector(clearCurrentLayoutOverride),
            keyEquivalent: ""
        )
        clearOverride.target = self
        manualLayoutMenu.addItem(clearOverride)

        manualLayoutMenu.addItem(.separator())

        let editLayout = NSMenuItem(title: L10n.text("Edit Layouts…", "编辑布局…"), action: #selector(openLayoutPanel), keyEquivalent: "l")
        editLayout.target = self
        manualLayoutMenu.addItem(editLayout)

        manualLayoutItem.submenu = manualLayoutMenu
        menu.addItem(manualLayoutItem)

        let newBrowser = NSMenuItem(
            title: L10n.text("New Browser Window", "新建浏览器窗口"),
            action: #selector(openNewBrowserWindow),
            keyEquivalent: ""
        )
        newBrowser.target = self
        if let newBrowserShortcut = ConfigStore.shared.newBrowserShortcut {
            newBrowser.keyEquivalent = newBrowserShortcut.menuKeyEquivalent
            newBrowser.keyEquivalentModifierMask = newBrowserShortcut.menuModifierMask
        }
        menu.addItem(newBrowser)

        let settingsItem = NSMenuItem(title: L10n.text("Settings", "设置"), action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        let browserAppItem = NSMenuItem(title: L10n.text("New Browser App", "新建浏览器应用"), action: nil, keyEquivalent: "")
        let browserAppMenu = NSMenu()
        let currentBrowserBundleID = ConfigStore.shared.newBrowserBundleID

        let currentBrowserApp = NSMenuItem(
            title: L10n.current(BrowserChoice.name(for: currentBrowserBundleID)),
            action: nil,
            keyEquivalent: ""
        )
        currentBrowserApp.isEnabled = false
        browserAppMenu.addItem(currentBrowserApp)
        browserAppMenu.addItem(.separator())

        for browser in BrowserChoice.all {
            let itemTitle = browser.isInstalled ? browser.name : L10n.notInstalled(browser.name)
            let item = NSMenuItem(title: itemTitle, action: #selector(selectNewBrowserApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = browser.bundleID
            item.isEnabled = browser.isInstalled
            item.state = browser.bundleID == currentBrowserBundleID ? .on : .off
            browserAppMenu.addItem(item)
        }

        browserAppItem.submenu = browserAppMenu
        settingsMenu.addItem(browserAppItem)
        settingsMenu.addItem(.separator())

        let shortcutItem = NSMenuItem(title: L10n.text("Arrange Shortcut", "排列快捷键"), action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        let currentShortcut = ConfigStore.shared.arrangeShortcut

        let current = NSMenuItem(
            title: L10n.current(currentShortcut?.displayName ?? L10n.text("Off", "关闭")),
            action: nil,
            keyEquivalent: ""
        )
        current.isEnabled = false
        shortcutMenu.addItem(current)
        shortcutMenu.addItem(.separator())

        for shortcut in KeyboardShortcut.arrangePresets {
            let item = NSMenuItem(title: shortcut.displayName, action: #selector(selectArrangeShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shortcut
            item.state = shortcut == currentShortcut ? .on : .off
            shortcutMenu.addItem(item)
        }

        shortcutMenu.addItem(.separator())
        let customShortcut = NSMenuItem(title: L10n.text("Set Custom Shortcut…", "设置自定义快捷键…"), action: #selector(setCustomArrangeShortcut), keyEquivalent: "")
        customShortcut.target = self
        shortcutMenu.addItem(customShortcut)

        let disableShortcut = NSMenuItem(title: L10n.text("Disable Shortcut", "关闭快捷键"), action: #selector(disableArrangeShortcut), keyEquivalent: "")
        disableShortcut.target = self
        disableShortcut.state = currentShortcut == nil ? .on : .off
        shortcutMenu.addItem(disableShortcut)

        shortcutItem.submenu = shortcutMenu
        settingsMenu.addItem(shortcutItem)

        let browserShortcutItem = NSMenuItem(title: L10n.text("New Browser Shortcut", "新建浏览器快捷键"), action: nil, keyEquivalent: "")
        let browserShortcutMenu = NSMenu()
        let currentBrowserShortcut = ConfigStore.shared.newBrowserShortcut

        let currentBrowser = NSMenuItem(
            title: L10n.current(currentBrowserShortcut?.displayName ?? L10n.text("Off", "关闭")),
            action: nil,
            keyEquivalent: ""
        )
        currentBrowser.isEnabled = false
        browserShortcutMenu.addItem(currentBrowser)
        browserShortcutMenu.addItem(.separator())

        for shortcut in KeyboardShortcut.newBrowserPresets {
            let item = NSMenuItem(title: shortcut.displayName, action: #selector(selectNewBrowserShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shortcut
            item.state = shortcut == currentBrowserShortcut ? .on : .off
            browserShortcutMenu.addItem(item)
        }

        browserShortcutMenu.addItem(.separator())
        let customBrowserShortcut = NSMenuItem(title: L10n.text("Set Custom Shortcut…", "设置自定义快捷键…"), action: #selector(setCustomNewBrowserShortcut), keyEquivalent: "")
        customBrowserShortcut.target = self
        browserShortcutMenu.addItem(customBrowserShortcut)

        let disableBrowserShortcut = NSMenuItem(title: L10n.text("Disable Shortcut", "关闭快捷键"), action: #selector(disableNewBrowserShortcut), keyEquivalent: "")
        disableBrowserShortcut.target = self
        disableBrowserShortcut.state = currentBrowserShortcut == nil ? .on : .off
        browserShortcutMenu.addItem(disableBrowserShortcut)

        browserShortcutItem.submenu = browserShortcutMenu
        settingsMenu.addItem(browserShortcutItem)
        settingsMenu.addItem(.separator())

        let checkForUpdates = NSMenuItem(
            title: L10n.text("Check for Updates…", "检查更新…"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        settingsMenu.addItem(checkForUpdates)

        settingsMenu.addItem(.separator())

        let preview = NSMenuItem(title: L10n.text("Preview Grid", "预览网格"), action: #selector(previewGrid), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)

        let modifierItem = NSMenuItem(title: L10n.text("Drag Modifier", "拖拽修饰键"), action: nil, keyEquivalent: "")
        let modifierMenu = NSMenu()
        for modifier in ActivationModifierKey.allCases {
            let item = NSMenuItem(
                title: modifier == .option
                    ? "\(modifier.symbol) \(modifier.displayName) \(L10n.text("(may conflict)", "（可能冲突）"))"
                    : "\(modifier.symbol) \(modifier.displayName)",
                action: #selector(switchActivationModifier(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = modifier
            item.state = modifier == activationModifierKey ? .on : .off
            modifierMenu.addItem(item)
        }
        modifierItem.submenu = modifierMenu
        settingsMenu.addItem(modifierItem)

        let openConfig = NSMenuItem(title: L10n.text("Open Config File…", "打开配置文件…"), action: #selector(openConfigFile), keyEquivalent: ",")
        openConfig.target = self
        settingsMenu.addItem(openConfig)

        let loginItem = NSMenuItem(title: L10n.text("Launch at Login", "登录时打开"), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        settingsMenu.addItem(loginItem)

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Scenes submenu
        let scenesItem = NSMenuItem(title: L10n.text("Scenes", "场景"), action: nil, keyEquivalent: "")
        let scenesMenu = NSMenu()

        let saveScene = NSMenuItem(title: L10n.text("Save Current Scene…", "保存当前场景…"), action: #selector(saveCurrentScene), keyEquivalent: "s")
        saveScene.target = self
        saveScene.keyEquivalentModifierMask = [.command, .shift]
        scenesMenu.addItem(saveScene)

        let savedScenes = ConfigStore.shared.allScenes
        if !savedScenes.isEmpty {
            scenesMenu.addItem(.separator())
            for scene in savedScenes {
                let sceneItem = NSMenuItem(title: scene.name, action: #selector(restoreSceneFromMenu(_:)), keyEquivalent: "")
                sceneItem.target = self
                sceneItem.representedObject = scene

                // Add update & delete as submenu
                let sceneSubMenu = NSMenu()
                let updateItem = NSMenuItem(
                    title: L10n.text("Update \"\(scene.name)\"", "更新“\(scene.name)”"),
                    action: #selector(updateSceneFromMenu(_:)),
                    keyEquivalent: ""
                )
                updateItem.target = self
                updateItem.representedObject = scene.name
                sceneSubMenu.addItem(updateItem)
                sceneSubMenu.addItem(.separator())
                let deleteItem = NSMenuItem(
                    title: L10n.text("Delete \"\(scene.name)\"", "删除“\(scene.name)”"),
                    action: #selector(deleteSceneFromMenu(_:)),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                deleteItem.representedObject = scene.name
                sceneSubMenu.addItem(deleteItem)
                sceneItem.submenu = sceneSubMenu

                scenesMenu.addItem(sceneItem)
            }
        }

        scenesItem.submenu = scenesMenu
        menu.addItem(scenesItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: L10n.text("About WindowGrid", "关于 WindowGrid"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: L10n.text("Quit WindowGrid", "退出 WindowGrid"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func switchLayout(_ sender: NSMenuItem) {
        guard let layout = sender.representedObject as? GridLayout,
              let screen = currentContextScreen() else { return }
        ConfigStore.shared.setLayout(layout, for: screen)
        overlayWindows[screen]?.updateLayout(effectiveLayout(for: screen))
        rebuildMenu()
        NSLog("WindowGrid: Switched \(ConfigStore.shared.contextLabel(for: screen)) to \"\(layout.name)\"")
    }

    @objc private func switchActivationModifier(_ sender: NSMenuItem) {
        guard let modifierKey = sender.representedObject as? ActivationModifierKey else { return }
        activationModifierKey = modifierKey
        ConfigStore.shared.setActivationModifierKey(modifierKey)
        rebuildMenu()
        debugLog("MODIFIER: changed to \(modifierKey.rawValue)")
        NSLog("WindowGrid: Drag modifier changed to \(modifierKey.displayName)")
    }

    @objc private func requestAccessibilityAccess() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
        rebuildMenu()
    }

    @objc private func nameCurrentDesktop() {
        guard let screen = currentContextScreen() else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("Name This Desktop", "命名此桌面")
        alert.informativeText = L10n.text(
            "Give the current desktop a short name, such as Development, Design, or Writing.",
            "给当前桌面起一个简短名称，比如开发、设计或写作。"
        )
        alert.addButton(withTitle: L10n.text("Save", "保存"))
        alert.addButton(withTitle: L10n.text("Cancel", "取消"))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = ConfigStore.shared.desktopName(for: screen) ?? ""
        textField.placeholderString = L10n.text("e.g. Development", "例如：开发")
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ConfigStore.shared.setDesktopName(textField.stringValue, for: screen)
        updateStatusBarTitle()
        rebuildMenu()
        debugLog("DESKTOP_NAME: \(textField.stringValue)")
    }

    @objc private func clearCurrentDesktopName() {
        guard let screen = currentContextScreen() else { return }
        ConfigStore.shared.setDesktopName(nil, for: screen)
        updateStatusBarTitle()
        rebuildMenu()
        debugLog("DESKTOP_NAME: cleared")
    }

    @objc private func selectArrangeShortcut(_ sender: NSMenuItem) {
        guard let shortcut = sender.representedObject as? KeyboardShortcut else { return }
        ConfigStore.shared.setArrangeShortcut(shortcut)
        registerArrangeHotKey()
        rebuildMenu()
        debugLog("ARRANGE_SHORTCUT: changed to \(shortcut.displayName)")
    }

    @objc private func setCustomArrangeShortcut() {
        let captureView = ShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 320, height: 88))
        let alert = NSAlert()
        alert.messageText = L10n.text("Set Arrange Shortcut", "设置排列快捷键")
        alert.informativeText = L10n.text(
            "Click the field, then press a shortcut with at least one modifier.",
            "点击输入框，然后按下至少包含一个修饰键的快捷键。"
        )
        alert.accessoryView = captureView
        alert.addButton(withTitle: L10n.text("Save", "保存"))
        alert.addButton(withTitle: L10n.text("Cancel", "取消"))
        alert.window.initialFirstResponder = captureView

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let shortcut = captureView.shortcut else { return }
        guard shortcut.hasUsableModifier else {
            let warning = NSAlert()
            warning.messageText = L10n.text("Shortcut needs a modifier", "快捷键需要修饰键")
            warning.informativeText = L10n.text(
                "Use Control, Option, Command, or Shift with a key.",
                "请将 Control、Option、Command 或 Shift 与某个按键组合使用。"
            )
            warning.runModal()
            return
        }
        ConfigStore.shared.setArrangeShortcut(shortcut)
        registerArrangeHotKey()
        rebuildMenu()
        debugLog("ARRANGE_SHORTCUT: custom \(shortcut.displayName)")
    }

    @objc private func disableArrangeShortcut() {
        ConfigStore.shared.setArrangeShortcut(nil)
        unregisterArrangeHotKey()
        rebuildMenu()
        debugLog("ARRANGE_SHORTCUT: disabled")
    }

    @objc private func selectNewBrowserShortcut(_ sender: NSMenuItem) {
        guard let shortcut = sender.representedObject as? KeyboardShortcut else { return }
        ConfigStore.shared.setNewBrowserShortcut(shortcut)
        registerNewBrowserHotKey()
        rebuildMenu()
        debugLog("NEW_BROWSER_SHORTCUT: changed to \(shortcut.displayName)")
    }

    @objc private func selectNewBrowserApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        ConfigStore.shared.setNewBrowserBundleID(bundleID)
        rebuildMenu()
        debugLog("NEW_BROWSER_APP: changed to \(bundleID)")
    }

    @objc private func setCustomNewBrowserShortcut() {
        let captureView = ShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 320, height: 88))
        let alert = NSAlert()
        alert.messageText = L10n.text("Set New Browser Shortcut", "设置新建浏览器快捷键")
        alert.informativeText = L10n.text(
            "Click the field, then press a shortcut with at least one modifier.",
            "点击输入框，然后按下至少包含一个修饰键的快捷键。"
        )
        alert.accessoryView = captureView
        alert.addButton(withTitle: L10n.text("Save", "保存"))
        alert.addButton(withTitle: L10n.text("Cancel", "取消"))
        alert.window.initialFirstResponder = captureView

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let shortcut = captureView.shortcut else { return }
        guard shortcut.hasUsableModifier else {
            let warning = NSAlert()
            warning.messageText = L10n.text("Shortcut needs a modifier", "快捷键需要修饰键")
            warning.informativeText = L10n.text(
                "Use Control, Option, Command, or Shift with a key.",
                "请将 Control、Option、Command 或 Shift 与某个按键组合使用。"
            )
            warning.runModal()
            return
        }
        ConfigStore.shared.setNewBrowserShortcut(shortcut)
        registerNewBrowserHotKey()
        rebuildMenu()
        debugLog("NEW_BROWSER_SHORTCUT: custom \(shortcut.displayName)")
    }

    @objc private func disableNewBrowserShortcut() {
        ConfigStore.shared.setNewBrowserShortcut(nil)
        unregisterNewBrowserHotKey()
        rebuildMenu()
        debugLog("NEW_BROWSER_SHORTCUT: disabled")
    }

    @objc private func openNewBrowserWindow() {
        let screen = currentContextScreen()
        let previousWindows = screen.map { WindowSnapper.getAllVisibleWindows(onScreen: $0) } ?? []
        let browserBundleID = ConfigStore.shared.newBrowserBundleID
        let opened = WindowSnapper.openNewBrowserWindow(preferredBundleID: browserBundleID)
        debugLog("NEW_BROWSER_WINDOW: \(opened ? "opened" : "failed")")
        if opened, let screen {
            arrangeAfterNewBrowserWindow(on: screen, previousWindows: previousWindows)
        }
        if !opened {
            let alert = NSAlert()
            alert.messageText = L10n.text("Could Not Open Browser", "无法打开浏览器")
            alert.informativeText = L10n.text(
                "WindowGrid could not find \(BrowserChoice.name(for: browserBundleID)) or a system default browser.",
                "WindowGrid 找不到 \(BrowserChoice.name(for: browserBundleID)) 或系统默认浏览器。"
            )
            alert.runModal()
        }
    }

    @objc private func toggleAdaptiveArrange(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        ConfigStore.shared.setAdaptiveArrangeEnabled(enabled)
        refreshOverlayLayouts()
        rebuildMenu()
        debugLog("ADAPTIVE_ARRANGE: \(enabled ? "enabled" : "disabled")")
    }

    @objc private func toggleLiveAdaptiveGrid(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        ConfigStore.shared.setLiveAdaptiveGridEnabled(enabled)
        refreshOverlayLayouts()
        rebuildMenu()
        debugLog("LIVE_ADAPTIVE_GRID: \(enabled ? "enabled" : "disabled")")
    }

    @objc private func setCurrentLayoutAsDefault() {
        guard let screen = currentContextScreen() else { return }
        let layout = ConfigStore.shared.layout(for: screen)
        ConfigStore.shared.setActiveLayout(layout)
        rebuildMenu()
        NSLog("WindowGrid: Set default layout to \"\(layout.name)\"")
    }

    @objc private func clearCurrentLayoutOverride() {
        guard let screen = currentContextScreen() else { return }
        ConfigStore.shared.clearLayoutOverride(for: screen)
        overlayWindows[screen]?.updateLayout(effectiveLayout(for: screen))
        rebuildMenu()
        NSLog("WindowGrid: Cleared layout override for \(ConfigStore.shared.contextLabel(for: screen))")
    }

    @objc private func arrangeAllWindows() {
        guard let screen = currentContextScreen() else { return }
        performArrangeAllWindows(on: screen)
    }

    private func performArrangeAllWindows(
        on screen: NSScreen,
        orderedWindows: [(window: AXUIElement, appName: String)]? = nil,
        cycleAdaptiveLayout: Bool = true
    ) {
        let visibleFrame = screen.visibleFrame
        let discoveredWindows = orderedWindows ?? WindowSnapper.getAllVisibleWindows(onScreen: screen)
        var windows = stableWindowOrder(discoveredWindows)

        let layout: GridLayout
        let arrangedWindows: [(window: AXUIElement, appName: String)]
        var orderVariant = 0
        if ConfigStore.shared.adaptiveArrangeEnabled {
            let context = LayoutContext.current(for: screen)
            let cycleKey = "\(context.key)|windows:\(windows.count)"
            if adaptiveArrangeCycleKey != cycleKey {
                adaptiveArrangeCycleKey = cycleKey
                adaptiveArrangeCycleIndex = 0
                adaptiveArrangeCycleWindowOrder = windows
            }
            windows = adaptiveCycleWindowOrder(for: windows)
            let variantCount = GridLayout.adaptiveVariantCount(forWindowCount: windows.count)
            let orderVariantCount = adaptiveWindowOrderVariantCount(forWindowCount: windows.count)
            let variant = cycleAdaptiveLayout && variantCount > 0
                ? (adaptiveArrangeCycleIndex / orderVariantCount) % variantCount
                : 0
            orderVariant = cycleAdaptiveLayout ? adaptiveArrangeCycleIndex % orderVariantCount : 0
            layout = GridLayout.adaptive(forWindowCount: windows.count, variant: variant)
            lastAdaptiveArrangeLayouts[cycleKey] = layout
            let cycleCount = adaptiveArrangeCycleCount(layoutVariants: variantCount, orderVariants: orderVariantCount)
            adaptiveArrangeCycleIndex = cycleAdaptiveLayout && cycleCount > 0
                ? nextAdaptiveArrangeCycleIndex(current: adaptiveArrangeCycleIndex, cycleCount: cycleCount)
                : 0
            arrangedWindows = adaptiveWindowOrder(windows, variant: orderVariant)
        } else if ConfigStore.shared.liveAdaptiveGridEnabled {
            layout = effectiveLayout(for: screen, windowCount: windows.count)
            arrangedWindows = windows
        } else {
            layout = effectiveLayout(for: screen, windowCount: windows.count)
            arrangedWindows = windows
        }
        let windowSummary = windows.enumerated()
            .map { index, win in "\(index + 1). \(WindowSnapper.debugDescription(for: win.window, appName: win.appName))" }
            .joined(separator: " | ")
        debugLog("ARRANGE_WINDOWS: count=\(windows.count) \(windowSummary)")
        let zones = layout.zoneRects(in: visibleFrame)
        let zoneSummary = zones.enumerated()
            .map { index, zone in
                "\(index + 1). x=\(Int(zone.rect.minX)) y=\(Int(zone.rect.minY)) w=\(Int(zone.rect.width)) h=\(Int(zone.rect.height))"
            }
            .joined(separator: " | ")
        debugLog("ARRANGE_ZONES: screen=x=\(Int(visibleFrame.minX)) y=\(Int(visibleFrame.minY)) w=\(Int(visibleFrame.width)) h=\(Int(visibleFrame.height)) layout=\"\(layout.name)\" \(zoneSummary)")

        guard !arrangedWindows.isEmpty && !zones.isEmpty else { return }

        let shouldFullyArrange = ConfigStore.shared.adaptiveArrangeEnabled || ConfigStore.shared.liveAdaptiveGridEnabled
        let result = shouldFullyArrange
            ? arrangeFully(windows: arrangedWindows, zones: zones)
            : arrangeIncrementally(windows: arrangedWindows, zones: zones)

        let mode = ConfigStore.shared.adaptiveArrangeEnabled
            ? "adaptive"
            : (ConfigStore.shared.liveAdaptiveGridEnabled ? "live adaptive" : "manual")
        debugLog("ARRANGE: \(mode) layout=\"\(layout.name)\" windows=\(windows.count) orderVariant=\(orderVariant) kept=\(result.kept) arranged=\(result.arranged) minimized=\(result.minimized)")
        NSLog("WindowGrid: \(mode) arrange kept \(result.kept), arranged \(result.arranged), minimized \(result.minimized)")
        refreshOverlayLayouts()
        rebuildMenu()
    }

    private func stableWindowOrder(
        _ windows: [(window: AXUIElement, appName: String)]
    ) -> [(window: AXUIElement, appName: String)] {
        windows.sorted { lhs, rhs in
            guard let lhsRect = WindowSnapper.getWindowRect(lhs.window) else { return false }
            guard let rhsRect = WindowSnapper.getWindowRect(rhs.window) else { return true }

            let rowTolerance = max(80, min(lhsRect.height, rhsRect.height) * 0.35)
            if abs(lhsRect.midY - rhsRect.midY) > rowTolerance {
                return lhsRect.midY > rhsRect.midY
            }
            if abs(lhsRect.midX - rhsRect.midX) > 12 {
                return lhsRect.midX < rhsRect.midX
            }
            return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
        }
    }

    private func adaptiveCycleWindowOrder(
        for windows: [(window: AXUIElement, appName: String)]
    ) -> [(window: AXUIElement, appName: String)] {
        guard adaptiveArrangeCycleWindowOrder.count == windows.count else {
            adaptiveArrangeCycleIndex = 0
            adaptiveArrangeCycleWindowOrder = windows
            return windows
        }

        var usedIndices = Set<Int>()
        var preservedWindows: [(window: AXUIElement, appName: String)] = []
        for previous in adaptiveArrangeCycleWindowOrder {
            guard let matchIndex = windows.indices.first(where: { index in
                !usedIndices.contains(index) && isSameCycleWindow(previous.window, windows[index].window)
            }) else {
                adaptiveArrangeCycleIndex = 0
                adaptiveArrangeCycleWindowOrder = windows
                return windows
            }
            usedIndices.insert(matchIndex)
            preservedWindows.append(windows[matchIndex])
        }
        adaptiveArrangeCycleWindowOrder = preservedWindows
        return preservedWindows
    }

    private func isSameCycleWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) { return true }

        var lhsPid: pid_t = 0
        var rhsPid: pid_t = 0
        AXUIElementGetPid(lhs, &lhsPid)
        AXUIElementGetPid(rhs, &rhsPid)
        guard lhsPid == rhsPid else { return false }

        let lhsTitle = windowTitle(lhs)
        return !lhsTitle.isEmpty && lhsTitle == windowTitle(rhs)
    }

    private func windowTitle(_ window: AXUIElement) -> String {
        var titleRef: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        return titleRef as? String ?? ""
    }

    private func adaptiveWindowOrderVariantCount(forWindowCount count: Int) -> Int {
        count <= 1 ? 1 : factorialClamped(count)
    }

    private func adaptiveWindowOrder(
        _ windows: [(window: AXUIElement, appName: String)],
        variant: Int
    ) -> [(window: AXUIElement, appName: String)] {
        guard windows.count > 1 else { return windows }

        return permutationIndices(count: windows.count, variant: variant).map { windows[$0] }
    }

    private func permutationIndices(count: Int, variant: Int) -> [Int] {
        guard count > 1 else { return Array(0..<count) }

        var pool = Array(0..<count)
        var result: [Int] = []
        var index = variant % factorialClamped(count)

        for remaining in stride(from: count, through: 1, by: -1) {
            let blockSize = factorialClamped(remaining - 1)
            let selectedIndex = blockSize > 0 ? (index / blockSize) % remaining : 0
            result.append(pool.remove(at: selectedIndex))
            index = blockSize > 0 ? index % blockSize : 0
        }

        return result
    }

    private func factorialClamped(_ value: Int) -> Int {
        guard value > 1 else { return 1 }

        var result = 1
        for multiplier in 2...value {
            if result > Int.max / multiplier {
                return Int.max
            }
            result *= multiplier
        }
        return result
    }

    private func adaptiveArrangeCycleCount(layoutVariants: Int, orderVariants: Int) -> Int {
        guard layoutVariants > 0 && orderVariants > 0 else { return 0 }
        let (cycleCount, overflow) = layoutVariants.multipliedReportingOverflow(by: orderVariants)
        return overflow ? Int.max : cycleCount
    }

    private func nextAdaptiveArrangeCycleIndex(current: Int, cycleCount: Int) -> Int {
        current >= cycleCount - 1 ? 0 : current + 1
    }

    private func arrangeAfterNewBrowserWindow(
        on screen: NSScreen,
        previousWindows: [(window: AXUIElement, appName: String)]
    ) {
        var attempts = 0
        let targetWindowCount = previousWindows.count + 1

        func checkAndArrange() {
            attempts += 1
            let currentWindows = WindowSnapper.getAllVisibleWindows(onScreen: screen)
            let currentWindowCount = currentWindows.count
            if currentWindowCount >= targetWindowCount {
                let orderedWindows = browserWindowLastOrder(previousWindows: previousWindows, currentWindows: currentWindows)
                debugLog("NEW_BROWSER_WINDOW: auto arrange after attempts=\(attempts) target=\(targetWindowCount) now=\(currentWindowCount) newLast=\(orderedWindows.count)")
                performArrangeAllWindows(on: screen, orderedWindows: orderedWindows, cycleAdaptiveLayout: false)
                return
            }

            if attempts >= 20 {
                debugLog("NEW_BROWSER_WINDOW: auto arrange skipped after attempts=\(attempts) target=\(targetWindowCount) now=\(currentWindowCount)")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                checkAndArrange()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            checkAndArrange()
        }
    }

    private func browserWindowLastOrder(
        previousWindows: [(window: AXUIElement, appName: String)],
        currentWindows: [(window: AXUIElement, appName: String)]
    ) -> [(window: AXUIElement, appName: String)] {
        let existingWindows = previousWindows.compactMap { previous in
            currentWindows.first { current in
                WindowSnapper.isSameWindow(previous.window, current.window)
            }
        }
        let newWindows = currentWindows.filter { current in
            !previousWindows.contains { previous in
                WindowSnapper.isSameWindow(previous.window, current.window)
            }
        }
        return existingWindows + newWindows
    }

    private func arrangeFully(
        windows: [(window: AXUIElement, appName: String)],
        zones: [(zone: Int, rect: NSRect)]
    ) -> (kept: Int, arranged: Int, minimized: Int) {
        var arranged = 0
        var minimized = 0

        for (index, win) in windows.enumerated() {
            if index < zones.count {
                WindowSnapper.snapWindow(win.window, to: zones[index].rect)
                arranged += 1
            } else {
                WindowSnapper.minimizeWindow(win.window)
                minimized += 1
            }
        }

        return (0, arranged, minimized)
    }

    private func arrangeIncrementally(
        windows: [(window: AXUIElement, appName: String)],
        zones: [(zone: Int, rect: NSRect)]
    ) -> (kept: Int, arranged: Int, minimized: Int) {
        var occupiedZoneIndices = Set<Int>()
        var unalignedWindows: [(window: AXUIElement, appName: String)] = []
        var kept = 0

        for win in windows {
            guard let rect = WindowSnapper.getWindowRect(win.window),
                  let zoneIndex = bestAlignedZoneIndex(for: rect, zones: zones, occupied: occupiedZoneIndices)
            else {
                unalignedWindows.append(win)
                continue
            }
            occupiedZoneIndices.insert(zoneIndex)
            kept += 1
        }

        let emptyZones = zones.enumerated()
            .filter { !occupiedZoneIndices.contains($0.offset) }
            .map { $0.element }

        var arranged = 0
        var minimized = 0
        for (index, win) in unalignedWindows.enumerated() {
            if index < emptyZones.count {
                WindowSnapper.snapWindow(win.window, to: emptyZones[index].rect)
                arranged += 1
            } else {
                WindowSnapper.minimizeWindow(win.window)
                minimized += 1
            }
        }

        return (kept, arranged, minimized)
    }

    private func bestAlignedZoneIndex(
        for windowRect: NSRect,
        zones: [(zone: Int, rect: NSRect)],
        occupied: Set<Int>
    ) -> Int? {
        var bestIndex: Int?
        var bestScore: CGFloat = 0

        for (index, zone) in zones.enumerated() {
            guard !occupied.contains(index) else { continue }
            let score = alignmentScore(windowRect: windowRect, zoneRect: zone.rect)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        return bestScore >= 0.82 ? bestIndex : nil
    }

    private func alignmentScore(windowRect: NSRect, zoneRect: NSRect) -> CGFloat {
        let intersection = windowRect.intersection(zoneRect)
        guard !intersection.isNull else { return 0 }

        let intersectionArea = intersection.width * intersection.height
        let windowArea = max(1, windowRect.width * windowRect.height)
        let zoneArea = max(1, zoneRect.width * zoneRect.height)
        let overlapScore = min(intersectionArea / windowArea, intersectionArea / zoneArea)

        let edgeTolerance: CGFloat = 28
        let edgeDelta = abs(windowRect.minX - zoneRect.minX)
            + abs(windowRect.minY - zoneRect.minY)
            + abs(windowRect.width - zoneRect.width)
            + abs(windowRect.height - zoneRect.height)
        let edgeScore = max(0, 1 - edgeDelta / (edgeTolerance * 4))

        return max(overlapScore, edgeScore)
    }

    private func setupHotKeyHandler() {
        guard hotKeyHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData = userData, let event = event else { return noErr }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == appDelegate.arrangeHotKeySignature
                else { return noErr }

                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case appDelegate.arrangeHotKeyID:
                        appDelegate.arrangeAllWindows()
                    case appDelegate.newBrowserHotKeyID:
                        appDelegate.openNewBrowserWindow()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
        if status != noErr {
            debugLog("HOTKEY: failed to install handler status=\(status)")
        }
    }

    private func registerArrangeHotKey() {
        unregisterArrangeHotKey()
        guard let shortcut = ConfigStore.shared.arrangeShortcut else {
            debugLog("HOTKEY: arrange shortcut disabled")
            return
        }

        let hotKeyID = EventHotKeyID(signature: arrangeHotKeySignature, id: arrangeHotKeyID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &arrangeHotKeyRef
        )

        if status == noErr {
            debugLog("HOTKEY: registered arrange \(shortcut.displayName)")
        } else {
            arrangeHotKeyRef = nil
            debugLog("HOTKEY: failed to register arrange \(shortcut.displayName), status=\(status)")
        }
    }

    private func unregisterArrangeHotKey() {
        if let arrangeHotKeyRef = arrangeHotKeyRef {
            UnregisterEventHotKey(arrangeHotKeyRef)
            self.arrangeHotKeyRef = nil
        }
    }

    private func registerNewBrowserHotKey() {
        unregisterNewBrowserHotKey()
        guard let shortcut = ConfigStore.shared.newBrowserShortcut else {
            debugLog("HOTKEY: new browser shortcut disabled")
            return
        }

        let hotKeyID = EventHotKeyID(signature: arrangeHotKeySignature, id: newBrowserHotKeyID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newBrowserHotKeyRef
        )

        if status == noErr {
            debugLog("HOTKEY: registered new browser \(shortcut.displayName)")
        } else {
            newBrowserHotKeyRef = nil
            debugLog("HOTKEY: failed to register new browser \(shortcut.displayName), status=\(status)")
        }
    }

    private func unregisterNewBrowserHotKey() {
        if let newBrowserHotKeyRef = newBrowserHotKeyRef {
            UnregisterEventHotKey(newBrowserHotKeyRef)
            self.newBrowserHotKeyRef = nil
        }
    }

    @objc private func previewGrid() {
        showOverlays()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.hideOverlays()
        }
    }

    private func effectiveLayout(for screen: NSScreen, windowCount: Int? = nil) -> GridLayout {
        let count = windowCount ?? WindowSnapper.getAllVisibleWindows(onScreen: screen).count

        if ConfigStore.shared.adaptiveArrangeEnabled {
            let key = adaptiveArrangeLayoutKey(for: screen, windowCount: count)
            return lastAdaptiveArrangeLayouts[key] ?? GridLayout.adaptive(forWindowCount: count)
        }

        if ConfigStore.shared.liveAdaptiveGridEnabled {
            return GridLayout.liveAdaptive(forWindowCount: count)
        }

        return ConfigStore.shared.layout(for: screen)
    }

    private func adaptiveArrangeLayoutKey(for screen: NSScreen, windowCount: Int) -> String {
        let context = LayoutContext.current(for: screen)
        return "\(context.key)|windows:\(windowCount)"
    }

    @objc private func saveCurrentScene() {
        guard let screen = currentContextScreen() else { return }
        let layout = effectiveLayout(for: screen)

        let assignments = WindowSnapper.captureArrangement(layout: layout, onScreen: screen)
        guard !assignments.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.text("No windows to save", "没有可保存的窗口")
            alert.informativeText = L10n.text(
                "Arrange some windows in the grid first, then save the scene.",
                "请先把一些窗口排列到网格中，然后再保存场景。"
            )
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.text("Save Scene", "保存场景")
        alert.informativeText = L10n.text("Name this window arrangement:", "给这个窗口排列命名：")
        alert.addButton(withTitle: L10n.text("Save", "保存"))
        alert.addButton(withTitle: L10n.text("Cancel", "取消"))

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = L10n.text("e.g. Coding, Design, Writing", "例如：开发、设计、写作")
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let scene = WindowScene(name: name, layoutName: layout.name, assignments: assignments)
        ConfigStore.shared.saveScene(scene)
        rebuildMenu()

        NSLog("WindowGrid: Saved scene \"\(name)\" with \(assignments.count) windows")
    }

    @objc private func restoreSceneFromMenu(_ sender: NSMenuItem) {
        guard let scene = sender.representedObject as? WindowScene,
              let screen = currentContextScreen() else { return }

        var layout = ConfigStore.shared.layout(for: screen)
        // Switch to the scene's layout if different
        if let sceneLayout = ConfigStore.shared.allLayouts.first(where: { $0.name == scene.layoutName }) {
            layout = sceneLayout
            ConfigStore.shared.setLayout(sceneLayout, for: screen)
            overlayWindows[screen]?.updateLayout(sceneLayout)
        }

        WindowSnapper.restoreScene(scene, layout: layout, onScreen: screen)
        rebuildMenu()
        NSLog("WindowGrid: Restored scene \"\(scene.name)\"")
    }

    @objc private func updateSceneFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let screen = currentContextScreen() else { return }
        let layout = effectiveLayout(for: screen)

        let assignments = WindowSnapper.captureArrangement(layout: layout, onScreen: screen)
        guard !assignments.isEmpty else { return }

        let scene = WindowScene(name: name, layoutName: layout.name, assignments: assignments)
        ConfigStore.shared.saveScene(scene)
        rebuildMenu()
        debugLog("Updated scene \"\(name)\" with \(assignments.count) windows")
    }

    @objc private func deleteSceneFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        ConfigStore.shared.deleteScene(name: name)
        rebuildMenu()
        NSLog("WindowGrid: Deleted scene \"\(name)\"")
    }

    @objc private func openLayoutPanel() {
        layoutPanelContextScreen = currentContextScreen()
        if layoutPanel == nil {
            let layout = layoutPanelContextScreen.map { ConfigStore.shared.layout(for: $0) } ?? ConfigStore.shared.activeLayout
            layoutPanel = LayoutPanel(currentLayout: layout)
            layoutPanel?.layoutDelegate = self
        }
        if let screen = layoutPanelContextScreen {
            layoutPanel?.setCurrentLayout(ConfigStore.shared.layout(for: screen))
        }
        layoutPanel?.showPanel()
    }

    func layoutPanel(_ panel: LayoutPanel, didSelectLayout layout: GridLayout) {
        guard let screen = layoutPanelContextScreen ?? currentContextScreen() else { return }
        ConfigStore.shared.setLayout(layout, for: screen)
        overlayWindows[screen]?.updateLayout(effectiveLayout(for: screen))
        rebuildMenu()
        NSLog("WindowGrid: Applied layout \"\(layout.name)\" to \(ConfigStore.shared.contextLabel(for: screen))")
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.toggle()
        rebuildMenu()
    }

    @objc private func openConfigFile() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/windowgrid/config.json")
        NSWorkspace.shared.open(configPath)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "WindowGrid"
        alert.informativeText = L10n.text(
            "Open-source window management for macOS.\n\nHold \(activationModifierKey.displayName) + drag any window to snap it to a grid zone.\n\nVersion 0.1.0",
            "开源 macOS 窗口管理工具。\n\n按住 \(activationModifierKey.displayName) 并拖拽任意窗口，即可将它吸附到网格区域。\n\n版本 0.1.0"
        )
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Event Monitoring

    private func setupEventMonitors() {
        // Track activation modifier via flags changed (global)
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Also need local flags monitor for when our own windows are focused
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalMouseDown = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
        }

        globalMouseDragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.handleMouseDragged(event)
        }

        globalMouseUp = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleMouseUp(event)
        }

        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleActiveSpaceChanged()
        }

        startSpacePolling()
    }

    private func removeEventMonitors() {
        [globalMouseDown, globalMouseDragged, globalMouseUp, flagsChangedMonitor, localFlagsMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        spacePollingTimer?.invalidate()
        spacePollingTimer = nil
        if let activeSpaceObserver = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
    }

    private func startSpacePolling() {
        syncLastSeenSpaceKeys()
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.pollActiveSpaces()
        }
        spacePollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollActiveSpaces() {
        let changedDisplays = detectChangedSpaceDisplayIDs()
        guard !changedDisplays.isEmpty else { return }

        debugLog("SPACE_POLL: changed displays=\(changedDisplays.map(String.init).joined(separator: ","))")
        handleActiveSpaceChanged(changedDisplayIDs: Set(changedDisplays))
    }

    private func syncLastSeenSpaceKeys() {
        lastSeenSpaceKeys = currentSpaceKeySnapshot()
    }

    private func currentSpaceKeySnapshot() -> [UInt32: String] {
        Dictionary(
            uniqueKeysWithValues: NSScreen.screens.map { screen in
                let context = LayoutContext.current(for: screen)
                return (context.displayID, context.key)
            }
        )
    }

    private func detectChangedSpaceDisplayIDs() -> [UInt32] {
        let nextSpaceKeys = currentSpaceKeySnapshot()
        var changedDisplays = nextSpaceKeys.compactMap { displayID, key -> UInt32? in
            guard let previousKey = lastSeenSpaceKeys[displayID] else { return displayID }
            return previousKey == key ? nil : displayID
        }

        for displayID in lastSeenSpaceKeys.keys where nextSpaceKeys[displayID] == nil {
            changedDisplays.append(displayID)
        }

        lastSeenSpaceKeys = nextSpaceKeys
        return Array(Set(changedDisplays))
    }

    // MARK: - Event Handlers

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifierPressed = activationModifierKey.isPressed(in: event.modifierFlags)

        if modifierPressed && !isActivationModifierHeld {
            isActivationModifierHeld = true
        } else if !modifierPressed && isActivationModifierHeld {
            isActivationModifierHeld = false
            // Activation modifier released — if we were dragging, cancel the snap overlay
            if isDragging {
                isDragging = false
                draggedWindow = nil
                hideOverlays()
            }
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard activationModifierKey.isPressed(in: event.modifierFlags) else { return }
        isActivationModifierHeld = true
        // Only record the start location. Don't touch windows yet.
        dragStartLocation = NSEvent.mouseLocation
        isDragging = false
        draggedWindow = nil
        dragSourceZoneIndex = -1
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard activationModifierKey.isPressed(in: event.modifierFlags) else {
            if isDragging {
                isDragging = false
                draggedWindow = nil
                hideOverlays()
            }
            isActivationModifierHeld = false
            return
        }
        isActivationModifierHeld = true

        let current = NSEvent.mouseLocation
        let distance = hypot(current.x - dragStartLocation.x, current.y - dragStartLocation.y)

        // First time crossing threshold: initialize drag state
        if !isDragging && distance > dragThreshold {
            // Get the window at the ORIGINAL mouseDown position
            draggedWindow = WindowSnapper.getWindowUnderCursor(at: dragStartLocation)
            guard draggedWindow != nil else {
                debugLog("DRAG: no AX window under cursor; accessibility=\(WindowSnapper.isAccessibilityTrusted)")
                hideOverlays()
                return
            }

            // Find which zone the drag started in
            for screen in NSScreen.screens {
                guard screen.frame.contains(dragStartLocation) else { continue }
                let layout = effectiveLayout(for: screen)
                if let zone = layout.zoneAt(point: dragStartLocation, in: screen.visibleFrame) {
                    dragSourceZoneIndex = zone.zone
                }
                break
            }

            isDragging = true
            showOverlays()

            if activationModifierKey == .option {
                // Undo macOS's Option+click "hide other apps" behavior
                for app in NSWorkspace.shared.runningApplications {
                    if app.isHidden && app.activationPolicy == .regular {
                        app.unhide()
                    }
                }
            }
        }

        if isDragging {
            updateHighlight(at: current)
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard isDragging, let window = draggedWindow else {
            isDragging = false
            draggedWindow = nil
            hideOverlays()
            return
        }

        let mouseLocation = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            guard screen.frame.contains(mouseLocation) else { continue }
            let layout = effectiveLayout(for: screen)
            let visibleFrame = screen.visibleFrame
            let zones = layout.zoneRects(in: visibleFrame)

            if let targetZone = layout.zoneAt(point: mouseLocation, in: visibleFrame) {
                let targetIndex = targetZone.zone
                let targetRect = targetZone.rect

                // Find occupant: any window in the target zone (excluding the dragged one)
                var occupant: AXUIElement? = nil
                if targetIndex != dragSourceZoneIndex,
                   dragSourceZoneIndex >= 0,
                   dragSourceZoneIndex < zones.count {

                    // Get PID of dragged window to exclude it
                    var draggedPid: pid_t = 0
                    AXUIElementGetPid(window, &draggedPid)

                    let allWindows = WindowSnapper.getAllAXWindows(onScreen: screen)
                    for win in allWindows {
                        // Skip the dragged window
                        var winPid: pid_t = 0
                        AXUIElementGetPid(win.window, &winPid)
                        if winPid == draggedPid {
                            var titleA: AnyObject?, titleB: AnyObject?
                            AXUIElementCopyAttributeValue(win.window, kAXTitleAttribute as CFString, &titleA)
                            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleB)
                            if (titleA as? String) == (titleB as? String) { continue }
                        }

                        // Check if this window's center is in the target zone
                        guard let winRect = WindowSnapper.getWindowRect(win.window) else { continue }
                        let center = NSPoint(x: winRect.midX, y: winRect.midY)
                        if targetRect.insetBy(dx: -20, dy: -20).contains(center) {
                            occupant = win.window
                            break
                        }
                    }
                }

                if let occupant = occupant {
                    let sourceRect = zones[dragSourceZoneIndex].rect
                    debugLog("SWAP: zone\(dragSourceZoneIndex) ↔ zone\(targetIndex)")
                    WindowSnapper.snapWindow(occupant, to: sourceRect)
                    usleep(150_000)
                    WindowSnapper.snapWindow(window, to: targetRect)
                    usleep(100_000)
                    let r1 = WindowSnapper.getWindowRect(occupant)
                    let r2 = WindowSnapper.getWindowRect(window)
                    debugLog("  occupant → \(r1?.debugDescription ?? "nil")")
                    debugLog("  dragged → \(r2?.debugDescription ?? "nil")")
                } else {
                    debugLog("NO_SWAP: snap to zone\(targetIndex)")
                    WindowSnapper.snapWindow(window, to: targetRect)
                }
            }
            break
        }

        isDragging = false
        draggedWindow = nil
        hideOverlays()
    }

    private func handleActiveSpaceChanged(changedDisplayIDs providedDisplayIDs: Set<UInt32>? = nil) {
        debugLog("SPACE: active space changed")
        let inferredDisplayIDs = providedDisplayIDs ?? Set(detectChangedSpaceDisplayIDs())
        let targetDisplayIDs = inferredDisplayIDs.isEmpty ? currentContextDisplayIDs() : inferredDisplayIDs
        updateStatusBarTitle()
        rebuildMenu()
        refreshOverlayLayouts()
        refreshDesktopToastAfterSpaceChange(displayIDs: targetDisplayIDs)
        if let screen = currentContextScreen(), layoutPanel?.isVisible == true {
            layoutPanelContextScreen = screen
            layoutPanel?.setCurrentLayout(ConfigStore.shared.layout(for: screen))
        }
    }

    private func currentContextDisplayIDs() -> Set<UInt32> {
        guard let screen = currentContextScreen() else {
            return Set(NSScreen.screens.map { LayoutContext.displayID(for: $0) })
        }
        return [LayoutContext.displayID(for: screen)]
    }

    private func refreshDesktopToastAfterSpaceChange(displayIDs: Set<UInt32>) {
        desktopToastRefreshGeneration += 1
        let generation = desktopToastRefreshGeneration
        showDesktopToast(displayIDs: displayIDs)

        for delay in [0.12, 0.28] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.desktopToastRefreshGeneration == generation else { return }
                self.showDesktopToast(displayIDs: displayIDs)
            }
        }
    }

    private func showDesktopToast(displayIDs targetDisplayIDs: Set<UInt32>? = nil) {
        let activeDisplayIDs = Set(NSScreen.screens.map { LayoutContext.displayID(for: $0) })
        let staleDisplayIDs = desktopToastWindows.keys.filter { !activeDisplayIDs.contains($0) }
        for displayID in staleDisplayIDs {
            desktopToastWindows[displayID]?.hide()
            desktopToastWindows.removeValue(forKey: displayID)
        }

        for screen in NSScreen.screens {
            let displayID = LayoutContext.displayID(for: screen)
            if let targetDisplayIDs, !targetDisplayIDs.contains(displayID) {
                continue
            }
            let toast = desktopToastWindow(for: screen)

            let rawSpaces = LayoutContext.spaces(on: screen)
            let effectiveCurrentSpaceID = effectiveCurrentSpaceID(in: rawSpaces)
            let titleName = ConfigStore.shared.desktopName(for: screen)
            let displayTitle = displayToastTitle(for: screen)
            let title = titleName?.isEmpty == false ? titleName! : L10n.text("Desktop", "桌面")
            debugLog("SPACE_TOAST: display=\(displayID) title=\(displayTitle) current=\(effectiveCurrentSpaceID.map(String.init) ?? "nil")")
            toast.show(
                title: title,
                name: titleName,
                near: screen,
                savedPosition: ConfigStore.shared.toastPosition(for: screen)
            )
        }
    }

    private func effectiveCurrentSpaceID(in spaces: [DesktopSpace]) -> Int? {
        return spaces.first(where: \.isCurrent)?.spaceID
    }

    // MARK: - Overlay Management

    private func refreshOverlayLayouts() {
        for (screen, overlay) in overlayWindows {
            overlay.updateLayout(effectiveLayout(for: screen))
        }
    }

    private func updateHighlight(at point: NSPoint) {
        for (screen, overlay) in overlayWindows {
            if screen.frame.contains(point) {
                overlay.highlightZone(at: point)
            } else {
                overlay.clearHighlight()
            }
        }
    }

    private func showOverlays() {
        for screen in NSScreen.screens {
            let layout = effectiveLayout(for: screen)
            if overlayWindows[screen] == nil {
                overlayWindows[screen] = OverlayWindow(screen: screen, layout: layout)
            } else {
                overlayWindows[screen]?.updateLayout(layout)
            }
            overlayWindows[screen]?.showWithAnimation()
        }
    }

    private func hideOverlays() {
        for (_, overlay) in overlayWindows {
            overlay.hideWithAnimation()
        }
    }
}

extension AppDelegate: DesktopToastWindowDelegate {
    func desktopToastWindowDidMove(_ window: DesktopToastWindow) {
        if let screen = screen(for: window) {
            ConfigStore.shared.setToastPosition(window.frame.origin, for: screen)
        }
    }

    func desktopToastWindow(_ window: DesktopToastWindow, didCommitDesktopName name: String) {
        guard let screen = screen(for: window) else { return }
        ConfigStore.shared.setDesktopName(name, for: screen)
        updateStatusBarTitle()
        rebuildMenu()
        showDesktopToast()
        debugLog("DESKTOP_NAME_INLINE: \(name)")
    }

    private func screen(for window: DesktopToastWindow) -> NSScreen? {
        if let targetDisplayID = window.targetDisplayID,
           let screen = NSScreen.screens.first(where: { LayoutContext.displayID(for: $0) == targetDisplayID }) {
            return screen
        }
        return window.screen
    }

    private func displayToastTitle(for screen: NSScreen) -> String {
        let index = NSScreen.screens.firstIndex(of: screen).map { $0 + 1 } ?? 1
        return L10n.text("Display \(index)", "显示器 \(index)")
    }

}
