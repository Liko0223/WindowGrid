import Foundation

struct AppConfig: Codable {
    var activeLayoutName: String
    var layouts: [GridLayout]
    var modifierKey: String
    var scenes: [WindowScene]

    init(activeLayoutName: String, layouts: [GridLayout], modifierKey: String, scenes: [WindowScene] = []) {
        self.activeLayoutName = activeLayoutName
        self.layouts = layouts
        self.modifierKey = modifierKey
        self.scenes = scenes
    }

    static let `default` = AppConfig(
        activeLayoutName: GridLayout.sixGrid.name,
        layouts: GridLayout.allPresets,
        modifierKey: "option"
    )

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeLayoutName = try container.decode(String.self, forKey: .activeLayoutName)
        layouts = try container.decode([GridLayout].self, forKey: .layouts)
        modifierKey = try container.decode(String.self, forKey: .modifierKey)
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

    func setActiveLayout(_ layout: GridLayout) {
        config.activeLayoutName = layout.name
        if let idx = config.layouts.firstIndex(where: { $0.name == layout.name }) {
            config.layouts[idx] = layout
        } else {
            config.layouts.append(layout)
        }
        save()
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
