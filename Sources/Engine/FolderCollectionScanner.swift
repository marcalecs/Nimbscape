import Foundation
import AVFoundation
import AppKit
import Combine

public struct CollectionCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let folderURL: URL
    public var item: WallpaperItem
    public var isAlreadyImported: Bool

    public init(id: String, folderURL: URL, item: WallpaperItem, isAlreadyImported: Bool) {
        self.id = id
        self.folderURL = folderURL
        self.item = item
        self.isAlreadyImported = isAlreadyImported
    }
}

public struct SkippedCollectionFolder: Identifiable, Equatable, Sendable {
    public let id: String
    public let folderName: String
    public let reason: String

    public init(folderName: String, reason: String) {
        self.id = folderName
        self.folderName = folderName
        self.reason = reason
    }
}

public struct CollectionScanResult: Equatable, Sendable {
    public let scannedPath: String
    public var candidates: [CollectionCandidate]
    public var skipped: [SkippedCollectionFolder]
    public let scannedAt: Date
}

public enum CollectionScanError: LocalizedError, Equatable, Sendable {
    case folderNotFound(String)
    case unreadableDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let path):
            return "Collection folder not found at:\n\(path)\n\nChoose a local folder containing wallpaper packages."
        case .unreadableDirectory(let detail):
            return "Unable to read folder: \(detail)"
        }
    }
}

@MainActor
public class FolderCollectionScanner: ObservableObject {
    public static let shared = FolderCollectionScanner()

    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var lastResult: CollectionScanResult?
    @Published public private(set) var lastError: CollectionScanError?

    public nonisolated static var thumbnailsCacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Nimbscape/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    public func scan(directoryURL: URL? = nil) {
        let targetURL = directoryURL ?? URL(fileURLWithPath: AppPreferences.shared.collectionFolderPath)
        let targetPath = targetURL.path

        self.isScanning = true
        self.lastError = nil

        let existingPaths: Set<String> = Set(
            WallpaperStore.shared.wallpapers.map {
                URL(fileURLWithPath: $0.pathOrURL).standardizedFileURL.path
            }
        )

        Task.detached(priority: .userInitiated) {
            let outcome = Self.performScanSync(
                targetURL: targetURL,
                targetPath: targetPath,
                existingPaths: existingPaths
            )
            await MainActor.run {
                self.isScanning = false
                switch outcome {
                case .success(let result):
                    self.lastError = nil
                    self.lastResult = result
                case .failure(let error):
                    self.lastResult = nil
                    self.lastError = error
                }
            }
        }
    }

    private nonisolated static func performScanSync(
        targetURL: URL,
        targetPath: String,
        existingPaths: Set<String>
    ) -> Result<CollectionScanResult, CollectionScanError> {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: targetPath, isDirectory: &isDir), isDir.boolValue else {
            return .failure(.folderNotFound(targetPath))
        }

        let subdirs: [URL]
        do {
            subdirs = try fileManager.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .failure(.unreadableDirectory(error.localizedDescription))
        }

        var candidates: [CollectionCandidate] = []
        var skipped: [SkippedCollectionFolder] = []

        for url in subdirs {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let projectJSON = url.appendingPathComponent("project.json")
            guard fileManager.fileExists(atPath: projectJSON.path) else { continue }

            switch WallpaperPackageParser.parseFolderResult(
                at: url,
                source: .localImport
            ) {
            case .success(var item):
                if item.previewPath == nil && item.type == .video {
                    if let thumbURL = Self.generateVideoThumbnailSync(for: URL(fileURLWithPath: item.pathOrURL), cacheKey: url.lastPathComponent) {
                        item.previewPath = thumbURL.path
                    }
                }
                let normalized = URL(fileURLWithPath: item.pathOrURL).standardizedFileURL.path
                let imported = existingPaths.contains(normalized)
                candidates.append(CollectionCandidate(
                    id: url.lastPathComponent,
                    folderURL: url,
                    item: item,
                    isAlreadyImported: imported
                ))
            case .failure(let error):
                skipped.append(SkippedCollectionFolder(
                    folderName: url.lastPathComponent,
                    reason: error.localizedDescription
                ))
            }
        }

        candidates.sort { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }

        return .success(CollectionScanResult(
            scannedPath: targetPath,
            candidates: candidates,
            skipped: skipped,
            scannedAt: Date()
        ))
    }

    public func importCandidate(_ candidate: CollectionCandidate, activate: Bool = false) {
        WallpaperStore.shared.addCustomWallpaper(candidate.item, activate: activate)
        refreshImportedFlags()
    }

    @discardableResult
    public func importAllNew() -> Int {
        guard let result = lastResult else { return 0 }
        let newCandidates = result.candidates.filter { !$0.isAlreadyImported }
        for candidate in newCandidates {
            WallpaperStore.shared.addCustomWallpaper(candidate.item, activate: false)
        }
        refreshImportedFlags()
        return newCandidates.count
    }

    public func refreshImportedFlags() {
        guard var result = lastResult else { return }
        for index in result.candidates.indices {
            let path = result.candidates[index].item.pathOrURL
            result.candidates[index].isAlreadyImported = WallpaperStore.shared.containsWallpaper(pathOrURL: path)
        }
        self.lastResult = result
    }

    public nonisolated static func generateVideoThumbnailSync(for videoURL: URL, cacheKey: String) -> URL? {
        let safeKey = cacheKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let destURL = thumbnailsCacheDirectory.appendingPathComponent("\(safeKey).jpg")

        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let times: [CMTime] = [
            CMTime(seconds: 1.0, preferredTimescale: 600),
            CMTime.zero
        ]

        var cgImage: CGImage?
        for time in times {
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                cgImage = image
                break
            }
        }

        guard let finalImage = cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: finalImage)
        guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return nil
        }

        do {
            try jpegData.write(to: destURL, options: .atomic)
            return destURL
        } catch {
            return nil
        }
    }

    public static func generateThumbnailAsync(for item: WallpaperItem) {
        guard item.type == .video, item.previewPath == nil else { return }
        let videoURL = URL(fileURLWithPath: item.pathOrURL)
        let id = item.id
        Task.detached(priority: .utility) {
            if let thumbURL = generateVideoThumbnailSync(for: videoURL, cacheKey: id) {
                await MainActor.run {
                    WallpaperStore.shared.updatePreviewPath(thumbURL.path, for: id)
                }
            }
        }
    }

    public nonisolated static func clearThumbnailCache() {
        let fileManager = FileManager.default
        let dir = thumbnailsCacheDirectory
        if let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    public nonisolated static func thumbnailCacheSizeBytes() -> Int64 {
        let fileManager = FileManager.default
        let dir = thumbnailsCacheDirectory
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }
}
