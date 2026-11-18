import SwiftUI
import AppKit

private struct RemoteCatalogThumbnailView: View {
    let url: URL?
    @ObservedObject var cache = RemotePreviewCache.shared

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let url {
                if let image = cache.images[url] {
                    Image(nsImage: image)
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

    @State private var searchQuery: String = ""
    @State private var selectedCategory: HDCatalogCategory = .all

    public var onImportedAndApplied: ((WallpaperItem) -> Void)?

    public init(onImportedAndApplied: ((WallpaperItem) -> Void)? = nil) {
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
                    ForEach(HDCatalogCategory.allCases) { category in
                        Button(category.rawValue) {
                            searchQuery = ""
                            selectedCategory = category
                            loadPage(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedCategory == category && searchQuery.isEmpty ? .accentColor : .secondary)
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
                    Text("Page \(catalog.currentPage) · Full HD / 4K MP4")
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
            if catalog.items.isEmpty && !catalog.isLoadingCatalog {
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
