import AppKit
import Carbon.HIToolbox
import Darwin

enum ActivationModifierKey: String, Codable, CaseIterable {
    case control
    case command
    case shift
    case option

    var displayName: String {
        switch self {
        case .option: return L10n.text("Option", "Option")
        case .control: return L10n.text("Control", "Control")
        case .command: return L10n.text("Command", "Command")
        case .shift: return L10n.text("Shift", "Shift")
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        case .shift: return "⇧"
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
        }
    }

    func isPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask).contains(modifierFlag) || isPressedInCurrentSession
    }

    private var isPressedInCurrentSession: Bool {
        switch self {
        case .option:
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Option))
                || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightOption))
        case .control:
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Control))
                || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightControl))
        case .command:
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Command))
                || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightCommand))
        case .shift:
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Shift))
                || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightShift))
        }
    }

    static func normalized(_ rawValue: String) -> ActivationModifierKey {
        ActivationModifierKey(rawValue: rawValue.lowercased()) ?? .control
    }
}

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyEquivalent: String

    var displayName: String {
        "\(modifierSymbols)\(keyEquivalent.uppercased())"
    }

    var modifierSymbols: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        return mask
    }

    var menuKeyEquivalent: String {
        switch keyEquivalent {
        case "space": return " "
        case "tab": return "\t"
        case "delete": return "\u{7F}"
        default: return keyEquivalent.lowercased()
        }
    }

    var hasUsableModifier: Bool {
        carbonModifiers & UInt32(controlKey | optionKey | shiftKey | cmdKey) != 0
    }

    static let defaultArrange = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(controlKey | cmdKey),
        keyEquivalent: "a"
    )

    static let defaultNewBrowser = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        carbonModifiers: UInt32(controlKey | optionKey),
        keyEquivalent: "n"
    )

    static let arrangePresets: [KeyboardShortcut] = [
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | cmdKey), keyEquivalent: "a"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(controlKey | cmdKey), keyEquivalent: "g"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey), keyEquivalent: "a"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(controlKey | optionKey), keyEquivalent: "g"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | shiftKey), keyEquivalent: "a"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(controlKey | shiftKey), keyEquivalent: "g"),
    ]

    static let newBrowserPresets: [KeyboardShortcut] = [
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(controlKey | optionKey), keyEquivalent: "n"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(controlKey | optionKey), keyEquivalent: "b"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(controlKey | cmdKey), keyEquivalent: "n"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(controlKey | cmdKey), keyEquivalent: "b"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(controlKey | shiftKey), keyEquivalent: "n"),
        KeyboardShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(controlKey | shiftKey), keyEquivalent: "b"),
    ]

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if normalized.contains(.control) { modifiers |= UInt32(controlKey) }
        if normalized.contains(.option) { modifiers |= UInt32(optionKey) }
        if normalized.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if normalized.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }
}

struct ToastPosition: Codable {
    let x: CGFloat
    let y: CGFloat

    var point: NSPoint {
        NSPoint(x: x, y: y)
    }

    init(point: NSPoint) {
        self.x = point.x
        self.y = point.y
    }
}

struct LayoutContext {
    let displayID: UInt32
    let spaceID: Int?

    var key: String {
        if let spaceID = spaceID {
            return "display:\(displayID)|space:\(spaceID)"
        }
        return displayKey
    }

    var displayKey: String {
        "display:\(displayID)"
    }

    var label: String {
        if let spaceID = spaceID {
            return L10n.text("Display \(displayID), Desktop \(spaceID)", "显示器 \(displayID)，桌面 \(spaceID)")
        }
        return L10n.text("Display \(displayID)", "显示器 \(displayID)")
    }

    static func current(for screen: NSScreen) -> LayoutContext {
        LayoutContext(
            displayID: displayID(for: screen),
            spaceID: currentSpaceID(on: screen)
        )
    }

