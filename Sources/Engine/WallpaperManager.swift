import Cocoa
import AVFoundation
import CoreImage
import ImageIO
import Combine

@MainActor
struct DisplaySlot {
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

    @Published public internal(set) var connectedDisplays: [DisplayInfo] = []
    @Published public internal(set) var isPlayingEffectively: Bool = true
    @Published public internal(set) var isSlowStopped: Bool = false
    @Published public internal(set) var isSlowStopping: Bool = false
    @Published public internal(set) var isWallpapersHidden: Bool = false

    var slotsByDisplayID: [String: DisplaySlot] = [:]
    var orderedDisplayIDs: [String] = []

    var sharedVideoPlayer: AVQueuePlayer?
    var sharedVideoLooper: AVPlayerLooper?
    var sharedVideoWallpaperID: String?
    var sharedVideoSpeed: Float = 1.0

    var identifyWindows: [DisplayIdentifyHUDWindow] = []
    var identifyDismissWorkItem: DispatchWorkItem?
    var spaceRecoveryWorkItem: DispatchWorkItem?
    var lockScreenPropertySyncWorkItem: DispatchWorkItem?
    var idleStoreSyncWorkItem: DispatchWorkItem?
    var syncedLockScreenEntries: [String: (url: URL, alignment: WallpaperAlignment)] = [:]
    var watchdogTimer: Timer?
    var slowStopTimer: Timer?
    var lastUnlockRampDate: Date = .distantPast
    var mouseMoveMonitor: Any?
    var lastMousePushTime: CFAbsoluteTime = 0

    var currentPolicy: PowerPolicyState = .running
    /// Set when a wallpaper window became visible while the desktop was paused only because windows
    /// covered it (typically mid Space swipe from a fullscreen app). Playback resumes at once instead
    /// of waiting for the swipe to end; the next settled policy evaluation clears it.
    var isResumedByVisibility: Bool = false
    var fadeOutWork: DispatchWorkItem?
    var isFadingOut: Bool = false
    var isRAMFreed: Bool = false
    var reloadScheduled: Bool = false
    var cancellables = Set<AnyCancellable>()

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

    func setupScreenNotifications() {
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

    func startVisibilityWatchdog() {
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

    func setupAudioAndMouseBridges() {
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

    func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reloadAllDisplays()
        }
    }

    func setupBindings() {
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

    func handleScreenChanges() {
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

    func teardownSharedVideoPlayer() {
        sharedVideoPlayer?.pause()
        sharedVideoPlayer?.removeAllItems()
        sharedVideoLooper?.disableLooping()
        sharedVideoLooper = nil
        sharedVideoPlayer = nil
        sharedVideoWallpaperID = nil
        sharedVideoSpeed = 1.0
    }

    func teardownAllRenderers() {
        for id in orderedDisplayIDs {
            slotsByDisplayID[id]?.teardownContent()
        }
        teardownSharedVideoPlayer()
    }

    func rebuildWindows() {
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

    var effectiveIsPaused: Bool {
        let policyPaused = currentPolicy.shouldPause && !(currentPolicy.isWindowCoverPause && isResumedByVisibility)
        return AppPreferences.shared.isPaused || isSlowStopped || isWallpapersHidden || policyPaused || currentPolicy.shouldStopAndFreeRAM
    }

    /// Paused because a window covers only this display (other displays keep playing).
    func isDisplayPausedByPolicy(_ id: String) -> Bool {
        currentPolicy.pausedDisplayIDs.contains(id)
    }

    func isSlotPaused(_ id: String) -> Bool {
        effectiveIsPaused || isDisplayPausedByPolicy(id)
    }

    /// The shared Clone/Stretch player keeps decoding while at least one display shows it.
    var isSharedPlayerPaused: Bool {
        effectiveIsPaused || orderedDisplayIDs.allSatisfy { isDisplayPausedByPolicy($0) }
    }

    /// The user's FPS cap, lowered to 30 while macOS Low Power Mode throttling is active.
    var effectiveFPSCap: Int {
        let cap = AppPreferences.shared.globalFPSCap
        return PowerMonitor.shared.isLowPowerThrottled ? min(cap, 30) : cap
    }

    var effectiveIsMuted: Bool {
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
    func installOverlays() {
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

    func loadPerDisplayMode(globalFPS: Int) {
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

    func loadSynchronizedMode(item: WallpaperItem, stretchAcrossDisplays: Bool, globalFPS: Int) {
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

    func scheduleLockScreenPropertySync(forWallpaperID wallpaperID: String) {
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

    func reapplyAllProperties() {
        let store = WallpaperStore.shared
        for id in orderedDisplayIDs {
            guard let slot = slotsByDisplayID[id],
                  let wallpaperID = slot.wallpaperID,
                  let item = store.wallpaper(id: wallpaperID) else { continue }
            applyLiveProperties(item.properties, forWallpaperID: wallpaperID)
        }
    }

    func updatePlaybackAndAudioState() {
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

}
