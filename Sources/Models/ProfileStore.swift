import Foundation
import Combine

public struct WallpaperProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var layoutMode: DisplayLayoutMode
    public var primaryWallpaperID: String
    public var displayAssignments: [String: String]
    public var activePlaylistID: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        layoutMode: DisplayLayoutMode,
        primaryWallpaperID: String,
        displayAssignments: [String: String],
        activePlaylistID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.layoutMode = layoutMode
        self.primaryWallpaperID = primaryWallpaperID
        self.displayAssignments = displayAssignments
        self.activePlaylistID = activePlaylistID
        self.createdAt = createdAt
    }
}

@MainActor
public class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    @Published public var profiles: [WallpaperProfile] = [] {
        didSet { save() }
    }

    private let storageKey = "nimbscape.profiles.v1"

    private init() {
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([WallpaperProfile].self, from: data) {
            self.profiles = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    public func saveCurrentAsProfile(name: String) {
        let store = WallpaperStore.shared
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = WallpaperProfile(
            name: cleanName.isEmpty ? "Profile \(profiles.count + 1)" : cleanName,
            layoutMode: store.displayLayoutMode,
            primaryWallpaperID: store.activeWallpaperId,
            displayAssignments: store.activeWallpaperByDisplayID,
            activePlaylistID: PlaylistStore.shared.activePlaylistID
        )
        profiles.append(profile)
    }

    public func applyProfile(_ profile: WallpaperProfile) {
        let store = WallpaperStore.shared
        store.displayLayoutMode = profile.layoutMode
        store.activeWallpaperByDisplayID = profile.displayAssignments
        if store.wallpapers.contains(where: { $0.id == profile.primaryWallpaperID }) {
            store.activeWallpaperId = profile.primaryWallpaperID
        }
        PlaylistStore.shared.activePlaylistID = profile.activePlaylistID
    }

    public func deleteProfile(id: String) {
        profiles.removeAll(where: { $0.id == id })
    }
}
