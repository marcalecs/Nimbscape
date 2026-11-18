import Foundation
import Combine

public enum PlaylistRotationMode: String, Codable, CaseIterable, Sendable {
    case interval
    case timeOfDay
    case onUnlock
    case manualOnly

    public var displayName: String {
        switch self {
        case .interval: return "Every Interval"
        case .timeOfDay: return "Time of Day"
        case .onUnlock: return "On Mac Unlock"
        case .manualOnly: return "Manual Only (⌘⇧N)"
        }
    }
}

public enum TimeOfDaySlot: String, Codable, CaseIterable, Sendable {
    case morning
    case day
    case evening
    case night

    public var displayName: String {
        switch self {
        case .morning: return "Morning (06:00–12:00)"
        case .day: return "Day (12:00–18:00)"
        case .evening: return "Evening (18:00–22:00)"
        case .night: return "Night (22:00–06:00)"
        }
    }

    public static func current(date: Date = Date()) -> TimeOfDaySlot {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 6..<12: return .morning
        case 12..<18: return .day
        case 18..<22: return .evening
        default: return .night
        }
    }
}

public struct WallpaperPlaylist: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var wallpaperIDs: [String]
    public var rotationMode: PlaylistRotationMode
    public var intervalMinutes: Int
    public var shuffle: Bool
    public var timeOfDaySlots: [String: String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        wallpaperIDs: [String] = [],
        rotationMode: PlaylistRotationMode = .interval,
        intervalMinutes: Int = 15,
        shuffle: Bool = false,
        timeOfDaySlots: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
        self.rotationMode = rotationMode
        self.intervalMinutes = intervalMinutes
        self.shuffle = shuffle
        self.timeOfDaySlots = timeOfDaySlots
    }
}

@MainActor
public class PlaylistStore: ObservableObject {
    public static let shared = PlaylistStore()

    @Published public var playlists: [WallpaperPlaylist] = [] {
        didSet { save() }
    }

    @Published public var activePlaylistID: String? = nil {
        didSet {
            UserDefaults.standard.set(activePlaylistID, forKey: Keys.activePlaylistID)
            restartScheduler()
            if activePlaylistID != nil {
                applyInitialPlaylistWallpaperIfNeeded()
            }
        }
    }

    private enum Keys {
        static let playlists = "nimbscape.playlists.v1"
        static let activePlaylistID = "nimbscape.activePlaylistID.v1"
    }

    private var rotationTimer: Timer?

    private init() {
        load()
        restartScheduler()
    }

    public var activePlaylist: WallpaperPlaylist? {
        guard let id = activePlaylistID else { return nil }
        return playlists.first(where: { $0.id == id })
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Keys.playlists),
           let decoded = try? JSONDecoder().decode([WallpaperPlaylist].self, from: data) {
            self.playlists = decoded
        } else {
            self.playlists = [
                WallpaperPlaylist(
                    name: "Calm Ambient Mix",
                    wallpaperIDs: ["builtin-alpine-dawn", "builtin-nordic-aurora", "builtin-rainy-dusk", "builtin-silk-waves"],
                    rotationMode: .interval,
                    intervalMinutes: 15,
                    shuffle: false,
                    timeOfDaySlots: [
                        TimeOfDaySlot.morning.rawValue: "builtin-clock",
                        TimeOfDaySlot.day.rawValue: "builtin-nordic-aurora",
                        TimeOfDaySlot.evening.rawValue: "builtin-alpine-dawn",
                        TimeOfDaySlot.night.rawValue: "builtin-rainy-dusk"
                    ]
                )
            ]
        }

