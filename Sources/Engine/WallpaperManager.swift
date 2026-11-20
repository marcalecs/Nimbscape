import Cocoa
import AVFoundation
import CoreImage
import ImageIO
import Combine

@MainActor
private struct DisplaySlot {
    let displayID: String
    var screen: NSScreen
    let window: WallpaperWindow
    var wallpaperID: String?
    var videoView: VideoWallpaperView?
    var webView: WebWallpaperView?
    var imageView: ImageWallpaperView?

    mutating func teardownContent() {
        videoView?.cleanup()
        videoView?.removeFromSuperview()
        videoView = nil

        webView?.onDidFinishLoad = nil
        webView?.cleanup()
        webView?.removeFromSuperview()
        webView = nil

        imageView?.cleanup()
        imageView?.removeFromSuperview()
        imageView = nil

        wallpaperID = nil
    }
}

@MainActor
public class WallpaperManager: ObservableObject, PowerMonitorDelegate {
    public static let shared = WallpaperManager()

    @Published public private(set) var connectedDisplays: [DisplayInfo] = []
    @Published public private(set) var isPlayingEffectively: Bool = true
    @Published public private(set) var isSlowStopped: Bool = false
    @Published public private(set) var isSlowStopping: Bool = false
    @Published public private(set) var isWallpapersHidden: Bool = false

    private var slotsByDisplayID: [String: DisplaySlot] = [:]
    private var orderedDisplayIDs: [String] = []

    private var sharedVideoPlayer: AVQueuePlayer?
    private var sharedVideoLooper: AVPlayerLooper?
    private var sharedVideoWallpaperID: String?
    private var sharedVideoSpeed: Float = 1.0

    private var identifyWindows: [DisplayIdentifyHUDWindow] = []
    private var identifyDismissWorkItem: DispatchWorkItem?
    private var spaceRecoveryWorkItem: DispatchWorkItem?
    private var lockScreenPropertySyncWorkItem: DispatchWorkItem?
    private var idleStoreSyncWorkItem: DispatchWorkItem?
    private var syncedLockScreenEntries: [String: (url: URL, alignment: WallpaperAlignment)] = [:]
    private var watchdogTimer: Timer?
    private var slowStopTimer: Timer?
    private var lastUnlockRampDate: Date = .distantPast
    private var mouseMoveMonitor: Any?
    private var lastMousePushTime: CFAbsoluteTime = 0

