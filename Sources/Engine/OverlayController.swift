import Cocoa
import SwiftUI
import Combine

/// Puts effects and widgets on top of each display's wallpaper and runs the full-screen editor.
///
/// - Effects (particles, dim, blur) and the visible widgets live inside the wallpaper window, above
///   the video/web/image. That window is part of what macOS draws during Space swipes, so widgets
///   stay on screen while swiping (a separate window is only drawn once a swipe ends).
/// - Clicks go to an invisible copy of the layout in a window just above the desktop icons. It only
///   takes the mouse while the pointer is over a widget; elsewhere clicks fall through to Finder.
/// - Editing happens in separate full-screen windows while other apps are hidden.
@MainActor
public final class OverlayController {
    public static let shared = OverlayController()

    private var effectViews: [String: OverlayEffectsView] = [:]      // by stableDisplayID
    private var widgetWindows: [String: DesktopWidgetWindow] = [:]   // by stableDisplayID
    private var editorWindows: [OverlayEditorWindow] = []
    private var appsHiddenForEditing: [NSRunningApplication] = []
    private var hiddenOwnWindows: [NSWindow] = []
    private var mouseMonitors: [Any] = []
    private var widgetsHidden = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        OverlayStore.shared.$configs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configs in
                self?.effectViews.values.forEach { $0.applyEffects(from: configs) }
            }
            .store(in: &cancellables)
        startMouseTracking()
    }

    /// (Re)installs effects and widgets for one display on top of its wallpaper.
    func install(in contentView: NSView, wallpaperID: String, displayID: String, screen: NSScreen) {
        effectViews[displayID]?.removeFromSuperview()
        let effects = OverlayEffectsView(frame: contentView.bounds, wallpaperID: wallpaperID, displayID: displayID,
                                         insets: Self.safeInsets(for: screen))
        effects.autoresizingMask = [.width, .height]
        contentView.addSubview(effects, positioned: .above, relativeTo: nil)
        effects.applyEffects(from: OverlayStore.shared.configs)
        effectViews[displayID] = effects

        let window = widgetWindows[displayID] ?? DesktopWidgetWindow(screen: screen)
        window.setFrame(screen.frame, display: false)
        window.show(wallpaperID: wallpaperID, displayID: displayID, insets: Self.safeInsets(for: screen))
        widgetWindows[displayID] = window
        if widgetsHidden { window.orderOut(nil) }

        // Drop windows for displays that are gone.
        let live = Set(NSScreen.screens.map(\.stableDisplayID))
        for (id, stale) in widgetWindows where !live.contains(id) {
            stale.orderOut(nil)
            widgetWindows[id] = nil
            effectViews[id] = nil
        }
    }

    /// Pauses particle effects together with the wallpaper to save energy (never while editing).
    func setPaused(_ paused: Bool, displayID: String) {
        effectViews[displayID]?.setEffectsPaused(paused && !isEditing)
    }

    /// Keeps widget windows on every Space and display, like the wallpaper windows: macOS can
    /// drop a low-level window from a Space it just switched to, so it is re-ordered when needed.
    func ensureWidgetWindowsVisible() {
        guard !widgetsHidden else { return }
        for window in widgetWindows.values {
            window.collectionBehavior = DesktopWidgetWindow.behavior
            if !window.isVisible || !window.isOnActiveSpace {
                window.orderFrontRegardless()
            }
        }
    }

    /// Follows "Hide Wallpapers".
    func setWidgetsHidden(_ hidden: Bool) {
        guard hidden != widgetsHidden else { return }
        widgetsHidden = hidden
        widgetWindows.values.forEach { hidden ? $0.orderOut(nil) : $0.orderFrontRegardless() }
    }

    /// Area widgets must stay inside: below the menu bar, clear of the Dock and screen edges.
    static func safeInsets(for screen: NSScreen) -> EdgeInsets {
        let frame = screen.frame, visible = screen.visibleFrame
        return EdgeInsets(
            top: max(frame.maxY - visible.maxY, screen.safeAreaInsets.top) + 12,
            leading: (visible.minX - frame.minX) + 12,
            bottom: (visible.minY - frame.minY) + 12,
            trailing: (frame.maxX - visible.maxX) + 12
        )
    }

    // MARK: Click-through

    /// Lets the widget window take the mouse only while the pointer is over a widget.
    private func startMouseTracking() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            MainActor.assumeIsolated { OverlayController.shared.updateMousePassThrough() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            MainActor.assumeIsolated { OverlayController.shared.updateMousePassThrough() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func updateMousePassThrough() {
        let mouse = NSEvent.mouseLocation
        for (displayID, window) in widgetWindows {
            let frame = window.frame
            guard frame.contains(mouse) else {
                window.setInteractive(false)
                continue
            }
            let local = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
            let overWidget = WidgetHitRegistry.shared.contains(local, displayID: displayID)
            window.setInteractive(overWidget)
        }
    }

    // MARK: Editing

    public var isEditing: Bool { OverlayEditorState.shared.isEditing }

    public func beginEditing() {
        guard !isEditing else {
            editorWindows.forEach { $0.makeKeyAndOrderFront(nil) }
            return
        }
        OverlayEditorState.shared.selectedWidgetID = nil
        OverlayEditorState.shared.isEditing = true
        WidgetCatalog.shared.refresh()
        hideOtherApps()
        effectViews.values.forEach { $0.setEffectsPaused(false) }
        for screen in NSScreen.screens {
            guard let wallpaperID = WallpaperManager.shared.currentWallpaperID(forDisplay: screen.stableDisplayID) else { continue }
            let window = OverlayEditorWindow(screen: screen)
            let root = OverlayCanvasView(
                wallpaperID: wallpaperID,
                displayID: screen.stableDisplayID,
                mode: .editor,
                insets: Self.safeInsets(for: screen),
                onDone: { OverlayController.shared.endEditing() }
            )
            window.contentView = NSHostingView(rootView: root)
            window.onEscape = { OverlayController.shared.endEditing() }
            window.makeKeyAndOrderFront(nil)
            editorWindows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func endEditing() {
        guard isEditing else { return }
        editorWindows.forEach { $0.orderOut(nil) }
        editorWindows.removeAll()
        OverlayEditorState.shared.selectedWidgetID = nil
        OverlayEditorState.shared.isEditing = false
        appsHiddenForEditing.forEach { $0.unhide() }
        appsHiddenForEditing.removeAll()
        hiddenOwnWindows.forEach { $0.orderFront(nil) }
        hiddenOwnWindows.removeAll()
        WallpaperManager.shared.refreshOverlayPauseState()
    }

    /// Clears the desktop for editing: other visible apps are hidden (as with ⌥⌘H) and our own
    /// regular windows step aside, so the wallpaper and its widgets are fully in view.
    private func hideOtherApps() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        appsHiddenForEditing = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ownPID
        }
        appsHiddenForEditing.forEach { $0.hide() }
        hiddenOwnWindows = NSApp.windows.filter {
            $0.isVisible && $0.level == .normal && !($0 is WallpaperWindow) && !($0 is OverlayEditorWindow)
        }
        hiddenOwnWindows.forEach { $0.orderOut(nil) }
    }
}

/// Canvas-local widget frames per display, used for click-through decisions.
@MainActor
final class WidgetHitRegistry {
    static let shared = WidgetHitRegistry()
    private var frames: [String: [CGRect]] = [:]

    func set(_ rects: [CGRect], displayID: String) { frames[displayID] = rects }
    func contains(_ point: CGPoint, displayID: String) -> Bool {
        frames[displayID]?.contains { $0.insetBy(dx: -2, dy: -2).contains(point) } ?? false
    }
}

// MARK: - Windows

/// Invisible click layer for one display, just above the desktop icons. It mirrors the widget
/// layout and takes the mouse only while the pointer is over a widget.
final class DesktopWidgetWindow: NSPanel {
    func setInteractive(_ interactive: Bool) {
        if ignoresMouseEvents == interactive { ignoresMouseEvents = !interactive }
    }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = Self.behavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        becomesKeyOnlyIfNeeded = true
    }

    /// On every Space (including next to fullscreen apps), fixed in place during Space swipes,
    /// and left out of Exposé / window cycling.
    static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(wallpaperID: String, displayID: String, insets: EdgeInsets) {
        contentView = FirstMouseHostingView(rootView: OverlayCanvasView(
            wallpaperID: wallpaperID, displayID: displayID, mode: .hitLayer, insets: insets, onDone: {}
        ))
        orderFrontRegardless()
    }
}

