import Cocoa
import SwiftUI
import Carbon

public class QuickSwitcherHUDPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

@MainActor
public final class QuickSwitcherController: ObservableObject {
    @Published public var query: String = "" {
        didSet { selectedIndex = 0 }
    }
    @Published public var selectedIndex: Int = 0
    @Published public var targetDisplayIndex: Int = 0

    public var filteredWallpapers: [WallpaperItem] {
        let all = WallpaperStore.shared.wallpapers
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return all }
        return all.filter { item in
            item.title.lowercased().contains(q)
                || item.tags.contains(where: { $0.lowercased().contains(q) })
                || item.type.rawValue.lowercased().contains(q)
        }
    }

    public var selectedItem: WallpaperItem? {
        let items = filteredWallpapers
        guard !items.isEmpty else { return nil }
        let safeIdx = max(0, min(selectedIndex, items.count - 1))
        return items[safeIdx]
    }

    public func moveSelection(delta: Int) {
        let count = filteredWallpapers.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    public func cycleTargetDisplay() {
        let count = WallpaperManager.shared.connectedDisplays.count
        guard count > 1 else {
            targetDisplayIndex = 0
            return
        }
        targetDisplayIndex = (targetDisplayIndex + 1) % (count + 1)
    }

    public func applySelected() {
        guard let item = selectedItem else { return }
        let displays = WallpaperManager.shared.connectedDisplays
        if targetDisplayIndex > 0, targetDisplayIndex - 1 < displays.count {
            let display = displays[targetDisplayIndex - 1]
            if WallpaperStore.shared.displayLayoutMode != .perDisplay {
                WallpaperStore.shared.displayLayoutMode = .perDisplay
            }
            WallpaperStore.shared.setActiveWallpaper(item.id, forStableDisplayID: display.id)
        } else {
            WallpaperStore.shared.setActiveWallpaper(item.id)
        }
    }

    public func reset() {
        query = ""
        selectedIndex = 0
    }
}

private func nimbscapeHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    Task { @MainActor in
        switch id {
        case 1:
            QuickSwitcherManager.shared.toggle()
        case 2:
            WallpaperManager.shared.togglePlayPause()
        case 3:
            PlaylistStore.shared.advanceNext()
        case 4:
            WallpaperManager.shared.toggleHideWallpapers()
        case 5:
            AppPreferences.shared.isMuted.toggle()
        default:
            break
        }
    }
    return noErr
}

@MainActor
public class QuickSwitcherManager: NSObject, NSWindowDelegate {
    public static let shared = QuickSwitcherManager()

    private var panel: QuickSwitcherHUDPanel?
    private let controller = QuickSwitcherController()
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var localKeyMonitor: Any?

    private let signature: OSType = 0x4E494D42

    private override init() {
        super.init()
    }

    public func registerGlobalHotkeys() {
        unregisterGlobalHotkeys()

        guard AppPreferences.shared.quickSwitcherHotkeyEnabled else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            nimbscapeHotKeyHandler,
            1,
            &eventSpec,
            nil,
            &handlerRef
        )
        if installStatus == noErr {
            self.eventHandlerRef = handlerRef
        }

        registerHotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey), id: 1)

        registerHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey), id: 2)

        registerHotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | shiftKey), id: 3)

        registerHotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey), id: 4)

        registerHotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey), id: 5)
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        }
    }

    public func unregisterGlobalHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    public func toggle() {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            show()
        }
    }

    public func show() {
        StatusItemManager.shared.closePopover()
        controller.reset()

        let hudSize = NSSize(width: 660, height: 410)
        let targetScreen = activeScreenForCursor() ?? NSScreen.main
        let origin: NSPoint
        if let screen = targetScreen {
            origin = NSPoint(
                x: screen.visibleFrame.midX - hudSize.width / 2,
                y: screen.visibleFrame.midY - hudSize.height / 2 + 40
            )
        } else {
            origin = NSPoint(x: 300, y: 300)
        }

        let contentView = QuickSwitcherView(
            controller: controller,
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        let hosting = NSHostingController(rootView: contentView)

        if let existing = panel {
            existing.contentViewController = hosting
            existing.setFrame(NSRect(origin: origin, size: hudSize), display: true)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            installKeyMonitor()
            return
        }

        let p = QuickSwitcherHUDPanel(
            contentRect: NSRect(origin: origin, size: hudSize),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        p.contentViewController = hosting

        self.panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    public func dismiss() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else {
                return event
            }
            switch event.keyCode {
            case 53:
                self.dismiss()
                return nil
            case 125:
                self.controller.moveSelection(delta: 1)
                return nil
            case 126:
                self.controller.moveSelection(delta: -1)
                return nil
            case 48:
                self.controller.cycleTargetDisplay()
                return nil
            case 36, 76:
                self.controller.applySelected()
                self.dismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    private func activeScreenForCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    public func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}
