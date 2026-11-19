import Foundation
import Combine
import AppKit

public struct BuiltInMetadataOverride: Codable, Equatable {
    public var isFavorite: Bool
    public var tags: [String]
    public var properties: WallpaperProperties
}

@MainActor
public class WallpaperStore: ObservableObject {
    public static let shared = WallpaperStore()

    @Published public var wallpapers: [WallpaperItem] = []

    @Published public var activeWallpaperId: String = "builtin-alpine-dawn" {
        didSet {
            UserDefaults.standard.set(activeWallpaperId, forKey: Keys.activeWallpaperId)
        }
    }

    @Published public var displayLayoutMode: DisplayLayoutMode = .clone {
        didSet {
            UserDefaults.standard.set(displayLayoutMode.rawValue, forKey: Keys.displayLayoutMode)
        }
    }

    @Published public var activeWallpaperByDisplayID: [String: String] = [:] {
        didSet {
            UserDefaults.standard.set(activeWallpaperByDisplayID, forKey: Keys.activeWallpaperByDisplayID)
        }
    }

    public let propertiesChanged = PassthroughSubject<(wallpaperID: String, properties: WallpaperProperties), Never>()

    private enum Keys {
        static let activeWallpaperId = "activeWallpaperId"
        static let customWallpapers = "customWallpapersData"
        static let builtInOverrides = "builtInOverridesData.v1"
        static let displayLayoutMode = "displayLayoutMode.v1"
        static let activeWallpaperByDisplayID = "activeWallpaperByDisplayID.v1"
    }

    private init() {
        loadLibrary()
    }

    public var activeWallpaper: WallpaperItem? {
        wallpapers.first(where: { $0.id == activeWallpaperId }) ?? wallpapers.first
    }

    public func wallpaper(id: String) -> WallpaperItem? {
        wallpapers.first(where: { $0.id == id })
    }

    public func wallpaper(forStableDisplayID stableID: String) -> WallpaperItem? {
        switch displayLayoutMode {
        case .perDisplay:
            if let assignedID = activeWallpaperByDisplayID[stableID],
               let item = wallpaper(id: assignedID) {
                return item
            }
            return activeWallpaper
        case .clone, .stretch:
            return activeWallpaper
        }
    }

    public func wallpaper(for screen: NSScreen) -> WallpaperItem? {
        wallpaper(forStableDisplayID: screen.stableDisplayID)
    }

    public func setActiveWallpaper(_ wallpaperID: String, forStableDisplayID stableID: String? = nil) {
        guard wallpapers.contains(where: { $0.id == wallpaperID }) else { return }

        if let stableID, displayLayoutMode == .perDisplay {
            activeWallpaperByDisplayID[stableID] = wallpaperID

            if NSScreen.main?.stableDisplayID == stableID {
                activeWallpaperId = wallpaperID
            }
        } else {
            activeWallpaperId = wallpaperID
            if let stableID {
                activeWallpaperByDisplayID[stableID] = wallpaperID
            }
        }
    }

    public func setActiveWallpaper(_ wallpaperID: String, for screen: NSScreen?) {
        setActiveWallpaper(wallpaperID, forStableDisplayID: screen?.stableDisplayID)
    }

    public func loadLibrary() {
        var items: [WallpaperItem] = []

        let presetsDir = Bundle.main.resourceURL?.appendingPathComponent("Presets")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Presets")

        let overrides = loadBuiltInOverrides()

        let builtInDefinitions: [(id: String, title: String, relPath: String, tags: [String])] = [
            ("builtin-alpine-dawn", "Misty Alpine Dawn", "alpine-dawn/index.html", ["Calm", "Mountains", "Minimal"]),
            ("builtin-nordic-aurora", "Nordic Aurora", "nordic-aurora/index.html", ["Calm", "Aurora", "Night"]),
            ("builtin-rainy-dusk", "Rainy Glass Dusk", "rainy-dusk/index.html", ["Calm", "Rain", "Cozy"]),
            ("builtin-silk-waves", "Silk Ink Waves", "silk-waves/index.html", ["Minimal", "Abstract", "Dark"]),
            ("builtin-clock", "Minimal Glass Clock", "clock/index.html", ["Minimal", "Clock", "Typography"]),
            ("builtin-audioviz", "Ambient Sound Horizon", "audioviz/index.html", ["Calm", "Audio", "Minimal"])
        ]

        for definition in builtInDefinitions {
            let fullPath = presetsDir.appendingPathComponent(definition.relPath).path
            let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? Int64)
            let overrideEntry = overrides[definition.id]
            items.append(WallpaperItem(
                id: definition.id,
                title: definition.title,
                type: .web,
                pathOrURL: fullPath,
                isBuiltIn: true,
                isFavorite: overrideEntry?.isFavorite ?? false,
                tags: overrideEntry?.tags ?? definition.tags,
                resolutionLabel: "Dynamic · 60 FPS",
                fileSizeBytes: size,
                source: .builtIn,
                properties: overrideEntry?.properties ?? WallpaperProperties()
            ))
        }