        if let savedID = UserDefaults.standard.string(forKey: Keys.activePlaylistID),
           playlists.contains(where: { $0.id == savedID }) {
            self.activePlaylistID = savedID
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: Keys.playlists)
        }
        restartScheduler()
    }

    public func createPlaylist(name: String, wallpaperIDs: [String] = []) -> WallpaperPlaylist {
        let p = WallpaperPlaylist(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Playlist" : name,
            wallpaperIDs: wallpaperIDs
        )
        playlists.append(p)
        return p
    }

    public func updatePlaylist(_ updated: WallpaperPlaylist) {
        if let idx = playlists.firstIndex(where: { $0.id == updated.id }) {
            playlists[idx] = updated
        }
    }

    public func deletePlaylist(id: String) {
        playlists.removeAll(where: { $0.id == id })
        if activePlaylistID == id {
            activePlaylistID = nil
        }
    }

    public func toggleWallpaper(_ wallpaperID: String, inPlaylist playlistID: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if let pos = playlists[idx].wallpaperIDs.firstIndex(of: wallpaperID) {
            playlists[idx].wallpaperIDs.remove(at: pos)
        } else {
            playlists[idx].wallpaperIDs.append(wallpaperID)
        }
    }

    public func advanceNext() {
        let store = WallpaperStore.shared

        if let playlist = activePlaylist {
            if playlist.rotationMode == .timeOfDay {
                applyTimeOfDay(for: playlist)
                return
            }

            let validIDs = playlist.wallpaperIDs.filter { id in store.wallpapers.contains(where: { $0.id == id }) }
            guard !validIDs.isEmpty else { return }

            if playlist.shuffle && validIDs.count > 1 {
                let others = validIDs.filter { $0 != store.activeWallpaperId }
                if let picked = others.randomElement() {
                    store.setActiveWallpaper(picked)
                }
                return
            }

            if let curIdx = validIDs.firstIndex(of: store.activeWallpaperId) {
                let nextIdx = (curIdx + 1) % validIDs.count
                store.setActiveWallpaper(validIDs[nextIdx])
            } else {
                store.setActiveWallpaper(validIDs[0])
            }
            return
        }

        let all = store.wallpapers
        guard all.count > 1 else { return }
        if let curIdx = all.firstIndex(where: { $0.id == store.activeWallpaperId }) {
            let nextIdx = (curIdx + 1) % all.count
            store.setActiveWallpaper(all[nextIdx].id)
        }
    }

    public func handleUnlock() {
        guard let playlist = activePlaylist else { return }
        switch playlist.rotationMode {
        case .onUnlock:
            advanceNext()
        case .timeOfDay:
            applyTimeOfDay(for: playlist)
        default:
            break
        }
    }

    private func applyInitialPlaylistWallpaperIfNeeded() {
        guard let playlist = activePlaylist else { return }
        if playlist.rotationMode == .timeOfDay {
            applyTimeOfDay(for: playlist)
            return
        }
        let store = WallpaperStore.shared
        if !playlist.wallpaperIDs.contains(store.activeWallpaperId),
           let first = playlist.wallpaperIDs.first(where: { id in store.wallpapers.contains(where: { $0.id == id }) }) {
            store.setActiveWallpaper(first)
        }
    }

    private func applyTimeOfDay(for playlist: WallpaperPlaylist) {
        let slot = TimeOfDaySlot.current()
        if let targetID = playlist.timeOfDaySlots[slot.rawValue],
           WallpaperStore.shared.wallpapers.contains(where: { $0.id == targetID }),
           WallpaperStore.shared.activeWallpaperId != targetID {
            WallpaperStore.shared.setActiveWallpaper(targetID)
        }
    }

    private func restartScheduler() {
        rotationTimer?.invalidate()
        rotationTimer = nil

        guard let playlist = activePlaylist else { return }

        switch playlist.rotationMode {
        case .interval:
            let intervalSec = TimeInterval(max(1, playlist.intervalMinutes) * 60)
            let t = Timer.scheduledTimer(withTimeInterval: intervalSec, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.advanceNext()
                }
            }
            t.tolerance = min(15.0, intervalSec * 0.1)
            rotationTimer = t

        case .timeOfDay:
            applyTimeOfDay(for: playlist)
            let t = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let active = self.activePlaylist, active.rotationMode == .timeOfDay else { return }
                    self.applyTimeOfDay(for: active)
                }
            }
            t.tolerance = 10.0
            rotationTimer = t

        case .onUnlock, .manualOnly:
            break
        }
    }
}
