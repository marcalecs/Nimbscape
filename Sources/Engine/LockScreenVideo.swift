import Cocoa
import AVFoundation
import VideoToolbox
import CoreImage

/// Puts a video wallpaper on the macOS lock screen (macOS 26+) by replacing the video of the
/// Aerial wallpaper the user picked in System Settings. macOS then plays it itself, under its own
/// clock and password field.
///
/// Requirements found while prototyping (see also github.com/AlexisBCD/macos-custom-video-wallpaper-fix):
/// - The file must carry HEVC temporal sub-layers (`BaseLayerFrameRate` = fps / 2); the unlock
///   animation reads them and the desktop turns black without them.
/// - Video only, about five minutes long (shorter files freeze after one pass).
/// - WallpaperAgent must not be restarted (macOS then re-downloads Apple's original); restarting
///   the Aerials extension is enough for it to pick the new file up.
@MainActor
public final class LockScreenVideo: ObservableObject {
    public static let shared = LockScreenVideo()

    public enum State: Equatable {
        case idle
        case encoding(progress: Double)
        case failed(String)
    }

    /// What is installed now.
    public struct Installed: Codable, Equatable, Sendable {
        public var assetID: String
        public var wallpaperID: String
        public var title: String
        public var fileSize: Int64
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var installed: Installed?
    @Published public var playDuration: LockScreenTimeline.PlayDuration {
        didSet { UserDefaults.standard.set(playDuration.rawValue, forKey: Self.durationKey) }
    }

    private static let durationKey = "nimbscape.lockVideo.duration"
    private static let installedKey = "nimbscape.lockVideo.installed"
    private var encodeTask: Task<Void, Never>?

    private init() {
        playDuration = LockScreenTimeline.PlayDuration(rawValue: UserDefaults.standard.integer(forKey: Self.durationKey)) ?? .minutes2
        if let data = UserDefaults.standard.data(forKey: Self.installedKey) {
            installed = try? JSONDecoder().decode(Installed.self, from: data)
        }
    }

    // MARK: Paths

    static var videosDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos", isDirectory: true)
    }

    static var backupDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Nimbscape/AerialBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Status

    /// True while our video is in place (macOS may restore Apple's file after an update).
    public var isActive: Bool {
        guard let installed else { return false }
        let path = Self.videosDirectory.appendingPathComponent("\(installed.assetID).mov").path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
        return size == installed.fileSize
    }

    /// macOS put its own video back over ours.
    public var wasRestoredByMacOS: Bool { installed != nil && !isActive }

    /// The Aerial picked in System Settings → Wallpaper, if its video is downloaded.
    public static func selectedAerialAssetID() -> String? {
        let index = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: index),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        var found: String?
        func walk(_ node: Any) {
            guard found == nil else { return }
            if let dict = node as? [String: Any] {
                if dict["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
                   let config = dict["Configuration"] as? Data,
                   let inner = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any],
                   let id = inner["assetID"] as? String,
                   FileManager.default.fileExists(atPath: videosDirectory.appendingPathComponent("\(id).mov").path) {
                    found = id
                    return
                }
                dict.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)
        return found
    }

    public static func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Install / restore

    public func install(_ item: WallpaperItem) {
        guard item.type == .video, encodeTask == nil else { return }
        guard let assetID = Self.selectedAerialAssetID() else {
            state = .failed("Pick a downloadable Aerial in System Settings → Wallpaper first (not Tahoe Day).")
            return
        }
        let target = Self.videosDirectory.appendingPathComponent("\(assetID).mov")
        let backup = Self.backupDirectory.appendingPathComponent("\(assetID).mov")
        // Back up Apple's file once; never overwrite the backup with one of our own encodes.
        let ownsTarget = installed?.assetID == assetID && isActive
        if !ownsTarget && !FileManager.default.fileExists(atPath: backup.path) {
            do { try FileManager.default.copyItem(at: target, to: backup) } catch {
                state = .failed("Couldn't back up the original Aerial.")
                return
            }
        }

        let source = URL(fileURLWithPath: item.pathOrURL)
        let staging = Self.videosDirectory.appendingPathComponent("\(assetID).mov.nimbscape-new")
        let playSeconds = Double(playDuration.rawValue)
        // Bake the desktop look into the video: color & tone and speed from the wallpaper's
        // properties, dim and blur from its overlay effects.
        let effects = OverlayStore.shared.config(for: item.id).effects
        let look = LockScreenLook(
            hue: item.properties.hue, brightness: item.properties.brightness,
            contrast: item.properties.contrast, saturation: item.properties.saturation,
            speed: Double(item.properties.speed), dim: effects.dim, blur: effects.blur
        )
        state = .encoding(progress: 0)
        encodeTask = Task { [weak self] in
            let size = await Self.outputSize(reference: backup)
            let result = await Self.encode(source: source, to: staging, size: size, playSeconds: playSeconds, look: look) { progress in
                Task { @MainActor in
                    if case .encoding = LockScreenVideo.shared.state { LockScreenVideo.shared.state = .encoding(progress: progress) }
                }
            }
            guard let self else { return }
            self.encodeTask = nil
            switch result {
            case .failure(let message):
                try? FileManager.default.removeItem(at: staging)
                self.state = .failed(message)
            case .success:
                do {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
                    let fileSize = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
                    self.setInstalled(Installed(assetID: assetID, wallpaperID: item.id, title: item.title, fileSize: fileSize))
                    Self.reloadAerialPlayer()
                    self.state = .idle
                    WallpaperManager.shared.refreshLockScreenSyncAfterLockVideoChange()
                } catch {
                    self.state = .failed("Couldn't replace the Aerial video.")
                }
            }
        }
    }

