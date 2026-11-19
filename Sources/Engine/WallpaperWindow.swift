import Cocoa

public class WallpaperWindow: NSWindow {
    public let targetScreen: NSScreen?
    public let stableDisplayID: String

    public init(screen: NSScreen) {
        self.targetScreen = screen
        self.stableDisplayID = screen.stableDisplayID
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        configure()
    }

    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        self.targetScreen = nil
        self.stableDisplayID = NSScreen.main?.stableDisplayID ?? "main"
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: backingStoreType,
            defer: flag
        )
        configure()
    }

    private func configure() {
        let belowIconsLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        self.level = NSWindow.Level(rawValue: belowIconsLevel)
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.canHide = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.ignoresMouseEvents = !AppPreferences.shared.interactiveMode

        if let contentView = self.contentView {
            contentView.wantsLayer = true
            contentView.clipsToBounds = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        ensureVisibleOnDesktop(forceReattach: true)
    }

    public var isActuallyOnScreen: Bool {
        let windowNumber = self.windowNumber
        guard windowNumber > 0,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]],
              let info = list.first else {
            return false
        }
        return (info[kCGWindowIsOnscreen as String] as? Int) == 1
    }

    @discardableResult
    public func ensureVisibleOnDesktop(frameOverride: NSRect? = nil, forceReattach: Bool = false) -> Bool {
        let belowIconsLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        let expectedFrame = frameOverride ?? targetScreen?.frame
        let needsLevelFix = (self.level.rawValue != belowIconsLevel)
        let needsFrameFix = (expectedFrame != nil && self.frame != expectedFrame!)
        let currentlyOnScreen = self.isVisible && self.isOnActiveSpace

        if !forceReattach && currentlyOnScreen && !needsLevelFix && !needsFrameFix {
            return false
        }

        if needsLevelFix {
            self.level = NSWindow.Level(rawValue: belowIconsLevel)
        }
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        if let expectedFrame, needsFrameFix {
            self.setFrame(expectedFrame, display: true)
        }

        if !currentlyOnScreen && !forceReattach {
            self.orderOut(nil)
        }
        self.orderFrontRegardless()
        return true
    }

    public func setBackdropImage(_ image: NSImage?) {
        guard let layer = self.contentView?.layer else { return }
        if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            layer.contents = cgImage
            layer.contentsGravity = .resizeAspectFill
        } else {
            layer.contents = nil
        }
    }

    public override var canBecomeKey: Bool {
        return false
    }

    public override var canBecomeMain: Bool {
        return false
    }

    public func updateInteractiveMode(_ enabled: Bool) {
        self.ignoresMouseEvents = !enabled
    }
}

public class DisplayIdentifyHUDWindow: NSWindow {
    public init(screen: NSScreen, index: Int) {
        let hudSize = NSSize(width: 340, height: 150)
        let origin = NSPoint(
            x: screen.frame.midX - hudSize.width / 2,
            y: screen.frame.midY - hudSize.height / 2
        )
        super.init(
            contentRect: NSRect(origin: origin, size: hudSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isReleasedWhenClosed = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: hudSize))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 22
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let titleLabel = NSTextField(labelWithString: "Display \(index)")
        titleLabel.font = NSFont.systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 16, y: 66, width: hudSize.width - 32, height: 48)

        let pixelW = Int(screen.frame.width * screen.backingScaleFactor)
        let pixelH = Int(screen.frame.height * screen.backingScaleFactor)
        let subtitleLabel = NSTextField(labelWithString: "\(screen.localizedName) · \(pixelW)×\(pixelH)")
        subtitleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        subtitleLabel.alignment = .center
        subtitleLabel.frame = NSRect(x: 16, y: 30, width: hudSize.width - 32, height: 22)

        visualEffect.addSubview(titleLabel)
        visualEffect.addSubview(subtitleLabel)
        self.contentView = visualEffect
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
