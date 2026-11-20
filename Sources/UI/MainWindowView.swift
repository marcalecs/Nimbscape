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

    @State private var selectedSection: SidebarSection = .installed
    @State private var selectedWallpaperID: String? = WallpaperStore.shared.activeWallpaperId
    @State private var showInspector: Bool = true
    @State private var searchText: String = ""
    @State private var typeFilter: WallpaperType? = nil
    @State private var importErrorMessage: String? = nil
    @State private var newProfileName: String = ""
    @State private var discoverTabMode: Int = 0

    public init() {}

    private var showsInspectorColumn: Bool {
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

    private func libraryView(favoritesOnly: Bool) -> some View {
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

    private var discoverView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discover Live Wallpapers")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Browse 1080p & 4K live wallpapers or scan a local folder of wallpaper packages.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker("", selection: $discoverTabMode) {
                    Text("HD Catalog").tag(0)
                    Text("Local Folder").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if discoverTabMode == 0 {
                HDCatalogGridView(
                    onImportedAndApplied: { item in
                        selectedWallpaperID = item.id
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                localCollectionScannerView
            }
        }
        .padding(18)
    }

    private var localCollectionScannerView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Local Folder Collection Scanner")
                    .font(.headline)
                Spacer()
                Button("Choose Folder...") {
                    chooseCollectionFolder()
                }
                .buttonStyle(.bordered)

                Button(action: { scanner.scan() }) {
                    Label(scanner.isScanning ? "Scanning..." : "Scan Folder", systemImage: "shippingbox")
                }
                .buttonStyle(.borderedProminent)
                .disabled(scanner.isScanning)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                Text(preferences.collectionFolderPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let result = scanner.lastResult {
                    let newCount = result.candidates.filter { !$0.isAlreadyImported }.count
                    if newCount > 0 {
                        Button("Import All New (\(newCount))") {
                            scanner.importAllNew()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            if let error = scanner.lastError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error.localizedDescription)
                        .font(.subheadline)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(10)
            } else if let result = scanner.lastResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if result.candidates.isEmpty {
                            Text("No compatible video, web, or image wallpaper packages found in this directory.")
                                .foregroundColor(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 14)], spacing: 14) {
                                ForEach(result.candidates) { candidate in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(candidate.item.title)
                                            .font(.headline)
                                            .lineLimit(1)
                                        HStack {
                                            Text(candidate.item.type.rawValue.uppercased())
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.15))
                                                .clipShape(Capsule())
                                            if let res = candidate.item.resolutionLabel {
                                                Text(res)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        HStack {
                                            Button(candidate.isAlreadyImported ? "Added" : "Import") {
                                                scanner.importCandidate(candidate, activate: false)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(candidate.isAlreadyImported)
                                            .controlSize(.small)

                                            if !candidate.isAlreadyImported {
                                                Button("Import & Apply") {
                                                    scanner.importCandidate(candidate, activate: true)
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                            }
                                        }
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.05))
                                    .cornerRadius(12)
                                }
                            }
                        }

                        if !result.skipped.isEmpty {
                            DisclosureGroup("Skipped Folders (\(result.skipped.count))") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(result.skipped) { skip in
                                        HStack(alignment: .top) {
                                            Text(skip.folderName)
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            Text("— \(skip.reason)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.top, 6)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 38))
                        .foregroundColor(.secondary)
                    Text("Click \"Scan Folder\" to detect local wallpaper packages.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    private var displaysView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Display & Multi-Monitor Mode")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure how single looping wallpapers map across your connected displays.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { manager.identifyDisplays() }) {
                    Label("Identify Displays", systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 12) {
                ForEach(DisplayLayoutMode.allCases, id: \.self) { mode in
                    let selected = store.displayLayoutMode == mode
                    Button(action: { store.displayLayoutMode = mode }) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: mode.symbolName)
                                    .font(.title3)
                                    .foregroundColor(selected ? .accentColor : .secondary)
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            Text(mode.displayName)
                                .font(.headline)
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Text("Connected Displays (\(manager.connectedDisplays.count))")
                .font(.headline)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(manager.connectedDisplays) { display in
                        let assigned = store.wallpaper(forStableDisplayID: display.id)
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.16))
                                    .frame(width: 64, height: 42)
                                Text("\(display.index)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Display \(display.index) — \(display.name)")
                                        .font(.headline)
                                    if display.isMain {
                                        Text("MAIN")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(display.resolutionText) (Logical \(display.logicalResolutionText))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if store.displayLayoutMode == .perDisplay {
                                Picker("Wallpaper", selection: Binding(
                                    get: { assigned?.id ?? store.activeWallpaperId },
                                    set: { newID in
                                        store.setActiveWallpaper(newID, forStableDisplayID: display.id)
                                    }
                                )) {
                                    ForEach(store.wallpapers) { wp in
                                        Text(wp.title).tag(wp.id)
                                    }
                                }
                                .frame(width: 230)
                            } else {
                                Text(assigned?.title ?? "—")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(12)
                    }

                    Divider()
                        .padding(.vertical, 6)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Saved Display Profiles")
                                .font(.headline)
                            Spacer()
                            TextField("Profile name...", text: $newProfileName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                            Button("Save Current Setup") {
                                profiles.saveCurrentAsProfile(name: newProfileName)
                                newProfileName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        if profiles.profiles.isEmpty {
                            Text("No saved profiles yet. Save your current displays & layout to switch in 1 click.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(profiles.profiles) { prof in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(prof.name)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Text("\(prof.layoutMode.displayName) · \(prof.displayAssignments.count) display mapping(s)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button("Apply") {
                                        profiles.applyProfile(prof)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    Button(action: { profiles.deleteProfile(id: prof.id) }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(10)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
    }

    @State private var urlTitle: String = ""
    @State private var urlInput: String = ""

    private var createView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Create / Import Dynamic Wallpaper")
                .font(.title2)
                .fontWeight(.bold)

            if let err = importErrorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                    Text(err)
                        .font(.subheadline)
                    Spacer()
                    Button("Dismiss") { importErrorMessage = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(12)
                .background(Color.red.opacity(0.14))
                .cornerRadius(10)
            }

            HStack(spacing: 16) {
                createTile(title: "Video File", subtitle: "MP4, MOV, M4V, WebM", icon: "video.badge.plus", color: .blue) {
                    importVideo()
                }
                createTile(title: "Wallpaper Folder", subtitle: "project.json or HTML5", icon: "folder.badge.gearshape", color: .purple) {
                    importFolder()
                }
                createTile(title: "Image / Animated GIF", subtitle: "GIF, PNG, JPG, HEIC, WebP", icon: "photo.badge.plus", color: .green) {
                    importImage()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Add Interactive Web / WebGL URL")
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField("Title", text: $urlTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    TextField("https://...", text: $urlInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Add & Apply") {
                        guard !urlInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let title = urlTitle.isEmpty ? "Web Scene" : urlTitle
                        let item = WallpaperItem(title: title, type: .url, pathOrURL: urlInput, source: .webURL)
                        store.addCustomWallpaper(item, activate: true)
                        urlTitle = ""
                        urlInput = ""
                        selectedWallpaperID = item.id
                        selectedSection = .installed
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private func createTile(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings & Application Rules")
                    .font(.title2)
                    .fontWeight(.bold)

                GroupBox("Performance & Battery") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Pause Wallpaper for Open Windows")
                            Spacer()
                            Picker("", selection: $preferences.windowPauseMode) {
                                ForEach(WindowPauseMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .frame(width: 210)
                        }

                        Toggle("Smooth slow-stop when window opens / pauses", isOn: $preferences.smoothSlowStop)
                        HStack(spacing: 10) {
                            Text("Slow-Stop Duration")
                            Slider(value: $preferences.slowStopDuration, in: 0.5...10.0, step: 0.5)
                                .disabled(!preferences.smoothSlowStop && !preferences.slowStopOnUnlock)
                            Text(String(format: "%.1f s", preferences.slowStopDuration))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 42, alignment: .trailing)
                            Button("Test") {
                                manager.triggerSlowStop(duration: preferences.slowStopDuration)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Toggle("Also slow-stop automatically after unlock", isOn: $preferences.slowStopOnUnlock)

                        Divider()

                        Toggle("Pause on Battery Power", isOn: $preferences.pauseOnBattery)
                        HStack(spacing: 10) {
                            Text("Only When Battery at or Below")
                            Slider(
                                value: Binding(
                                    get: { Double(preferences.pauseOnBatteryBelowPercent) },
                                    set: { preferences.pauseOnBatteryBelowPercent = Int($0) }
                                ),
                                in: 5...100,
                                step: 5
                            )
                            Text(preferences.pauseOnBatteryBelowPercent >= 100 ? "Always" : "\(preferences.pauseOnBatteryBelowPercent)%")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 48, alignment: .trailing)
                        }
                        .disabled(!preferences.pauseOnBattery)
                        if power.isOnBattery, let level = power.batteryLevel {
                            Text("On battery · \(level)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Limit to 30 FPS in macOS Low Power Mode", isOn: $preferences.pauseOnLowPowerMode)
                        Toggle("Manual Battery Override (Resume Anyway)", isOn: $power.overrideSystemPause)

                        HStack {
                            Text("Global FPS Cap")
                            Spacer()
                            Picker("", selection: $preferences.globalFPSCap) {
                                Text("30 FPS").tag(30)
                                Text("60 FPS").tag(60)
                                Text("120 FPS").tag(120)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                    }
                    .padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Per-application overrides evaluated live by PowerMonitor.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: addAppRuleDialog) {
                                Label("Add Application...", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        ForEach(appRules.rules) { rule in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { _ in appRules.toggleRule(id: rule.id) }
                                ))
                                .labelsHidden()

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rule.appName)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text(rule.bundleIdentifier)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Picker("Condition", selection: Binding(
                                    get: { rule.condition },
                                    set: { newCond in
                                        var updated = rule
                                        updated.condition = newCond
                                        appRules.updateRule(updated)
                                    }
                                )) {
                                    ForEach(AppRuleCondition.allCases, id: \.self) { c in
                                        Text(c.displayName).tag(c)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 140)

                                Picker("Action", selection: Binding(
                                    get: { rule.action },
                                    set: { newAct in
                                        var updated = rule
                                        updated.action = newAct
                                        appRules.updateRule(updated)
                                    }
                                )) {
                                    ForEach(AppRuleAction.allCases, id: \.self) { a in
                                        Text(a.displayName).tag(a)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)

                                Button(action: { appRules.removeRule(id: rule.id) }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Application Rules", systemImage: "app.badge.checkmark")
                }

                GroupBox("Audio Visualizer & Sound") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Real-Time Audio Visualizer (ScreenCaptureKit 128-band FFT)", isOn: $preferences.audioVisualizerEnabled)
                            Spacer()
                            Text(audioVisualizer.status.label)
                                .font(.caption)
                                .foregroundColor(audioVisualizer.status == .running ? .green : .secondary)
                        }
                        Toggle("Auto-Mute Wallpaper When Other Apps Play Audio", isOn: $preferences.muteOnExternalAudio)

                        HStack {
                            Text("Wallpaper Audio Volume")
                            Slider(value: $preferences.volume, in: 0...1)
                                .disabled(preferences.isMuted)
                            Text("\(Int(preferences.volume * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 40)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Screensaver Mode") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Enable Wallpaper Screensaver on Idle", isOn: $preferences.screensaverEnabled)
                            Spacer()
                            Button("Start Screensaver Now") {
                                screensaver.startScreensaver()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        HStack {
                            Text("Start after idle")
                            Spacer()
                            Picker("", selection: $preferences.screensaverIdleMinutes) {
                                Text("1 min").tag(1)
                                Text("3 min").tag(3)
                                Text("5 min").tag(5)
                                Text("10 min").tag(10)
                                Text("15 min").tag(15)
                                Text("30 min").tag(30)
                            }
                            .frame(width: 120)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Desktop, Startup, Theme & Hotkeys") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Launch Nimbscape at Login", isOn: $preferences.launchAtLogin)
                        Toggle("Crossfade Transition When Switching Wallpapers", isOn: $preferences.crossfadeTransitions)
                        Toggle("Mouse Parallax Tracking Across Desktop", isOn: $preferences.mouseParallaxTracking)
                        Toggle("Sync Active Wallpaper to macOS Lock Screen & Unlock Transition", isOn: $preferences.syncLockScreenWallpaper)
                        Toggle("Interactive Desktop Mode (Forward mouse clicks to web scenes)", isOn: $preferences.interactiveMode)
                        Toggle("Global Hotkeys (⌘⇧W Switcher · ⌘⇧P Pause · ⌘⇧N Next · ⌘⇧H Hide · ⌘⇧M Mute)", isOn: $preferences.quickSwitcherHotkeyEnabled)

                        HStack {
                            Text("Appearance")
                            Spacer()
                            Picker("", selection: $preferences.appearanceMode) {
                                ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Engine & Storage") {
                    HStack {
                        let hdBytes = StorageJanitor.managedSizeBytes()
                        Text("Downloaded HD Wallpapers: \(ByteCountFormatter.string(fromByteCount: hdBytes, countStyle: .file))")
                            .font(.subheadline)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(HDCatalogDownloader.shared.wallpapersDirectory)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    Text("Removing a downloaded wallpaper from the library also deletes its file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                    HStack {
                        let cacheBytes = FolderCollectionScanner.thumbnailCacheSizeBytes()
                        Text("Thumbnail Cache: \(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))")
                            .font(.subheadline)
                        Spacer()
                        Button("Clear Thumbnail Cache") {
                            FolderCollectionScanner.clearThumbnailCache()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
    }

    private func importVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK, let url = panel.url {
            importErrorMessage = nil
            let item = WallpaperPackageParser.parseVideoFile(at: url)
            store.addCustomWallpaper(item, activate: true)
            FolderCollectionScanner.generateThumbnailAsync(for: item)
            selectedWallpaperID = item.id
            selectedSection = .installed
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .gif]
        if panel.runModal() == .OK, let url = panel.url {
            importErrorMessage = nil
            let item = WallpaperPackageParser.parseImageFile(at: url)
            store.addCustomWallpaper(item, activate: true)
            selectedWallpaperID = item.id
            selectedSection = .installed
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            switch WallpaperPackageParser.parseFolderResult(at: url, source: .localImport) {
            case .success(let item):
                importErrorMessage = nil
                store.addCustomWallpaper(item, activate: true)
                FolderCollectionScanner.generateThumbnailAsync(for: item)
                selectedWallpaperID = item.id
                selectedSection = .installed
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            }
        }
    }

    private func chooseCollectionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select a local folder containing wallpaper packages"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.collectionFolderPath = url.path
            scanner.scan(directoryURL: url)
        }
    }

    private func addAppRuleDialog() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url,
           let rule = AppRulesStore.makeRule(fromAppURL: url) {
            appRules.addRule(rule)
        }
    }
}

private struct LibraryWallpaperCard: View {
    let item: WallpaperItem
    let isSelected: Bool
    let isActive: Bool
    let onSelect: () -> Void
    let onApply: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var thumbnailGenerator = WallpaperThumbnailGenerator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.primary.opacity(0.07)
                    if let img = thumbnailGenerator.thumbnails[item.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        VStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(item.type.rawValue.uppercased())
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                        }
                        .onAppear {
                            thumbnailGenerator.requestThumbnail(for: item)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 128)
                .clipped()
                .cornerRadius(10)

                HStack(spacing: 6) {
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    Button(action: onToggleFavorite) {
                        Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 11))
                            .foregroundColor(item.isFavorite ? .pink : .white)
                            .padding(5)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(item.resolutionLabel ?? item.source.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Button(action: onApply) {
                    Text(isActive ? "Active" : "Apply")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isActive ? .green : .accentColor)
                .controlSize(.small)

                if !item.isBuiltIn {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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

public struct PropertiesInspectorPanel: View {
    @ObservedObject var store = WallpaperStore.shared
    let wallpaperID: String

    private var item: WallpaperItem? {
        store.wallpaper(id: wallpaperID)
    }

    private func propsBinding<T>(_ keyPath: WritableKeyPath<WallpaperProperties, T>) -> Binding<T> {
        Binding(
            get: {
                store.wallpaper(id: wallpaperID)?.properties[keyPath: keyPath] ?? WallpaperProperties()[keyPath: keyPath]
            },
            set: { newValue in
                guard var props = store.wallpaper(id: wallpaperID)?.properties else { return }
                props[keyPath: keyPath] = newValue
                store.updateProperties(props, for: wallpaperID)
            }
        )
    }

    public var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(item.resolutionLabel ?? item.type.rawValue.uppercased())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: { store.toggleFavorite(id: item.id) }) {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .foregroundColor(item.isFavorite ? .pink : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: { store.setActiveWallpaper(item.id) }) {
                        Label(
                            item.id == store.activeWallpaperId ? "Currently Active" : "Apply Wallpaper",
                            systemImage: "checkmark.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(item.id == store.activeWallpaperId ? .green : .accentColor)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("PLAYBACK & ALIGNMENT")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("Speed")
                            Spacer()
                            Text(String(format: "%.2fx", item.properties.speed))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: propsBinding(\.speed), in: 0.25...2.0, step: 0.05)

                        HStack {
                            Text("FPS Cap")
                            Spacer()
                            Picker("", selection: propsBinding(\.fpsCap)) {
                                Text("30").tag(30)
                                Text("60").tag(60)
                                Text("120").tag(120)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 150)
                        }

                        HStack {
                            Text("Alignment")
                            Spacer()
                            Picker("", selection: propsBinding(\.alignment)) {
                                ForEach(WallpaperAlignment.allCases, id: \.self) { a in
                                    Text(a.displayName).tag(a)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("COLOR & TONE (LIVE)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)

                        filterSlider(label: "Hue", value: propsBinding(\.hue), range: -180...180, format: "%.0f°")
                        filterSlider(label: "Brightness", value: propsBinding(\.brightness), range: 0.5...1.5, format: "%.2f")
                        filterSlider(label: "Contrast", value: propsBinding(\.contrast), range: 0.5...1.6, format: "%.2f")
                        filterSlider(label: "Saturation", value: propsBinding(\.saturation), range: 0.0...2.0, format: "%.2f")
                    }

                    if !item.projectPropertySpecs.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SCENE PROPERTIES (project.json)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)

                            ForEach(item.projectPropertySpecs) { spec in
                                projectPropertyControl(spec: spec)
                            }
                        }
                    }

                    Divider()

                    Button("Reset Properties to Default") {
                        store.resetProperties(for: item.id)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                .padding(16)
            } else {
                Text("Select a wallpaper to inspect its live properties.")
                    .foregroundColor(.secondary)
                    .padding(20)
            }
        }
    }

    private func filterSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    @ViewBuilder
    private func projectPropertyControl(spec: ProjectPropertySpec) -> some View {
        let stringBinding = Binding<String>(
            get: {
                store.wallpaper(id: wallpaperID)?.properties.customProps[spec.key] ?? spec.defaultValue
            },
            set: { newVal in
                guard var props = store.wallpaper(id: wallpaperID)?.properties else { return }
                props.customProps[spec.key] = newVal
                store.updateProperties(props, for: wallpaperID)
            }
        )

        switch spec.type {
        case .bool:
            Toggle(spec.text, isOn: Binding(
                get: { stringBinding.wrappedValue.lowercased() == "true" || stringBinding.wrappedValue == "1" },
                set: { stringBinding.wrappedValue = $0 ? "true" : "false" }
            ))
        case .slider:
            let minVal = spec.min ?? 0
            let maxVal = spec.max ?? 100
            let numBinding = Binding<Double>(
                get: { Double(stringBinding.wrappedValue) ?? minVal },
                set: { stringBinding.wrappedValue = String(format: "%.2f", $0) }
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(spec.text).font(.subheadline)
                    Spacer()
                    Text(stringBinding.wrappedValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: numBinding, in: minVal...max(minVal + 0.01, maxVal))
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.text).font(.caption).foregroundColor(.secondary)
                TextField(spec.key, text: stringBinding)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