    static func spaces(on screen: NSScreen) -> [DesktopSpace] {
        guard let displaySpaces = managedDisplaySpaces() else { return [] }

        let displayID = displayID(for: screen)
        let displayUUID = displayUUIDString(for: displayID)
        let current = current(for: screen)
        let displaySpace = matchingDisplaySpace(
            in: displaySpaces,
            for: screen,
            displayUUID: displayUUID
        )

        guard let spaces = displaySpace?["Spaces"] as? [[String: Any]] else { return [] }
        let displayIdentifier = displaySpace?["Display Identifier"] as? String
            ?? displayUUID
            ?? "Main"
        let desktopUUIDsOnDisplay = Set(
            spaces.compactMap { space -> String? in
                guard number(from: space["type"])?.intValue == 0 else { return nil }
                return spaceUUID(from: space)
            }
        )

        var desktopIndex = 0
        var result: [DesktopSpace] = []

        for (index, space) in spaces.enumerated() {
            let type = number(from: space["type"])?.intValue ?? 0
            guard type == 0 || type == 4,
                  let spaceID = spaceID(from: space)
            else { continue }

            if type == 4, !fullscreenSpaceBelongsToDisplay(space, desktopUUIDsOnDisplay: desktopUUIDsOnDisplay) {
                continue
            }

            if type == 0 {
                desktopIndex += 1
            }

            result.append(DesktopSpace(
                displayID: displayID,
                displayIdentifier: displayIdentifier,
                spaceID: spaceID,
                index: index + 1,
                desktopIndex: type == 0 ? desktopIndex : nil,
                type: type,
                title: spaceTitle(from: space),
                isCurrent: spaceID == current.spaceID
            ))
        }

        return result
    }

    static func switchToSpace(_ space: DesktopSpace) -> Bool {
        typealias MainConnectionID = @convention(c) () -> Int
        typealias ManagedDisplaySetCurrentSpace = @convention(c) (Int, CFString, UInt64) -> Int32

        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
            return false
        }
        defer { dlclose(handle) }

        guard let mainConnectionSymbol = dlsym(handle, "CGSMainConnectionID"),
              let setCurrentSpaceSymbol = dlsym(handle, "CGSManagedDisplaySetCurrentSpace")
        else {
            return false
        }

