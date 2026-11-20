import Cocoa
import AVFoundation
import CoreImage
import ImageIO

/// Keeping wallpaper windows on every Space and display, and the display-identify HUD.
extension WallpaperManager {
    func handleActiveSpaceChange() {
        // Widgets are re-checked at once (cheap, no playback change), not after the swipe settles.
        OverlayController.shared.ensureWidgetWindowsVisible()
        spaceRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reattached = self.ensureAllWindowsVisible()
                self.ensureActivePlaybackAlive(didReattach: reattached)
            }
        }
        spaceRecoveryWorkItem = work
        // Wait out the swipe animation (same settle window as PowerMonitor) before reordering windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    @discardableResult
    public func ensureAllWindowsVisible(forceReattach: Bool = false) -> Bool {
        if isWallpapersHidden {
            for id in orderedDisplayIDs {
                slotsByDisplayID[id]?.window.orderOut(nil)
            }
            return false
        }
        let screensByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.stableDisplayID, $0) })
        var anyReattached = false
        defer { OverlayController.shared.ensureWidgetWindowsVisible() }
        for id in orderedDisplayIDs {
            if let screen = screensByID[id] {
                slotsByDisplayID[id]?.screen = screen
                if slotsByDisplayID[id]?.window.ensureVisibleOnDesktop(frameOverride: screen.frame, forceReattach: forceReattach) == true {
                    anyReattached = true
                }
            } else {
                if slotsByDisplayID[id]?.window.ensureVisibleOnDesktop(forceReattach: forceReattach) == true {
                    anyReattached = true
                }
            }
        }
        return anyReattached
    }

    func ensureActivePlaybackAlive(didReattach: Bool) {
        guard !isWallpapersHidden, !isRAMFreed, !effectiveIsPaused else { return }
        if isPlayingEffectively && !isSlowStopping && !isSlowStopped {
            if let sharedPlayer = sharedVideoPlayer, !isSharedPlayerPaused {
                if sharedPlayer.rate == 0 || sharedPlayer.timeControlStatus == .paused {
                    sharedPlayer.rate = sharedVideoSpeed
                }
            }
            for id in orderedDisplayIDs where !isDisplayPausedByPolicy(id) {
                slotsByDisplayID[id]?.videoView?.ensurePlayingIfExpected()
                if didReattach {
                    slotsByDisplayID[id]?.webView?.recoverAfterWake()
                }
            }
        }
    }

    public func toggleHideWallpapers() {
        isWallpapersHidden.toggle()
        ensureAllWindowsVisible()
        updatePlaybackAndAudioState()
        OverlayController.shared.setWidgetsHidden(isWallpapersHidden)
    }

    public func identifyDisplays() {
        identifyDismissWorkItem?.cancel()
        identifyWindows.forEach { $0.close() }
        identifyWindows.removeAll()

        for (idx, screen) in NSScreen.screens.enumerated() {
            let hud = DisplayIdentifyHUDWindow(screen: screen, index: idx + 1)
            hud.alphaValue = 0
            hud.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                hud.animator().alphaValue = 1.0
            }
            identifyWindows.append(hud)
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let windowsToDismiss = self.identifyWindows
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    windowsToDismiss.forEach { $0.animator().alphaValue = 0 }
                }, completionHandler: {
                    Task { @MainActor in
                        windowsToDismiss.forEach { $0.orderOut(nil) }
                        if self.identifyWindows.elementsEqual(windowsToDismiss, by: { $0 === $1 }) {
                            self.identifyWindows.removeAll()
                        }
                    }
                })
            }
        }
        identifyDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
}
