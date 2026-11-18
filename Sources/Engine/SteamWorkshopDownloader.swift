import Foundation
import AppKit
import Combine

public enum SteamWorkshopCategory: String, Sendable, Equatable {
    case video = "Video"
    case web = "Web"
    case scene = "Scene"
    case application = "Application"
    case unknown = "Unknown"

    public var isNativelyCompatible: Bool {
        self == .video || self == .web
    }
}

public enum WorkshopBrowseSort: String, CaseIterable, Identifiable, Sendable {
    case trend = "trend"
    case popular = "totaluniquesubscribers"
    case topRated = "toprated"
    case newest = "mostrecent"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .trend: return "Trending"
        case .popular: return "Most Popular"
        case .topRated: return "Top Rated"
        case .newest: return "Newest"
        }
    }
}

public enum WorkshopBrowseType: String, CaseIterable, Identifiable, Sendable {
    case video = "Video"
    case web = "Web"
    case scene = "Scene"
    case all = "All"

    public var id: String { rawValue }

    public var tagQueryValue: String? {
        switch self {
        case .video: return "Video"
        case .web: return "Web"
        case .scene: return "Scene"
        case .all: return nil
        }
    }
}

public struct SteamWorkshopItemMetadata: Identifiable, Equatable, Sendable {
    public var id: String { itemID }
    public let itemID: String
    public let title: String
    public let itemDescription: String
    public let previewURL: URL?
    public let fileSizeBytes: Int64
    public let consumerAppID: Int
    public let subscriptions: Int
    public let tags: [String]
    public let category: SteamWorkshopCategory

    public var isWallpaperEngineItem: Bool {
        consumerAppID == 431960 || consumerAppID == 0
    }

    public var formattedFileSize: String {
        guard fileSizeBytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }

    public var formattedSubscriptions: String {
        if subscriptions >= 1_000_000 {
            return String(format: "%.1fM", Double(subscriptions) / 1_000_000.0)
        } else if subscriptions >= 1_000 {
            return String(format: "%.1fK", Double(subscriptions) / 1_000.0)
        }
        return "\(subscriptions)"
    }
}

public enum SteamWorkshopError: LocalizedError, Equatable, Sendable {
    case invalidInput
    case itemNotFound(String)
    case wrongAppID(Int)
    case networkError(String)
    case steamcmdMissing
    case installFailed(String)
    case downloadFailed(String)
    case noPreviewAvailable

    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Enter a search query, Steam Workshop URL, or numeric Item ID."
        case .itemNotFound(let id):
            return "Steam Workshop item \(id) was not found or is private."
        case .wrongAppID(let appID):
            return "Item belongs to Steam App \(appID), not Wallpaper Engine (431960)."
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .steamcmdMissing:
            return "SteamCMD is not installed."
        case .installFailed(let detail):
            return "Failed to install SteamCMD: \(detail)"
        case .downloadFailed(let detail):
            return detail
        case .noPreviewAvailable:
            return "No preview image is available for this Workshop item."
        }
    }
}

@MainActor
public final class SteamWorkshopDownloader: ObservableObject {
    public static let shared = SteamWorkshopDownloader()
    public static let wallpaperEngineAppID = 431960

    private static let steamcmdTarballURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
    private static let publishedFileDetailsURL = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

    @Published public private(set) var catalogItems: [SteamWorkshopItemMetadata] = []
    @Published public private(set) var isLoadingCatalog: Bool = false
    @Published public private(set) var currentPage: Int = 1

    @Published public private(set) var isSteamcmdInstalled: Bool = false
    @Published public private(set) var resolvedSteamcmdPath: String? = nil
    @Published public private(set) var isInstallingSteamcmd: Bool = false
    @Published public private(set) var isDownloading: Bool = false
    @Published public private(set) var downloadingItemID: String? = nil
    @Published public private(set) var statusText: String = ""
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var failedItemNeedingLogin: SteamWorkshopItemMetadata? = nil
    @Published public private(set) var lastImportedItem: WallpaperItem? = nil
    @Published public private(set) var consoleLog: [String] = []

    private var activeProcess: Process?
    private var activeStdoutPipe: Pipe?
    private var activeStderrPipe: Pipe?