        let mainConnection = unsafeBitCast(mainConnectionSymbol, to: MainConnectionID.self)
        let setCurrentSpace = unsafeBitCast(setCurrentSpaceSymbol, to: ManagedDisplaySetCurrentSpace.self)
        return setCurrentSpace(mainConnection(), space.displayIdentifier as CFString, UInt64(space.spaceID)) == 0
    }

    static func displayID(for screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.uint32Value
        }
        let index = NSScreen.screens.firstIndex { $0 == screen } ?? 0
        return UInt32(index)
    }

    private static func currentSpaceID(on screen: NSScreen) -> Int? {
        if let spaceID = currentSpaceIDFromManagedDisplaySpaces(on: screen) {
            return spaceID
        }

        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        func screenFrameInCGCoordinates(_ screen: NSScreen) -> CGRect? {
            guard let mainScreen = NSScreen.screens.first else { return nil }
            let frame = screen.frame
            return CGRect(
                x: frame.origin.x,
                y: mainScreen.frame.height - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
        }

        guard let screenRect = screenFrameInCGCoordinates(screen) else { return nil }

        func number(_ dict: [String: Any], _ key: String) -> CGFloat? {
            if let value = dict[key] as? CGFloat { return value }
            if let value = dict[key] as? NSNumber { return CGFloat(value.doubleValue) }
            return nil
        }

        func workspaceID(from info: [String: Any]) -> Int? {
            if let number = info["kCGWindowWorkspace"] as? NSNumber { return number.intValue }
            if let intValue = info["kCGWindowWorkspace"] as? Int { return intValue }
            return nil
        }

        func matchingWorkspace(preferNormalWindows: Bool) -> Int? {
            for info in windowInfoList {
                if preferNormalWindows {
                    guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
                }
                guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                      let x = number(bounds, "X"),
                      let y = number(bounds, "Y"),
                      let width = number(bounds, "Width"),
                      let height = number(bounds, "Height"),
                      width > 1,
                      height > 1,
                      let workspace = workspaceID(from: info)
                else { continue }

                let center = CGPoint(x: x + width / 2, y: y + height / 2)
                if screenRect.contains(center) {
                    return workspace
                }
            }
            return nil
        }

        return matchingWorkspace(preferNormalWindows: true)
            ?? matchingWorkspace(preferNormalWindows: false)
    }

    private static func currentSpaceIDFromManagedDisplaySpaces(on screen: NSScreen) -> Int? {
        guard let displaySpaces = managedDisplaySpaces() else { return nil }

        let displayID = displayID(for: screen)
        let displayUUID = displayUUIDString(for: displayID)

        func spaceID(from displaySpace: [String: Any]) -> Int? {
            guard let currentSpace = displaySpace["Current Space"] as? [String: Any] else { return nil }
            if let number = currentSpace["id64"] as? NSNumber { return number.intValue }
            if let intValue = currentSpace["id64"] as? Int { return intValue }
            if let number = currentSpace["id"] as? NSNumber { return number.intValue }
            if let intValue = currentSpace["id"] as? Int { return intValue }
            return nil
        }

        if let displayUUID = displayUUID {
            for displaySpace in displaySpaces {
                if displaySpace["Display Identifier"] as? String == displayUUID {
                    return spaceID(from: displaySpace)
                }
            }
        }

        if screen == NSScreen.main {
            for displaySpace in displaySpaces {
                if displaySpace["Display Identifier"] as? String == "Main" {
                    return spaceID(from: displaySpace)
                }
            }
        }

        if let index = NSScreen.screens.firstIndex(of: screen), index < displaySpaces.count {
            return spaceID(from: displaySpaces[index])
        }

        return nil
    }

    private static func managedDisplaySpaces() -> [[String: Any]]? {
        typealias MainConnectionID = @convention(c) () -> Int
        typealias CopyManagedDisplaySpaces = @convention(c) (Int) -> Unmanaged<CFArray>?

        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }

        guard let mainConnectionSymbol = dlsym(handle, "CGSMainConnectionID"),
              let copySpacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces")
        else {
            return nil
        }

        let mainConnection = unsafeBitCast(mainConnectionSymbol, to: MainConnectionID.self)
        let copyManagedDisplaySpaces = unsafeBitCast(copySpacesSymbol, to: CopyManagedDisplaySpaces.self)

        guard let unmanagedSpaces = copyManagedDisplaySpaces(mainConnection()) else { return nil }
        return unmanagedSpaces.takeRetainedValue() as? [[String: Any]]
    }

    private static func matchingDisplaySpace(
        in displaySpaces: [[String: Any]],
        for screen: NSScreen,
        displayUUID: String?
    ) -> [String: Any]? {
        if let displayUUID = displayUUID {
            for displaySpace in displaySpaces where displaySpace["Display Identifier"] as? String == displayUUID {
                return displaySpace
            }
        }

        if screen == NSScreen.main {
            for displaySpace in displaySpaces where displaySpace["Display Identifier"] as? String == "Main" {
                return displaySpace
            }
        }

        if let index = NSScreen.screens.firstIndex(of: screen), index < displaySpaces.count {
            return displaySpaces[index]
        }

        return nil
    }

    private static func spaceID(from space: [String: Any]) -> Int? {
        if let number = space["id64"] as? NSNumber { return number.intValue }
        if let intValue = space["id64"] as? Int { return intValue }
        if let number = space["id"] as? NSNumber { return number.intValue }
        if let intValue = space["id"] as? Int { return intValue }
        if let number = space["ManagedSpaceID"] as? NSNumber { return number.intValue }
        if let intValue = space["ManagedSpaceID"] as? Int { return intValue }
        return nil
    }

    private static func spaceUUID(from space: [String: Any]) -> String? {
        if let uuid = space["uuid"] as? String, !uuid.isEmpty { return uuid }
        return nil
    }

    private static func fullscreenSpaceBelongsToDisplay(
        _ space: [String: Any],
        desktopUUIDsOnDisplay: Set<String>
    ) -> Bool {
        guard let fromSpace = fullscreenSourceSpaceUUID(from: space) else {
            return true
        }
        return desktopUUIDsOnDisplay.contains(fromSpace)
    }

    private static func fullscreenSourceSpaceUUID(from space: [String: Any]) -> String? {
        if let fromSpace = space["fromSpace"] as? String, !fromSpace.isEmpty {
            return fromSpace
        }
        guard let tileLayout = space["TileLayoutManager"] as? [String: Any],
              let tileSpaces = tileLayout["TileSpaces"] as? [[String: Any]]
        else {
            return nil
        }

        for tileSpace in tileSpaces {
            if let fromSpace = tileSpace["fromSpace"] as? String, !fromSpace.isEmpty {
                return fromSpace
            }
        }
        return nil
    }

    private static func spaceTitle(from space: [String: Any]) -> String? {
        if let name = space["name"] as? String, !name.isEmpty { return name }
        if let appName = space["appName"] as? String, !appName.isEmpty { return appName }
        guard let tileLayout = space["TileLayoutManager"] as? [String: Any],
              let tileSpaces = tileLayout["TileSpaces"] as? [[String: Any]]
        else {
            return nil
        }

        for tileSpace in tileSpaces {
            if let appName = tileSpace["appName"] as? String, !appName.isEmpty {
                return appName
            }
            if let name = tileSpace["name"] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func number(from value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let intValue = value as? Int { return NSNumber(value: intValue) }
        return nil
    }

    static func displayUUIDString(for displayID: UInt32) -> String? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = unmanagedUUID.takeRetainedValue()
        guard let uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return nil }
        return uuidString as String
    }
}

