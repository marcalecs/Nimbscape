import Cocoa
import SwiftUI

@MainActor
public class StatusItemManager: NSObject {
    public static let shared = StatusItemManager()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "Nimbscape") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "NS"
            }
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let statusPopover = NSPopover()
        statusPopover.contentSize = NSSize(width: 324, height: 448)
        statusPopover.behavior = .transient
        statusPopover.animates = false
        statusPopover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                onOpenMainWindow: { [weak self] in
                    self?.closePopover()
                    self?.openMainWindow()
                },
                onOpenQuickSwitcher: { [weak self] in
                    self?.closePopover()
                    QuickSwitcherManager.shared.show()
                },
                onQuit: { [weak self] in
                    self?.quitApp()
                }
            )
        )
        self.popover = statusPopover
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            closePopover()
            showContextMenu(anchoredTo: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.close()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            if let win = popover.contentViewController?.view.window {
                win.animationBehavior = .none
                win.makeKey()
            }
        }
    }

    public func closePopover() {
        if popover?.isShown == true {
            popover.close()
        }
    }

    private func showContextMenu(anchoredTo button: NSStatusBarButton) {
        let menu = NSMenu()

        let activeTitle = WallpaperStore.shared.activeWallpaper?.title ?? "None"
        let header = NSMenuItem(title: "Nimbscape · \(activeTitle)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Control Center", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let switcherItem = NSMenuItem(title: "Quick Switcher", action: #selector(openQuickSwitcher), keyEquivalent: "W")
        switcherItem.keyEquivalentModifierMask = [.command, .shift]
        switcherItem.target = self
        menu.addItem(switcherItem)

        menu.addItem(NSMenuItem.separator())

        let playPauseItem = NSMenuItem(
            title: (AppPreferences.shared.isPaused || WallpaperManager.shared.isSlowStopped) ? "Play Wallpaper" : "Pause Wallpaper",
            action: #selector(togglePlayPause),
            keyEquivalent: "p"
        )
        playPauseItem.target = self
        menu.addItem(playPauseItem)

        let nextItem = NSMenuItem(title: "Next Wallpaper", action: #selector(nextWallpaper), keyEquivalent: "N")
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        nextItem.target = self
        menu.addItem(nextItem)

        let hideItem = NSMenuItem(
            title: WallpaperManager.shared.isWallpapersHidden ? "Show Wallpapers" : "Hide Wallpapers",
            action: #selector(toggleHideWallpapers),
            keyEquivalent: "H"
        )
        hideItem.keyEquivalentModifierMask = [.command, .shift]
        hideItem.target = self
        menu.addItem(hideItem)

        let muteItem = NSMenuItem(
            title: AppPreferences.shared.isMuted ? "Unmute Audio" : "Mute Audio",
            action: #selector(toggleMute),
            keyEquivalent: "m"
        )
        muteItem.target = self
        menu.addItem(muteItem)

        let saverItem = NSMenuItem(title: "Start Screensaver Now", action: #selector(startScreensaver), keyEquivalent: "")
        saverItem.target = self
        menu.addItem(saverItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Nimbscape", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc public func openMainWindow() {
        NSApp.unhide(nil)
        if let win = mainWindow {
            if win.isMiniaturized {
                win.deminiaturize(nil)
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: MainWindowView())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 980, height: 620)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Nimbscape"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.center()

        self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func openGallery() {
        openMainWindow()
    }

    @objc private func openQuickSwitcher() {
        QuickSwitcherManager.shared.show()
    }

    @objc private func togglePlayPause() {
        WallpaperManager.shared.togglePlayPause()
    }

    @objc private func nextWallpaper() {
        PlaylistStore.shared.advanceNext()
    }

    @objc private func toggleHideWallpapers() {
        WallpaperManager.shared.toggleHideWallpapers()
    }

    @objc private func startScreensaver() {
        ScreensaverEngine.shared.startScreensaver()
    }

    @objc private func toggleMute() {
        AppPreferences.shared.isMuted.toggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