/// Lets a single click on a widget act at once, without first activating Nimbscape.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Full-screen, transparent window used while arranging widgets.
final class OverlayEditorWindow: NSWindow {
    var onEscape: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Effects (inside the wallpaper window)

final class OverlayEffectsView: NSView {
    let wallpaperID: String
    private let widgetsView: NSHostingView<OverlayCanvasView>
    private let blurView = NSVisualEffectView()
    private let dimLayer = CALayer()
    private let emitter = CAEmitterLayer()
    private var currentEffects: OverlayEffects?

    init(frame: NSRect, wallpaperID: String, displayID: String, insets: EdgeInsets) {
        self.wallpaperID = wallpaperID
        self.widgetsView = NSHostingView(rootView: OverlayCanvasView(
            wallpaperID: wallpaperID, displayID: displayID, mode: .desktop, insets: insets, onDone: {}
        ))
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        blurView.blendingMode = .withinWindow
        blurView.material = .fullScreenUI
        blurView.state = .active
        blurView.frame = bounds
        blurView.autoresizingMask = [.width, .height]
        blurView.isHidden = true
        addSubview(blurView)

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        layer?.addSublayer(dimLayer)

        layer?.addSublayer(emitter)

        widgetsView.frame = bounds
        widgetsView.autoresizingMask = [.width, .height]
        addSubview(widgetsView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        emitter.frame = bounds
        configureEmitterGeometry()
        CATransaction.commit()
    }

    func applyEffects(from configs: [String: OverlayConfig]) {
        let effects = configs[wallpaperID]?.effects ?? OverlayEffects()
        guard effects != currentEffects else { return }
        let previous = currentEffects
        currentEffects = effects

        if effects.blur != previous?.blur {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                blurView.animator().isHidden = !effects.blur
            }
        }
        if effects.dim != previous?.dim {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = dimLayer.presentation()?.opacity ?? dimLayer.opacity
            fade.toValue = Float(effects.dim)
            fade.duration = 0.25
            dimLayer.opacity = Float(effects.dim)
            dimLayer.add(fade, forKey: "dim")
        }
        if effects.particles != previous?.particles {
            emitter.emitterCells = ParticleFactory.cells(for: effects.particles)
            configureEmitterGeometry()
        }
        // Density scales births of the existing cells, so moving the slider never resets the scene.
        emitter.birthRate = Float(effects.particleDensity * 2)
    }

