import Foundation
import AppKit
import AVFoundation
import WebKit
import ImageIO
import Combine

public enum SmartImageDecoder {
    public static func decodeBestFrame(from data: Data, maxPixelSize: Int = 520) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }
        return decodeBestFrame(from: source, maxPixelSize: maxPixelSize)
    }

    public static func decodeBestFrame(from url: URL, maxPixelSize: Int = 520) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        return decodeBestFrame(from: source, maxPixelSize: maxPixelSize)
    }

    private static func decodeBestFrame(from source: CGImageSource, maxPixelSize: Int) -> NSImage? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        if count == 1 {
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            return nil
        }

        let candidateIndices = Array(Set([
            0,
            max(0, count / 4),
            max(0, count / 2),
            max(0, (count * 3) / 4)
        ])).sorted()

        var bestCG: CGImage?
        var bestScore: Double = -1

        for idx in candidateIndices {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, idx, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, idx, nil) else { continue }
            let score = averageLuminance(of: cg)
            if score > bestScore {
                bestScore = score
                bestCG = cg
            }
            if score > 0.18 {
                break
            }
        }

        guard let finalCG = bestCG else { return nil }
        return NSImage(cgImage: finalCG, size: NSSize(width: finalCG.width, height: finalCG.height))
    }

    private static func averageLuminance(of cgImage: CGImage) -> Double {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0.5
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var sum: Double = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return sum / Double(size * size)
    }
}

@MainActor
public final class RemotePreviewCache: ObservableObject {
    public static let shared = RemotePreviewCache()

    @Published public private(set) var images: [URL: NSImage] = [:]
    private var inFlight: Set<URL> = []

    private var diskCacheDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Nimbscape/WorkshopThumbCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    public func image(for url: URL) -> NSImage? {
        if let cached = images[url] {
            return cached
        }
        request(url: url)
        return nil
    }

    public func request(url: URL) {
        if images[url] != nil || inFlight.contains(url) { return }
        inFlight.insert(url)

        let cacheFile = diskCacheFile(for: url)
        Task.detached(priority: .utility) {
            if let diskData = try? Data(contentsOf: cacheFile),
               let img = NSImage(data: diskData) {
                await MainActor.run {
                    self.images[url] = img
                    self.inFlight.remove(url)
                }
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

            var decoded: NSImage?
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 {
                decoded = SmartImageDecoder.decodeBestFrame(from: data, maxPixelSize: 480)
                if let img = decoded,
                   let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                    try? jpg.write(to: cacheFile, options: .atomic)
                }
            }

            let finalImage = decoded
            await MainActor.run {
                if let img = finalImage {
                    self.images[url] = img
                }
                self.inFlight.remove(url)
            }
        }
    }

    private func diskCacheFile(for url: URL) -> URL {
        let key = String(abs(url.absoluteString.hashValue))
        return diskCacheDir.appendingPathComponent("\(key).jpg")
    }
}

@MainActor
public final class WallpaperThumbnailGenerator: NSObject, ObservableObject, WKNavigationDelegate {
    public static let shared = WallpaperThumbnailGenerator()

    @Published public private(set) var thumbnails: [String: NSImage] = [:]

    private var queuedIDs: Set<String> = []
    private var webQueue: [WallpaperItem] = []
    private var isCapturingWeb: Bool = false

    private var offscreenWindow: NSWindow?
    private var captureWebView: WKWebView?
    private var currentWebItem: WallpaperItem?
    private var captureTimeoutWork: DispatchWorkItem?

    private var cacheDir: URL {
        WorkshopScanner.thumbnailsCacheDirectory
    }

    private override init() {
        super.init()
    }

    public func thumbnail(for item: WallpaperItem) -> NSImage? {
        if let mem = thumbnails[item.id] {
            return mem
        }
        requestThumbnail(for: item)
        return nil
    }

    public func requestThumbnail(for item: WallpaperItem) {
        if thumbnails[item.id] != nil || queuedIDs.contains(item.id) { return }
        queuedIDs.insert(item.id)

        if let p = item.previewPath, FileManager.default.fileExists(atPath: p) {
            let url = URL(fileURLWithPath: p)
            let itemID = item.id
            Task.detached(priority: .userInitiated) {
                let img = SmartImageDecoder.decodeBestFrame(from: url, maxPixelSize: 520)
                await MainActor.run {
                    if let img { self.thumbnails[itemID] = img }
                }
            }
            return
        }

        let cachedURL = cacheURL(for: item)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            let itemID = item.id
            Task.detached(priority: .userInitiated) {
                let img = NSImage(contentsOf: cachedURL)
                await MainActor.run {
                    if let img { self.thumbnails[itemID] = img }
                }
            }
            return
        }

