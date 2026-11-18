import Foundation
import AppKit
import Combine

public enum HDCatalogCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "Latest"
    case uhd4k = "4K UHD"
    case anime = "Anime"
    case games = "Games"
    case scifi = "Sci-Fi"
    case fantasy = "Fantasy"
    case landscape = "Landscape"
    case abstract = "Abstract"
    case pixelArt = "Pixel Art"
    case cars = "Cars"

    public var id: String { rawValue }

    public func pageURL(page: Int, searchQuery: String) -> URL? {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            let path = page > 1 ? "https://moewalls.com/page/\(page)/?s=\(encoded)" : "https://moewalls.com/?s=\(encoded)"
            return URL(string: path)
        }

        let base: String
        switch self {
        case .all: base = "https://moewalls.com"
        case .uhd4k: base = "https://moewalls.com/resolution/3840x2160"
        case .anime: base = "https://moewalls.com/category/anime"
        case .games: base = "https://moewalls.com/category/games"
        case .scifi: base = "https://moewalls.com/category/sci-fi"
        case .fantasy: base = "https://moewalls.com/category/fantasy"
        case .landscape: base = "https://moewalls.com/category/landscape"
        case .abstract: base = "https://moewalls.com/category/abstract"
        case .pixelArt: base = "https://moewalls.com/category/pixel-art"
        case .cars: base = "https://moewalls.com/category/cars"
        }
        return URL(string: page > 1 ? "\(base)/page/\(page)/" : "\(base)/")
    }
}

public struct HDCatalogItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let pageURL: URL
    public let thumbnailURL: URL
    public let categoryLabel: String
}

@MainActor
public final class HDCatalogDownloader: ObservableObject {
    public static let shared = HDCatalogDownloader()

    @Published public private(set) var items: [HDCatalogItem] = []
    @Published public private(set) var isLoadingCatalog: Bool = false
    @Published public private(set) var currentPage: Int = 1

    @Published public private(set) var isDownloading: Bool = false
    @Published public private(set) var downloadingItemID: String? = nil
    @Published public private(set) var downloadProgress: Double = 0
    @Published public private(set) var statusText: String = ""
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var lastImportedItem: WallpaperItem? = nil

    private var downloadTask: Task<Void, Never>?
    private var activeSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?

    public var wallpapersDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Nimbscape/HDWallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    public func loadCatalog(category: HDCatalogCategory = .all, query: String = "", page: Int = 1) async {
        isLoadingCatalog = true
        errorMessage = nil
        currentPage = max(1, page)

        guard let url = category.pageURL(page: currentPage, searchQuery: query) else {
            errorMessage = "Invalid search URL."
            isLoadingCatalog = false
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 18
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw NSError(domain: "HDCatalog", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Catalog HTTP \(http.statusCode)"])
            }

            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let parsed = Self.parseCatalogHTML(html)
            items = parsed

            for item in parsed.prefix(12) {
                RemotePreviewCache.shared.request(url: item.thumbnailURL)
            }
        } catch {
            errorMessage = "Failed to load HD catalog: \(error.localizedDescription)"
        }

        isLoadingCatalog = false
    }

    public func startDownload(item: HDCatalogItem, activate: Bool = true) {
        guard !isDownloading else { return }
        downloadTask = Task {
            await performDownload(item: item, activate: activate)
        }
    }

