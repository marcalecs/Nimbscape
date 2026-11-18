import SwiftUI
import AppKit

public struct QuickSwitcherView: View {
    @ObservedObject var store = WallpaperStore.shared
    @ObservedObject var manager = WallpaperManager.shared
    @ObservedObject var controller: QuickSwitcherController

    let onDismiss: () -> Void

    @FocusState private var isSearchFocused: Bool

    public init(controller: QuickSwitcherController, onDismiss: @escaping () -> Void) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    private var targetDisplayLabel: String {
        if controller.targetDisplayIndex == 0 || manager.connectedDisplays.count <= 1 {
            return "All Displays"
        }
        let idx = controller.targetDisplayIndex - 1
        if idx >= 0 && idx < manager.connectedDisplays.count {
            return "Display \(manager.connectedDisplays[idx].index)"
        }
        return "All Displays"
    }

    public var body: some View {
        let filtered = controller.filteredWallpapers
        let selectedItem = controller.selectedItem

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)

                TextField("Search wallpapers by title, tag, or type...", text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isSearchFocused)

                Button(action: { controller.cycleTargetDisplay() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "display.2")
                            .font(.system(size: 11))
                        Text(targetDisplayLabel)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Press Tab to cycle target display")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            if filtered.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.title2)
                                        .foregroundColor(.secondary)
                                    Text("No matching wallpapers")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                            } else {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                                    let isSelected = (idx == min(controller.selectedIndex, filtered.count - 1))
                                    let isActive = (item.id == store.activeWallpaperId)

                                    HStack(spacing: 10) {
                                        Image(systemName: iconForType(item.type))
                                            .font(.system(size: 14))
                                            .foregroundColor(isSelected ? .white : .secondary)
                                            .frame(width: 20)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(isSelected ? .white : .primary)
                                                .lineLimit(1)
                                            Text(item.resolutionLabel ?? item.type.rawValue.uppercased())
                                                .font(.system(size: 10))
                                                .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                                        }

                                        Spacer()

                                        if item.isFavorite {
                                            Image(systemName: "heart.fill")
                                                .font(.system(size: 10))
                                                .foregroundColor(isSelected ? .white : .pink)
                                        }
                                        if isActive {
                                            Text("ACTIVE")
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(isSelected ? Color.white.opacity(0.25) : Color.green.opacity(0.2))
                                                .foregroundColor(isSelected ? .white : .green)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(isSelected ? Color.accentColor : Color.clear)
                                    .cornerRadius(8)
                                    .contentShape(Rectangle())
                                    .id(item.id)
                                    .onTapGesture {
                                        controller.selectedIndex = idx
                                        controller.applySelected()
                                        onDismiss()
                                    }
                                }
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: controller.selectedIndex) { _, newIdx in
                        if newIdx >= 0 && newIdx < filtered.count {
                            proxy.scrollTo(filtered[newIdx].id, anchor: .center)
                        }
                    }
                }
                .frame(width: 340)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    if let item = selectedItem {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.08))
                            if let previewPath = item.previewPath,
                               let nsImage = NSImage(contentsOfFile: previewPath) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .cornerRadius(12)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: iconForType(item.type))
                                        .font(.system(size: 36))
                                        .foregroundStyle(.tint)
                                    Text(item.type.rawValue.uppercased())
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .frame(height: 155)
                        .clipped()

                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            Label(item.type.rawValue.uppercased(), systemImage: iconForType(item.type))
                            if let res = item.resolutionLabel {
                                Text("·")
                                Text(res)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        if !item.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(item.tags.prefix(3), id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.08))
                                        .clipShape(Capsule())
                                }
                            }
                        }

                        Spacer()

                        Button(action: {
                            controller.applySelected()
                            onDismiss()
                        }) {
                            Label("Apply to \(targetDisplayLabel)", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Spacer()
                        Text("Select a wallpaper")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(spacing: 16) {
                shortcutHint(keys: "↑↓", label: "Navigate")
                shortcutHint(keys: "⇥", label: "Display")
                shortcutHint(keys: "↵", label: "Apply")
                shortcutHint(keys: "Esc", label: "Dismiss")
                Spacer()
                Text("Single Loop · No Playlists")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
        }
        .frame(width: 660, height: 410)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .onAppear {
            isSearchFocused = true
        }
    }

    private func shortcutHint(keys: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.1))
                .cornerRadius(4)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func iconForType(_ type: WallpaperType) -> String {
        switch type {
        case .video: return "film"
        case .web: return "sparkles"
        case .url: return "globe"
        case .image: return "photo"
        }
    }
}