struct DesktopSpace: Hashable {
    let displayID: UInt32
    let displayIdentifier: String
    let spaceID: Int
    let index: Int
    let desktopIndex: Int?
    let type: Int
    let title: String?
    let isCurrent: Bool

    var isFullscreenSpace: Bool {
        type == 4
    }

    var contextKey: String {
        "display:\(displayID)|space:\(spaceID)"
    }

    var displayKey: String {
        "display:\(displayID)"
    }

    func withCurrent(_ isCurrent: Bool) -> DesktopSpace {
        DesktopSpace(
            displayID: displayID,
            displayIdentifier: displayIdentifier,
            spaceID: spaceID,
            index: index,
            desktopIndex: desktopIndex,
            type: type,
            title: title,
            isCurrent: isCurrent
        )
    }
}

struct BrowserChoice: Equatable {
    let name: String
    let bundleID: String

    static let defaultBundleID = "com.google.Chrome"

    static let all: [BrowserChoice] = [
        BrowserChoice(name: "Chrome", bundleID: "com.google.Chrome"),
        BrowserChoice(name: "Tabbit", bundleID: "com.tabbit-ai.Tabbit"),
        BrowserChoice(name: "Safari", bundleID: "com.apple.Safari"),
        BrowserChoice(name: "Edge", bundleID: "com.microsoft.edgemac"),
        BrowserChoice(name: "Brave", bundleID: "com.brave.Browser"),
        BrowserChoice(name: "Arc", bundleID: "company.thebrowser.Browser"),
        BrowserChoice(name: "Firefox", bundleID: "org.mozilla.firefox"),
        BrowserChoice(name: "Chromium", bundleID: "org.chromium.Chromium")
    ]

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func name(for bundleID: String) -> String {
        all.first(where: { $0.bundleID == bundleID })?.name ?? bundleID
    }
}

struct AppConfig: Codable {
    var activeLayoutName: String
    var layouts: [GridLayout]
    var modifierKey: String
    var arrangeShortcut: KeyboardShortcut?
    var newBrowserShortcut: KeyboardShortcut?
    var newBrowserBundleID: String
    var adaptiveArrangeEnabled: Bool
    var liveAdaptiveGridEnabled: Bool
    var layoutAssignments: [String: String]
    var desktopNames: [String: String]
    var toastPosition: ToastPosition?
    var toastPositions: [String: ToastPosition]
    var scenes: [WindowScene]