        if let data = UserDefaults.standard.data(forKey: Keys.customWallpapers),
           let custom = try? JSONDecoder().decode([WallpaperItem].self, from: data) {
            items.append(contentsOf: custom)
        }

        self.wallpapers = items

        if let modeRaw = UserDefaults.standard.string(forKey: Keys.displayLayoutMode),
           let mode = DisplayLayoutMode(rawValue: modeRaw) {
            self.displayLayoutMode = mode
        } else {
            self.displayLayoutMode = .clone
        }

        if let map = UserDefaults.standard.dictionary(forKey: Keys.activeWallpaperByDisplayID) as? [String: String] {
            self.activeWallpaperByDisplayID = map
        }

        if let savedActive = UserDefaults.standard.string(forKey: Keys.activeWallpaperId),
           items.contains(where: { $0.id == savedActive }) {
            self.activeWallpaperId = savedActive
        } else {
            self.activeWallpaperId = "builtin-alpine-dawn"
        }
    }

    public func addCustomWallpaper(_ item: WallpaperItem, activate: Bool = true) {
        if let existingIndex = wallpapers.firstIndex(where: { $0.pathOrURL == item.pathOrURL }) {
            wallpapers[existingIndex] = item
            saveCustomWallpapers()
            if activate {
                activeWallpaperId = item.id
            }
            return
        }

        wallpapers.append(item)
        saveCustomWallpapers()
        if activate {
            activeWallpaperId = item.id
        }
    }

    public func removeWallpaper(id: String) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        if wallpapers[index].isBuiltIn { return }

        let removed = wallpapers.remove(at: index)
        saveCustomWallpapers()
        StorageJanitor.deleteManagedFiles(of: removed, remaining: wallpapers)

        var updatedMap = activeWallpaperByDisplayID
        for (displayID, wallpaperID) in updatedMap where wallpaperID == id {
            updatedMap.removeValue(forKey: displayID)
        }
        activeWallpaperByDisplayID = updatedMap

        if activeWallpaperId == id {
            activeWallpaperId = wallpapers.first?.id ?? "builtin-alpine-dawn"
        }
    }

    public func toggleFavorite(id: String) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[idx].isFavorite.toggle()
        persistItemChange(at: idx)
    }

    public func updateProperties(_ properties: WallpaperProperties, for wallpaperID: String) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == wallpaperID }) else { return }
        wallpapers[idx].properties = properties
        persistItemChange(at: idx)
        propertiesChanged.send((wallpaperID: wallpaperID, properties: properties))
    }

    public func resetProperties(for wallpaperID: String) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == wallpaperID }) else { return }
        var defaults = WallpaperProperties()

        for spec in wallpapers[idx].projectPropertySpecs {
            defaults.customProps[spec.key] = spec.defaultValue
        }
        updateProperties(defaults, for: wallpaperID)
    }

    public func updateItem(_ updated: WallpaperItem) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == updated.id }) else { return }
        let oldProps = wallpapers[idx].properties
        wallpapers[idx] = updated
        persistItemChange(at: idx)
        if oldProps != updated.properties {
            propertiesChanged.send((wallpaperID: updated.id, properties: updated.properties))
        }
    }

    public func updatePreviewPath(_ previewPath: String, for wallpaperID: String) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == wallpaperID }) else { return }
        wallpapers[idx].previewPath = previewPath
        persistItemChange(at: idx)
    }

    public func containsWallpaper(pathOrURL: String) -> Bool {
        let normalized = URL(fileURLWithPath: pathOrURL).standardizedFileURL.path
        return wallpapers.contains { item in
            item.pathOrURL == pathOrURL
                || URL(fileURLWithPath: item.pathOrURL).standardizedFileURL.path == normalized
        }
    }

    public var favoriteWallpapers: [WallpaperItem] {
        wallpapers.filter { $0.isFavorite }
    }

    private func persistItemChange(at index: Int) {
        if wallpapers[index].isBuiltIn {
            saveBuiltInOverrides()
        } else {
            saveCustomWallpapers()
        }
    }

    private func saveCustomWallpapers() {
        let customItems = wallpapers.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(customItems) {
            UserDefaults.standard.set(data, forKey: Keys.customWallpapers)
        }
    }

    private func loadBuiltInOverrides() -> [String: BuiltInMetadataOverride] {
        guard let data = UserDefaults.standard.data(forKey: Keys.builtInOverrides),
              let decoded = try? JSONDecoder().decode([String: BuiltInMetadataOverride].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveBuiltInOverrides() {
        var map: [String: BuiltInMetadataOverride] = [:]
        for item in wallpapers where item.isBuiltIn {
            map[item.id] = BuiltInMetadataOverride(
                isFavorite: item.isFavorite,
                tags: item.tags,
                properties: item.properties
            )
        }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: Keys.builtInOverrides)
        }
    }
}
