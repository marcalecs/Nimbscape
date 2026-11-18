import SwiftUI
import AppKit

private struct RemoteCatalogThumbnailView: View {
    let url: URL?
    @ObservedObject var cache = RemotePreviewCache.shared

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let url {
                if let img = cache.images[url] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .onAppear {
                            cache.request(url: url)
                        }
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
            }
        }
        .clipped()
    }
}

public struct HDCatalogGridView: View {
    @ObservedObject var catalog = HDCatalogDownloader.shared
    @Binding var externalSearchQuery: String

    @State private var searchQuery: String = ""
    @State private var selectedCategory: HDCatalogCategory = .all

    public var onImportedAndApplied: ((WallpaperItem) -> Void)?

    public init(
        externalSearchQuery: Binding<String> = .constant(""),
        onImportedAndApplied: ((WallpaperItem) -> Void)? = nil
    ) {
        self._externalSearchQuery = externalSearchQuery
        self.onImportedAndApplied = onImportedAndApplied
    }

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 270), spacing: 14)
    ]

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("Search 1080p / 4K live wallpapers (cyberpunk, anime, cars, space)...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { loadPage(1) }
                    if !searchQuery.isEmpty {
                        Button(action: {
                            searchQuery = ""
                            loadPage(1)
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(8)

                Button("Search") {
                    loadPage(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: { loadPage(catalog.currentPage) }) {
                    if catalog.isLoadingCatalog {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh catalog")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(HDCatalogCategory.allCases) { cat in
                        Button(cat.rawValue) {
                            searchQuery = ""
                            selectedCategory = cat
                            loadPage(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedCategory == cat && searchQuery.isEmpty ? .accentColor : .secondary)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 1)
            }

            if catalog.isDownloading || catalog.errorMessage != nil || !catalog.statusText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if catalog.isDownloading {
                            ProgressView().controlSize(.small)
                        } else if catalog.errorMessage != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }

                        Text(catalog.errorMessage ?? catalog.statusText)
                            .font(.caption)
                            .foregroundColor(catalog.errorMessage != nil ? .orange : .primary)
                            .lineLimit(2)

                        Spacer()

                        if catalog.isDownloading {
                            Button("Cancel") {
                                catalog.cancelDownload()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }

                    if catalog.isDownloading && catalog.downloadProgress > 0 {
                        ProgressView(value: catalog.downloadProgress)
                            .progressViewStyle(.linear)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(8)
            }

            if catalog.isLoadingCatalog && catalog.items.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading Full HD & 4K wallpapers...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if catalog.items.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No wallpapers found for this query.")
                        .font(.headline)
                    Button("Show Latest") {
                        searchQuery = ""
                        selectedCategory = .all
                        loadPage(1)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(catalog.items) { item in
                            hdCard(item)
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    Button(action: { loadPage(max(1, catalog.currentPage - 1)) }) {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(catalog.currentPage <= 1 || catalog.isLoadingCatalog)

                    Spacer()
                    Text("Page \(catalog.currentPage) · Full HD / 4K MP4 (No Login)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()

                    Button(action: { loadPage(catalog.currentPage + 1) }) {
                        HStack(spacing: 4) {
                            Text("Next")
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(catalog.items.count < 8 || catalog.isLoadingCatalog)
                }
            }
        }
        .onAppear {
            if !externalSearchQuery.isEmpty {
                searchQuery = externalSearchQuery
                externalSearchQuery = ""
                loadPage(1)
            } else if catalog.items.isEmpty && !catalog.isLoadingCatalog {
                loadPage(1)
            }
        }
        .onChange(of: externalSearchQuery) { _, newValue in
            if !newValue.isEmpty {
                searchQuery = newValue
                externalSearchQuery = ""
                loadPage(1)
            }
        }
        .onChange(of: catalog.lastImportedItem?.id) { _, _ in
            if let item = catalog.lastImportedItem {
                onImportedAndApplied?(item)
            }
        }
    }

    private func hdCard(_ item: HDCatalogItem) -> some View {
        let isThisDownloading = catalog.isDownloading && catalog.downloadingItemID == item.id

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RemoteCatalogThumbnailView(url: item.thumbnailURL)
                    .frame(height: 128)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    Text(item.categoryLabel.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.68))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    Spacer()
                    Text(selectedCategory == .uhd4k ? "4K MP4" : "HD MP4")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.88))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .padding(7)

                if isThisDownloading {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.58))
                        .overlay(
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                Text(catalog.downloadProgress > 0 ? "\(Int(catalog.downloadProgress * 100))%" : "Starting...")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            }
                        )
                }
            }

            Text(item.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)

            Button(action: {
                catalog.startDownload(item: item, activate: true)
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(isThisDownloading ? "Downloading..." : "Download & Apply")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(catalog.isDownloading)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func loadPage(_ page: Int) {
        Task {
            await catalog.loadCatalog(category: selectedCategory, query: searchQuery, page: page)
        }
    }
}

public struct SteamWorkshopBrowserView: View {
    @ObservedObject var downloader = SteamWorkshopDownloader.shared
    @ObservedObject var preferences = AppPreferences.shared

    @State private var searchQuery: String = ""
    @State private var selectedType: WorkshopBrowseType = .video
    @State private var selectedSort: WorkshopBrowseSort = .trend
    @State private var showAccountSheet: Bool = false
    @State private var showConsoleLog: Bool = false

    public var onImportedAndApplied: ((WallpaperItem) -> Void)?
    public var onSearchInHDCatalog: ((String) -> Void)?

    public init(
        onImportedAndApplied: ((WallpaperItem) -> Void)? = nil,
        onSearchInHDCatalog: ((String) -> Void)? = nil
    ) {
        self.onImportedAndApplied = onImportedAndApplied
        self.onSearchInHDCatalog = onSearchInHDCatalog
    }

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 270), spacing: 14)
    ]

    public var body: some View {
        VStack(spacing: 12) {
            filterBar

            if showAccountSheet {
                steamAccountDrawer
            }

            if downloader.isDownloading || downloader.isInstallingSteamcmd || downloader.errorMessage != nil || !downloader.statusText.isEmpty {
                statusBanner
            }

            if downloader.isLoadingCatalog && downloader.catalogItems.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading Steam Workshop catalog...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if downloader.catalogItems.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No wallpapers found.")
                        .font(.headline)
                    Button("Reload Catalog") {
                        loadPage(1)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(downloader.catalogItems) { item in
                            workshopCard(item)
                        }
                    }
                    .padding(.vertical, 2)
                }

                paginationBar
            }
        }
        .onAppear {
            if downloader.catalogItems.isEmpty && !downloader.isLoadingCatalog {
                loadPage(1)
            }
        }
        .onChange(of: selectedType) { _, _ in
            loadPage(1)
        }
        .onChange(of: selectedSort) { _, _ in
            loadPage(1)
        }
        .onChange(of: downloader.lastImportedItem?.id) { _, _ in
            if let item = downloader.lastImportedItem {
                onImportedAndApplied?(item)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Search Workshop or paste URL / ID...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { loadPage(1) }
                if !searchQuery.isEmpty {
                    Button(action: {
                        searchQuery = ""
                        loadPage(1)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(8)

            Picker("", selection: $selectedType) {
                ForEach(WorkshopBrowseType.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 215)

            Picker("", selection: $selectedSort) {
                ForEach(WorkshopBrowseSort.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .frame(width: 125)

            Button(action: { loadPage(downloader.currentPage) }) {
                if downloader.isLoadingCatalog {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: { showAccountSheet.toggle() }) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(preferences.steamUsername.isEmpty ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(preferences.steamUsername.isEmpty ? "Steam Login" : preferences.steamUsername)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func workshopCard(_ item: SteamWorkshopItemMetadata) -> some View {
        let isThisDownloading = downloader.isDownloading && downloader.downloadingItemID == item.itemID

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RemoteCatalogThumbnailView(url: item.previewURL)
                    .frame(height: 128)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    categoryBadge(item.category)
                    Spacer()
                    Text(item.formattedFileSize)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.68))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .padding(7)

                if isThisDownloading {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.55))
                        .overlay(
                            VStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                Text("Downloading...")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                        )
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if item.subscriptions > 0 {
                        Label(item.formattedSubscriptions, systemImage: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if !item.tags.isEmpty {
                        Text(item.tags.prefix(2).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 6) {
                Button(action: {
                    Task { await downloader.downloadAndImport(item: item, activate: true) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(isThisDownloading ? "Working..." : "Download")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(downloader.isDownloading)

                if let onSearchInHDCatalog {
                    Button(action: {
                        onSearchInHDCatalog(item.title)
                    }) {
                        Image(systemName: "sparkles.tv")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Find in Free HD Catalog (no Steam login)")
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func categoryBadge(_ category: SteamWorkshopCategory) -> some View {
        let color: Color
        switch category {
        case .video: color = .green
        case .web: color = .blue
        case .scene: color = .orange
        case .application: color = .red
        case .unknown: color = .gray
        }
        return Text(category.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.88))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }

    private var steamAccountDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Steam Account:")
                    .font(.caption)
                    .fontWeight(.semibold)

                TextField("Steam username (owns Wallpaper Engine 431960)", text: $preferences.steamUsername)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 260)

                Button(action: {
                    downloader.openInteractiveSteamLogin(username: preferences.steamUsername)
                }) {
                    Label("Login in Terminal", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(preferences.steamUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Toggle("Scene GIF Fallback", isOn: $preferences.allowScenePreviewFallback)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button("Hide") {
                    showAccountSheet = false
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(10)
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if downloader.isDownloading || downloader.isInstallingSteamcmd {
                    ProgressView().controlSize(.small)
                } else if downloader.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }

                Text(downloader.errorMessage ?? downloader.statusText)
                    .font(.caption)
                    .foregroundColor(downloader.errorMessage != nil ? .orange : .primary)
                    .lineLimit(2)

                Spacer()

                if let failedItem = downloader.failedItemNeedingLogin {
                    if let onSearchInHDCatalog {
                        Button("Find in Free HD Catalog") {
                            onSearchInHDCatalog(failedItem.title)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }

                    Button("Steam Login") {
                        showAccountSheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                if !downloader.consoleLog.isEmpty {
                    Button(showConsoleLog ? "Hide Log" : "Log") {
                        showConsoleLog.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                if downloader.isDownloading {
                    Button("Cancel") {
                        downloader.cancelCurrentDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if showConsoleLog && !downloader.consoleLog.isEmpty {
                ScrollView {
                    Text(downloader.consoleLog.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 80)
                .padding(6)
                .background(Color.black.opacity(0.25))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    private var paginationBar: some View {
        HStack {
            Button(action: { loadPage(max(1, downloader.currentPage - 1)) }) {
                Label("Previous", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(downloader.currentPage <= 1 || downloader.isLoadingCatalog)

            Spacer()
            Text("Page \(downloader.currentPage) · Steam Workshop (431960)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()

            Button(action: { loadPage(downloader.currentPage + 1) }) {
                HStack(spacing: 4) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(downloader.catalogItems.count < 10 || downloader.isLoadingCatalog)
        }
    }

    private func loadPage(_ page: Int) {
        Task {
            await downloader.browseCatalog(
                query: searchQuery,
                type: selectedType,
                sort: selectedSort,
                page: page
            )
        }
    }
}