    public func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadingItemID = nil
        downloadProgress = 0
        statusText = "Cancelled"
    }

    private func performDownload(item: HDCatalogItem, activate: Bool) async {
        isDownloading = true
        downloadingItemID = item.id
        downloadProgress = 0
        errorMessage = nil
        lastImportedItem = nil
        statusText = "Resolving HD MP4 link for \"\(item.title)\"..."

        let destMP4 = wallpapersDirectory.appendingPathComponent("\(item.id).mp4")
        let destThumb = wallpapersDirectory.appendingPathComponent("\(item.id).jpg")

        if FileManager.default.fileExists(atPath: destMP4.path),
           let size = WallpaperEngineParser.fileSizeBytes(at: destMP4), size > 100_000 {
            finalizeImport(item: item, mp4URL: destMP4, thumbURL: destThumb, resolutionOverride: nil, activate: activate)
            isDownloading = false
            downloadingItemID = nil
            return
        }

        do {
            var pageReq = URLRequest(url: item.pageURL)
            pageReq.timeoutInterval = 18
            pageReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

            let (pageData, pageResp) = try await URLSession.shared.data(for: pageReq)
            if let http = pageResp as? HTTPURLResponse, http.statusCode >= 400 {
                throw NSError(domain: "HDCatalog", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Item page HTTP \(http.statusCode)"])
            }
            try Task.checkCancellation()

            let pageHTML = String(data: pageData, encoding: .utf8) ?? String(decoding: pageData, as: UTF8.self)
            guard let token = Self.extractDownloadToken(from: pageHTML) else {
                throw NSError(domain: "HDCatalog", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not locate full HD MP4 download token for this wallpaper."])
            }
            let resolution = Self.extractResolution(from: pageHTML)

            guard let downloadURL = URL(string: "https://go.moewalls.com/download.php?video=\(token)") else {
                throw NSError(domain: "HDCatalog", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid HD download URL."])
            }

            if !FileManager.default.fileExists(atPath: destThumb.path) {
                if let (thumbData, _) = try? await URLSession.shared.data(from: item.thumbnailURL), thumbData.count > 1024 {
                    try? thumbData.write(to: destThumb, options: .atomic)
                }
            }

            var dlReq = URLRequest(url: downloadURL)
            dlReq.timeoutInterval = 240
            dlReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            dlReq.setValue(item.pageURL.absoluteString, forHTTPHeaderField: "Referer")

            statusText = "Downloading \(resolution ?? "HD") MP4: \(item.title)..."
            try await downloadFileToDisk(request: dlReq, destinationURL: destMP4, resolutionLabel: resolution ?? "HD")

            guard let size = WallpaperEngineParser.fileSizeBytes(at: destMP4), size > 50_000 else {
                try? FileManager.default.removeItem(at: destMP4)
                throw NSError(domain: "HDCatalog", code: -3, userInfo: [NSLocalizedDescriptionKey: "Downloaded file was too small or invalid."])
            }

            downloadProgress = 1.0
            finalizeImport(item: item, mp4URL: destMP4, thumbURL: destThumb, resolutionOverride: resolution, activate: activate)
        } catch is CancellationError {
            statusText = "Cancelled"
        } catch let nsErr as NSError where nsErr.code == NSURLErrorCancelled {
            statusText = "Cancelled"
        } catch {
            errorMessage = error.localizedDescription
            statusText = "Download failed"
        }

        isDownloading = false
        downloadingItemID = nil
        downloadTask = nil
    }

    private func downloadFileToDisk(
        request: URLRequest,
        destinationURL: URL,
        resolutionLabel: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
                let destinationURL: URL
                let onProgress: @Sendable (Double, Int64, Int64) -> Void
                private let lock = NSLock()
                private var continuation: CheckedContinuation<Void, Error>?
                private var lastReportTime: TimeInterval = 0

                init(
                    destinationURL: URL,
                    continuation: CheckedContinuation<Void, Error>,
                    onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void
                ) {
                    self.destinationURL = destinationURL
                    self.continuation = continuation
                    self.onProgress = onProgress
                }

                private func resumeOnce(_ result: Result<Void, Error>) {
                    lock.lock()
                    let cont = continuation
                    continuation = nil
                    lock.unlock()
                    guard let cont else { return }
                    switch result {
                    case .success: cont.resume()
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }

                func urlSession(
                    _ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64
                ) {
                    let now = ProcessInfo.processInfo.systemUptime
                    lock.lock()
                    let shouldReport = (now - lastReportTime) >= 0.45
                    if shouldReport { lastReportTime = now }
                    lock.unlock()
                    guard shouldReport else { return }

                    let progress = totalBytesExpectedToWrite > 0
                        ? min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
                        : 0
                    onProgress(progress, totalBytesWritten, totalBytesExpectedToWrite)
                }

                func urlSession(
                    _ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL
                ) {
                    if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                        resumeOnce(.failure(NSError(
                            domain: "HDCatalog",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "MP4 server HTTP \(http.statusCode)"]
                        )))
                        return
                    }
                    do {
                        let fileManager = FileManager.default
                        if fileManager.fileExists(atPath: destinationURL.path) {
                            try fileManager.removeItem(at: destinationURL)
                        }
                        try fileManager.moveItem(at: location, to: destinationURL)
                        resumeOnce(.success(()))
                    } catch {
                        resumeOnce(.failure(error))
                    }
                }

                func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                    if let error {
                        resumeOnce(.failure(error))
                    }
                }
            }

            let delegate = FileDownloadDelegate(
                destinationURL: destinationURL,
                continuation: continuation,
                onProgress: { [weak self] progress, written, expected in
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloading else { return }
                        self.downloadProgress = progress
                        let mbDone = Double(written) / 1_048_576.0
                        if expected > 0 {
                            let mbTotal = Double(expected) / 1_048_576.0
                            self.statusText = String(format: "Downloading %@ — %.1f / %.1f MB (%d%%)", resolutionLabel, mbDone, mbTotal, Int(progress * 100))
                        } else {
                            self.statusText = String(format: "Downloading %@ — %.1f MB", resolutionLabel, mbDone)
                        }
                    }
                }
            )

            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = true
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
            let task = session.downloadTask(with: request)
            self.activeSession = session
            self.activeDownloadTask = task
            task.resume()
            session.finishTasksAndInvalidate()
        }
        self.activeSession = nil
        self.activeDownloadTask = nil
    }

    private func finalizeImport(
        item: HDCatalogItem,
        mp4URL: URL,
        thumbURL: URL,
        resolutionOverride: String?,
        activate: Bool
    ) {
        var wp = WallpaperEngineParser.parseVideoFile(at: mp4URL, source: .localImport)
        wp.title = item.title
        if FileManager.default.fileExists(atPath: thumbURL.path) {
            wp.previewPath = thumbURL.path
        }
        if let res = resolutionOverride, !res.isEmpty, wp.resolutionLabel == "Video" {
            wp.resolutionLabel = res
        }
        if !wp.tags.contains(item.categoryLabel) {
            wp.tags.append(item.categoryLabel)
        }
        if !wp.tags.contains("HD Catalog") {
            wp.tags.append("HD Catalog")
        }

        WallpaperStore.shared.addCustomWallpaper(wp, activate: activate)
        lastImportedItem = wp
        statusText = "Downloaded & Applied: \(wp.title) (\(wp.resolutionLabel ?? "HD"))"
        errorMessage = nil
    }

    private nonisolated static func parseCatalogHTML(_ html: String) -> [HDCatalogItem] {
        let pattern = #"<div class="entry-featured-media[^"]*"\s*>\s*<a\s+title="([^"]+)"\s+class="g1-frame"\s+href="(https://moewalls\.com/([^/]+)/([^/"]+)/)"[^>]*>([\s\S]*?)</a>\s*</div>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: nsRange)

        var seen = Set<String>()
        var results: [HDCatalogItem] = []

        for m in matches {
            guard m.numberOfRanges >= 6,
                  let titleRange = Range(m.range(at: 1), in: html),
                  let urlRange = Range(m.range(at: 2), in: html),
                  let catRange = Range(m.range(at: 3), in: html),
                  let slugRange = Range(m.range(at: 4), in: html),
                  let innerRange = Range(m.range(at: 5), in: html) else {
                continue
            }

            let slug = String(html[slugRange])
            if !seen.insert(slug).inserted { continue }

            let rawTitle = decodeHTMLEntities(String(html[titleRange]))
                .replacingOccurrences(of: " Live Wallpaper", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let pageURL = URL(string: String(html[urlRange])) else { continue }
            let inner = String(html[innerRange])

            let thumbURLString = extractBestThumbURL(from: inner)
            guard let thumbStr = thumbURLString, let thumbURL = URL(string: thumbStr) else { continue }

            let rawCat = String(html[catRange])
                .replacingOccurrences(of: "-", with: " ")
                .capitalized

            results.append(HDCatalogItem(
                id: slug,
                title: rawTitle.isEmpty ? slug : rawTitle,
                pageURL: pageURL,
                thumbnailURL: thumbURL,
                categoryLabel: rawCat
            ))
        }

        return results
    }

    private nonisolated static func extractBestThumbURL(from innerHTML: String) -> String? {
        if let r728 = try? NSRegularExpression(pattern: #"(https://moewalls\.com/wp-content/uploads/[^\s"']+728x410\.(?:jpg|jpeg|png|webp))"#),
           let m = r728.firstMatch(in: innerHTML, range: NSRange(innerHTML.startIndex..., in: innerHTML)),
           let range = Range(m.range(at: 1), in: innerHTML) {
            return String(innerHTML[range])
        }
        if let rSrc = try? NSRegularExpression(pattern: #"src="(https://moewalls\.com/wp-content/uploads/[^"']+\.(?:jpg|jpeg|png|webp))""#),
           let m = rSrc.firstMatch(in: innerHTML, range: NSRange(innerHTML.startIndex..., in: innerHTML)),
           let range = Range(m.range(at: 1), in: innerHTML) {
            return String(innerHTML[range])
        }
        return nil
    }

    private nonisolated static func extractDownloadToken(from pageHTML: String) -> String? {
        let pattern = #"id="moe-download"[^>]*data-url="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: pageHTML, range: NSRange(pageHTML.startIndex..., in: pageHTML)),
           let range = Range(match.range(at: 1), in: pageHTML) {
            return String(pageHTML[range])
        }
        return nil
    }

    private nonisolated static func extractResolution(from pageHTML: String) -> String? {
        let pattern = #"/resolution/(\d+x\d+)/"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: pageHTML, range: NSRange(pageHTML.startIndex..., in: pageHTML)),
           let range = Range(match.range(at: 1), in: pageHTML) {
            return String(pageHTML[range]).replacingOccurrences(of: "x", with: "×")
        }
        return nil
    }

    private nonisolated static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&#8217;", with: "'")
            .replacingOccurrences(of: "&#8216;", with: "'")
            .replacingOccurrences(of: "&#8220;", with: "\"")
            .replacingOccurrences(of: "&#8221;", with: "\"")
            .replacingOccurrences(of: "&#038;", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&mdash;", with: "—")
    }
}
