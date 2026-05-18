import AppKit
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, LayoutPanelDelegate {
    private var statusItem: NSStatusItem!
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
    private var arrangeHotKeyRef: EventHotKeyRef?
    private var newBrowserHotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var adaptiveArrangeCycleKey: String?
    private var adaptiveArrangeCycleIndex = 0

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

        if !WindowSnapper.checkAccessibility() {
            showAccessibilityAlert()
        }

        debugLog("START: accessibility=\(WindowSnapper.isAccessibilityTrusted), modifier=\(activationModifierKey.rawValue)")
        NSLog("WindowGrid: Started with \(activationModifierKey.displayName) drag modifier")
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

    // MARK: - Accessibility Alert

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "WindowGrid Needs Accessibility Access"
        alert.informativeText = "Grant access in System Settings → Privacy & Security → Accessibility, then relaunch WindowGrid."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")

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
        let contextLabel = contextScreen.map { ConfigStore.shared.contextLabel(for: $0) } ?? "Current Desktop"
        let desktopName = contextScreen.flatMap { ConfigStore.shared.desktopName(for: $0) }

        updateStatusBarTitle()

        let status = NSMenuItem(
            title: WindowSnapper.isAccessibilityTrusted ? "Accessibility: Granted" : "Accessibility: Missing",
            action: WindowSnapper.isAccessibilityTrusted ? nil : #selector(requestAccessibilityAccess),
            keyEquivalent: ""
        )
        status.target = self
        status.isEnabled = true
        menu.addItem(status)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "This Desktop: \(contextLabel)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let hint = NSMenuItem(title: "Choose a layout below for this desktop only", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        if ConfigStore.shared.liveAdaptiveGridEnabled {
            let adaptiveGridItem = NSMenuItem(title: "Current Grid: \(contextLayout.name)", action: nil, keyEquivalent: "")
            adaptiveGridItem.isEnabled = false
            menu.addItem(adaptiveGridItem)
        }

        let nameItem = NSMenuItem(
            title: "Desktop Name: \(desktopName ?? "Not Set")",
            action: nil,
            keyEquivalent: ""
        )
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        let setName = NSMenuItem(title: "Name This Desktop…", action: #selector(nameCurrentDesktop), keyEquivalent: "")
        setName.target = self
        menu.addItem(setName)

        if desktopName != nil {
            let clearName = NSMenuItem(title: "Clear Desktop Name", action: #selector(clearCurrentDesktopName), keyEquivalent: "")
            clearName.target = self
            menu.addItem(clearName)
        }

        menu.addItem(.separator())

        for layout in ConfigStore.shared.allLayouts {
            let item = NSMenuItem(title: layout.name, action: #selector(switchLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout
            item.state = layout.name == savedContextLayout.name && !ConfigStore.shared.liveAdaptiveGridEnabled ? .on : .off
            menu.addItem(item)
        }

        let setDefault = NSMenuItem(
            title: "Set \"\(savedContextLayout.name)\" as Default",
            action: #selector(setCurrentLayoutAsDefault),
            keyEquivalent: ""
        )
        setDefault.target = self
        menu.addItem(setDefault)

        let clearOverride = NSMenuItem(
            title: "Use Default Layout on This Desktop",
            action: #selector(clearCurrentLayoutOverride),
            keyEquivalent: ""
        )
        clearOverride.target = self
        menu.addItem(clearOverride)

        menu.addItem(.separator())

        let arrange = NSMenuItem(
            title: "Arrange All Windows",
            action: #selector(arrangeAllWindows),
            keyEquivalent: ""
        )
        arrange.target = self
        if let arrangeShortcut = ConfigStore.shared.arrangeShortcut {
            arrange.keyEquivalent = arrangeShortcut.menuKeyEquivalent
            arrange.keyEquivalentModifierMask = arrangeShortcut.menuModifierMask
        }
        menu.addItem(arrange)

        let newBrowser = NSMenuItem(
            title: "New Browser Window",
            action: #selector(openNewBrowserWindow),
            keyEquivalent: ""
        )
        newBrowser.target = self
        if let newBrowserShortcut = ConfigStore.shared.newBrowserShortcut {
            newBrowser.keyEquivalent = newBrowserShortcut.menuKeyEquivalent
            newBrowser.keyEquivalentModifierMask = newBrowserShortcut.menuModifierMask
        }
        menu.addItem(newBrowser)

        let adaptiveArrange = NSMenuItem(
            title: "Adaptive Arrange by Window Count",
            action: #selector(toggleAdaptiveArrange(_:)),
            keyEquivalent: ""
        )
        adaptiveArrange.target = self
        adaptiveArrange.state = ConfigStore.shared.adaptiveArrangeEnabled ? .on : .off
        menu.addItem(adaptiveArrange)

        let liveAdaptiveGrid = NSMenuItem(
            title: "Live Adaptive Grid by Window Count",
            action: #selector(toggleLiveAdaptiveGrid(_:)),
            keyEquivalent: ""
        )
        liveAdaptiveGrid.target = self
        liveAdaptiveGrid.state = ConfigStore.shared.liveAdaptiveGridEnabled ? .on : .off
        menu.addItem(liveAdaptiveGrid)

        let shortcutItem = NSMenuItem(title: "Arrange Shortcut", action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        let currentShortcut = ConfigStore.shared.arrangeShortcut

        let current = NSMenuItem(
            title: "Current: \(currentShortcut?.displayName ?? "Off")",
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
        let customShortcut = NSMenuItem(title: "Set Custom Shortcut…", action: #selector(setCustomArrangeShortcut), keyEquivalent: "")
        customShortcut.target = self
        shortcutMenu.addItem(customShortcut)

        let disableShortcut = NSMenuItem(title: "Disable Shortcut", action: #selector(disableArrangeShortcut), keyEquivalent: "")
        disableShortcut.target = self
        disableShortcut.state = currentShortcut == nil ? .on : .off
        shortcutMenu.addItem(disableShortcut)

        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        let browserShortcutItem = NSMenuItem(title: "New Browser Shortcut", action: nil, keyEquivalent: "")
        let browserShortcutMenu = NSMenu()
        let currentBrowserShortcut = ConfigStore.shared.newBrowserShortcut

        let currentBrowser = NSMenuItem(
            title: "Current: \(currentBrowserShortcut?.displayName ?? "Off")",
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
        let customBrowserShortcut = NSMenuItem(title: "Set Custom Shortcut…", action: #selector(setCustomNewBrowserShortcut), keyEquivalent: "")
        customBrowserShortcut.target = self
        browserShortcutMenu.addItem(customBrowserShortcut)

        let disableBrowserShortcut = NSMenuItem(title: "Disable Shortcut", action: #selector(disableNewBrowserShortcut), keyEquivalent: "")
        disableBrowserShortcut.target = self
        disableBrowserShortcut.state = currentBrowserShortcut == nil ? .on : .off
        browserShortcutMenu.addItem(disableBrowserShortcut)

        browserShortcutItem.submenu = browserShortcutMenu
        menu.addItem(browserShortcutItem)

        let preview = NSMenuItem(title: "Preview Grid", action: #selector(previewGrid), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)

        let editLayout = NSMenuItem(title: "Edit Layouts…", action: #selector(openLayoutPanel), keyEquivalent: "l")
        editLayout.target = self
        menu.addItem(editLayout)

        let modifierItem = NSMenuItem(title: "Drag Modifier", action: nil, keyEquivalent: "")
        let modifierMenu = NSMenu()
        for modifier in ActivationModifierKey.allCases {
            let item = NSMenuItem(
                title: modifier == .option
                    ? "\(modifier.symbol) \(modifier.displayName) (may conflict)"
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
        menu.addItem(modifierItem)

        let openConfig = NSMenuItem(title: "Open Config File…", action: #selector(openConfigFile), keyEquivalent: ",")
        openConfig.target = self
        menu.addItem(openConfig)

        menu.addItem(.separator())

        // Scenes submenu
        let scenesItem = NSMenuItem(title: "Scenes", action: nil, keyEquivalent: "")
        let scenesMenu = NSMenu()

        let saveScene = NSMenuItem(title: "Save Current Scene…", action: #selector(saveCurrentScene), keyEquivalent: "s")
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
                let updateItem = NSMenuItem(title: "Update \"\(scene.name)\"", action: #selector(updateSceneFromMenu(_:)), keyEquivalent: "")
                updateItem.target = self
                updateItem.representedObject = scene.name
                sceneSubMenu.addItem(updateItem)
                sceneSubMenu.addItem(.separator())
                let deleteItem = NSMenuItem(title: "Delete \"\(scene.name)\"", action: #selector(deleteSceneFromMenu(_:)), keyEquivalent: "")
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

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let about = NSMenuItem(title: "About WindowGrid", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit WindowGrid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        _ = WindowSnapper.checkAccessibility()
        showAccessibilityAlert()
        rebuildMenu()
    }

    @objc private func nameCurrentDesktop() {
        guard let screen = currentContextScreen() else { return }
        let alert = NSAlert()
        alert.messageText = "Name This Desktop"
        alert.informativeText = "Give the current desktop a short name, such as Development, Design, or Writing."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = ConfigStore.shared.desktopName(for: screen) ?? ""
        textField.placeholderString = "e.g. Development"
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
        alert.messageText = "Set Arrange Shortcut"
        alert.informativeText = "Click the field, then press a shortcut with at least one modifier."
        alert.accessoryView = captureView
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = captureView

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let shortcut = captureView.shortcut else { return }
        guard shortcut.hasUsableModifier else {
            let warning = NSAlert()
            warning.messageText = "Shortcut needs a modifier"
            warning.informativeText = "Use Control, Option, Command, or Shift with a key."
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

    @objc private func setCustomNewBrowserShortcut() {
        let captureView = ShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 320, height: 88))
        let alert = NSAlert()
        alert.messageText = "Set New Browser Shortcut"
        alert.informativeText = "Click the field, then press a shortcut with at least one modifier."
        alert.accessoryView = captureView
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = captureView

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let shortcut = captureView.shortcut else { return }
        guard shortcut.hasUsableModifier else {
            let warning = NSAlert()
            warning.messageText = "Shortcut needs a modifier"
            warning.informativeText = "Use Control, Option, Command, or Shift with a key."
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
        let opened = WindowSnapper.openNewBrowserWindow()
        debugLog("NEW_BROWSER_WINDOW: \(opened ? "opened" : "failed")")
        if opened, let screen {
            arrangeAfterNewBrowserWindow(on: screen, previousWindows: previousWindows)
        }
        if !opened {
            let alert = NSAlert()
            alert.messageText = "Could Not Open Browser"
            alert.informativeText = "WindowGrid could not find Tabbit or a system default browser."
            alert.runModal()
        }
    }

    @objc private func toggleAdaptiveArrange(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        ConfigStore.shared.setAdaptiveArrangeEnabled(enabled)
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
        let windows = orderedWindows ?? WindowSnapper.getAllVisibleWindows(onScreen: screen)

        let layout: GridLayout
        let arrangedWindows: [(window: AXUIElement, appName: String)]
        var windowOffset = 0
        if ConfigStore.shared.adaptiveArrangeEnabled {
            let context = LayoutContext.current(for: screen)
            let cycleKey = "\(context.key)|windows:\(windows.count)"
            if adaptiveArrangeCycleKey != cycleKey {
                adaptiveArrangeCycleKey = cycleKey
                adaptiveArrangeCycleIndex = 0
            }
            let windowCount = max(1, windows.count)
            let variantCount = GridLayout.adaptiveVariantCount(forWindowCount: windows.count)
            let variant = cycleAdaptiveLayout && variantCount > 0
                ? (adaptiveArrangeCycleIndex / windowCount) % variantCount
                : 0
            windowOffset = cycleAdaptiveLayout && !windows.isEmpty ? adaptiveArrangeCycleIndex % windows.count : 0
            layout = GridLayout.adaptive(forWindowCount: windows.count, variant: variant)
            adaptiveArrangeCycleIndex = cycleAdaptiveLayout && variantCount > 0
                ? (adaptiveArrangeCycleIndex + 1) % (variantCount * windowCount)
                : 0
            arrangedWindows = windows.isEmpty
                ? windows
                : Array(windows.dropFirst(windowOffset)) + Array(windows.prefix(windowOffset))
        } else if ConfigStore.shared.liveAdaptiveGridEnabled {
            layout = effectiveLayout(for: screen, windowCount: windows.count)
            arrangedWindows = windows
        } else {
            layout = effectiveLayout(for: screen, windowCount: windows.count)
            arrangedWindows = windows
        }
        let zones = layout.zoneRects(in: visibleFrame)

        guard !arrangedWindows.isEmpty && !zones.isEmpty else { return }

        let shouldFullyArrange = ConfigStore.shared.adaptiveArrangeEnabled || ConfigStore.shared.liveAdaptiveGridEnabled
        let result = shouldFullyArrange
            ? arrangeFully(windows: arrangedWindows, zones: zones)
            : arrangeIncrementally(windows: arrangedWindows, zones: zones)

        let mode = ConfigStore.shared.adaptiveArrangeEnabled
            ? "adaptive"
            : (ConfigStore.shared.liveAdaptiveGridEnabled ? "live adaptive" : "manual")
        debugLog("ARRANGE: \(mode) layout=\"\(layout.name)\" windows=\(windows.count) offset=\(windowOffset) kept=\(result.kept) arranged=\(result.arranged) minimized=\(result.minimized)")
        NSLog("WindowGrid: \(mode) arrange kept \(result.kept), arranged \(result.arranged), minimized \(result.minimized)")
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
        guard ConfigStore.shared.liveAdaptiveGridEnabled else {
            return ConfigStore.shared.layout(for: screen)
        }

        let count = windowCount ?? WindowSnapper.getAllVisibleWindows(onScreen: screen).count
        return GridLayout.liveAdaptive(forWindowCount: count)
    }

    @objc private func saveCurrentScene() {
        guard let screen = currentContextScreen() else { return }
        let layout = effectiveLayout(for: screen)

        let assignments = WindowSnapper.captureArrangement(layout: layout, onScreen: screen)
        guard !assignments.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No windows to save"
            alert.informativeText = "Arrange some windows in the grid first, then save the scene."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Save Scene"
        alert.informativeText = "Name this window arrangement:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "e.g. Coding, Design, Writing"
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
        alert.informativeText = "Open-source window management for macOS.\n\nHold \(activationModifierKey.displayName) + drag any window to snap it to a grid zone.\n\nVersion 0.1.0"
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
    }

    private func removeEventMonitors() {
        [globalMouseDown, globalMouseDragged, globalMouseUp, flagsChangedMonitor, localFlagsMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        if let activeSpaceObserver = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
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

    private func handleActiveSpaceChanged() {
        debugLog("SPACE: active space changed")
        updateStatusBarTitle()
        rebuildMenu()
        refreshOverlayLayouts()
        showDesktopToast()
        if let screen = currentContextScreen(), layoutPanel?.isVisible == true {
            layoutPanelContextScreen = screen
            layoutPanel?.setCurrentLayout(ConfigStore.shared.layout(for: screen))
        }
    }

    private func showDesktopToast() {
        let activeDisplayIDs = Set(NSScreen.screens.map { LayoutContext.displayID(for: $0) })
        let staleDisplayIDs = desktopToastWindows.keys.filter { !activeDisplayIDs.contains($0) }
        for displayID in staleDisplayIDs {
            desktopToastWindows[displayID]?.hide()
            desktopToastWindows.removeValue(forKey: displayID)
        }

        for screen in NSScreen.screens {
            let displayID = LayoutContext.displayID(for: screen)
            let toast = desktopToastWindow(for: screen)
            guard !shouldSuppressDesktopToast(on: screen) else {
                toast.hide()
                continue
            }

            let rawSpaces = LayoutContext.spaces(on: screen)
            let effectiveCurrentSpaceID = effectiveCurrentSpaceID(in: rawSpaces)
            let titleName = ConfigStore.shared.desktopName(for: screen)
            let displayTitle = displayToastTitle(for: screen)
            let title = titleName?.isEmpty == false ? titleName! : "Desktop"
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

    private func shouldSuppressDesktopToast(on screen: NSScreen) -> Bool {
        let windows = WindowSnapper.getAllVisibleWindows(onScreen: screen)
        guard windows.count == 1,
              let rect = WindowSnapper.getWindowRect(windows[0].window)
        else { return false }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let screenArea = max(1, screenFrame.width * screenFrame.height)
        let visibleArea = max(1, visibleFrame.width * visibleFrame.height)
        let overlapWithScreen = rect.intersection(screenFrame)
        let overlapWithVisible = rect.intersection(visibleFrame)
        let screenCoverage = overlapWithScreen.width * overlapWithScreen.height / screenArea
        let visibleCoverage = overlapWithVisible.width * overlapWithVisible.height / visibleArea

        return screenCoverage > 0.9 || visibleCoverage > 0.94
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
        if let screen = window.screen {
            ConfigStore.shared.setToastPosition(window.frame.origin, for: screen)
        }
    }

    func desktopToastWindow(_ window: DesktopToastWindow, didCommitDesktopName name: String) {
        guard let screen = window.screen else { return }
        ConfigStore.shared.setDesktopName(name, for: screen)
        updateStatusBarTitle()
        rebuildMenu()
        showDesktopToast()
        debugLog("DESKTOP_NAME_INLINE: \(name)")
    }

    private func displayToastTitle(for screen: NSScreen) -> String {
        let index = NSScreen.screens.firstIndex(of: screen).map { $0 + 1 } ?? 1
        return "Display \(index)"
    }

}
