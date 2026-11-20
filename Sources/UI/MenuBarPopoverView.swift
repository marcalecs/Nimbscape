import SwiftUI
import AppKit

public struct MenuBarPopoverView: View {
    @ObservedObject var store = WallpaperStore.shared
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var power = PowerMonitor.shared
    @ObservedObject var manager = WallpaperManager.shared

    let onOpenMainWindow: () -> Void
    let onOpenQuickSwitcher: () -> Void
    let onQuit: () -> Void

    public init(
        onOpenMainWindow: @escaping () -> Void,
        onOpenQuickSwitcher: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenQuickSwitcher = onOpenQuickSwitcher
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.activeWallpaper?.title ?? "No Wallpaper")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()

                Text("\(preferences.globalFPSCap) FPS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
            }

            if let reason = power.powerPauseReason, !power.overrideSystemPause {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.slash.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-Paused")
                            .font(.system(size: 11, weight: .semibold))
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Override") {
                        power.overrideSystemPause = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.mini)
                }
                .padding(8)
                .background(Color.orange.opacity(0.14))
                .cornerRadius(10)
            } else if power.overrideSystemPause {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("Power Override Active")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Restore Auto") {
                        power.overrideSystemPause = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(8)
                .background(Color.green.opacity(0.12))
                .cornerRadius(10)
            }

            HStack(spacing: 8) {
                let showPlay = preferences.isPaused || manager.isSlowStopped
                Button(action: { manager.togglePlayPause() }) {
                    Label(showPlay ? "Play" : "Pause", systemImage: showPlay ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(showPlay ? .green : .secondary)

                Button(action: { PlaylistStore.shared.advanceNext() }) {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 22)
                }
                .buttonStyle(.bordered)
                .help("Next Wallpaper (⌘⇧N)")

                Button(action: { preferences.isMuted.toggle() }) {
                    Image(systemName: preferences.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 22)
                }
                .buttonStyle(.bordered)

                Button(action: { manager.toggleHideWallpapers() }) {
                    Image(systemName: manager.isWallpapersHidden ? "eye.slash.fill" : "eye")
                        .frame(width: 22)
                }
                .buttonStyle(.bordered)
                .tint(manager.isWallpapersHidden ? .orange : .secondary)
                .help("Hide / Show Wallpapers (⌘⇧H)")
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(value: $preferences.volume, in: 0...1)
                    .disabled(preferences.isMuted)
                Text("\(Int(preferences.volume * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Quick Switch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(store.displayLayoutMode.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Array(store.wallpapers.prefix(4))) { item in
                        let isActive = item.id == store.activeWallpaperId
                        Button(action: {
                            store.setActiveWallpaper(item.id)
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: symbolForType(item.type))
                                        .font(.system(size: 12))
                                        .foregroundColor(isActive ? .accentColor : .secondary)
                                    Spacer()
                                    if isActive {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(.green)
                                    }
                                }
                                Text(item.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .foregroundColor(.primary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Image(systemName: power.isOnBattery ? "battery.75percent" : "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundColor(power.isOnBattery ? .orange : .green)
                Text(powerTelemetryText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "repeat")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("Loop")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            Divider()

            HStack {
                Button(action: onOpenMainWindow) {
                    Label("Control Center", systemImage: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { OverlayController.shared.beginEditing() }) {
                    Image(systemName: "slider.horizontal.below.square.and.square.filled")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Customize Wallpaper: widgets & effects")

                Button(action: onOpenQuickSwitcher) {
                    Text("⌘⇧W")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Quick Switcher")

                Spacer()

                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Quit Nimbscape")
            }
        }
        .padding(14)
        .frame(width: 324, height: 448)
        .background(.ultraThinMaterial)
        .transaction { $0.animation = nil }
    }

    private var statusColor: Color {
        if power.isStoppedToFreeRAM { return .red }
        if !manager.isPlayingEffectively { return .orange }
        return .green
    }

    private var statusLabel: String {
        if manager.isWallpapersHidden { return "HIDDEN (⌘⇧H TO SHOW)" }
        if power.isStoppedToFreeRAM { return "STOPPED · RAM FREED" }
        if manager.isSlowStopping { return "DECELERATING..." }
        if manager.isSlowStopped { return "SETTLED · PAUSED" }
        if let reason = power.powerPauseReason, !power.overrideSystemPause { return "PAUSED · \(reason.uppercased())" }
        if preferences.isPaused { return "PAUSED" }
        return "ACTIVE · \(manager.connectedDisplays.count) DISPLAY\(manager.connectedDisplays.count == 1 ? "" : "S")"
    }

    private var powerTelemetryText: String {
        let source = power.isOnBattery ? "Battery" : "AC Power"
        if let level = power.batteryLevel {
            return "\(source) · \(level)%"
        }
        return source
    }

    private func symbolForType(_ type: WallpaperType) -> String {
        switch type {
        case .video: return "film"
        case .web: return "sparkles"
        case .url: return "globe"
        case .image: return "photo"
        }
    }
}
