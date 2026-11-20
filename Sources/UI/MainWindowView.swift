import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum SidebarSection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case favorites = "Favorites"
    case playlists = "Playlists"
    case discover = "Discover"
    case sceneEditor = "Scene Editor"
    case displays = "Displays & Profiles"
    case create = "Create"
    case settings = "Settings"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .installed: return "square.grid.2x2"
        case .favorites: return "heart"
        case .playlists: return "music.note.list"
        case .discover: return "safari"
        case .sceneEditor: return "slider.horizontal.below.square.filled.and.square"
        case .displays: return "display.2"
        case .create: return "plus.circle"
        case .settings: return "gearshape"
        }
    }
}

public struct MainWindowView: View {
    @ObservedObject var store = WallpaperStore.shared
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var power = PowerMonitor.shared
    @ObservedObject var manager = WallpaperManager.shared
    @ObservedObject var scanner = FolderCollectionScanner.shared
    @ObservedObject var appRules = AppRulesStore.shared
    @ObservedObject var profiles = ProfileStore.shared
    @ObservedObject var audioVisualizer = AudioVisualizerEngine.shared
    @ObservedObject var screensaver = ScreensaverEngine.shared

    @State var selectedSection: SidebarSection = .installed
    @State var selectedWallpaperID: String? = WallpaperStore.shared.activeWallpaperId
    @State var showInspector: Bool = true
    @State var searchText: String = ""
    @State var typeFilter: WallpaperType? = nil
    @State var importErrorMessage: String? = nil
    @State var newProfileName: String = ""
    @State var urlTitle: String = ""
    @State var urlInput: String = ""
    @State var discoverTabMode: Int = 0

    public init() {}

    var showsInspectorColumn: Bool {
        showInspector && (selectedSection == .installed || selectedSection == .favorites)
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 205, ideal: 215, max: 245)
        } detail: {
            VStack(spacing: 0) {
                if let reason = power.powerPauseReason, !power.overrideSystemPause {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.slash.fill")
                            .foregroundColor(.orange)
                        Text("Playback Auto-Paused — \(reason)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Button("Resume Anyway (Override)") {
                            power.overrideSystemPause = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.14))
                    Divider()
                }

                HStack(spacing: 0) {
                    Group {
                        switch selectedSection {
                        case .installed:
                            libraryView(favoritesOnly: false)
                        case .favorites:
                            libraryView(favoritesOnly: true)
                        case .playlists:
                            PlaylistsView()
                        case .discover:
                            discoverView
                        case .sceneEditor:
                            SceneEditorView(onSavedAndApplied: { item in
                                selectedWallpaperID = item.id
                            })
                        case .displays:
                            displaysView
                        case .create:
                            createView
                        case .settings:
                            settingsView
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

                    if showsInspectorColumn {
                        Divider()
                        PropertiesInspectorPanel(
                            wallpaperID: selectedWallpaperID ?? store.activeWallpaperId
                        )
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    let isPausedVisual = preferences.isPaused || manager.isSlowStopped
                    Button(action: { manager.togglePlayPause() }) {
                        Label(isPausedVisual ? "Play" : "Pause", systemImage: isPausedVisual ? "play.fill" : "pause.fill")
                    }
                    .keyboardShortcut("p", modifiers: .command)

                    Button(action: { PlaylistStore.shared.advanceNext() }) {
                        Label("Next Wallpaper", systemImage: "forward.end.fill")
                    }

                    Button(action: { OverlayController.shared.beginEditing() }) {
                        Label("Customize Wallpaper", systemImage: "slider.horizontal.below.square.and.square.filled")
                    }
                    .help("Add widgets and effects on top of the wallpaper")
                    .help("Next Wallpaper (⌘⇧N)")

                    Button(action: { preferences.isMuted.toggle() }) {
                        Label(preferences.isMuted ? "Unmute" : "Mute", systemImage: preferences.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .keyboardShortcut("m", modifiers: .command)

                    Button(action: { manager.toggleHideWallpapers() }) {
                        Label(manager.isWallpapersHidden ? "Show Desktop" : "Hide Desktop", systemImage: manager.isWallpapersHidden ? "eye.slash.fill" : "eye")
                    }
                    .help("Hide / Show Wallpapers (⌘⇧H)")

                    Button(action: { QuickSwitcherManager.shared.show() }) {
                        Label("Quick Switcher", systemImage: "sparkle.magnifyingglass")
                    }
                    .help("Quick Switcher (⌘⇧W)")

                    if selectedSection == .installed || selectedSection == .favorites {
                        Button(action: { showInspector.toggle() }) {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
            }
        }
        .frame(minWidth: 1020, minHeight: 660)
    }

    func libraryView(favoritesOnly: Bool) -> some View {
        let items = store.wallpapers.filter { item in
            if favoritesOnly && !item.isFavorite { return false }
            if let filter = typeFilter, item.type != filter { return false }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !q.isEmpty {
                let matchesTitle = item.title.lowercased().contains(q)
                let matchesTag = item.tags.contains(where: { $0.lowercased().contains(q) })
                if !matchesTitle && !matchesTag { return false }
            }
            return true
        }

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Filter wallpapers...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(8)

                Picker("Type", selection: $typeFilter) {
                    Text("All Types").tag(WallpaperType?.none)
                    Text("Video").tag(WallpaperType?.some(.video))
                    Text("Web / HTML").tag(WallpaperType?.some(.web))
                    Text("URL").tag(WallpaperType?.some(.url))
                    Text("Image").tag(WallpaperType?.some(.image))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: favoritesOnly ? "heart.slash" : "square.grid.2x2")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(favoritesOnly ? "No Favorite Wallpapers Yet" : "No Matching Wallpapers")
                        .font(.headline)
                    Text(favoritesOnly ? "Click the heart icon on any wallpaper card to pin it here." : "Try clearing your search or import new wallpapers.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 290), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in
                            LibraryWallpaperCard(
                                item: item,
                                isSelected: selectedWallpaperID == item.id,
                                isActive: item.id == store.activeWallpaperId,
                                onSelect: {
                                    selectedWallpaperID = item.id
                                },
                                onApply: {
                                    selectedWallpaperID = item.id
                                    store.setActiveWallpaper(item.id)
                                },
                                onToggleFavorite: {
                                    store.toggleFavorite(id: item.id)
                                },
                                onDelete: {
                                    store.removeWallpaper(id: item.id)
                                }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}
