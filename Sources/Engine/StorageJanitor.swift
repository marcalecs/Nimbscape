import Foundation

/// Owns the on-disk lifecycle of files Nimbscape downloads itself (the HD catalog folder),
/// plus one-time cleanup of folders left behind by older builds.
/// Files the user imported from elsewhere are never touched.
@MainActor
public enum StorageJanitor {
    /// Folders written by pre-1.0 builds (Steam Workshop integration) that no code uses anymore.
    private static let legacyFolders = ["steamcmd", "WorkshopDownloads", "WorkshopPreviews", "WorkshopThumbCache"]

    /// Files touched more recently than this are left alone by the orphan sweep, so a download
    /// that is still being written or imported is never mistaken for an orphan.
    private static let orphanGracePeriod: TimeInterval = 10 * 60

    private static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Nimbscape", isDirectory: true)
    }

    private static var managedDirectory: URL {
        HDCatalogDownloader.shared.wallpapersDirectory.standardizedFileURL
    }

    /// True when `path` lives inside the folder Nimbscape manages (HD catalog downloads).
    public static func isManaged(path: String) -> Bool {
        let dir = managedDirectory.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(dir + "/")
    }

    // MARK: - Removal

    /// Deletes the managed files (video + preview) of a wallpaper just removed from the library.
    /// A file still referenced by another library item is kept.
    public static func deleteManagedFiles(of removed: WallpaperItem, remaining: [WallpaperItem]) {
        let stillReferenced = referencedPaths(in: remaining)
        for path in [removed.pathOrURL, removed.previewPath].compactMap({ $0 }) {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard isManaged(path: standardized), !stillReferenced.contains(standardized) else { continue }
            try? FileManager.default.removeItem(atPath: standardized)
        }
    }

    // MARK: - Launch cleanup

    /// Removes legacy Steam/Workshop folders, interrupted `.part` downloads and HD files no
    /// library item references. Disk work runs off the main thread.
    public static func cleanupOnLaunch() {
        let referenced = referencedPaths(in: WallpaperStore.shared.wallpapers)
        let appSupport = appSupportDirectory
        let managed = managedDirectory
        let downloadInProgress = HDCatalogDownloader.shared.isDownloading
        let grace = orphanGracePeriod
        let legacy = legacyFolders

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var freed: Int64 = 0

            for name in legacy {
                let url = appSupport.appendingPathComponent(name, isDirectory: true)
                guard fm.fileExists(atPath: url.path) else { continue }
                freed += directorySize(url)
                try? fm.removeItem(at: url)
            }

            if !downloadInProgress,
               let files = try? fm.contentsOfDirectory(
                   at: managed,
                   includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
               ) {
                let cutoff = Date().addingTimeInterval(-grace)
                for file in files {
                    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    let modified = values?.contentModificationDate ?? .distantPast
                    let isPart = file.pathExtension == "part"
                    let isOrphan = !referenced.contains(file.standardizedFileURL.path)
                    guard (isPart || isOrphan), modified < cutoff else { continue }
                    freed += Int64(values?.fileSize ?? 0)
                    try? fm.removeItem(at: file)
                }
            }

            if freed > 0 {
                NSLog("Nimbscape StorageJanitor: freed %@", ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))
            }
        }
    }

    // MARK: - Usage

    /// Total size of downloaded HD wallpapers, for the Settings screen.
    public static func managedSizeBytes() -> Int64 {
        directorySize(managedDirectory)
    }

    // MARK: - Helpers

    private static func referencedPaths(in items: [WallpaperItem]) -> Set<String> {
        var paths = Set<String>()
        for item in items where !item.isBuiltIn {
            paths.insert(URL(fileURLWithPath: item.pathOrURL).standardizedFileURL.path)
            if let preview = item.previewPath {
                paths.insert(URL(fileURLWithPath: preview).standardizedFileURL.path)
            }
        }
        return paths
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
