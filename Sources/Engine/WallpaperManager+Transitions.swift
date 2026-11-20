import Cocoa
import AVFoundation
import CoreImage
import ImageIO

/// Smooth stop/start: still-frame cross-fades, the manual slow-stop ramp, and resuming as soon as
/// a covered wallpaper comes into view.
extension WallpaperManager {
    func handleOcclusionChange(of window: NSWindow?) {
        guard let window, window.occlusionState.contains(.visible),
              slotsByDisplayID.values.contains(where: { $0.window === window }),
              currentPolicy.shouldPause, currentPolicy.isWindowCoverPause,
              !isResumedByVisibility, !AppPreferences.shared.isPaused, !isWallpapersHidden
        else { return }
        isResumedByVisibility = true
        triggerFadeResume()
    }

    public func powerMonitorDidSettleAfterSpaceChange() {
        guard isResumedByVisibility else { return }
        guard currentPolicy.shouldPause && currentPolicy.isWindowCoverPause else {
            isResumedByVisibility = false
            updatePlaybackAndAudioState()
            return
        }
        // Right after a swipe the window list often still shows the fullscreen app we just left,
        // which would stop the video and restart it a moment later. Keep playing and confirm
        // with a fresh scan before easing down.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coverRecheckDelay) { [weak self] in
            MainActor.assumeIsolated {
                PowerMonitor.shared.evaluateState { [weak self] in
                    guard let self, self.isResumedByVisibility else { return }
                    self.isResumedByVisibility = false
                    if self.effectiveIsPaused { self.triggerFadeStop() } else { self.updatePlaybackAndAudioState() }
                }
            }
        }
    }

    /// Delay before re-checking a cover pause right after a swipe.
    static let coverRecheckDelay: TimeInterval = 0.5

    // MARK: - Still-frame cross-fade (smooth stop / start)

    static let fadeDuration: TimeInterval = 0.6

    /// Video slots and the player each one renders.
    var videoSlotPlayers: [(id: String, view: VideoWallpaperView, player: AVQueuePlayer)] {
        orderedDisplayIDs.compactMap { id in
            guard let view = slotsByDisplayID[id]?.videoView, let player = view.renderedPlayer else { return nil }
            return (id, view, player)
        }
    }

    /// Grabs the frame each video player shows right now (one capture per player).
    func captureStills(_ completion: @escaping @MainActor ([ObjectIdentifier: CGImage]) -> Void) {
        var players: [ObjectIdentifier: AVQueuePlayer] = [:]
        for entry in videoSlotPlayers { players[ObjectIdentifier(entry.player)] = entry.player }
        guard !players.isEmpty else {
            completion([:])
            return
        }
        let maxSize = NSScreen.screens.reduce(CGSize.zero) { size, screen in
            let scale = screen.backingScaleFactor
            return CGSize(width: max(size.width, screen.frame.width * scale), height: max(size.height, screen.frame.height * scale))
        }
        final class Box: @unchecked Sendable { var images: [ObjectIdentifier: CGImage] = [:]; var remaining = 0 }
        let box = Box()
        box.remaining = players.count
        for (key, player) in players {
            guard let item = player.currentItem else {
                box.remaining -= 1
                continue
            }
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = maxSize
            generator.generateCGImageAsynchronously(for: item.currentTime()) { image, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let image { box.images[key] = image }
                        box.remaining -= 1
                        if box.remaining == 0 { completion(box.images) }
                    }
                }
            }
        }
        if box.remaining == 0 { completion(box.images) }
    }

    /// Pause with a cross-fade: the current frame fades in over the still-moving video, then
    /// playback stops underneath it. Web/image wallpapers use their own slow-stop.
    func triggerFadeStop() {
        cancelFadeOut()
        guard !videoSlotPlayers.isEmpty else {
            triggerSlowStop(duration: AppPreferences.shared.slowStopDuration, markManualSettled: false)
            return
        }
        isFadingOut = true
        captureStills { [weak self] images in
            guard let self, self.isFadingOut else { return }
            for entry in self.videoSlotPlayers {
                if let image = images[ObjectIdentifier(entry.player)] {
                    entry.view.showStill(image, fadeDuration: Self.fadeDuration)
                }
            }
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isFadingOut else { return }
                    self.isFadingOut = false
                    self.updatePlaybackAndAudioState()
                }
            }
            self.fadeOutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration, execute: work)
        }
    }

    func cancelFadeOut() {
        isFadingOut = false
        fadeOutWork?.cancel()
        fadeOutWork = nil
    }

    /// Resume with a cross-fade: a still of the paused frame covers the video, playback starts
    /// underneath (hiding the decoder warm-up), then the still fades away.
    func triggerFadeResume() {
        cancelFadeOut()
        cancelSlowStop()
        let entries = videoSlotPlayers
        let start: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // Starts playback under the still; updatePlaybackAndAudioState then fades the still away.
            self.updatePlaybackAndAudioState()
        }
        if entries.allSatisfy({ $0.view.isShowingStill }) {
            start()
            return
        }
        captureStills { images in
            for entry in entries where !entry.view.isShowingStill {
                if let image = images[ObjectIdentifier(entry.player)] {
                    entry.view.showStill(image, fadeDuration: 0)
                }
            }
            start()
        }
    }

    public func triggerSlowStop(duration: Double, markManualSettled: Bool = true) {
        cancelFadeOut()
        let duration = max(0.5, min(10.0, duration))
        slowStopTimer?.invalidate()
        slowStopTimer = nil

        isSlowStopped = false
        isSlowStopping = true
        isPlayingEffectively = true

        for id in orderedDisplayIDs {
            slotsByDisplayID[id]?.webView?.startSlowStop(duration: duration)
        }

        if let sharedPlayer = sharedVideoPlayer {
            sharedPlayer.rate = sharedVideoSpeed
        }
        for id in orderedDisplayIDs {
            slotsByDisplayID[id]?.videoView?.setLiveSpeedFactor(1.0)
            slotsByDisplayID[id]?.imageView?.setLiveSpeedFactor(1.0)
        }

        let startTime = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isSlowStopping else {
                    self.slowStopTimer?.invalidate()
                    self.slowStopTimer = nil
                    return
                }
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(1.0, elapsed / duration)
                let factor = Float((1.0 - progress) * (1.0 - progress))

                if let sharedPlayer = self.sharedVideoPlayer {
                    if factor <= 0.01 {
                        sharedPlayer.pause()
                    } else {
                        sharedPlayer.rate = self.sharedVideoSpeed * factor
                    }
                }
                for id in self.orderedDisplayIDs {
                    self.slotsByDisplayID[id]?.videoView?.setLiveSpeedFactor(factor)
                    self.slotsByDisplayID[id]?.imageView?.setLiveSpeedFactor(factor)
                }

                if progress >= 1.0 {
                    self.slowStopTimer?.invalidate()
                    self.slowStopTimer = nil
                    self.isSlowStopping = false
                    if markManualSettled {
                        self.isSlowStopped = true
                    }
                    self.isPlayingEffectively = false
                    for id in self.orderedDisplayIDs {
                        self.slotsByDisplayID[id]?.videoView?.pause()
                        self.slotsByDisplayID[id]?.webView?.pause()
                        self.slotsByDisplayID[id]?.imageView?.pause()
                    }
                }
            }
        }
        slowStopTimer = timer
    }

    public func cancelSlowStop() {
        slowStopTimer?.invalidate()
        slowStopTimer = nil
        let wasActive = isSlowStopping || isSlowStopped
        isSlowStopping = false
        isSlowStopped = false
        if wasActive {
            for id in orderedDisplayIDs {
                slotsByDisplayID[id]?.webView?.cancelSlowStop()
            }
        }
    }
}