    func setEffectsPaused(_ paused: Bool) {
        let target: Float = paused ? 0 : 1
        guard emitter.speed != target else { return }
        // Freeze or resume the particles where they are (no jump in the particle timeline).
        let localTime = emitter.convertTime(CACurrentMediaTime(), from: nil)
        emitter.speed = target
        emitter.timeOffset = localTime
        emitter.beginTime = CACurrentMediaTime()
    }

    private func configureEmitterGeometry() {
        switch currentEffects?.particles ?? .none {
        case .snow, .rain:
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + 30)
            emitter.emitterSize = CGSize(width: bounds.width * 1.4, height: 1)
        case .embers:
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: -10)
            emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        case .fireflies:
            emitter.emitterShape = .rectangle
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            emitter.emitterSize = bounds.size
        case .none:
            break
        }
    }
}

/// Particle cells with depth: far layers are small, dim and slow; near layers big, bright and fast.
enum ParticleFactory {
    static func cells(for particles: OverlayParticles) -> [CAEmitterCell]? {
        switch particles {
        case .none:
            return nil
        case .snow:
            let flake = dot(diameter: 14, color: .white, softness: 0.55)
            return [
                snowLayer(flake, scale: 0.18, speed: 22, birth: 22, alpha: 0.55, drift: 3),
                snowLayer(flake, scale: 0.34, speed: 40, birth: 12, alpha: 0.8, drift: 7),
                snowLayer(flake, scale: 0.62, speed: 75, birth: 4, alpha: 0.95, drift: 12)
            ]
        case .rain:
            // Thin, long drops pre-tilted to match the wind; far drops faint and short, near ones bright.
            return [
                rainLayer(streakImage(length: 38), scale: 0.6, speed: 1100, birth: 140, alpha: 0.16),
                rainLayer(streakImage(length: 60), scale: 0.8, speed: 1500, birth: 70, alpha: 0.26),
                rainLayer(streakImage(length: 90), scale: 1.0, speed: 2000, birth: 18, alpha: 0.38)
            ]
        case .fireflies:
            let cell = CAEmitterCell()
            cell.contents = dot(diameter: 18, color: NSColor(calibratedRed: 1, green: 0.93, blue: 0.55, alpha: 1), softness: 1)
            cell.birthRate = 4
            cell.lifetime = 10
            cell.lifetimeRange = 4
            cell.velocity = 10
            cell.velocityRange = 9
            cell.emissionRange = .pi * 2
            cell.scale = 0.42
            cell.scaleRange = 0.25
            cell.alphaRange = 0.5
            cell.alphaSpeed = -0.08
            return [cell]
        case .embers:
            let cell = CAEmitterCell()
            cell.contents = dot(diameter: 12, color: NSColor(calibratedRed: 1, green: 0.62, blue: 0.25, alpha: 1), softness: 0.8)
            cell.birthRate = 12
            cell.lifetime = 9
            cell.lifetimeRange = 3
            cell.velocity = 65
            cell.velocityRange = 30
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi / 7
            cell.xAcceleration = 6
            cell.yAcceleration = 5
            cell.scale = 0.4
            cell.scaleRange = 0.25
            cell.scaleSpeed = -0.03
            cell.greenSpeed = -0.06
            cell.alphaSpeed = -0.1
            return [cell]
        }
    }