    init(
        activeLayoutName: String,
        layouts: [GridLayout],
        modifierKey: String,
        arrangeShortcut: KeyboardShortcut? = .defaultArrange,
        newBrowserShortcut: KeyboardShortcut? = .defaultNewBrowser,
        newBrowserBundleID: String = BrowserChoice.defaultBundleID,
        adaptiveArrangeEnabled: Bool = true,
        liveAdaptiveGridEnabled: Bool = false,
        layoutAssignments: [String: String] = [:],
        desktopNames: [String: String] = [:],
        toastPosition: ToastPosition? = nil,
        toastPositions: [String: ToastPosition] = [:],
        scenes: [WindowScene] = []
    ) {
        self.activeLayoutName = activeLayoutName
        self.layouts = layouts
        self.modifierKey = modifierKey
        self.arrangeShortcut = arrangeShortcut
        self.newBrowserShortcut = newBrowserShortcut
        self.newBrowserBundleID = newBrowserBundleID
        self.adaptiveArrangeEnabled = adaptiveArrangeEnabled
        self.liveAdaptiveGridEnabled = liveAdaptiveGridEnabled
        self.layoutAssignments = layoutAssignments
        self.desktopNames = desktopNames
        self.toastPosition = toastPosition
        self.toastPositions = toastPositions
        self.scenes = scenes
    }

    static let `default` = AppConfig(
        activeLayoutName: GridLayout.sixGrid.name,
        layouts: GridLayout.allPresets,
        modifierKey: "control"
    )

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeLayoutName = try container.decode(String.self, forKey: .activeLayoutName)
        layouts = try container.decode([GridLayout].self, forKey: .layouts)
        modifierKey = try container.decodeIfPresent(String.self, forKey: .modifierKey) ?? "control"
        arrangeShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .arrangeShortcut) ?? .defaultArrange
        newBrowserShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .newBrowserShortcut) ?? .defaultNewBrowser
        newBrowserBundleID = try container.decodeIfPresent(String.self, forKey: .newBrowserBundleID) ?? BrowserChoice.defaultBundleID
        adaptiveArrangeEnabled = try container.decodeIfPresent(Bool.self, forKey: .adaptiveArrangeEnabled) ?? true
        liveAdaptiveGridEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveAdaptiveGridEnabled) ?? false
        layoutAssignments = try container.decodeIfPresent([String: String].self, forKey: .layoutAssignments) ?? [:]
        desktopNames = try container.decodeIfPresent([String: String].self, forKey: .desktopNames) ?? [:]
        toastPosition = try container.decodeIfPresent(ToastPosition.self, forKey: .toastPosition)
        toastPositions = try container.decodeIfPresent([String: ToastPosition].self, forKey: .toastPositions) ?? [:]
        scenes = try container.decodeIfPresent([WindowScene].self, forKey: .scenes) ?? []
    }
}

class ConfigStore {
    static let shared = ConfigStore()