    private var currentPolicy: PowerPolicyState = .running
    /// Set when a wallpaper window became visible while the desktop was paused only because windows
    /// covered it (typically mid Space swipe from a fullscreen app). Playback resumes at once instead
    /// of waiting for the swipe to end; the next settled policy evaluation clears it.
    private var isResumedByVisibility: Bool = false
    private var isRAMFreed: Bool = false
    private var reloadScheduled: Bool = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        PowerMonitor.shared.delegate = self
        refreshConnectedDisplays()
        setupScreenNotifications()
        setupBindings()
        setupAudioAndMouseBridges()
        startVisibilityWatchdog()
    }

    public func start() {
        refreshConnectedDisplays()
        rebuildWindows()
        PowerMonitor.shared.evaluateState()
        if !currentPolicy.shouldStopAndFreeRAM {
            reloadAllDisplays()
        }
        updatePlaybackAndAudioState()
    }

    public func refreshConnectedDisplays() {
        let screens = NSScreen.screens
        let infos = screens.enumerated().map { idx, screen in
            screen.toDisplayInfo(index: idx + 1)
        }
        self.connectedDisplays = infos
    }

    private func setupScreenNotifications() {
        // Block-based observers hop onto the main actor explicitly: these notifications can be
        // delivered off the main thread (display reconfiguration, wake), and @objc selectors on a
        // @MainActor class trip Swift 6's isolation check (same SIGTRAP PowerMonitor hit in v1.0.1).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenChanges() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil
        ) { [weak self] note in
            let window = note.object as? NSWindow
            Task { @MainActor [weak self] in self?.handleOcclusionChange(of: window) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didUnhideApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleActiveSpaceChange() }
            }
        }
    }

    private func startVisibilityWatchdog() {
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !NSScreen.screens.isEmpty else { return }
                if self.slotsByDisplayID.isEmpty {
                    self.rebuildWindows()
                    if !self.currentPolicy.shouldStopAndFreeRAM {
                        self.reloadAllDisplays()
                    }
                    return
                }
                let reattached = self.ensureAllWindowsVisible()
                if reattached {
                    self.ensureActivePlaybackAlive(didReattach: true)
                }
            }
        }
        timer.tolerance = 2.0
        watchdogTimer = timer
    }

    private func handleActiveSpaceChange() {
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

    private func ensureActivePlaybackAlive(didReattach: Bool) {
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

    private func setupAudioAndMouseBridges() {
        AudioVisualizerEngine.shared.onSpectrumUpdate = { [weak self] spectrum in
            guard let self, self.isPlayingEffectively, !self.isWallpapersHidden else { return }
            for id in self.orderedDisplayIDs {
                self.slotsByDisplayID[id]?.webView?.pushAudioSpectrum(spectrum)
            }
        }

        AudioVisualizerEngine.shared.$isExternalAudioPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if AppPreferences.shared.muteOnExternalAudio {
                    self?.updatePlaybackAndAudioState()
                }
            }
            .store(in: &cancellables)

        AppPreferences.shared.$muteOnExternalAudio
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePlaybackAndAudioState()
            }
            .store(in: &cancellables)

        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      AppPreferences.shared.mouseParallaxTracking,
                      self.isPlayingEffectively,
                      !self.isWallpapersHidden else { return }
                let now = CFAbsoluteTimeGetCurrent()
                guard now - self.lastMousePushTime >= (1.0 / 24.0) else { return }
                self.lastMousePushTime = now

                let mouseLoc = NSEvent.mouseLocation
                for id in self.orderedDisplayIDs {
                    guard let slot = self.slotsByDisplayID[id], let wv = slot.webView else { continue }
                    let f = slot.screen.frame
                    guard f.width > 0 && f.height > 0 else { continue }
                    let nx = max(-1.0, min(1.0, ((mouseLoc.x - f.minX) / f.width - 0.5) * 2.0))
                    let ny = max(-1.0, min(1.0, ((f.maxY - mouseLoc.y) / f.height - 0.5) * 2.0))
                    wv.pushMousePosition(normX: nx, normY: ny)
                }
            }
        }
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reloadAllDisplays()
        }
    }

    private func setupBindings() {
        let store = WallpaperStore.shared
        let preferences = AppPreferences.shared

        store.$activeWallpaperId
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleReload()
            }
            .store(in: &cancellables)

        store.$displayLayoutMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleReload()
            }
            .store(in: &cancellables)

        store.$activeWallpaperByDisplayID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if WallpaperStore.shared.displayLayoutMode == .perDisplay {
                    self?.scheduleReload()
                }
            }
            .store(in: &cancellables)

        store.propertiesChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] payload in
                self?.applyLiveProperties(payload.properties, forWallpaperID: payload.wallpaperID)
            }
            .store(in: &cancellables)

        preferences.$isPaused
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                guard let self else { return }
                if paused && AppPreferences.shared.smoothSlowStop && !self.currentPolicy.shouldPause {
                    self.triggerSlowStop(duration: AppPreferences.shared.slowStopDuration, markManualSettled: false)
                } else {
                    self.cancelSlowStop()
                    self.updatePlaybackAndAudioState()
                }
            }
            .store(in: &cancellables)

        preferences.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePlaybackAndAudioState()
            }
            .store(in: &cancellables)

        preferences.$volume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePlaybackAndAudioState()
            }
            .store(in: &cancellables)

        preferences.$interactiveMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] interactive in
                self?.slotsByDisplayID.values.forEach { $0.window.updateInteractiveMode(interactive) }
            }
            .store(in: &cancellables)

        preferences.$globalFPSCap
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reapplyAllProperties()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(PowerMonitor.shared.$isLowPowerMode, preferences.$pauseOnLowPowerMode)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reapplyAllProperties()
            }
            .store(in: &cancellables)

        preferences.$syncLockScreenWallpaper
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.syncAllDisplaysToLockScreen()
                }
            }
            .store(in: &cancellables)
    }

    private func handleScreenChanges() {
        let screens = NSScreen.screens

        guard !screens.isEmpty else { return }

        refreshConnectedDisplays()
        let newIDs = screens.map { $0.stableDisplayID }

        if newIDs == orderedDisplayIDs && !orderedDisplayIDs.isEmpty {
            var boundsChanged = false
            for screen in screens {
                let id = screen.stableDisplayID
                if let existing = slotsByDisplayID[id] {
                    if existing.window.frame != screen.frame {
                        boundsChanged = true
                    }
                    slotsByDisplayID[id]?.screen = screen
                    existing.window.ensureVisibleOnDesktop(frameOverride: screen.frame)
                }
            }
            if boundsChanged && WallpaperStore.shared.displayLayoutMode == .stretch && !currentPolicy.shouldStopAndFreeRAM {
                reloadAllDisplays()
            }
            return
        }

        rebuildWindows()
        if !currentPolicy.shouldStopAndFreeRAM {
            reloadAllDisplays()
        }
    }

    private func teardownSharedVideoPlayer() {
        sharedVideoPlayer?.pause()
        sharedVideoPlayer?.removeAllItems()
        sharedVideoLooper?.disableLooping()
        sharedVideoLooper = nil
        sharedVideoPlayer = nil
        sharedVideoWallpaperID = nil
        sharedVideoSpeed = 1.0
    }

    private func teardownAllRenderers() {
        for id in orderedDisplayIDs {
            slotsByDisplayID[id]?.teardownContent()
        }
        teardownSharedVideoPlayer()
    }

    private func rebuildWindows() {
        teardownAllRenderers()
        for slot in slotsByDisplayID.values {
            slot.window.close()
        }
        slotsByDisplayID.removeAll()
        orderedDisplayIDs.removeAll()

        for screen in NSScreen.screens {
            let win = WallpaperWindow(screen: screen)
            let id = screen.stableDisplayID
            slotsByDisplayID[id] = DisplaySlot(displayID: id, screen: screen, window: win)
            orderedDisplayIDs.append(id)
        }
    }

    private var effectiveIsPaused: Bool {
        let policyPaused = currentPolicy.shouldPause && !(currentPolicy.isWindowCoverPause && isResumedByVisibility)
        return AppPreferences.shared.isPaused || isSlowStopped || isWallpapersHidden || policyPaused || currentPolicy.shouldStopAndFreeRAM
    }

    private func handleOcclusionChange(of window: NSWindow?) {
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
        isResumedByVisibility = false
        // Policy unchanged (still covered): the user landed on a covered desktop, so ease back down.
        if effectiveIsPaused {
            triggerFadeStop()
        } else {
            updatePlaybackAndAudioState()
        }
    }

    // MARK: - Still-frame cross-fade (smooth stop / start)

    private static let fadeDuration: TimeInterval = 0.6
    private var fadeOutWork: DispatchWorkItem?
    private var isFadingOut: Bool = false

    /// Video slots and the player each one renders.
    private var videoSlotPlayers: [(id: String, view: VideoWallpaperView, player: AVQueuePlayer)] {
        orderedDisplayIDs.compactMap { id in
            guard let view = slotsByDisplayID[id]?.videoView, let player = view.renderedPlayer else { return nil }
            return (id, view, player)
        }
    }

    /// Grabs the frame each video player shows right now (one capture per player).
    private func captureStills(_ completion: @escaping @MainActor ([ObjectIdentifier: CGImage]) -> Void) {
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
    private func triggerFadeStop() {
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

    private func cancelFadeOut() {
        isFadingOut = false
        fadeOutWork?.cancel()
        fadeOutWork = nil
    }

    /// Resume with a cross-fade: a still of the paused frame covers the video, playback starts
    /// underneath (hiding the decoder warm-up), then the still fades away.
    private func triggerFadeResume() {
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

    /// Paused because a window covers only this display (other displays keep playing).
    private func isDisplayPausedByPolicy(_ id: String) -> Bool {
        currentPolicy.pausedDisplayIDs.contains(id)
    }

    private func isSlotPaused(_ id: String) -> Bool {
        effectiveIsPaused || isDisplayPausedByPolicy(id)
    }

    /// The shared Clone/Stretch player keeps decoding while at least one display shows it.
    private var isSharedPlayerPaused: Bool {
        effectiveIsPaused || orderedDisplayIDs.allSatisfy { isDisplayPausedByPolicy($0) }
    }

    /// The user's FPS cap, lowered to 30 while macOS Low Power Mode throttling is active.
    private var effectiveFPSCap: Int {
        let cap = AppPreferences.shared.globalFPSCap
        return PowerMonitor.shared.isLowPowerThrottled ? min(cap, 30) : cap
    }

    private var effectiveIsMuted: Bool {
        let muteExternal = AppPreferences.shared.muteOnExternalAudio && AudioVisualizerEngine.shared.isExternalAudioPlaying
        return AppPreferences.shared.isMuted || currentPolicy.shouldMuteAudio || muteExternal
    }

    public func reloadAllDisplays() {
        cancelSlowStop()

        if currentPolicy.shouldStopAndFreeRAM {
            teardownAllRenderers()
            isRAMFreed = true
            isPlayingEffectively = false
            return
        }

        if AppPreferences.shared.crossfadeTransitions && !slotsByDisplayID.isEmpty {
            for id in orderedDisplayIDs {
                if let layer = slotsByDisplayID[id]?.window.contentView?.layer {
                    let transition = CATransition()
                    transition.type = .fade
                    transition.duration = 0.5
                    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(transition, forKey: "nimbscape.crossfade")
                }
            }
        }

        isRAMFreed = false
        teardownAllRenderers()

        let store = WallpaperStore.shared
        let mode = store.displayLayoutMode
        let globalFPS = effectiveFPSCap

        switch mode {
        case .perDisplay:
            loadPerDisplayMode(globalFPS: globalFPS)
        case .clone:
            if let item = store.activeWallpaper {
                loadSynchronizedMode(item: item, stretchAcrossDisplays: false, globalFPS: globalFPS)
            }
        case .stretch:
            if let item = store.activeWallpaper {
                loadSynchronizedMode(item: item, stretchAcrossDisplays: true, globalFPS: globalFPS)
            }
        }

        installOverlays()
        updatePlaybackAndAudioState()
        ensureAllWindowsVisible()
        syncAllDisplaysToLockScreen()
    }

    /// Widgets and effects for each display's wallpaper, layered above the wallpaper content.
    private func installOverlays() {
        for id in orderedDisplayIDs {
            guard let slot = slotsByDisplayID[id], let contentView = slot.window.contentView,
                  let wallpaperID = slot.wallpaperID else { continue }
            OverlayController.shared.install(in: contentView, wallpaperID: wallpaperID, displayID: id, screen: slot.screen)
        }
        OverlayController.shared.setWidgetsHidden(isWallpapersHidden)
    }

    /// Re-applies pause state to overlay effects (e.g. after the widget editor closes).
    public func refreshOverlayPauseState() {
        for id in orderedDisplayIDs {
            OverlayController.shared.setPaused(isSlotPaused(id), displayID: id)
        }
    }

    /// The wallpaper currently shown on a display (used by the widget editor).
    public func currentWallpaperID(forDisplay displayID: String) -> String? {
        slotsByDisplayID[displayID]?.wallpaperID ?? WallpaperStore.shared.activeWallpaperId
    }

    private func loadPerDisplayMode(globalFPS: Int) {
        let store = WallpaperStore.shared
        let mainID = NSScreen.main?.stableDisplayID ?? orderedDisplayIDs.first
        let paused = effectiveIsPaused
        let muted = effectiveIsMuted
        let volume = AppPreferences.shared.volume

        for id in orderedDisplayIDs {
            guard var slot = slotsByDisplayID[id],
                  let contentView = slot.window.contentView,
                  let item = store.wallpaper(forStableDisplayID: id) else {
                continue
            }

            let isPrimaryAudioScreen = (id == mainID)
            let slotMuted = muted || !isPrimaryAudioScreen
            let frame = contentView.bounds
            let paused = paused || isDisplayPausedByPolicy(id)

            slot.wallpaperID = item.id

            switch item.type {
            case .video:
                let videoView = VideoWallpaperView(frame: frame)
                videoView.autoresizingMask = [.width, .height]
                contentView.addSubview(videoView)
                videoView.loadVideo(
                    url: URL(fileURLWithPath: item.pathOrURL),
                    isMuted: slotMuted,
                    volume: volume,
                    isPaused: paused,
                    properties: item.properties,
                    globalFPSCap: globalFPS
                )
                slot.videoView = videoView

            case .web:
                let webView = WebWallpaperView(frame: frame)
                webView.autoresizingMask = [.width, .height]
                contentView.addSubview(webView)
                webView.loadWeb(
                    url: URL(fileURLWithPath: item.pathOrURL),
                    isPaused: paused,
                    isMuted: slotMuted,
                    volume: volume,
                    properties: item.properties,
                    globalFPSCap: globalFPS
                )
                slot.webView = webView

            case .url:
                if let url = URL(string: item.pathOrURL) {
                    let webView = WebWallpaperView(frame: frame)
                    webView.autoresizingMask = [.width, .height]
                    contentView.addSubview(webView)
                    webView.loadWeb(
                        url: url,
                        isPaused: paused,
                        isMuted: slotMuted,
                        volume: volume,
                        properties: item.properties,
                        globalFPSCap: globalFPS
                    )
                    slot.webView = webView
                }

            case .image:
                let imageView = ImageWallpaperView(frame: frame)
                imageView.autoresizingMask = [.width, .height]
                contentView.addSubview(imageView)
                imageView.loadImage(url: URL(fileURLWithPath: item.pathOrURL), properties: item.properties, isPaused: paused)
                slot.imageView = imageView
            }

            slotsByDisplayID[id] = slot
        }
    }

    private func loadSynchronizedMode(item: WallpaperItem, stretchAcrossDisplays: Bool, globalFPS: Int) {
        let paused = effectiveIsPaused
        let muted = effectiveIsMuted
        let volume = AppPreferences.shared.volume
        let mainID = NSScreen.main?.stableDisplayID ?? orderedDisplayIDs.first

        let unionRect: CGRect = NSScreen.screens.reduce(CGRect.null) { accumulator, screen in
            accumulator.isNull ? screen.frame : accumulator.union(screen.frame)
        }

        if item.type == .video {
            let asset = AVURLAsset(url: URL(fileURLWithPath: item.pathOrURL))
            let templateItem = AVPlayerItem(asset: asset)
            let player = AVQueuePlayer(playerItem: templateItem)
            player.automaticallyWaitsToMinimizeStalling = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            let looper = AVPlayerLooper(player: player, templateItem: templateItem)

            player.isMuted = muted
            player.volume = volume
            self.sharedVideoSpeed = max(0.25, min(2.0, item.properties.speed))
            self.sharedVideoPlayer = player
            self.sharedVideoLooper = looper
            self.sharedVideoWallpaperID = item.id

            if !isSharedPlayerPaused {
                player.rate = self.sharedVideoSpeed
            }
        }

        for id in orderedDisplayIDs {
            guard var slot = slotsByDisplayID[id],
                  let contentView = slot.window.contentView else {
                continue
            }

            let targetFrame: NSRect
            let autoresizing: NSView.AutoresizingMask
            if stretchAcrossDisplays && !unionRect.isNull {
                targetFrame = NSRect(
                    x: unionRect.minX - slot.screen.frame.minX,
                    y: unionRect.minY - slot.screen.frame.minY,
                    width: unionRect.width,
                    height: unionRect.height
                )
                autoresizing = []
            } else {
                targetFrame = contentView.bounds
                autoresizing = [.width, .height]
            }

            let isPrimaryAudioScreen = (id == mainID)
            let slotMuted = muted || !isPrimaryAudioScreen
            let paused = paused || isDisplayPausedByPolicy(id)
            slot.wallpaperID = item.id

            switch item.type {
            case .video:
                if let player = sharedVideoPlayer {
                    let videoView = VideoWallpaperView(frame: targetFrame)
                    videoView.autoresizingMask = autoresizing
                    contentView.addSubview(videoView)
                    videoView.attachSharedPlayer(
                        player,
                        isPaused: paused,
                        properties: item.properties,
                        globalFPSCap: globalFPS
                    )
                    slot.videoView = videoView
                }

            case .web:
                let webView = WebWallpaperView(frame: targetFrame)
                webView.autoresizingMask = autoresizing
                contentView.addSubview(webView)
                webView.loadWeb(
                    url: URL(fileURLWithPath: item.pathOrURL),
                    isPaused: paused,
                    isMuted: slotMuted,
                    volume: volume,
                    properties: item.properties,
                    globalFPSCap: globalFPS
                )
                slot.webView = webView

            case .url:
                if let url = URL(string: item.pathOrURL) {
                    let webView = WebWallpaperView(frame: targetFrame)
                    webView.autoresizingMask = autoresizing
                    contentView.addSubview(webView)
                    webView.loadWeb(
                        url: url,
                        isPaused: paused,
                        isMuted: slotMuted,
                        volume: volume,
                        properties: item.properties,
                        globalFPSCap: globalFPS
                    )
                    slot.webView = webView
                }

            case .image:
                let imageView = ImageWallpaperView(frame: targetFrame)
                imageView.autoresizingMask = autoresizing
                contentView.addSubview(imageView)
                imageView.loadImage(url: URL(fileURLWithPath: item.pathOrURL), properties: item.properties, isPaused: paused)
                slot.imageView = imageView
            }

            slotsByDisplayID[id] = slot
        }
    }

    public func applyLiveProperties(_ properties: WallpaperProperties, forWallpaperID wallpaperID: String) {
        let globalFPS = effectiveFPSCap

        if sharedVideoWallpaperID == wallpaperID, let player = sharedVideoPlayer {
            sharedVideoSpeed = max(0.25, min(2.0, properties.speed))
            if !isSharedPlayerPaused {
                player.rate = sharedVideoSpeed
            }
        }

        var affectedAnyDisplay = false
        for id in orderedDisplayIDs {
            guard let slot = slotsByDisplayID[id], slot.wallpaperID == wallpaperID else { continue }
            affectedAnyDisplay = true
            slot.videoView?.applyProperties(properties, globalFPSCap: globalFPS)
            slot.webView?.applyProperties(properties, globalFPSCap: globalFPS)
            slot.imageView?.applyProperties(properties)
        }

        if affectedAnyDisplay {
            scheduleLockScreenPropertySync(forWallpaperID: wallpaperID)
        }
    }

    private func scheduleLockScreenPropertySync(forWallpaperID wallpaperID: String) {
        lockScreenPropertySyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      let item = WallpaperStore.shared.wallpaper(id: wallpaperID) else { return }
                for id in self.orderedDisplayIDs {
                    guard self.slotsByDisplayID[id]?.wallpaperID == wallpaperID else { continue }
                    self.syncSlotToLockScreen(displayID: id, item: item)
                }
            }
        }
        lockScreenPropertySyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func reapplyAllProperties() {
        let store = WallpaperStore.shared
        for id in orderedDisplayIDs {
            guard let slot = slotsByDisplayID[id],
                  let wallpaperID = slot.wallpaperID,
                  let item = store.wallpaper(id: wallpaperID) else { continue }
            applyLiveProperties(item.properties, forWallpaperID: wallpaperID)
        }
    }

    private func updatePlaybackAndAudioState() {
        let muted = effectiveIsMuted
        let volume = AppPreferences.shared.volume
        let mainID = NSScreen.main?.stableDisplayID ?? orderedDisplayIDs.first

        sharedVideoPlayer?.isMuted = muted
        sharedVideoPlayer?.volume = volume
        for id in orderedDisplayIDs {
            guard let slot = slotsByDisplayID[id] else { continue }
            let slotMuted = muted || (id != mainID)
            slot.videoView?.setMuted(slotMuted)
            slot.videoView?.setVolume(volume)
            slot.webView?.setMuted(slotMuted)
            slot.webView?.setVolume(volume)
        }

        if isSlowStopping || isFadingOut {
            if currentPolicy.shouldStopAndFreeRAM {
                cancelSlowStop()
                cancelFadeOut()
            } else {
                return
            }
        }

        let paused = effectiveIsPaused
        let anyDisplayPlaying = orderedDisplayIDs.contains { !isSlotPaused($0) }
        isPlayingEffectively = !paused && anyDisplayPlaying && !isRAMFreed

        if let sharedPlayer = sharedVideoPlayer {
            if isSharedPlayerPaused {
                sharedPlayer.pause()
            } else {
                sharedPlayer.rate = sharedVideoSpeed
            }
        }

        for id in orderedDisplayIDs {
            guard let slot = slotsByDisplayID[id] else { continue }
            OverlayController.shared.setPaused(isSlotPaused(id), displayID: id)
            if isSlotPaused(id) {
                slot.videoView?.pause()
                slot.webView?.pause()
                slot.imageView?.pause()
            } else {
                slot.videoView?.play()
                slot.videoView?.hideStill(fadeDuration: Self.fadeDuration)
                slot.webView?.play()
                slot.imageView?.play()
            }
        }
    }

    public func togglePlayPause() {
        if isSlowStopped || isSlowStopping {
            cancelSlowStop()
            AppPreferences.shared.isPaused = false
            updatePlaybackAndAudioState()
        } else {
            AppPreferences.shared.isPaused.toggle()
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

    public func powerMonitorDidUpdatePolicy(_ state: PowerPolicyState) {
        let wasResumedByVisibility = isResumedByVisibility
        if !(state.shouldPause && state.isWindowCoverPause) {
            isResumedByVisibility = false
        }
        let wasStoppedRAM = currentPolicy.shouldStopAndFreeRAM
        let wasPausedByPolicy = currentPolicy.shouldPause
        currentPolicy = state

        if state.shouldStopAndFreeRAM && !wasStoppedRAM {
            cancelSlowStop()
            teardownAllRenderers()
            isRAMFreed = true
            isPlayingEffectively = false
            return
        }

        if !state.shouldStopAndFreeRAM && (wasStoppedRAM || isRAMFreed) {
            reloadAllDisplays()
            return
        }

        if !wasPausedByPolicy && state.shouldPause {
            if !state.isHardwareSleepOrLock
                && AppPreferences.shared.smoothSlowStop
                && !AppPreferences.shared.isPaused
                && !isSlowStopped {
                triggerFadeStop()
                return
            }
            cancelSlowStop()
            updatePlaybackAndAudioState()
            return
        }

        if wasPausedByPolicy && !state.shouldPause {
            if wasResumedByVisibility && !isFadingOut {
                // Already playing since the wallpaper came into view mid-swipe.
                return
            }
            triggerFadeResume()
            return
        }

        updatePlaybackAndAudioState()
    }

    public func powerMonitorDidUnlockOrWake() {
        ensureAllWindowsVisible()
        PlaylistStore.shared.handleUnlock()
        if currentPolicy.shouldStopAndFreeRAM { return }

        let sharedFailed = sharedVideoPlayer?.status == .failed
            || sharedVideoPlayer?.currentItem?.status == .failed
        let anySlotFailed = slotsByDisplayID.values.contains { $0.videoView?.hasFailedDecoder == true }

        if sharedFailed || anySlotFailed || slotsByDisplayID.isEmpty {
            reloadAllDisplays()
        } else {
            for id in orderedDisplayIDs {
                slotsByDisplayID[id]?.videoView?.recoverAfterWake()
            }
        }

        if AppPreferences.shared.slowStopOnUnlock && !AppPreferences.shared.isPaused {
            let now = Date()
            if now.timeIntervalSince(lastUnlockRampDate) > 1.2 {
                lastUnlockRampDate = now
                triggerSlowStop(duration: AppPreferences.shared.slowStopDuration)
            }
            return
        }

        for id in orderedDisplayIDs {
            slotsByDisplayID[id]?.webView?.recoverAfterWake()
        }
        updatePlaybackAndAudioState()
    }

    private nonisolated static var lockScreenSyncDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Nimbscape/LockScreenSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func syncAllDisplaysToLockScreen() {
        let store = WallpaperStore.shared
        for id in orderedDisplayIDs {
            guard let slot = slotsByDisplayID[id],
                  let wallpaperID = slot.wallpaperID,
                  let item = store.wallpaper(id: wallpaperID) else { continue }
            syncSlotToLockScreen(displayID: id, item: item)
        }
    }

    private func syncSlotToLockScreen(displayID: String, item: WallpaperItem) {
        guard let slot = slotsByDisplayID[displayID] else { return }
        let shouldSyncSystem = AppPreferences.shared.syncLockScreenWallpaper
        let props = item.properties

        switch item.type {
        case .image:
            let imgURL = URL(fileURLWithPath: item.pathOrURL)
            let wallpaperID = item.id
            Task.detached(priority: .utility) {
                guard let savedURL = Self.extractAndSaveImageSyncPNG(url: imgURL, properties: props, key: "\(wallpaperID)_\(displayID)") else { return }
                await MainActor.run { [weak self] in
                    guard let self, let currentSlot = self.slotsByDisplayID[displayID],
                          currentSlot.wallpaperID == wallpaperID else { return }
                    currentSlot.window.setBackdropImage(NSImage(contentsOf: savedURL))
                    if shouldSyncSystem {
                        self.applySystemDesktopWallpaper(fileURL: savedURL, for: currentSlot.screen, alignment: props.alignment)
                    }
                }
            }

        case .video:
            let videoURL = URL(fileURLWithPath: item.pathOrURL)
            let wallpaperID = item.id
            Task.detached(priority: .utility) {
                guard let savedURL = Self.extractAndSaveVideoSyncPNG(url: videoURL, properties: props, key: "\(wallpaperID)_\(displayID)") else { return }
                await MainActor.run { [weak self] in
                    guard let self, let currentSlot = self.slotsByDisplayID[displayID],
                          currentSlot.wallpaperID == wallpaperID else { return }
                    currentSlot.window.setBackdropImage(NSImage(contentsOf: savedURL))
                    if shouldSyncSystem {
                        self.applySystemDesktopWallpaper(fileURL: savedURL, for: currentSlot.screen, alignment: props.alignment)
                    }
                }
            }

        case .web, .url:
            guard let webView = slot.webView else { return }
            let wallpaperID = item.id
            let alignment = props.alignment
            let captureAction: @MainActor () -> Void = { [weak self, weak webView] in
                guard let self, let webView else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    Task { @MainActor [weak self, weak webView] in
                        guard let self, let webView,
                              self.slotsByDisplayID[displayID]?.wallpaperID == wallpaperID else { return }
                        webView.captureSnapshot { [weak self] snapshot in
                            guard let self, let snapshot else { return }
                            self.slotsByDisplayID[displayID]?.window.setBackdropImage(snapshot)
                            guard AppPreferences.shared.syncLockScreenWallpaper,
                                  let tiffData = snapshot.tiffRepresentation else { return }
                            Task.detached(priority: .utility) {
                                if let savedURL = Self.saveSyncPNG(tiffData: tiffData, key: "\(wallpaperID)_\(displayID)") {
                                    await MainActor.run { [weak self] in
                                        if let targetScreen = self?.slotsByDisplayID[displayID]?.screen {
                                            self?.applySystemDesktopWallpaper(fileURL: savedURL, for: targetScreen, alignment: alignment)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            webView.onDidFinishLoad = captureAction
            captureAction()
        }
    }

    private func applySystemDesktopWallpaper(fileURL: URL, for screen: NSScreen, alignment: WallpaperAlignment = .fill) {
        let scaling: NSImageScaling
        let allowClipping: Bool
        switch alignment {
        case .fill:
            scaling = .scaleProportionallyUpOrDown
            allowClipping = true
        case .fit:
            scaling = .scaleProportionallyUpOrDown
            allowClipping = false
        case .stretch:
            scaling = .scaleAxesIndependently
            allowClipping = false
        }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: scaling.rawValue,
            .allowClipping: allowClipping
        ]
        try? NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: options)

        syncedLockScreenEntries[screen.stableDisplayID] = (url: fileURL, alignment: alignment)
        scheduleIdleAndSpacesStoreSync()
    }

    private func scheduleIdleAndSpacesStoreSync() {
        guard AppPreferences.shared.syncLockScreenWallpaper else { return }
        idleStoreSyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, AppPreferences.shared.syncLockScreenWallpaper else { return }
                let entries = self.syncedLockScreenEntries
                guard !entries.isEmpty else { return }
                let primaryID = self.orderedDisplayIDs.first ?? entries.keys.sorted().first ?? ""
                guard let primaryEntry = entries[primaryID] ?? entries.values.first else { return }

                let serializedEntries = entries.mapValues { ($0.url.absoluteString, $0.alignment.rawValue) }
                let primaryPair = (primaryEntry.url.absoluteString, primaryEntry.alignment.rawValue)

                Task.detached(priority: .utility) {
                    let didReload = Self.syncMacOSWallpaperStore(
                        entriesByDisplayID: serializedEntries,
                        primaryEntry: primaryPair
                    )
                    if didReload {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        await MainActor.run { [weak self] in
                            _ = self?.ensureAllWindowsVisible(forceReattach: true)
                        }
                    }
                }
            }
        }
        idleStoreSyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    private nonisolated static func syncMacOSWallpaperStore(
        entriesByDisplayID: [String: (String, String)],
        primaryEntry: (String, String)
    ) -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let storeURL = appSupport.appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
        guard let rawData = try? Data(contentsOf: storeURL),
              let parsed = try? PropertyListSerialization.propertyList(from: rawData, options: [], format: nil),
              var root = parsed as? [String: Any] else {
            return false
        }

        let templateDesktop = (root["SystemDefault"] as? [String: Any])?["Desktop"] as? [String: Any]
        let now = Date()
        var didChange = false

        func placementID(for alignmentRaw: String) -> String {
            switch alignmentRaw {
            case WallpaperAlignment.fit.rawValue:
                return "SizeToFit"
            case WallpaperAlignment.stretch.rawValue:
                return "FillScreen"
            default:
                return "Crop"
            }
        }

        func existingImageURL(in slot: [String: Any]?) -> String? {
            guard let content = slot?["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]],
                  let first = choices.first,
                  (first["Provider"] as? String) == "com.apple.wallpaper.choice.image",
                  let cfgData = first["Configuration"] as? Data,
                  let cfgObj = try? PropertyListSerialization.propertyList(from: cfgData, options: [], format: nil) as? [String: Any],
                  let urlDict = cfgObj["url"] as? [String: Any] else {
                return nil
            }
            return urlDict["relative"] as? String
        }

        func makeSlotDict(urlString: String, alignmentRaw: String) -> [String: Any]? {
            let cfgDict: [String: Any] = [
                "type": "imageFile",
                "url": ["relative": urlString]
            ]
            guard let cfgData = try? PropertyListSerialization.data(fromPropertyList: cfgDict, format: .binary, options: 0) else {
                return nil
            }

            var optionsData: Data?
            if let templateContent = templateDesktop?["Content"] as? [String: Any],
               let existingOpts = templateContent["EncodedOptionValues"] as? Data,
               var optsDict = (try? PropertyListSerialization.propertyList(from: existingOpts, options: [], format: nil)) as? [String: Any],
               var values = optsDict["values"] as? [String: Any] {
                values["placement"] = ["picker": ["_0": ["id": placementID(for: alignmentRaw)]]]
                optsDict["values"] = values
                optionsData = try? PropertyListSerialization.data(fromPropertyList: optsDict, format: .binary, options: 0)
            }
            if optionsData == nil {
                let fallbackColorSpace = (try? PropertyListSerialization.data(
                    fromPropertyList: "kCGColorSpaceGenericRGB",
                    format: .binary,
                    options: 0
                )) ?? Data()
                let fallbackOpts: [String: Any] = [
                    "values": [
                        "color": [
                            "color": [
                                "_0": [
                                    "color": [
                                        "colorSpace": fallbackColorSpace,
                                        "components": [0.0, 0.0, 0.0, 1.0]
                                    ]
                                ]
                            ]
                        ],
                        "placement": ["picker": ["_0": ["id": placementID(for: alignmentRaw)]]]
                    ]
                ]
                optionsData = try? PropertyListSerialization.data(fromPropertyList: fallbackOpts, format: .binary, options: 0)
            }

            var content: [String: Any] = [
                "Choices": [[
                    "Configuration": cfgData,
                    "Files": [Any](),
                    "Provider": "com.apple.wallpaper.choice.image"
                ]],
                "Shuffle": "$null"
            ]
            if let optionsData {
                content["EncodedOptionValues"] = optionsData
            }
            return [
                "Content": content,
                "LastSet": now,
                "LastUse": now
            ]
        }

        func patchConfigNode(_ node: [String: Any], entry: (String, String), idleOnlyWhenLinked: Bool = false) -> [String: Any] {
            var updated = node
            let (urlString, alignmentRaw) = entry
            guard let slotDict = makeSlotDict(urlString: urlString, alignmentRaw: alignmentRaw) else {
                return updated
            }

            if (updated["Type"] as? String) == "linked" || updated["Linked"] != nil {
                updated.removeValue(forKey: "Linked")
                if idleOnlyWhenLinked {
                    updated["Type"] = "idle"
                    updated.removeValue(forKey: "Desktop")
                    updated["Idle"] = slotDict
                } else {
                    updated["Type"] = "individual"
                    updated["Desktop"] = slotDict
                    updated["Idle"] = slotDict
                }
                didChange = true
                return updated
            }

            if updated["Desktop"] != nil {
                if existingImageURL(in: updated["Desktop"] as? [String: Any]) != urlString {
                    updated["Desktop"] = slotDict
                    didChange = true
                }
            }
            if updated["Idle"] != nil {
                if existingImageURL(in: updated["Idle"] as? [String: Any]) != urlString {
                    updated["Idle"] = slotDict
                    didChange = true
                }
            }
            return updated
        }

        if let allNode = root["AllSpacesAndDisplays"] as? [String: Any] {
            root["AllSpacesAndDisplays"] = patchConfigNode(allNode, entry: primaryEntry, idleOnlyWhenLinked: true)
        }
        if let sysNode = root["SystemDefault"] as? [String: Any] {
            root["SystemDefault"] = patchConfigNode(sysNode, entry: primaryEntry)
        }
        if var displaysDict = root["Displays"] as? [String: Any] {
            for (dispID, rawVal) in displaysDict {
                if let dispNode = rawVal as? [String: Any] {
                    let entry = entriesByDisplayID[dispID] ?? primaryEntry
                    displaysDict[dispID] = patchConfigNode(dispNode, entry: entry)
                }
            }
            root["Displays"] = displaysDict
        }
        if var spacesDict = root["Spaces"] as? [String: Any] {
            for (spaceID, rawSpace) in spacesDict {
                guard var spaceNode = rawSpace as? [String: Any] else { continue }
                if let defNode = spaceNode["Default"] as? [String: Any] {
                    spaceNode["Default"] = patchConfigNode(defNode, entry: primaryEntry)
                }
                if var spaceDisplays = spaceNode["Displays"] as? [String: Any] {
                    for (dispID, rawDisp) in spaceDisplays {
                        if let dispNode = rawDisp as? [String: Any] {
                            let entry = entriesByDisplayID[dispID] ?? primaryEntry
                            spaceDisplays[dispID] = patchConfigNode(dispNode, entry: entry)
                        }
                    }
                    spaceNode["Displays"] = spaceDisplays
                }
                spacesDict[spaceID] = spaceNode
            }
            root["Spaces"] = spacesDict
        }

        guard didChange,
              let outData = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) else {
            return false
        }

        do {
            try outData.write(to: storeURL, options: .atomic)
        } catch {
            return false
        }

        let activeFileNames = Set(
            ([primaryEntry.0] + entriesByDisplayID.values.map { $0.0 })
                .compactMap { URL(string: $0)?.lastPathComponent }
        )
        if !activeFileNames.isEmpty,
           let files = try? FileManager.default.contentsOfDirectory(at: lockScreenSyncDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "png" && !activeFileNames.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["WallpaperAgent"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return true
    }

    private nonisolated static func applyColorFilters(to cgImage: CGImage, properties: WallpaperProperties) -> CGImage {
        guard properties.hasColorAdjustments else { return cgImage }

        var ciImage = CIImage(cgImage: cgImage)
        if abs(properties.hue) > 0.01, let hueFilter = CIFilter(name: "CIHueAdjust") {
            hueFilter.setValue(ciImage, forKey: kCIInputImageKey)
            hueFilter.setValue(properties.hue * .pi / 180.0, forKey: kCIInputAngleKey)
            if let out = hueFilter.outputImage {
                ciImage = out
            }
        }

        if abs(properties.brightness - 1.0) > 0.01
            || abs(properties.contrast - 1.0) > 0.01
            || abs(properties.saturation - 1.0) > 0.01,
           let colorControls = CIFilter(name: "CIColorControls") {
            let mappedBrightness = max(-0.5, min(0.5, (properties.brightness - 1.0) * 0.5))
            colorControls.setValue(ciImage, forKey: kCIInputImageKey)
            colorControls.setValue(mappedBrightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(properties.contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(properties.saturation, forKey: kCIInputSaturationKey)
            if let out = colorControls.outputImage {
                ciImage = out
            }
        }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(ciImage, from: ciImage.extent) ?? cgImage
    }

    private nonisolated static func extractAndSaveImageSyncPNG(
        url: URL,
        properties: WallpaperProperties,
        key: String
    ) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let idx = count > 2 ? count / 2 : 0
        guard let rawCG = CGImageSourceCreateImageAtIndex(source, idx, nil) else { return nil }
        let styledCG = applyColorFilters(to: rawCG, properties: properties)
        let rep = NSBitmapImageRep(cgImage: styledCG)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        return writeSyncPNGData(pngData, key: key)
    }

    private nonisolated static func extractAndSaveVideoSyncPNG(
        url: URL,
        properties: WallpaperProperties,
        key: String
    ) -> URL? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 2560, height: 1440)
        for sec in [1.0, 0.0] {
            if let rawCG = try? gen.copyCGImage(at: CMTime(seconds: sec, preferredTimescale: 600), actualTime: nil) {
                let styledCG = applyColorFilters(to: rawCG, properties: properties)
                let rep = NSBitmapImageRep(cgImage: styledCG)
                if let pngData = rep.representation(using: .png, properties: [:]) {
                    return writeSyncPNGData(pngData, key: key)
                }
            }
        }
        return nil
    }

    private nonisolated static func saveSyncPNG(tiffData: Data, key: String) -> URL? {
        guard let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return writeSyncPNGData(pngData, key: key)
    }

    private nonisolated static func writeSyncPNGData(_ pngData: Data, key: String) -> URL? {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let dir = lockScreenSyncDir
        let dest = dir.appendingPathComponent("\(safeKey)_\(stamp).png")

        do {
            try pngData.write(to: dest, options: .atomic)
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in files where f.lastPathComponent != dest.lastPathComponent && f.lastPathComponent.hasPrefix("\(safeKey)_") {
                    try? FileManager.default.removeItem(at: f)
                }
            }
            return dest
        } catch {
            return nil
        }
    }
}
