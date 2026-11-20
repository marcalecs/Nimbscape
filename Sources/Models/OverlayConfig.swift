import Foundation
import Combine

/// Stores one overlay configuration per wallpaper ID.
@MainActor
public final class OverlayStore: ObservableObject {
    public static let shared = OverlayStore()

    @Published public private(set) var configs: [String: OverlayConfig] = [:]

    private let defaultsKey = "nimbscape.overlays.v1"
    private var saveWork: DispatchWorkItem?

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: OverlayConfig].self, from: data) {
            configs = decoded
        }
    }

    public func config(for wallpaperID: String) -> OverlayConfig {
        configs[wallpaperID] ?? OverlayConfig()
    }

    public func setConfig(_ config: OverlayConfig, for wallpaperID: String) {
        if config.isEmpty {
            configs.removeValue(forKey: wallpaperID)
        } else {
            configs[wallpaperID] = config
        }
        save()
    }

    public func update(_ wallpaperID: String, _ change: (inout OverlayConfig) -> Void) {
        var config = config(for: wallpaperID)
        change(&config)
        setConfig(config, for: wallpaperID)
    }

    /// Widget kinds in use by any wallpaper; data providers only run for these.
    public var kindsInUse: Set<OverlayWidgetKind> {
        Set(configs.values.flatMap { $0.widgets.map(\.kind) })
    }

    /// Writes are coalesced so dragging a slider doesn't hit the disk on every tick.
    private func save() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let data = try? JSONEncoder().encode(self.configs) else { return }
                UserDefaults.standard.set(data, forKey: self.defaultsKey)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
