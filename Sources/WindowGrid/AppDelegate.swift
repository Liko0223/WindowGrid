import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, LayoutPanelDelegate {
    private var statusItem: NSStatusItem!
    private var overlayWindows: [NSScreen: OverlayWindow] = [:]
    private var currentLayout: GridLayout = .sixGrid
    private var layoutPanel: LayoutPanel?

    // Drag state
    private var isDragging = false
    private var isOptionHeld = false
    private var draggedWindow: AXUIElement?
    private var dragStartLocation: NSPoint = .zero
    private var dragSourceZoneIndex: Int = -1

    // Event monitors
    private var globalMouseDown: Any?
    private var globalMouseDragged: Any?
    private var globalMouseUp: Any?
    private var flagsChangedMonitor: Any?
    private var localFlagsMonitor: Any?

    private let dragThreshold: CGFloat = 8
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
        if !WindowSnapper.checkAccessibility() {
            showAccessibilityAlert()
            return
        }

        // Load config
        currentLayout = ConfigStore.shared.activeLayout

        setupStatusBar()
        setupEventMonitors()
        NSLog("WindowGrid: Started with layout \"\(currentLayout.name)\"")
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventMonitors()
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
        NSApp.terminate(nil)
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "WindowGrid")
            button.image?.size = NSSize(width: 18, height: 18)
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for layout in ConfigStore.shared.allLayouts {
            let item = NSMenuItem(title: layout.name, action: #selector(switchLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout
            item.state = layout.name == currentLayout.name ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let arrange = NSMenuItem(title: "Arrange All Windows", action: #selector(arrangeAllWindows), keyEquivalent: "A")
        arrange.target = self
        arrange.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(arrange)

        let preview = NSMenuItem(title: "Preview Grid", action: #selector(previewGrid), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)

        let editLayout = NSMenuItem(title: "Edit Layouts…", action: #selector(openLayoutPanel), keyEquivalent: "l")
        editLayout.target = self
        menu.addItem(editLayout)

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
        guard let layout = sender.representedObject as? GridLayout else { return }
        currentLayout = layout
        ConfigStore.shared.setActiveLayout(layout)

        for (_, overlay) in overlayWindows {
            overlay.updateLayout(layout)
        }
        rebuildMenu()
        NSLog("WindowGrid: Switched to \"\(layout.name)\"")
    }

    @objc private func arrangeAllWindows() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let zones = currentLayout.zoneRects(in: visibleFrame)
        let windows = WindowSnapper.getAllVisibleWindows(onScreen: screen)

        guard !windows.isEmpty && !zones.isEmpty else { return }

        // Assign windows to zones in MRU order
        for (index, win) in windows.enumerated() {
            if index < zones.count {
                WindowSnapper.snapWindow(win.window, to: zones[index].rect)
            } else {
                WindowSnapper.minimizeWindow(win.window)
            }
        }

        NSLog("WindowGrid: Arranged \(min(windows.count, zones.count)) windows, minimized \(max(0, windows.count - zones.count))")
    }

    @objc private func previewGrid() {
        showOverlays()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.hideOverlays()
        }
    }

    @objc private func saveCurrentScene() {
        guard let screen = NSScreen.main else { return }

        let assignments = WindowSnapper.captureArrangement(layout: currentLayout, onScreen: screen)
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

        let scene = WindowScene(name: name, layoutName: currentLayout.name, assignments: assignments)
        ConfigStore.shared.saveScene(scene)
        rebuildMenu()

        NSLog("WindowGrid: Saved scene \"\(name)\" with \(assignments.count) windows")
    }

    @objc private func restoreSceneFromMenu(_ sender: NSMenuItem) {
        guard let scene = sender.representedObject as? WindowScene,
              let screen = NSScreen.main else { return }

        // Switch to the scene's layout if different
        if let layout = ConfigStore.shared.allLayouts.first(where: { $0.name == scene.layoutName }) {
            currentLayout = layout
            ConfigStore.shared.setActiveLayout(layout)
            for (_, overlay) in overlayWindows { overlay.updateLayout(layout) }
        }

        WindowSnapper.restoreScene(scene, layout: currentLayout, onScreen: screen)
        rebuildMenu()
        NSLog("WindowGrid: Restored scene \"\(scene.name)\"")
    }

    @objc private func updateSceneFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let screen = NSScreen.main else { return }

        let assignments = WindowSnapper.captureArrangement(layout: currentLayout, onScreen: screen)
        guard !assignments.isEmpty else { return }

        let scene = WindowScene(name: name, layoutName: currentLayout.name, assignments: assignments)
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
        if layoutPanel == nil {
            layoutPanel = LayoutPanel(currentLayout: currentLayout)
            layoutPanel?.layoutDelegate = self
        }
        layoutPanel?.showPanel()
    }

    func layoutPanel(_ panel: LayoutPanel, didSelectLayout layout: GridLayout) {
        currentLayout = layout
        ConfigStore.shared.setActiveLayout(layout)
        for (_, overlay) in overlayWindows {
            overlay.updateLayout(layout)
        }
        rebuildMenu()
        NSLog("WindowGrid: Applied layout \"\(layout.name)\"")
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
        alert.informativeText = "Open-source window management for macOS.\n\nHold Option + drag any window to snap it to a grid zone.\n\nVersion 0.1.0"
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Event Monitoring

    private func setupEventMonitors() {
        // Track Option key via flags changed (global)
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
    }

    private func removeEventMonitors() {
        [globalMouseDown, globalMouseDragged, globalMouseUp, flagsChangedMonitor, localFlagsMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
    }

    // MARK: - Event Handlers

    private func handleFlagsChanged(_ event: NSEvent) {
        let optionPressed = event.modifierFlags.contains(.option)

        if optionPressed && !isOptionHeld {
            isOptionHeld = true
        } else if !optionPressed && isOptionHeld {
            isOptionHeld = false
            // Option released — if we were dragging, cancel the snap overlay
            if isDragging {
                isDragging = false
                draggedWindow = nil
                hideOverlays()
            }
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard isOptionHeld else { return }
        // Only record the start location. Don't touch windows yet.
        dragStartLocation = NSEvent.mouseLocation
        isDragging = false
        draggedWindow = nil
        dragSourceZoneIndex = -1
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard isOptionHeld else { return }

        let current = NSEvent.mouseLocation
        let distance = hypot(current.x - dragStartLocation.x, current.y - dragStartLocation.y)

        // First time crossing threshold: initialize drag state
        if !isDragging && distance > dragThreshold {
            // Get the window at the ORIGINAL mouseDown position
            draggedWindow = WindowSnapper.getWindowUnderCursor(at: dragStartLocation)
            guard draggedWindow != nil else { return }

            // Find which zone the drag started in
            for screen in NSScreen.screens {
                guard screen.frame.contains(dragStartLocation) else { continue }
                if let zone = currentLayout.zoneAt(point: dragStartLocation, in: screen.visibleFrame) {
                    dragSourceZoneIndex = zone.zone
                }
                break
            }

            isDragging = true

            // Undo macOS's Option+click "hide other apps" behavior
            for app in NSWorkspace.shared.runningApplications {
                if app.isHidden && app.activationPolicy == .regular {
                    app.unhide()
                }
            }

            showOverlays()
        }

        if isDragging {
            updateHighlight(at: current)
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard isDragging, let window = draggedWindow else {
            isDragging = false
            draggedWindow = nil
            return
        }

        let mouseLocation = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            guard screen.frame.contains(mouseLocation) else { continue }
            let visibleFrame = screen.visibleFrame
            let zones = currentLayout.zoneRects(in: visibleFrame)

            if let targetZone = currentLayout.zoneAt(point: mouseLocation, in: visibleFrame) {
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

    // MARK: - Overlay Management

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
            if overlayWindows[screen] == nil {
                overlayWindows[screen] = OverlayWindow(screen: screen, layout: currentLayout)
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