    private let configDir: URL
    private let configFile: URL
    private(set) var config: AppConfig

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configDir = home.appendingPathComponent(".config/windowgrid")
        configFile = configDir.appendingPathComponent("config.json")
        config = AppConfig.default
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            save()
            return
        }
        do {
            let data = try Data(contentsOf: configFile)
            config = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            NSLog("WindowGrid: Failed to load config: \(error). Using defaults.")
            config = AppConfig.default
            save()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: configFile)
        } catch {
            NSLog("WindowGrid: Failed to save config: \(error)")
        }
    }

    var activeLayout: GridLayout {
        config.layouts.first { $0.name == config.activeLayoutName } ?? GridLayout.sixGrid
    }

    var activationModifierKey: ActivationModifierKey {
        ActivationModifierKey.normalized(config.modifierKey)
    }

    func setActivationModifierKey(_ modifierKey: ActivationModifierKey) {
        config.modifierKey = modifierKey.rawValue
        save()
    }

    var arrangeShortcut: KeyboardShortcut? {
        config.arrangeShortcut
    }

    func setArrangeShortcut(_ shortcut: KeyboardShortcut?) {
        config.arrangeShortcut = shortcut
        save()
    }

    var newBrowserShortcut: KeyboardShortcut? {
        config.newBrowserShortcut
    }

    func setNewBrowserShortcut(_ shortcut: KeyboardShortcut?) {
        config.newBrowserShortcut = shortcut
        save()
    }

    var newBrowserBundleID: String {
        config.newBrowserBundleID
    }

    func setNewBrowserBundleID(_ bundleID: String) {
        config.newBrowserBundleID = bundleID
        save()
    }

    var adaptiveArrangeEnabled: Bool {
        config.adaptiveArrangeEnabled
    }

    func setAdaptiveArrangeEnabled(_ enabled: Bool) {
        config.adaptiveArrangeEnabled = enabled
        save()
    }

    var liveAdaptiveGridEnabled: Bool {
        config.liveAdaptiveGridEnabled
    }

    func setLiveAdaptiveGridEnabled(_ enabled: Bool) {
        config.liveAdaptiveGridEnabled = enabled
        save()
    }

    func setActiveLayout(_ layout: GridLayout) {
        upsertLayout(layout)
        config.activeLayoutName = layout.name
        save()
    }

    func saveLayout(_ layout: GridLayout) {
        upsertLayout(layout)
        save()
    }

    func layout(for screen: NSScreen) -> GridLayout {
        let context = LayoutContext.current(for: screen)
        let layoutName = config.layoutAssignments[context.key]
            ?? config.layoutAssignments[context.displayKey]
            ?? config.activeLayoutName
        return config.layouts.first { $0.name == layoutName } ?? activeLayout
    }

    func setLayout(_ layout: GridLayout, for screen: NSScreen) {
        upsertLayout(layout)
        let context = LayoutContext.current(for: screen)
        config.layoutAssignments[context.key] = layout.name
        save()
    }

    func clearLayoutOverride(for screen: NSScreen) {
        let context = LayoutContext.current(for: screen)
        config.layoutAssignments.removeValue(forKey: context.key)
        save()
    }

    func contextLabel(for screen: NSScreen) -> String {
        LayoutContext.current(for: screen).label
    }

    func desktopName(for screen: NSScreen) -> String? {
        let context = LayoutContext.current(for: screen)
        return config.desktopNames[context.key] ?? config.desktopNames[context.displayKey]
    }

    func setDesktopName(_ name: String?, for screen: NSScreen) {
        let context = LayoutContext.current(for: screen)
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleaned.isEmpty {
            config.desktopNames.removeValue(forKey: context.key)
        } else {
            config.desktopNames[context.key] = cleaned
        }
        save()
    }

    var toastPosition: NSPoint? {
        config.toastPosition?.point
    }

    func setToastPosition(_ point: NSPoint) {
        config.toastPosition = ToastPosition(point: point)
        save()
    }

    func toastPosition(for screen: NSScreen) -> NSPoint? {
        let context = LayoutContext.current(for: screen)
        if let position = config.toastPositions[context.displayKey]?.point,
           screen.visibleFrame.insetBy(dx: -80, dy: -80).contains(position) {
            return position
        }
        if let legacyPosition = config.toastPosition?.point,
           NSScreen.screens.count == 1 || screen.frame.contains(legacyPosition) {
            return legacyPosition
        }
        return nil
    }

    func setToastPosition(_ point: NSPoint, for screen: NSScreen) {
        let context = LayoutContext.current(for: screen)
        config.toastPositions[context.displayKey] = ToastPosition(point: point)
        if NSScreen.screens.count == 1 {
            config.toastPosition = ToastPosition(point: point)
        }
        save()
    }

    private func upsertLayout(_ layout: GridLayout) {
        if let idx = config.layouts.firstIndex(where: { $0.name == layout.name }) {
            config.layouts[idx] = layout
        } else {
            config.layouts.append(layout)
        }
    }

    var allLayouts: [GridLayout] {
        config.layouts
    }

    // MARK: - Scenes

    var allScenes: [WindowScene] {
        config.scenes
    }

    func saveScene(_ scene: WindowScene) {
        if let idx = config.scenes.firstIndex(where: { $0.name == scene.name }) {
            config.scenes[idx] = scene
        } else {
            config.scenes.append(scene)
        }
        save()
    }

    func deleteScene(name: String) {
        config.scenes.removeAll { $0.name == name }
        save()
    }
}
