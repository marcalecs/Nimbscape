import Foundation
import AVFoundation
import AppKit

public enum WallpaperImportError: LocalizedError, Equatable, Sendable {
    case folderNotFound(String)
    case invalidProjectJSON(String)
    case unsupportedScenePackage(String)
    case missingSupportedMedia(String)

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let path):
            return "Folder not found: \(path)"
        case .invalidProjectJSON(let detail):
            return "Invalid project.json manifest: \(detail)"
        case .unsupportedScenePackage(let file):
            return "Unsupported binary package (\(file)). Select a video, HTML5 web scene, or image instead."
        case .missingSupportedMedia(let folder):
            return "No supported video (.mp4/.mov/.m4v/.webm), web scene (index.html), or image found in \"\(folder)\"."
        }
    }
}

public enum AnyJSONScalar: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)

    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            self = .string("")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        }
    }
}

public struct ProjectJSONPropertyOption: Codable {
    public let label: String?
    public let value: AnyJSONScalar?
}

public struct ProjectJSONProperty: Codable {
    public let text: String?
    public let type: String?
    public let value: AnyJSONScalar?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let options: [ProjectJSONPropertyOption]?
}

public struct ProjectJSONGeneral: Codable {
    public let properties: [String: ProjectJSONProperty]?
}

public struct WallpaperManifest: Codable {
    public let title: String?
    public let description: String?
    public let file: String?
    public let preview: String?
    public let type: String?
    public let tags: [String]?
    public let general: ProjectJSONGeneral?
}

public class WallpaperPackageParser {
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif"]

    public static func parseFolder(at folderURL: URL, source: WallpaperSource = .localImport) -> WallpaperItem? {
        if case .success(let item) = parseFolderResult(at: folderURL, source: source) {
            return item
        }
        return nil
    }

    public static func parseFolderResult(
        at folderURL: URL,
        source: WallpaperSource = .localImport,
        allowScenePreviewFallback: Bool = false
    ) -> Result<WallpaperItem, WallpaperImportError> {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(.folderNotFound(folderURL.path))
        }

        let projectJSONURL = folderURL.appendingPathComponent("project.json")

        var title = folderURL.lastPathComponent
        var targetFile: String?
        var previewPath: String?
        var detectedType: WallpaperType = .web
        var tags: [String] = []
        var customProps: [String: String] = [:]
        var propertySpecs: [ProjectPropertySpec] = []
        var unsupportedPkgFile: String?