        switch item.type {
        case .image:
            let url = URL(fileURLWithPath: item.pathOrURL)
            let itemID = item.id
            Task.detached(priority: .userInitiated) {
                let img = SmartImageDecoder.decodeBestFrame(from: url, maxPixelSize: 520)
                await MainActor.run {
                    if let img { self.thumbnails[itemID] = img }
                }
            }

        case .video:
            let url = URL(fileURLWithPath: item.pathOrURL)
            let itemID = item.id
            Task.detached(priority: .utility) {
                let img = Self.generateVideoThumbnail(url: url, saveTo: cachedURL)
                await MainActor.run {
                    if let img { self.thumbnails[itemID] = img }
                }
            }

        case .web, .url:
            webQueue.append(item)
            processNextWebCapture()
        }
    }

    private func cacheURL(for item: WallpaperItem) -> URL {
        let safeID = item.id.replacingOccurrences(of: "/", with: "_")
        return cacheDir.appendingPathComponent("thumb_v5_\(safeID).png")
    }

    private nonisolated static func generateVideoThumbnail(url: URL, saveTo outURL: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 520, height: 300)

        let times = [
            CMTime(seconds: 1.5, preferredTimescale: 600),
            CMTime(seconds: 0.2, preferredTimescale: 600),
            CMTime.zero
        ]
        for t in times {
            if let cg = try? generator.copyCGImage(at: t, actualTime: nil) {
                let nsImg = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                if let rep = NSBitmapImageRep(cgImage: cg) as NSBitmapImageRep?,
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: outURL, options: .atomic)
                }
                return nsImg
            }
        }
        return nil
    }

    private func ensureOffscreenWebView() -> WKWebView {
        if let wv = captureWebView { return wv }

        let screenOrigin = NSScreen.main?.frame.origin ?? .zero
        let rect = NSRect(x: screenOrigin.x, y: screenOrigin.y, width: 480, height: 270)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 5)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.canHide = false
        win.alphaValue = 1.0
        win.orderBack(nil)

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let captureShim = """
        (function() {
            window.__nsSpeed = 1.0;

            window.requestAnimationFrame = function(cb) {
                return setTimeout(function() { cb(performance.now()); }, 16);
            };
            window.cancelAnimationFrame = function(id) {
                clearTimeout(id);
            };
            window.wallpaperRegisterAudioListener = function(cb) {
                if (typeof cb !== 'function') return;
                const arr = new Array(128);
                for (let i = 0; i < 128; i++) {
                    const x = (i % 64) / 64;
                    arr[i] = Math.max(0.08, Math.sin(x * Math.PI) * 0.85 + Math.abs(Math.sin(i * 0.65)) * 0.25);
                }
                setTimeout(() => { try { cb(arr); } catch(e) {} }, 80);
                setTimeout(() => { try { cb(arr); } catch(e) {} }, 250);
            };
        })();
"""
        config.userContentController.addUserScript(
            WKUserScript(source: captureShim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
        wv.navigationDelegate = self
        win.contentView = wv

        offscreenWindow = win
        captureWebView = wv
        return wv
    }

    private func processNextWebCapture() {
        guard !isCapturingWeb else { return }
        guard !webQueue.isEmpty else {
            tearDownOffscreenWebView()
            return
        }

        isCapturingWeb = true
        let item = webQueue.removeFirst()
        currentWebItem = item

        let wv = ensureOffscreenWebView()

        captureTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishCurrentWebCapture(with: nil)
            }
        }
        captureTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)

        if item.type == .url, let remoteURL = URL(string: item.pathOrURL) {
            wv.load(URLRequest(url: remoteURL))
        } else {
            let fileURL = URL(fileURLWithPath: item.pathOrURL)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                wv.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            } else {
                finishCurrentWebCapture(with: nil)
            }
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCapturingWeb, let item = currentWebItem else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, self.isCapturingWeb, self.currentWebItem?.id == item.id else { return }
            let snapConfig = WKSnapshotConfiguration()
            snapConfig.rect = CGRect(x: 0, y: 0, width: 480, height: 270)
            webView.takeSnapshot(with: snapConfig) { [weak self] image, _ in
                Task { @MainActor [weak self] in
                    self?.finishCurrentWebCapture(with: image)
                }
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishCurrentWebCapture(with: nil)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishCurrentWebCapture(with: nil)
    }

    private func finishCurrentWebCapture(with image: NSImage?) {
        captureTimeoutWork?.cancel()
        captureTimeoutWork = nil

        if let item = currentWebItem, let img = image {
            thumbnails[item.id] = img
            let outURL = cacheURL(for: item)
            if let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: outURL, options: .atomic)
            }
        }

        currentWebItem = nil
        isCapturingWeb = false
        processNextWebCapture()
    }

    private func tearDownOffscreenWebView() {
        captureWebView?.navigationDelegate = nil
        captureWebView?.loadHTMLString("", baseURL: nil)
        captureWebView = nil
        offscreenWindow?.orderOut(nil)
        offscreenWindow = nil
    }
}