    public var steamcmdDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Nimbscape/steamcmd", isDirectory: true)
    }

    public var downloadsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Nimbscape/WorkshopDownloads", isDirectory: true)
    }

    public var previewsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Nimbscape/WorkshopPreviews", isDirectory: true)
    }

    private init() {
        refreshSteamcmdStatus()
    }

    public static func extractItemID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.allSatisfy({ $0.isNumber }), trimmed.count >= 5, trimmed.count <= 15 {
            return trimmed
        }

        if let components = URLComponents(string: trimmed),
           let idParam = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
           idParam.allSatisfy({ $0.isNumber }), !idParam.isEmpty {
            return idParam
        }

        let patterns = [
            #"(?:[?&]id=)(\d{5,15})"#,
            #"CommunityFilePage/(\d{5,15})"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return String(trimmed[range])
            }
        }
        return nil
    }

    public func browseCatalog(
        query: String = "",
        type: WorkshopBrowseType = .video,
        sort: WorkshopBrowseSort = .trend,
        page: Int = 1
    ) async {
        isLoadingCatalog = true
        errorMessage = nil
        currentPage = max(1, page)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let directID = Self.extractItemID(from: trimmed) {
            do {
                let items = try await requestPublishedFileDetails(itemIDs: [directID])
                catalogItems = items
                if items.isEmpty {
                    errorMessage = SteamWorkshopError.itemNotFound(directID).localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingCatalog = false
            return
        }

        do {
            var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "appid", value: String(Self.wallpaperEngineAppID)),
                URLQueryItem(name: "browsesort", value: sort.rawValue),
                URLQueryItem(name: "section", value: "readytouseitems"),
                URLQueryItem(name: "actualsort", value: sort.rawValue),
                URLQueryItem(name: "p", value: String(currentPage)),
                URLQueryItem(name: "numperpage", value: "30")
            ]
            if sort == .trend {
                queryItems.append(URLQueryItem(name: "days", value: "7"))
            }
            if let tag = type.tagQueryValue {
                queryItems.append(URLQueryItem(name: "requiredtags[]", value: tag))
            }
            if !trimmed.isEmpty {
                queryItems.append(URLQueryItem(name: "searchtext", value: trimmed))
            }
            components.queryItems = queryItems

            guard let browseURL = components.url else {
                throw SteamWorkshopError.invalidInput
            }

            var request = URLRequest(url: browseURL)
            request.timeoutInterval = 18
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw SteamWorkshopError.networkError("Steam Workshop HTTP \(http.statusCode)")
            }

            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let extractedIDs = extractOrderedItemIDs(fromBrowseHTML: html)

            guard !extractedIDs.isEmpty else {
                catalogItems = []
                statusText = "No items found for this filter."
                isLoadingCatalog = false
                return
            }

            let items = try await requestPublishedFileDetails(itemIDs: extractedIDs)

            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) })
            catalogItems = extractedIDs.compactMap { byID[$0] }.filter { $0.isWallpaperEngineItem }

            for item in catalogItems.prefix(12) {
                if let url = item.previewURL {
                    RemotePreviewCache.shared.request(url: url)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingCatalog = false
    }

    private func extractOrderedItemIDs(fromBrowseHTML html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"filedetails/\?id=(\d{5,15})"#) else {
            return []
        }
        let nsRange = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: nsRange)
        var seen = Set<String>()
        var ordered: [String] = []
        for match in matches {
            if let range = Range(match.range(at: 1), in: html) {
                let id = String(html[range])
                if seen.insert(id).inserted {
                    ordered.append(id)
                    if ordered.count >= 30 { break }
                }
            }
        }
        return ordered
    }

    private func requestPublishedFileDetails(itemIDs: [String]) async throws -> [SteamWorkshopItemMetadata] {
        guard !itemIDs.isEmpty else { return [] }

        var request = URLRequest(url: Self.publishedFileDetailsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var pairs = ["itemcount=\(itemIDs.count)"]
        for (idx, id) in itemIDs.enumerated() {
            pairs.append("publishedfileids[\(idx)]=\(id)")
        }
        request.httpBody = pairs.joined(separator: "&").data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SteamWorkshopError.networkError(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SteamWorkshopError.networkError("Steam API HTTP \(http.statusCode)")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let details = response["publishedfiledetails"] as? [[String: Any]] else {
            return []
        }

        var results: [SteamWorkshopItemMetadata] = []
        for entry in details {
            let resultCode = (entry["result"] as? Int) ?? 0
            guard resultCode == 1, let itemID = entry["publishedfileid"] as? String else { continue }

            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = (entry["description"] as? String) ?? ""
            let previewStr = (entry["preview_url"] as? String) ?? ""
            let previewURL = previewStr.isEmpty ? nil : URL(string: previewStr)
            let appID = (entry["consumer_app_id"] as? Int) ?? (entry["creator_app_id"] as? Int) ?? 0
            let subs = (entry["subscriptions"] as? Int) ?? 0

            let fileSize: Int64
            if let sizeNum = entry["file_size"] as? Int64 {
                fileSize = sizeNum
            } else if let sizeInt = entry["file_size"] as? Int {
                fileSize = Int64(sizeInt)
            } else if let sizeStr = entry["file_size"] as? String, let parsed = Int64(sizeStr) {
                fileSize = parsed
            } else {
                fileSize = 0
            }

            var tags: [String] = []
            if let rawTags = entry["tags"] as? [[String: Any]] {
                tags = rawTags.compactMap { $0["tag"] as? String }.filter { !$0.isEmpty }
            }

            let lowerTags = Set(tags.map { $0.lowercased() })
            let category: SteamWorkshopCategory
            if lowerTags.contains("video") {
                category = .video
            } else if lowerTags.contains("web") {
                category = .web
            } else if lowerTags.contains("scene") {
                category = .scene
            } else if lowerTags.contains("application") {
                category = .application
            } else {
                category = .unknown
            }

            results.append(SteamWorkshopItemMetadata(
                itemID: itemID,
                title: (title?.isEmpty == false ? title! : "Workshop \(itemID)"),
                itemDescription: desc,
                previewURL: previewURL,
                fileSizeBytes: fileSize,
                consumerAppID: appID,
                subscriptions: subs,
                tags: tags,
                category: category
            ))
        }
        return results
    }

    public func refreshSteamcmdStatus() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        let custom = AppPreferences.shared.customSteamcmdPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            candidates.append(custom)
        }

        candidates.append(contentsOf: [
            steamcmdDirectory.appendingPathComponent("steamcmd.sh").path,
            "/opt/homebrew/bin/steamcmd",
            "/usr/local/bin/steamcmd",
            "\(home)/steamcmd/steamcmd.sh"
        ])

        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            resolvedSteamcmdPath = found
            isSteamcmdInstalled = true
        } else {
            resolvedSteamcmdPath = nil
            isSteamcmdInstalled = false
        }
    }

    @discardableResult
    public func installSteamCMD() async -> Bool {
        if isSteamcmdInstalled { return true }
        guard !isInstallingSteamcmd else { return false }
        isInstallingSteamcmd = true
        errorMessage = nil
        statusText = "Installing Valve SteamCMD (2.5 MB)..."
        appendLog("Downloading SteamCMD from \(Self.steamcmdTarballURL.absoluteString)")

        let dir = steamcmdDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let (data, response) = try await URLSession.shared.data(from: Self.steamcmdTarballURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw SteamWorkshopError.installFailed("HTTP \(http.statusCode)")
            }

            let archiveURL = dir.appendingPathComponent("steamcmd_osx.tar.gz")
            try data.write(to: archiveURL, options: .atomic)
            statusText = "Extracting SteamCMD..."
            appendLog("Extracting archive (\(data.count) bytes)...")

            let exitCode = try await runSimpleProcess(
                executable: "/usr/bin/tar",
                arguments: ["-xzf", archiveURL.path, "-C", dir.path]
            )
            try? FileManager.default.removeItem(at: archiveURL)

            guard exitCode == 0 else {
                throw SteamWorkshopError.installFailed("tar exited with status \(exitCode)")
            }

            let shURL = dir.appendingPathComponent("steamcmd.sh")
            _ = try? await runSimpleProcess(executable: "/bin/chmod", arguments: ["+x", shURL.path])

            refreshSteamcmdStatus()
            isInstallingSteamcmd = false
            if isSteamcmdInstalled {
                statusText = "SteamCMD ready."
                appendLog("SteamCMD installed at \(shURL.path)")
                return true
            } else {
                throw SteamWorkshopError.installFailed("steamcmd.sh not found after extraction")
            }
        } catch {
            errorMessage = error.localizedDescription
            statusText = "SteamCMD install failed"
            appendLog("Error: \(error.localizedDescription)")
            isInstallingSteamcmd = false
            return false
        }
    }

    public func openInteractiveSteamLogin(username: String) {
        Task {
            refreshSteamcmdStatus()
            if !isSteamcmdInstalled {
                let ok = await installSteamCMD()
                if !ok { return }
            }
            launchTerminalLogin(username: username)
        }
    }

    private func launchTerminalLogin(username: String) {
        guard let steamcmd = resolvedSteamcmdPath else {
            errorMessage = SteamWorkshopError.steamcmdMissing.localizedDescription
            return
        }

        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty else {
            errorMessage = "Enter your Steam username in Steam Account settings first."
            return
        }

        let escapedCmd = shellQuote(steamcmd)
        let escapedUser = shellQuote(cleanUser)
        let script = """
        #!/bin/zsh
        clear
        echo "=== Nimbscape: Official Valve SteamCMD Login ==="
        echo "Sign in once with your Steam password and Steam Guard code."
        echo "SteamCMD will cache your token so Nimbscape downloads Workshop items in 1 click."
        echo ""
        \(escapedCmd) +login \(escapedUser) +quit
        echo ""
        echo "Done. Close this Terminal window and click Download in Nimbscape."
        """

        do {
            try FileManager.default.createDirectory(at: steamcmdDirectory, withIntermediateDirectories: true)
            let scriptURL = steamcmdDirectory.appendingPathComponent("nimbscape_steam_login.command")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)
            errorMessage = nil
            statusText = "Complete Steam Guard login in Terminal, then click Download."
            appendLog("Opened Terminal for interactive SteamCMD login (\(cleanUser)).")
        } catch {
            errorMessage = "Could not launch Terminal login: \(error.localizedDescription)"
        }
    }

    public func downloadAndImport(
        item: SteamWorkshopItemMetadata,
        activate: Bool = true
    ) async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadingItemID = item.itemID
        errorMessage = nil
        failedItemNeedingLogin = nil
        lastImportedItem = nil
        consoleLog.removeAll()

        refreshSteamcmdStatus()
        if !isSteamcmdInstalled {
            let installed = await installSteamCMD()
            guard installed else {
                isDownloading = false
                downloadingItemID = nil
                return
            }
        }

        guard let steamcmdPath = resolvedSteamcmdPath else {
            errorMessage = SteamWorkshopError.steamcmdMissing.localizedDescription
            isDownloading = false
            downloadingItemID = nil
            return
        }

        let savedUser = AppPreferences.shared.steamUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginUser = savedUser.isEmpty ? "anonymous" : savedUser

        do {
            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        } catch {
            isDownloading = false
            downloadingItemID = nil
            errorMessage = error.localizedDescription
            return
        }

        statusText = "Downloading \"\(item.title)\" (\(item.formattedFileSize))..."
        appendLog("Running: \(steamcmdPath) +force_install_dir \"\(downloadsDirectory.path)\" +login \(loginUser) +workshop_download_item 431960 \(item.itemID) +quit")

        let args = [
            "+force_install_dir", downloadsDirectory.path,
            "+login", loginUser,
            "+workshop_download_item", String(Self.wallpaperEngineAppID), item.itemID,
            "+quit"
        ]

        let (exitCode, fullOutput) = await runSteamCMDProcess(executable: steamcmdPath, arguments: args)
        isDownloading = false
        downloadingItemID = nil

        if let folder = locateDownloadedFolder(itemID: item.itemID, steamcmdOutput: fullOutput) {
            statusText = "Importing \"\(item.title)\"..."
            appendLog("Located downloaded files at: \(folder.path)")
            importDownloadedFolder(
                folderURL: folder,
                itemID: item.itemID,
                metadata: item,
                activate: activate
            )
            return
        }

        let lower = fullOutput.lowercased()
        if lower.contains("no subscription") || lower.contains("access denied") || (lower.contains("failure") && loginUser == "anonymous") {
            failedItemNeedingLogin = item
            errorMessage = "Steam требует аккаунт с купленным Wallpaper Engine (431960) для полного скачивания. Войди в Steam Account или нажми «Use Preview GIF»."
        } else if lower.contains("cached credentials not found") || lower.contains("invalid password") || lower.contains("two-factor") || lower.contains("steam guard") || lower.contains("password:") {
            failedItemNeedingLogin = item
            errorMessage = "Сессия SteamCMD для «\(loginUser)» не авторизована. Нажми «Login in Terminal (Steam Guard)» один раз и повтори Download."
        } else if lower.contains("rate limit") {
            errorMessage = "Steam Rate Limit Exceeded. Подожди пару минут и попробуй снова."
        } else {
            failedItemNeedingLogin = item
            errorMessage = "SteamCMD завершился с кодом \(exitCode). Открой Console Log или импортируй Preview GIF."
        }
        statusText = "Download failed"
    }

    public func cancelCurrentDownload() {
        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
            appendLog("Download cancelled by user.")
            statusText = "Cancelled"
        }
        isDownloading = false
        downloadingItemID = nil
    }

    public func importPreviewOnly(metadata: SteamWorkshopItemMetadata, activate: Bool = true) async {
        guard let previewURL = metadata.previewURL else {
            errorMessage = SteamWorkshopError.noPreviewAvailable.localizedDescription
            return
        }
        guard !isDownloading else { return }

        isDownloading = true
        downloadingItemID = metadata.itemID
        errorMessage = nil
        failedItemNeedingLogin = nil
        statusText = "Importing animated preview: \(metadata.title)..."

        do {
            try FileManager.default.createDirectory(at: previewsDirectory, withIntermediateDirectories: true)
            var request = URLRequest(url: previewURL)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw SteamWorkshopError.networkError("Preview HTTP \(http.statusCode)")
            }

            let ext = detectImageExtension(data: data, response: response, url: previewURL)
            let destURL = previewsDirectory.appendingPathComponent("\(metadata.itemID).\(ext)")
            try data.write(to: destURL, options: .atomic)

            var tags = metadata.tags
            if !tags.contains("Steam Workshop") { tags.append("Steam Workshop") }
            if !tags.contains("Preview") { tags.append("Preview") }

            let item = WallpaperItem(
                id: UUID().uuidString,
                title: metadata.title,
                type: .image,
                pathOrURL: destURL.path,
                previewPath: destURL.path,
                isBuiltIn: false,
                isFavorite: false,
                tags: tags,
                resolutionLabel: WallpaperEngineParser.extractResolutionLabel(for: destURL, type: .image),
                fileSizeBytes: Int64(data.count),
                source: .steamWorkshop
            )

            WallpaperStore.shared.addCustomWallpaper(item, activate: activate)
            lastImportedItem = item
            statusText = "Applied preview: \(item.title)"
            appendLog("Imported preview to \(destURL.path)")
        } catch {
            errorMessage = error.localizedDescription
            statusText = "Preview import failed"
        }

        isDownloading = false
        downloadingItemID = nil
    }

    private func importDownloadedFolder(
        folderURL: URL,
        itemID: String,
        metadata: SteamWorkshopItemMetadata?,
        activate: Bool
    ) {
        let allowFallback = AppPreferences.shared.allowScenePreviewFallback
        let result = WallpaperEngineParser.parseFolderResult(
            at: folderURL,
            source: .steamWorkshop,
            allowScenePreviewFallback: allowFallback
        )

        switch result {
        case .success(var item):
            if !item.tags.contains("Steam Workshop") {
                item.tags.append("Steam Workshop")
            }
            if let meta = metadata, (item.title == itemID || item.title.isEmpty) {
                item.title = meta.title
            }
            WallpaperStore.shared.addCustomWallpaper(item, activate: activate)
            lastImportedItem = item
            statusText = "Imported & Applied: \(item.title)"
            appendLog("Successfully imported \"\(item.title)\" (\(item.type.rawValue))")
            errorMessage = nil

        case .failure(let err):
            errorMessage = err.localizedDescription
            statusText = "Downloaded, but could not import"
            appendLog("Import error: \(err.localizedDescription)")
        }
    }

    private func locateDownloadedFolder(itemID: String, steamcmdOutput: String) -> URL? {
        let fileManager = FileManager.default

        if let regex = try? NSRegularExpression(pattern: #"Downloaded item \d+ to "([^"]+)""#),
           let match = regex.firstMatch(in: steamcmdOutput, range: NSRange(steamcmdOutput.startIndex..., in: steamcmdOutput)),
           let range = Range(match.range(at: 1), in: steamcmdOutput) {
            let parsedPath = String(steamcmdOutput[range])
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: parsedPath, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: parsedPath)
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let candidateFolders: [URL] = [
            downloadsDirectory.appendingPathComponent("steamapps/workshop/content/431960/\(itemID)", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960/\(itemID)", isDirectory: true),
            steamcmdDirectory.appendingPathComponent("steamapps/workshop/content/431960/\(itemID)", isDirectory: true),
            URL(fileURLWithPath: AppPreferences.shared.workshopFolderPath).appendingPathComponent(itemID, isDirectory: true)
        ]

        for dir in candidateFolders {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
        }
        return nil
    }

    private func runSteamCMDProcess(executable: String, arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let devNull = FileHandle(forReadingAtPath: "/dev/null")
            process.standardInput = devNull

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            final class OutputAccumulator: @unchecked Sendable {
                private let lock = NSLock()
                private var buffer = ""

                func append(_ text: String) {
                    lock.lock()
                    buffer.append(text)
                    lock.unlock()
                }

                func snapshot() -> String {
                    lock.lock()
                    defer { lock.unlock() }
                    return buffer
                }
            }

            let accumulator = OutputAccumulator()

            let handleChunk: @Sendable (Data) -> Void = { [weak self] data in
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                accumulator.append(str)
                let lines = str
                    .replacingOccurrences(of: "\r", with: "\n")
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !lines.isEmpty else { return }
                Task { @MainActor [weak self] in
                    for line in lines {
                        self?.appendLog(line)
                    }
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                handleChunk(handle.availableData)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                handleChunk(handle.availableData)
            }

            process.terminationHandler = { [weak self] proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let remainingOut = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let s = String(data: remainingOut, encoding: .utf8), !s.isEmpty {
                    accumulator.append(s)
                }
                let remainingErr = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let s = String(data: remainingErr, encoding: .utf8), !s.isEmpty {
                    accumulator.append(s)
                }
                try? devNull?.close()

                let code = proc.terminationStatus
                let text = accumulator.snapshot()
                Task { @MainActor [weak self] in
                    self?.activeProcess = nil
                    self?.activeStdoutPipe = nil
                    self?.activeStderrPipe = nil
                    continuation.resume(returning: (code, text))
                }
            }

            self.activeProcess = process
            self.activeStdoutPipe = outputPipe
            self.activeStderrPipe = errorPipe

            do {
                try process.run()
            } catch {
                self.activeProcess = nil
                self.activeStdoutPipe = nil
                self.activeStderrPipe = nil
                continuation.resume(returning: (-1, "Failed to launch process: \(error.localizedDescription)"))
            }
        }
    }

    private func runSimpleProcess(executable: String, arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func appendLog(_ line: String) {
        consoleLog.append(line)
        if consoleLog.count > 160 {
            consoleLog.removeFirst(consoleLog.count - 160)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func detectImageExtension(data: Data, response: URLResponse, url: URL) -> String {
        if data.count >= 6 {
            let header = [UInt8](data.prefix(6))
            if header[0] == 0x47 && header[1] == 0x49 && header[2] == 0x46 { return "gif" }
            if header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 { return "png" }
            if header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF { return "jpg" }
        }
        if data.count >= 12 {
            let riff = String(data: data.prefix(4), encoding: .ascii)
            let webp = String(data: data.subdata(in: 8..<12), encoding: .ascii)
            if riff == "RIFF" && webp == "WEBP" { return "webp" }
        }
        if let mime = response.mimeType?.lowercased() {
            if mime.contains("gif") { return "gif" }
            if mime.contains("png") { return "png" }
            if mime.contains("webp") { return "webp" }
        }
        let pathExt = url.pathExtension.lowercased()
        if ["gif", "png", "jpg", "jpeg", "webp"].contains(pathExt) {
            return pathExt
        }
        return "jpg"
    }
}
