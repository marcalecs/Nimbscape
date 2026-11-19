import Foundation
import Combine
import AppKit
import ServiceManagement

public enum AppAppearanceMode: String, Codable, CaseIterable, Sendable {
    case dark
    case light
    case system

    public var displayName: String {
        switch self {
        case .dark: return "Dark Glass"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    public var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}

public enum WindowPauseMode: String, Codable, CaseIterable, Sendable {
    case anyWindow
    case maximizedOrFullscreen
    case fullscreenOnly
    case never

    public var displayName: String {
        switch self {
        case .anyWindow: return "Any Open Window"
        case .maximizedOrFullscreen: return "Maximized / Fullscreen"
        case .fullscreenOnly: return "Fullscreen Only"
        case .never: return "Never"
        }
    }
}

@MainActor
public class AppPreferences: ObservableObject {
    public static let shared = AppPreferences()

    public static var defaultCollectionPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Pictures/Nimbscape"
    }

    private enum Keys {
        static let isPaused = "isPaused"
        static let isMuted = "isMuted"
        static let volume = "volume"
        static let pauseOnBattery = "pauseOnBattery"
        static let pauseOnLowPowerMode = "pauseOnLowPowerMode"
        static let pauseOnFullscreen = "pauseOnFullscreen"
        static let pauseOnMaximized = "pauseOnMaximized"
        static let windowPauseMode = "windowPauseMode"
        static let interactiveMode = "interactiveMode"
        static let globalFPSCap = "globalFPSCap"
        static let appearanceMode = "appearanceMode"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let quickSwitcherHotkeyEnabled = "quickSwitcherHotkeyEnabled"
        static let collectionFolderPath = "collectionFolderPath"
        static let syncLockScreenWallpaper = "syncLockScreenWallpaper"
        static let smoothSlowStop = "smoothSlowStop"
        static let slowStopOnUnlock = "slowStopOnUnlock"
        static let slowStopDuration = "slowStopDuration"
        static let audioVisualizerEnabled = "audioVisualizerEnabled"
        static let muteOnExternalAudio = "muteOnExternalAudio"
        static let crossfadeTransitions = "crossfadeTransitions"
        static let screensaverEnabled = "screensaverEnabled"
        static let screensaverIdleMinutes = "screensaverIdleMinutes"
        static let mouseParallaxTracking = "mouseParallaxTracking"
    }

    @Published public var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: Keys.isPaused) }
    }

    @Published public var isMuted: Bool {
        didSet { UserDefaults.standard.set(isMuted, forKey: Keys.isMuted) }
    }

    @Published public var volume: Float {
        didSet { UserDefaults.standard.set(volume, forKey: Keys.volume) }
    }

    @Published public var pauseOnBattery: Bool {
        didSet { UserDefaults.standard.set(pauseOnBattery, forKey: Keys.pauseOnBattery) }
    }

    @Published public var pauseOnLowPowerMode: Bool {
        didSet { UserDefaults.standard.set(pauseOnLowPowerMode, forKey: Keys.pauseOnLowPowerMode) }
    }

    @Published public var pauseOnFullscreen: Bool {
        didSet { UserDefaults.standard.set(pauseOnFullscreen, forKey: Keys.pauseOnFullscreen) }
    }

    @Published public var pauseOnMaximized: Bool {
        didSet { UserDefaults.standard.set(pauseOnMaximized, forKey: Keys.pauseOnMaximized) }
    }

    @Published public var windowPauseMode: WindowPauseMode {
        didSet { UserDefaults.standard.set(windowPauseMode.rawValue, forKey: Keys.windowPauseMode) }
    }

    @Published public var interactiveMode: Bool {
        didSet { UserDefaults.standard.set(interactiveMode, forKey: Keys.interactiveMode) }
    }

    @Published public var globalFPSCap: Int {
        didSet { UserDefaults.standard.set(globalFPSCap, forKey: Keys.globalFPSCap) }
    }

    @Published public var appearanceMode: AppAppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearanceMode)
            applyAppearance()
        }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published public var quickSwitcherHotkeyEnabled: Bool {
        didSet { UserDefaults.standard.set(quickSwitcherHotkeyEnabled, forKey: Keys.quickSwitcherHotkeyEnabled) }
    }

    @Published public var collectionFolderPath: String {
        didSet { UserDefaults.standard.set(collectionFolderPath, forKey: Keys.collectionFolderPath) }
    }

    @Published public var syncLockScreenWallpaper: Bool {
        didSet { UserDefaults.standard.set(syncLockScreenWallpaper, forKey: Keys.syncLockScreenWallpaper) }
    }

    @Published public var smoothSlowStop: Bool {
        didSet { UserDefaults.standard.set(smoothSlowStop, forKey: Keys.smoothSlowStop) }
    }

    @Published public var slowStopOnUnlock: Bool {
        didSet { UserDefaults.standard.set(slowStopOnUnlock, forKey: Keys.slowStopOnUnlock) }
    }

    @Published public var slowStopDuration: Double {
        didSet { UserDefaults.standard.set(slowStopDuration, forKey: Keys.slowStopDuration) }
    }

    @Published public var audioVisualizerEnabled: Bool {
        didSet { UserDefaults.standard.set(audioVisualizerEnabled, forKey: Keys.audioVisualizerEnabled) }
    }

    @Published public var muteOnExternalAudio: Bool {
        didSet { UserDefaults.standard.set(muteOnExternalAudio, forKey: Keys.muteOnExternalAudio) }
    }

    @Published public var crossfadeTransitions: Bool {
        didSet { UserDefaults.standard.set(crossfadeTransitions, forKey: Keys.crossfadeTransitions) }
    }

    @Published public var screensaverEnabled: Bool {
        didSet { UserDefaults.standard.set(screensaverEnabled, forKey: Keys.screensaverEnabled) }
    }

    @Published public var screensaverIdleMinutes: Int {
        didSet { UserDefaults.standard.set(screensaverIdleMinutes, forKey: Keys.screensaverIdleMinutes) }
    }

    @Published public var mouseParallaxTracking: Bool {
        didSet { UserDefaults.standard.set(mouseParallaxTracking, forKey: Keys.mouseParallaxTracking) }
    }

    @Published public var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                let actual = (SMAppService.mainApp.status == .enabled)
                if actual != launchAtLogin {
                    launchAtLogin = actual
                }
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.isPaused: false,
            Keys.isMuted: true,
            Keys.volume: 0.5,
            Keys.pauseOnBattery: true,
            Keys.pauseOnLowPowerMode: true,
            Keys.pauseOnFullscreen: true,
            Keys.pauseOnMaximized: true,
            Keys.windowPauseMode: WindowPauseMode.anyWindow.rawValue,
            Keys.interactiveMode: false,
            Keys.globalFPSCap: 60,
            Keys.appearanceMode: AppAppearanceMode.dark.rawValue,
            Keys.hasCompletedOnboarding: false,
            Keys.quickSwitcherHotkeyEnabled: true,
            Keys.collectionFolderPath: Self.defaultCollectionPath,
            Keys.syncLockScreenWallpaper: true,
            Keys.smoothSlowStop: true,
            Keys.slowStopOnUnlock: false,
            Keys.slowStopDuration: 3.0,
            Keys.audioVisualizerEnabled: false,
            Keys.muteOnExternalAudio: false,
            Keys.crossfadeTransitions: true,
            Keys.screensaverEnabled: false,
            Keys.screensaverIdleMinutes: 5,
            Keys.mouseParallaxTracking: true
        ])

        self.isPaused = defaults.bool(forKey: Keys.isPaused)
        self.isMuted = defaults.bool(forKey: Keys.isMuted)
        self.volume = defaults.float(forKey: Keys.volume)
        self.pauseOnBattery = defaults.bool(forKey: Keys.pauseOnBattery)
        self.pauseOnLowPowerMode = defaults.bool(forKey: Keys.pauseOnLowPowerMode)
        self.pauseOnFullscreen = defaults.bool(forKey: Keys.pauseOnFullscreen)
        self.pauseOnMaximized = defaults.bool(forKey: Keys.pauseOnMaximized)
        self.windowPauseMode = WindowPauseMode(rawValue: defaults.string(forKey: Keys.windowPauseMode) ?? "") ?? .anyWindow
        self.interactiveMode = defaults.bool(forKey: Keys.interactiveMode)
        let savedFPS = defaults.integer(forKey: Keys.globalFPSCap)
        self.globalFPSCap = [30, 60, 120].contains(savedFPS) ? savedFPS : 60
        self.appearanceMode = AppAppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .dark
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.quickSwitcherHotkeyEnabled = defaults.bool(forKey: Keys.quickSwitcherHotkeyEnabled)
        self.collectionFolderPath = defaults.string(forKey: Keys.collectionFolderPath) ?? Self.defaultCollectionPath
        self.syncLockScreenWallpaper = defaults.bool(forKey: Keys.syncLockScreenWallpaper)
        self.smoothSlowStop = defaults.bool(forKey: Keys.smoothSlowStop)
        self.slowStopOnUnlock = defaults.bool(forKey: Keys.slowStopOnUnlock)
        let savedDur = defaults.double(forKey: Keys.slowStopDuration)
        self.slowStopDuration = max(0.5, min(10.0, savedDur > 0 ? savedDur : 3.0))
        self.audioVisualizerEnabled = defaults.bool(forKey: Keys.audioVisualizerEnabled)
        self.muteOnExternalAudio = defaults.bool(forKey: Keys.muteOnExternalAudio)
        self.crossfadeTransitions = defaults.bool(forKey: Keys.crossfadeTransitions)
        self.screensaverEnabled = defaults.bool(forKey: Keys.screensaverEnabled)
        let savedIdle = defaults.integer(forKey: Keys.screensaverIdleMinutes)
        self.screensaverIdleMinutes = max(1, min(60, savedIdle > 0 ? savedIdle : 5))
        self.mouseParallaxTracking = defaults.bool(forKey: Keys.mouseParallaxTracking)
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    public func applyAppearance() {
        DispatchQueue.main.async {
            NSApp.appearance = self.appearanceMode.nsAppearance
        }
    }
}
