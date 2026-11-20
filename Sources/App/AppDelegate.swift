import Cocoa
import Combine

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.shared.applyAppearance()

        WallpaperManager.shared.start()
        StorageJanitor.cleanupOnLaunch()
        WidgetDataHub.shared.start()

        _ = PlaylistStore.shared
        _ = ScreensaverEngine.shared
        _ = AudioVisualizerEngine.shared
        if AppPreferences.shared.audioVisualizerEnabled || AppPreferences.shared.muteOnExternalAudio {
            AudioVisualizerEngine.shared.startIfNeeded()
        }

        StatusItemManager.shared.setup()

        QuickSwitcherManager.shared.registerGlobalHotkeys()
        AppPreferences.shared.$quickSwitcherHotkeyEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                QuickSwitcherManager.shared.registerGlobalHotkeys()
            }
            .store(in: &cancellables)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            StatusItemManager.shared.openMainWindow()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StatusItemManager.shared.openMainWindow()
        return false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        QuickSwitcherManager.shared.unregisterGlobalHotkeys()
    }
}