    private static func snowLayer(_ image: CGImage?, scale: CGFloat, speed: CGFloat, birth: Float, alpha: CGFloat, drift: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.birthRate = birth
        cell.lifetime = Float(1400 / speed)
        cell.velocity = speed
        cell.velocityRange = speed * 0.3
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 10
        cell.xAcceleration = drift          // gentle wind
        cell.yAcceleration = -speed * 0.05
        cell.scale = scale
        cell.scaleRange = scale * 0.35
        cell.spin = 0.3
        cell.spinRange = 1.2
        cell.color = NSColor(white: 1, alpha: alpha).cgColor
        cell.alphaRange = 0.2
        return cell
    }

    private static func rainLayer(_ image: CGImage?, scale: CGFloat, speed: CGFloat, birth: Float, alpha: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.birthRate = birth
        cell.lifetime = Float(1600 / speed)
        cell.velocity = speed
        cell.velocityRange = speed * 0.12
        cell.emissionLongitude = -.pi / 2 - rainTilt   // falling slightly sideways, like the streak
        cell.emissionRange = 0.015
        cell.scale = scale
        cell.scaleRange = scale * 0.25
        cell.color = NSColor(calibratedRed: 0.85, green: 0.9, blue: 1, alpha: alpha).cgColor
        cell.alphaRange = Float(alpha * 0.5)
        return cell
    }

    private static func dot(diameter: CGFloat, color: NSColor, softness: CGFloat) -> CGImage? {
        let size = Int(diameter * 2)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let colors = [c.withAlphaComponent(1).cgColor, c.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [1 - softness, 1]) else { return nil }
        let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size) / 2, options: [])
        return ctx.makeImage()
    }

    /// Wind tilt of the rain, in radians from vertical.
    private static let rainTilt: CGFloat = 0.16

    /// A 1.5 pt wide drop, bright at the head and fading towards the tail, drawn at the rain's tilt
    /// (emitter particles don't rotate to their direction of travel).
    private static func streakImage(length: CGFloat) -> CGImage? {
        let width = Int(ceil(length * sin(rainTilt))) + 4
        let height = Int(ceil(length * cos(rainTilt))) + 4
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CG origin is bottom-left: the head (bottom, leading edge of the fall) is at low y.
        let head = CGPoint(x: 2, y: 2)
        let tail = CGPoint(x: 2 + length * sin(rainTilt), y: 2 + length * cos(rainTilt))
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.5)
        let steps = 12
        for i in 0..<steps {
            let t0 = CGFloat(i) / CGFloat(steps), t1 = CGFloat(i + 1) / CGFloat(steps)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(1 - t0 * 0.95).cgColor)
            ctx.move(to: CGPoint(x: head.x + (tail.x - head.x) * t0, y: head.y + (tail.y - head.y) * t0))
            ctx.addLine(to: CGPoint(x: head.x + (tail.x - head.x) * t1, y: head.y + (tail.y - head.y) * t1))
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}