    public func cancel() {
        encodeTask?.cancel()
    }

    /// Puts Apple's original video back.
    public func restore() {
        guard let installed else { return }
        let target = Self.videosDirectory.appendingPathComponent("\(installed.assetID).mov")
        let backup = Self.backupDirectory.appendingPathComponent("\(installed.assetID).mov")
        if FileManager.default.fileExists(atPath: backup.path) {
            let staging = Self.videosDirectory.appendingPathComponent("\(installed.assetID).mov.nimbscape-new")
            try? FileManager.default.removeItem(at: staging)
            if (try? FileManager.default.copyItem(at: backup, to: staging)) != nil {
                _ = try? FileManager.default.replaceItemAt(target, withItemAt: staging)
                try? FileManager.default.removeItem(at: backup)
            }
        }
        setInstalled(nil)
        Self.reloadAerialPlayer()
        state = .idle
        WallpaperManager.shared.refreshLockScreenSyncAfterLockVideoChange()
    }

    private func setInstalled(_ value: Installed?) {
        installed = value
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.installedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.installedKey)
        }
    }

    /// Restarts only the Aerials extension so it opens the new file (not WallpaperAgent).
    private static func reloadAerialPlayer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAerialsExtension"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Encoding

    enum EncodeResult: Sendable, Equatable { case success, failure(String) }

    /// Matches Apple's file size (usually 3840×2160).
    private nonisolated static func outputSize(reference: URL) async -> CGSize {
        let asset = AVURLAsset(url: reference)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), size.width > 0 {
            return size
        }
        return CGSize(width: 3840, height: 2160)
    }

    private final class SampleSink: @unchecked Sendable {
        var samples: [CMSampleBuffer] = []
        /// Frames handed to the encoder and not yet returned (bounded to keep memory flat).
        var inFlight = 0
        let lock = NSLock()

        /// Takes an encoder slot if one is free.
        func tryReserve(limit: Int) -> Bool {
            lock.withLock {
                guard inFlight < limit else { return false }
                inFlight += 1
                return true
            }
        }

        func releaseSlot() { lock.withLock { inFlight -= 1 } }
    }

    /// Frames allowed in the encoder at once. Without a bound the hardware encoder lags behind
    /// and every queued 4K 10-bit frame (~25 MB) stays in memory.
    private nonisolated static let maxFramesInFlight = 4
    /// Stop encoding if the process footprint ever exceeds this.
    private nonisolated static let memoryLimitBytes: UInt64 = 3 << 30

    private nonisolated static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// HEVC Main10 with temporal sub-layers, BT.709, video only, scaled to cover `size`, following
    /// `LockScreenTimeline` (play, ease out, hold).
    nonisolated static func encode(source: URL, to destination: URL, size: CGSize, playSeconds: Double,
                                           look: LockScreenLook,
                                           progress: @escaping @Sendable (Double) -> Void) async -> EncodeResult {
        do {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .failure("The wallpaper has no video track.") }
            let fps = max(1, Double(try await track.load(.nominalFrameRate)))
            let flags = LockScreenTimeline.advanceFlags(fps: fps, playSeconds: playSeconds)
            let width = Int(size.width), height = Int(size.height)

            let sink = SampleSink()
            var session: VTCompressionSession?
            let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
            VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                                       encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                       outputCallback: { refcon, _, status, _, sample in
                                           guard let refcon else { return }
                                           let sink = Unmanaged<SampleSink>.fromOpaque(refcon).takeUnretainedValue()
                                           sink.lock.lock()
                                           sink.inFlight -= 1
                                           if status == noErr, let sample { sink.samples.append(sample) }
                                           sink.lock.unlock()
                                       }, refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &session)
            guard let session else { return .failure("The HEVC encoder isn't available.") }
            defer { VTCompressionSessionInvalidate(session) }
            let properties: [CFString: Any] = [
                kVTCompressionPropertyKey_RealTime: false,
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel,
                kVTCompressionPropertyKey_AllowFrameReordering: true,
                kVTCompressionPropertyKey_ExpectedFrameRate: fps,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(fps * 5),
                kVTCompressionPropertyKey_AverageBitRate: 12_000_000,
                kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
                kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                kVTCompressionPropertyKey_AllowTemporalCompression: true,
                kVTCompressionPropertyKey_BaseLayerFrameRate: fps / 2,   // the temporal sub-layers
            ]
            for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
            VTCompressionSessionPrepareToEncodeFrames(session)

            var transfer: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            guard let transfer else { return .failure("Couldn't scale the video.") }
            // Wallpaper videos and Apple's Aerials are both 16:9, so a straight scale fills the frame.

            var reader: AVAssetReader?
            var output: AVAssetReaderTrackOutput?
            func nextSourceFrame() throws -> CVPixelBuffer? {
                for _ in 0..<2 {   // restart once at the end of the clip (looping)
                    if reader == nil {
                        let r = try AVAssetReader(asset: asset)
                        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
                        o.alwaysCopiesSampleData = false
                        r.add(o); r.startReading()
                        reader = r; output = o
                    }
                    if let sample = output?.copyNextSampleBuffer(), let image = CMSampleBufferGetImageBuffer(sample) { return image }
                    reader = nil
                }
                return nil
            }

            let frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 600_000)
            // Reuse frame memory instead of allocating a new 4K buffer per frame.
            var poolOut: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary, &poolOut)
            guard let pool = poolOut else { return .failure("Couldn't allocate video frames.") }
            let styler = FrameStyler(look: look, pool: pool)
            // Speed: each advancing output frame moves `speed` source frames forward.
            let speed = look.clampedSpeed
            var sourcePosition = 0.0
            var sourceFramesRead = 0
            var current: CVPixelBuffer?
            for (index, advance) in flags.enumerated() {
                if Task.isCancelled { return .failure("Cancelled.") }
                if advance || current == nil {
                    sourcePosition += current == nil ? 1 : speed
                    var image: CVImageBuffer?
                    while sourceFramesRead < Int(sourcePosition) {
                        guard let next = try nextSourceFrame() else { break }
                        image = next
                        sourceFramesRead += 1
                    }
                    if let image {
                        let styled: CVPixelBuffer? = autoreleasepool {
                            var scaled: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled)
                            guard let scaled else { return nil }
                            VTPixelTransferSessionTransferImage(transfer, from: image, to: scaled)
                            return styler.apply(to: scaled)
                        }
                        guard let styled else { return .failure("Out of memory while preparing frames.") }
                        current = styled
                    }
                    if current == nil { break }
                }

                // Backpressure: wait until the encoder has room.
                while !sink.tryReserve(limit: Self.maxFramesInFlight) { usleep(500) }
                let pts = CMTime(seconds: Double(index) / fps, preferredTimescale: 600_000)
                let status = VTCompressionSessionEncodeFrame(session, imageBuffer: current!, presentationTimeStamp: pts, duration: frameDuration,
                                                             frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
                if status != noErr {
                    sink.releaseSlot()
                    return .failure("The encoder rejected a frame (\(status)).")
                }
                if index % 300 == 0 {
                    progress(Double(index) / Double(flags.count) * 0.95)
                    if Self.physicalFootprint() > Self.memoryLimitBytes {
                        return .failure("Stopped: encoding used too much memory.")
                    }
                }
            }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

            guard let first = sink.samples.first else { return .failure("The encoder produced no frames.") }
            try? FileManager.default.removeItem(at: destination)
            let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(first))
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(first))
            for sample in sink.samples {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                input.append(sample)
            }
            input.markAsFinished()
            await writer.finishWriting()
            progress(1)
            return writer.status == .completed ? .success : .failure("Couldn't write the video file.")
        } catch {
            return .failure("Encoding failed: \(error.localizedDescription)")
        }
    }
}

/// Applies `LockScreenLook` to a frame with Core Image (same filters as the desktop view).
private struct FrameStyler {
    let look: LockScreenLook
    let pool: CVPixelBufferPool
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    init(look: LockScreenLook, pool: CVPixelBufferPool) {
        self.look = look
        self.pool = pool
    }

    func apply(to buffer: CVPixelBuffer) -> CVPixelBuffer {
        guard !look.isIdentityImage else { return buffer }
        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        if look.hasHue {
            image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: look.hueAngle])
        }
        if look.hasColorControls {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: look.mappedBrightness,
                kCIInputContrastKey: look.contrast,
                kCIInputSaturationKey: look.saturation,
            ])
        }
        if look.blur {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: LockScreenLook.blurRadius(forWidth: Double(extent.width))])
                .cropped(to: extent)
        }
        if look.dim > 0.001 {
            let f = look.dimFactor
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
            ])
        }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return buffer }
        context.render(image, to: output, bounds: extent, colorSpace: colorSpace)
        return output
    }
}