        if fileManager.fileExists(atPath: projectJSONURL.path) {
            do {
                let data = try Data(contentsOf: projectJSONURL)
                let project = try JSONDecoder().decode(WallpaperManifest.self, from: data)

                if let pTitle = project.title, !pTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = pTitle
                }

                if let pTags = project.tags {
                    tags = pTags.filter { !$0.isEmpty }
                }

                if let props = project.general?.properties {
                    for (key, rawProp) in props.sorted(by: { $0.key < $1.key }) {
                        let valueStr = rawProp.value?.stringValue ?? ""
                        customProps[key] = valueStr

                        let mappedType: ProjectPropertyType
                        switch (rawProp.type ?? "").lowercased() {
                        case "slider": mappedType = .slider
                        case "bool": mappedType = .bool
                        case "color": mappedType = .color
                        case "combo": mappedType = .combo
                        default: mappedType = .text
                        }

                        var opts: [String: String]? = nil
                        if let rawOptions = rawProp.options {
                            var dict: [String: String] = [:]
                            for opt in rawOptions {
                                if let val = opt.value?.stringValue {
                                    dict[val] = opt.label ?? val
                                }
                            }
                            if !dict.isEmpty { opts = dict }
                        }

                        propertySpecs.append(ProjectPropertySpec(
                            key: key,
                            text: rawProp.text ?? key,
                            type: mappedType,
                            defaultValue: valueStr,
                            min: rawProp.min,
                            max: rawProp.max,
                            step: rawProp.step,
                            options: opts
                        ))
                    }
                }

                if let pFile = project.file, !pFile.isEmpty {
                    let fullPath = folderURL.appendingPathComponent(pFile)
                    let ext = fullPath.pathExtension.lowercased()
                    if ext == "pkg" || (project.type?.lowercased() == "scene" && ext == "json") {
                        unsupportedPkgFile = pFile
                    } else if fileManager.fileExists(atPath: fullPath.path) {
                        targetFile = fullPath.path
                        if videoExtensions.contains(ext) {
                            detectedType = .video
                        } else if imageExtensions.contains(ext) {
                            detectedType = .image
                        } else {
                            detectedType = .web
                        }
                    }
                }

                if let pPreview = project.preview, !pPreview.isEmpty {
                    let fullPreview = folderURL.appendingPathComponent(pPreview)
                    if fileManager.fileExists(atPath: fullPreview.path) {
                        previewPath = fullPreview.path
                    }
                }
            } catch {
                return .failure(.invalidProjectJSON(error.localizedDescription))
            }
        }

        if targetFile == nil {
            if let contents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) {
                if let videoURL = contents.first(where: { videoExtensions.contains($0.pathExtension.lowercased()) }) {
                    targetFile = videoURL.path
                    detectedType = .video
                } else if let htmlURL = contents.first(where: { $0.lastPathComponent.lowercased() == "index.html" }) {
                    targetFile = htmlURL.path
                    detectedType = .web
                } else if let anyHtmlURL = contents.first(where: { $0.pathExtension.lowercased() == "html" }) {
                    targetFile = anyHtmlURL.path
                    detectedType = .web
                }

                if previewPath == nil {
                    if let imgURL = contents.first(where: { ["gif", "png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }) {
                        previewPath = imgURL.path
                    }
                }
            }
        }

        if targetFile == nil, unsupportedPkgFile != nil, allowScenePreviewFallback, let preview = previewPath {
            targetFile = preview
            detectedType = .image
            if !tags.contains("Scene Preview") {
                tags.append("Scene Preview")
            }
        }

        guard var finalPath = targetFile else {
            if let pkg = unsupportedPkgFile {
                return .failure(.unsupportedScenePackage(pkg))
            }
            return .failure(.missingSupportedMedia(folderURL.lastPathComponent))
        }

        let originalFileURL = URL(fileURLWithPath: finalPath)
        let fileSize = fileSizeBytes(at: originalFileURL)
        let resolutionLabel = extractResolutionLabel(for: originalFileURL, type: detectedType)

        if detectedType == .video && originalFileURL.pathExtension.lowercased() == "webm" {
            if let wrappedHTML = createWebMWrapper(for: originalFileURL) {
                finalPath = wrappedHTML.path
                detectedType = .web
                if !tags.contains("WebM") {
                    tags.append("WebM")
                }
            }
        }

        var wpProps = WallpaperProperties()
        wpProps.customProps = customProps

        let item = WallpaperItem(
            id: UUID().uuidString,
            title: title,
            type: detectedType,
            pathOrURL: finalPath,
            previewPath: previewPath,
            isBuiltIn: false,
            isFavorite: false,
            tags: tags,
            resolutionLabel: resolutionLabel,
            fileSizeBytes: fileSize,
            source: source,
            properties: wpProps,
            projectPropertySpecs: propertySpecs
        )
        return .success(item)
    }

    public static func parseVideoFile(at fileURL: URL, source: WallpaperSource = .localImport) -> WallpaperItem {
        let title = fileURL.deletingPathExtension().lastPathComponent
        var finalPath = fileURL.path
        var finalType: WallpaperType = .video
        var tags = ["Video"]

        if fileURL.pathExtension.lowercased() == "webm",
           let wrapped = createWebMWrapper(for: fileURL) {
            finalPath = wrapped.path
            finalType = .web
            tags.append("WebM")
        }

        return WallpaperItem(
            id: UUID().uuidString,
            title: title,
            type: finalType,
            pathOrURL: finalPath,
            previewPath: nil,
            isBuiltIn: false,
            isFavorite: false,
            tags: tags,
            resolutionLabel: extractResolutionLabel(for: fileURL, type: .video),
            fileSizeBytes: fileSizeBytes(at: fileURL),
            source: source
        )
    }

    public static func parseImageFile(at fileURL: URL, source: WallpaperSource = .localImport) -> WallpaperItem {
        let title = fileURL.deletingPathExtension().lastPathComponent
        return WallpaperItem(
            id: UUID().uuidString,
            title: title,
            type: .image,
            pathOrURL: fileURL.path,
            previewPath: fileURL.path,
            isBuiltIn: false,
            isFavorite: false,
            tags: ["Image"],
            resolutionLabel: extractResolutionLabel(for: fileURL, type: .image),
            fileSizeBytes: fileSizeBytes(at: fileURL),
            source: source
        )
    }

    public static func createWebMWrapper(for videoURL: URL) -> URL? {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let key = String(abs(videoURL.standardizedFileURL.path.hashValue))
        let wrapperDir = appSupport
            .appendingPathComponent("Nimbscape/WebmWrappers", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)

        do {
            try fileManager.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
            let linkURL = wrapperDir.appendingPathComponent("video.webm")
            if fileManager.fileExists(atPath: linkURL.path) {
                try? fileManager.removeItem(at: linkURL)
            }
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: videoURL.standardizedFileURL)

            let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
            video { width: 100vw; height: 100vh; object-fit: cover; display: block; }
            </style>
            </head>
            <body>
            <video id="v" src="video.webm" autoplay loop muted playsinline></video>
            <script>
            const v = document.getElementById('v');
            v.play().catch(() => {});
            </script>
            </body>
            </html>
"""
            let indexURL = wrapperDir.appendingPathComponent("index.html")
            try html.write(to: indexURL, atomically: true, encoding: .utf8)
            return indexURL
        } catch {
            return nil
        }
    }

    public static func fileSizeBytes(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    public static func extractResolutionLabel(for url: URL, type: WallpaperType) -> String? {
        switch type {
        case .video:
            final class LabelBox: @unchecked Sendable {
                var value: String = "Video"
            }
            let asset = AVURLAsset(url: url)
            let sem = DispatchSemaphore(value: 0)
            let box = LabelBox()
            Task.detached {
                if let tracks = try? await asset.loadTracks(withMediaType: .video),
                   let track = tracks.first,
                   let (naturalSize, transform, frameRate) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) {
                    let transformed = naturalSize.applying(transform)
                    let w = Int(abs(transformed.width))
                    let h = Int(abs(transformed.height))
                    let fps = Int(round(frameRate))
                    if w > 0 && h > 0 {
                        box.value = fps > 0 ? "\(w)×\(h) · \(fps) FPS" : "\(w)×\(h)"
                    }
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2.0)
            return box.value
        case .image:
            if let rep = NSImageRep(contentsOf: url), rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                return "\(rep.pixelsWide)×\(rep.pixelsHigh)"
            }
            return "Image"
        case .web:
            return "Dynamic · HTML5"
        case .url:
            return "Web Scene"
        }
    }
}
