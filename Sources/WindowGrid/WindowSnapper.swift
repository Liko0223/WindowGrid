import AppKit
import ApplicationServices

class WindowSnapper {

    /// Get the window under the cursor that is being dragged (title bar hit test)
    static func getWindowUnderCursor(at nsPoint: NSPoint? = nil) -> AXUIElement? {
        let mouseLocation = nsPoint ?? NSEvent.mouseLocation
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let cgPoint = CGPoint(x: mouseLocation.x, y: mainScreen.frame.height - mouseLocation.y)

        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windowInfoList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName != "WindowGrid"
            else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // Title bar region: top 40px of the window
            let titleBar = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 40)
            guard titleBar.contains(cgPoint) else { continue }

            let appRef = AXUIElementCreateApplication(pid)
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement]
            else { continue }

            for window in windows {
                var posRef: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
                guard let posRef = posRef else { continue }

                var pos = CGPoint.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)

                if abs(pos.x - bounds.origin.x) < 5 && abs(pos.y - bounds.origin.y) < 5 {
                    return window
                }
            }
            return windows.first
        }
        return nil
    }

    /// Move and resize a window to a target rect (NSRect, bottom-left origin)
    static func snapWindow(_ window: AXUIElement, to rect: NSRect) {
        // Find which screen this rect belongs to (use the screen whose frame contains the rect center)
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let cgY = primaryHeight - rect.origin.y - rect.height

        var position = CGPoint(x: rect.origin.x, y: cgY)
        var size = CGSize(width: rect.width, height: rect.height)

        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return }

        // Set position first, then size (some apps need this order)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        // Set position again in case size change shifted it
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
    }

    /// Get all visible windows in most-recently-used order (front to back).
    /// If `onScreen` is provided, only returns windows whose center is on that screen.
    static func getAllVisibleWindows(onScreen screen: NSScreen? = nil) -> [(window: AXUIElement, appName: String)] {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        // Convert screen frame to CG coordinates (top-left origin) for filtering
        let screenCGRect: CGRect? = {
            guard let screen = screen, let mainScreen = NSScreen.screens.first else { return nil }
            let f = screen.frame
            return CGRect(x: f.origin.x, y: mainScreen.frame.height - f.origin.y - f.height,
                          width: f.width, height: f.height)
        }()

        var result: [(window: AXUIElement, appName: String)] = []
        var seenPids: [Int32: [AXUIElement]] = [:]

        for info in windowInfoList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName != "WindowGrid",
                  ownerName != "Window Server",
                  ownerName != "Dock"
            else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // Filter by screen: check if window center is on the target screen
            if let screenRect = screenCGRect {
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                if !screenRect.contains(center) { continue }
            }

            // Skip tiny windows (toolbars, popups, etc.)
            guard bounds.width > 100 && bounds.height > 100 else { continue }

            // Get AX windows for this pid (cache per pid)
            if seenPids[pid] == nil {
                let appRef = AXUIElementCreateApplication(pid)
                var windowsRef: AnyObject?
                if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                   let windows = windowsRef as? [AXUIElement] {
                    seenPids[pid] = windows
                } else {
                    seenPids[pid] = []
                }
            }

            guard let axWindows = seenPids[pid] else { continue }

            // Match CG window to AX window by position
            for axWindow in axWindows {
                var posRef: AnyObject?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                guard let posRef = posRef else { continue }

                var pos = CGPoint.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)

                if abs(pos.x - bounds.origin.x) < 5 && abs(pos.y - bounds.origin.y) < 5 {
                    // Check not already minimized
                    var minimizedRef: AnyObject?
                    AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
                    if let minimized = minimizedRef as? Bool, minimized { continue }

                    // Avoid duplicates
                    let isDuplicate = result.contains { existing in
                        var existingPos: AnyObject?
                        AXUIElementCopyAttributeValue(existing.window, kAXPositionAttribute as CFString, &existingPos)
                        guard let ep = existingPos else { return false }
                        var ePoint = CGPoint.zero
                        AXValueGetValue(ep as! AXValue, .cgPoint, &ePoint)
                        return abs(ePoint.x - pos.x) < 3 && abs(ePoint.y - pos.y) < 3
                    }
                    if !isDuplicate {
                        result.append((window: axWindow, appName: ownerName))
                    }
                    break
                }
            }
        }
        return result
    }

    /// Get a window's current frame in CG coordinates (top-left origin), returned as NSRect (bottom-left origin)
    static func getWindowRect(_ window: AXUIElement) -> NSRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard let posRef = posRef, let sizeRef = sizeRef else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        guard let mainScreen = NSScreen.screens.first else { return nil }
        // Convert CG coords (top-left) to NSRect (bottom-left)
        let nsY = mainScreen.frame.height - pos.y - size.height
        return NSRect(x: pos.x, y: nsY, width: size.width, height: size.height)
    }

    /// Check if two AXUIElements refer to the same window
    static func isSameWindow(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        // Compare by PID + title + role (most reliable without CFEqual)
        var pidA: pid_t = 0, pidB: pid_t = 0
        AXUIElementGetPid(a, &pidA)
        AXUIElementGetPid(b, &pidB)
        if pidA != pidB { return false }

        var titleA: AnyObject?, titleB: AnyObject?
        AXUIElementCopyAttributeValue(a, kAXTitleAttribute as CFString, &titleA)
        AXUIElementCopyAttributeValue(b, kAXTitleAttribute as CFString, &titleB)
        let tA = titleA as? String ?? ""
        let tB = titleB as? String ?? ""
        return tA == tB
    }

    /// Find the window occupying a given zone rect on screen (excluding a specific window)
    static func findWindow(in targetRect: NSRect, excluding: AXUIElement?, onScreen screen: NSScreen) -> AXUIElement? {
        let allWindows = getAllVisibleWindows(onScreen: screen)

        for win in allWindows {
            // Skip the excluded window
            if let excluding = excluding, isSameWindow(win.window, excluding) {
                continue
            }

            guard let winRect = getWindowRect(win.window) else { continue }

            // Check if window overlaps significantly with the target zone
            let intersection = winRect.intersection(targetRect)
            let overlapArea = intersection.width * intersection.height
            let winArea = winRect.width * winRect.height
            // Window overlaps at least 30% with the target zone
            if winArea > 0 && overlapArea / winArea > 0.3 {
                return win.window
            }
        }
        return nil
    }

    /// Get all AX windows directly (bypasses CG window matching, more reliable after snapping)
    static func getAllAXWindows(onScreen screen: NSScreen? = nil) -> [(window: AXUIElement, appName: String)] {
        var result: [(window: AXUIElement, appName: String)] = []
        let screenFrame = screen?.frame

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let appName = app.localizedName ?? ""
            guard appName != "WindowGrid" else { continue }

            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                // Skip minimized windows
                var minimizedRef: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
                if let minimized = minimizedRef as? Bool, minimized { continue }

                // Skip windows that aren't standard (must have AXWindow role)
                var roleRef: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
                guard (roleRef as? String) == "AXWindow" else { continue }

                // Skip windows without a title (often system/background windows)
                var titleRef: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""
                guard !title.isEmpty else { continue }

                // Get position and size
                guard let rect = getWindowRect(window) else { continue }
                guard rect.width > 50 && rect.height > 50 else { continue }

                // Filter by screen if specified
                if let screenFrame = screenFrame {
                    let center = NSPoint(x: rect.midX, y: rect.midY)
                    if !screenFrame.contains(center) { continue }
                }

                result.append((window: window, appName: appName))
            }
        }
        return result
    }

    /// Raise a window to the front
    static func raiseWindow(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXFrontmostAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Minimize a window
    static func minimizeWindow(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
    }

    /// Capture current window arrangement as zone assignments
    static func captureArrangement(layout: GridLayout, onScreen screen: NSScreen) -> [ZoneAssignment] {
        let windows = getAllVisibleWindows(onScreen: screen)
        let zones = layout.zoneRects(in: screen.visibleFrame)
        var assignments: [ZoneAssignment] = []

        for win in windows {
            guard let rect = getWindowRect(win.window) else { continue }
            let center = NSPoint(x: rect.midX, y: rect.midY)

            for z in zones {
                if z.rect.contains(center) {
                    let bundleID = bundleIDForWindow(win.window) ?? ""
                    if !bundleID.isEmpty {
                        var url: String? = nil
                        var allTabs: [String]? = nil
                        if isBrowser(bundleID) {
                            if let info = getBrowserWindowInfo(bundleID: bundleID, window: win.window) {
                                url = info.activeURL
                                allTabs = info.allTabURLs
                            }
                        }

                        assignments.append(ZoneAssignment(
                            zoneIndex: z.zone,
                            appBundleID: bundleID,
                            appName: win.appName,
                            windowURL: url,
                            allTabURLs: allTabs
                        ))
                    }
                    break
                }
            }
        }
        return assignments
    }

    /// Unminimize a window
    static func unminimizeWindow(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
    }

    /// Get all windows for a given bundle ID (including minimized), across all screens
    private static func findAllWindowsForBundleID(_ bundleID: String) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.bundleIdentifier == bundleID else { continue }
            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: AnyObject?
            if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                result.append(contentsOf: windows)
            }
        }
        return result
    }

    /// Restore a saved scene
    static func restoreScene(_ scene: WindowScene, layout: GridLayout, onScreen screen: NSScreen) {
        let zones = layout.zoneRects(in: screen.visibleFrame)
        let allWindowsOnScreen = getAllVisibleWindows(onScreen: screen)

        // Collect all available windows per bundle ID (including minimized)
        var availableWindows: [String: [AXUIElement]] = [:]
        for assignment in scene.assignments {
            let bid = assignment.appBundleID
            if availableWindows[bid] == nil {
                availableWindows[bid] = findAllWindowsForBundleID(bid)
            }
        }

        NSLog("WindowGrid: Restoring scene \"\(scene.name)\" with \(scene.assignments.count) assignments")
        for (bid, windows) in availableWindows {
            NSLog("WindowGrid:   \(bid): \(windows.count) windows available")
        }

        // Track which assignments got a window, and which AX windows have been used (by array index)
        var assignedIndices: Set<Int> = []
        var usedWindowIndices: [String: Set<Int>] = [:]  // bundleID -> set of used indices

        // First pass: assign existing windows to zones
        for (i, assignment) in scene.assignments.enumerated() {
            guard assignment.zoneIndex < zones.count else { continue }
            let targetRect = zones[assignment.zoneIndex].rect
            let bundleID = assignment.appBundleID

            let candidates = availableWindows[bundleID] ?? []
            let usedIndices = usedWindowIndices[bundleID] ?? []

            // Find the first candidate not yet used (by index, simple and reliable)
            if let idx = candidates.indices.first(where: { !usedIndices.contains($0) }) {
                let window = candidates[idx]
                unminimizeWindow(window)
                usleep(50_000)
                snapWindow(window, to: targetRect)
                usedWindowIndices[bundleID, default: []].insert(idx)
                assignedIndices.insert(i)
                NSLog("WindowGrid:   zone\(assignment.zoneIndex) ← \(assignment.appName) (existing window #\(idx))")
            }
        }

        // Second pass: only open new windows for assignments that didn't get one
        let unassigned = scene.assignments.enumerated().filter { !assignedIndices.contains($0.offset) }
        NSLog("WindowGrid:   \(unassigned.count) assignments need new windows")

        for (_, assignment) in unassigned {
            let bundleID = assignment.appBundleID
            let zoneIndex = assignment.zoneIndex
            guard zoneIndex < zones.count else { continue }
            let existingCount = findAllWindowsForBundleID(bundleID).count

            if isBrowser(bundleID) {
                openBrowserWithTabs(bundleID: bundleID, assignment: assignment)
            } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let openConfig = NSWorkspace.OpenConfiguration()
                openConfig.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: openConfig, completionHandler: nil)
            }

            snapNewWindow(bundleID: bundleID, to: zones[zoneIndex].rect, existingCount: existingCount)
        }

        // Minimize windows on this screen that aren't part of the scene
        let assignedBundleIDs = Set(scene.assignments.map { $0.appBundleID })
        for win in allWindowsOnScreen {
            let bid = bundleIDForWindow(win.window) ?? ""
            if !assignedBundleIDs.contains(bid) {
                minimizeWindow(win.window)
            }
        }
    }

    /// Get the bundle ID for a window's owning application
    private static func bundleIDForWindow(_ window: AXUIElement) -> String? {
        var pidValue: pid_t = 0
        AXUIElementGetPid(window, &pidValue)
        return NSRunningApplication(processIdentifier: pidValue)?.bundleIdentifier
    }

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser",
        "com.operasoftware.Opera", "com.opera.operaGX",
        "com.vivaldi.Vivaldi",
        "com.tabbit-ai.Tabbit",
        "ru.nicze.nicze",  // Zen Browser
        "org.chromium.Chromium",
        "com.nickvision.nickvision.nicegui",  // Nicegui
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    struct BrowserWindowInfo {
        let position: CGPoint
        let activeURL: String
        let allTabURLs: [String]
    }

    /// Get all browser window info (position, active URL, all tab URLs)
    static func getAllBrowserWindowInfo(bundleID: String) -> [BrowserWindowInfo] {
        let isSafari = bundleID == "com.apple.Safari"
        let activeTabProp = isSafari ? "URL of current tab of w" : "URL of active tab of w"
        let tabsProp = isSafari ? "tabs of w" : "tabs of w"

        // Use bounds (not position) — Chrome doesn't support "position of window"
        // Output format per window: "x,y;activeURL;tab1URL|tab2URL|..."  separated by newlines
        let script = """
            tell application id "\(bundleID)"
                set resultStr to ""
                set windowCount to count of windows
                repeat with i from 1 to windowCount
                    try
                        set w to window i
                        set b to bounds of w
                        set x to item 1 of b
                        set y to item 2 of b
                        set activeURL to \(activeTabProp)
                        set tabCount to count of \(tabsProp)
                        set tabURLs to ""
                        repeat with j from 1 to tabCount
                            if j > 1 then set tabURLs to tabURLs & "|"
                            set tabURLs to tabURLs & (URL of tab j of w)
                        end repeat
                        set resultStr to resultStr & (x as text) & "," & (y as text) & ";" & activeURL & ";" & tabURLs & (ASCII character 10)
                    end try
                end repeat
                return resultStr
            end tell
            """

        var results: [BrowserWindowInfo] = []

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("WindowGrid: AppleScript error for \(bundleID): \(error)")
            }
            if error == nil, let output = result.stringValue {
                let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    let parts = line.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count >= 2 else { continue }

                    let posParts = parts[0].split(separator: ",")
                    guard posParts.count == 2,
                          let x = Double(posParts[0]),
                          let y = Double(posParts[1]) else { continue }

                    let activeURL = String(parts[1])
                    let allTabs: [String] = parts.count >= 3
                        ? String(parts[2]).split(separator: "|").map(String.init)
                        : [activeURL]

                    results.append(BrowserWindowInfo(
                        position: CGPoint(x: x, y: y),
                        activeURL: activeURL,
                        allTabURLs: allTabs.filter { !$0.isEmpty }
                    ))
                }
            }
        }

        // Accessibility fallback
        if results.isEmpty {
            let windows = findAllWindowsForBundleID(bundleID)
            for (idx, win) in windows.enumerated() {
                if let url = getBrowserURLViaAccessibility(bundleID: bundleID, windowIndex: idx) {
                    var posRef: AnyObject?
                    AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
                    if let posRef = posRef {
                        var pos = CGPoint.zero
                        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                        results.append(BrowserWindowInfo(position: pos, activeURL: url, allTabURLs: [url]))
                    }
                }
            }
        }

        NSLog("WindowGrid: Got \(results.count) windows for \(bundleID)")
        return results
    }

    /// Get info for a specific browser window by matching its AX position
    static func getBrowserWindowInfo(bundleID: String, window: AXUIElement) -> BrowserWindowInfo? {
        var posRef: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        guard let posRef = posRef else { return nil }
        var windowPos = CGPoint.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &windowPos)

        let allInfo = getAllBrowserWindowInfo(bundleID: bundleID)
        for info in allInfo {
            if abs(info.position.x - windowPos.x) < 10 && abs(info.position.y - windowPos.y) < 10 {
                return info
            }
        }
        return nil
    }

    /// Fallback: read URL from browser address bar using Accessibility API
    private static func getBrowserURLViaAccessibility(bundleID: String, windowIndex: Int) -> String? {
        for app in NSWorkspace.shared.runningApplications {
            guard app.bundleIdentifier == bundleID else { continue }
            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement],
                  windowIndex < windows.count
            else { continue }

            let window = windows[windowIndex]
            // Try to find AXTextField or AXWebArea with URL value
            if let url = findURLInElement(window) {
                return url
            }
        }
        return nil
    }

    /// Recursively search for a URL-like value in AX element tree (limited depth)
    private static func findURLInElement(_ element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Check text fields (address bar)
        if role == "AXTextField" || role == "AXComboBox" {
            var valueRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let value = valueRef as? String,
               (value.hasPrefix("http://") || value.hasPrefix("https://") || value.contains(".")) {
                let url = value.hasPrefix("http") ? value : "https://\(value)"
                return url
            }
        }

        // Recurse into children
        var childrenRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(20) {
                if let url = findURLInElement(child, depth: depth + 1) {
                    return url
                }
            }
        }
        return nil
    }

    /// Open browser with all saved tabs in a new window
    static func openBrowserWithTabs(bundleID: String, assignment: ZoneAssignment) {
        let appName = appNameForBundleID(bundleID)
        guard let appName = appName else { return }

        let tabs = assignment.allTabURLs ?? []
        let firstURL = tabs.first ?? assignment.windowURL

        if tabs.count <= 1 {
            // Single tab or no tabs — just open the URL in a new window
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            if bundleID == "com.apple.Safari" {
                if let url = firstURL, !url.isEmpty {
                    process.arguments = ["-na", appName, url]
                } else {
                    process.arguments = ["-a", appName]
                }
            } else {
                if let url = firstURL, !url.isEmpty {
                    process.arguments = ["-na", appName, "--args", "--new-window", url]
                } else {
                    process.arguments = ["-na", appName, "--args", "--new-window"]
                }
            }
            try? process.run()
        } else {
            // Multiple tabs — open first URL in new window, then add remaining tabs
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            if bundleID == "com.apple.Safari" {
                process.arguments = ["-na", appName, tabs[0]]
            } else {
                process.arguments = ["-na", appName, "--args", "--new-window", tabs[0]]
            }
            try? process.run()

            // After a short delay, open remaining URLs in the same window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for tabURL in tabs.dropFirst() {
                    if bundleID == "com.apple.Safari" {
                        let script = """
                            tell application id "\(bundleID)"
                                tell front window
                                    set newTab to make new tab
                                    set URL of newTab to "\(tabURL)"
                                end tell
                            end tell
                            """
                        if let s = NSAppleScript(source: script) {
                            var err: NSDictionary?
                            s.executeAndReturnError(&err)
                        }
                    } else {
                        let script = """
                            tell application id "\(bundleID)"
                                tell front window
                                    set newTab to make new tab
                                    set URL of newTab to "\(tabURL)"
                                end tell
                            end tell
                            """
                        if let s = NSAppleScript(source: script) {
                            var err: NSDictionary?
                            s.executeAndReturnError(&err)
                        }
                    }
                }
            }
        }
    }

    private static func appNameForBundleID(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent
    }

    /// Snap a newly created window for a bundle ID, waiting for it to appear
    static func snapNewWindow(bundleID: String, to rect: NSRect, existingCount: Int) {
        // Poll for up to 5 seconds for a new window to appear
        var attempts = 0
        func check() {
            attempts += 1
            let windows = findAllWindowsForBundleID(bundleID)
            if windows.count > existingCount {
                // New window appeared — snap the last one
                if let newWindow = windows.last {
                    snapWindow(newWindow, to: rect)
                }
            } else if attempts < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { check() }
    }

    /// Check and prompt for accessibility permission
    static func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
