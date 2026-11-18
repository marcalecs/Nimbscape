import Cocoa
import CoreGraphics
import Combine

@MainActor
public class ScreensaverEngine: ObservableObject {
    public static let shared = ScreensaverEngine()

    @Published public private(set) var isActive: Bool = false

    private var idleTimer: Timer?
    private var saverWindows: [NSWindow] = []
    private var videoViews: [VideoWallpaperView] = []
    private var webViews: [WebWallpaperView] = []
    private var imageViews: [ImageWallpaperView] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var startMouseLocation: NSPoint = .zero
    private var startedAt: Date = .distantPast

    private init() {
        startIdleMonitor()
    }

    private func startIdleMonitor() {
        let timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIdleThreshold()
            }
        }
        timer.tolerance = 2.0
        idleTimer = timer
    }

    private func checkIdleThreshold() {
        guard AppPreferences.shared.screensaverEnabled, !isActive else { return }
        let thresholdSec = TimeInterval(max(1, AppPreferences.shared.screensaverIdleMinutes) * 60)
        let inputTypes: [CGEventType] = [
            .mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged
        ]
        let idleSec = inputTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        if idleSec >= thresholdSec {
            startScreensaver()
        }
    }

    public func startScreensaver() {
        guard !isActive, let item = WallpaperStore.shared.activeWallpaper else { return }
        isActive = true
        startedAt = Date()
        startMouseLocation = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .screenSaver
            win.backgroundColor = .black
            win.isOpaque = true
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.setFrame(screen.frame, display: true)

            if let contentView = win.contentView {
                contentView.wantsLayer = true
                switch item.type {
                case .video:
                    let vv = VideoWallpaperView(frame: contentView.bounds)
                    vv.autoresizingMask = [.width, .height]
                    contentView.addSubview(vv)
                    vv.loadVideo(
                        url: URL(fileURLWithPath: item.pathOrURL),
                        isMuted: true,
                        volume: 0,
                        isPaused: false,
                        properties: item.properties,
                        globalFPSCap: AppPreferences.shared.globalFPSCap
                    )
                    videoViews.append(vv)
                case .web:
                    let wv = WebWallpaperView(frame: contentView.bounds)
                    wv.autoresizingMask = [.width, .height]
                    contentView.addSubview(wv)
                    wv.loadWeb(
                        url: URL(fileURLWithPath: item.pathOrURL),
                        isPaused: false,
                        isMuted: true,
                        volume: 0,
                        properties: item.properties,
                        globalFPSCap: AppPreferences.shared.globalFPSCap
                    )
                    webViews.append(wv)
                case .url:
                    if let url = URL(string: item.pathOrURL) {
                        let wv = WebWallpaperView(frame: contentView.bounds)
                        wv.autoresizingMask = [.width, .height]
                        contentView.addSubview(wv)
                        wv.loadWeb(
                            url: url,
                            isPaused: false,
                            isMuted: true,
                            volume: 0,
                            properties: item.properties,
                            globalFPSCap: AppPreferences.shared.globalFPSCap
                        )
                        webViews.append(wv)
                    }
                case .image:
                    let iv = ImageWallpaperView(frame: contentView.bounds)
                    iv.autoresizingMask = [.width, .height]
                    contentView.addSubview(iv)
                    iv.loadImage(url: URL(fileURLWithPath: item.pathOrURL), properties: item.properties)
                    imageViews.append(iv)
                }
            }

            win.orderFrontRegardless()
            saverWindows.append(win)
        }

        NSCursor.hide()
        installExitMonitors()
    }

    public func stopScreensaver() {
        guard isActive else { return }
        isActive = false
        removeExitMonitors()
        NSCursor.unhide()

        videoViews.forEach { $0.cleanup(); $0.removeFromSuperview() }
        webViews.forEach { $0.cleanup(); $0.removeFromSuperview() }
        imageViews.forEach { $0.cleanup(); $0.removeFromSuperview() }
        videoViews.removeAll()
        webViews.removeAll()
        imageViews.removeAll()

        saverWindows.forEach { $0.orderOut(nil) }
        saverWindows.removeAll()
    }

    private func installExitMonitors() {
        removeExitMonitors()
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleInputEvent(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleInputEvent(event)
            return nil
        }
    }

    private func handleInputEvent(_ event: NSEvent) {
        guard Date().timeIntervalSince(startedAt) > 0.5 else { return }
        if event.type == .mouseMoved {
            let loc = NSEvent.mouseLocation
            let dist = hypot(loc.x - startMouseLocation.x, loc.y - startMouseLocation.y)
            if dist < 16 { return }
        }
        stopScreensaver()
    }

    private func removeExitMonitors() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
    }
}
