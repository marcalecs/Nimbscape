import Foundation
@preconcurrency import ScreenCaptureKit
import Accelerate
import CoreMedia
import Combine

public enum AudioCaptureStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case permissionDenied
    case error(String)

    public var label: String {
        switch self {
        case .stopped: return "Off"
        case .starting: return "Starting..."
        case .running: return "Live System Audio"
        case .permissionDenied: return "Permission Required (System Settings → Screen & System Audio)"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

private final class AudioFFTProcessor: NSObject, SCStreamOutput, @unchecked Sendable {
    private let fftSize = 512
    private let log2n: vDSP_Length = 9
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var lastEmitTime: CFAbsoluteTime = 0
    private let emitInterval: CFAbsoluteTime = 1.0 / 24.0

    var onFrame: (@Sendable ([Float], Float) -> Void)?

    override init() {
        self.window = [Float](repeating: 0, count: 512)
        super.init()
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmitTime >= emitInterval else { return }
        lastEmitTime = now

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let rawPtr = dataPointer, totalLength >= fftSize * MemoryLayout<Float>.size else {
            return
        }

        let floatCount = totalLength / MemoryLayout<Float>.size
        let floatPtr = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Float.self)

        var leftSamples = [Float](repeating: 0, count: fftSize)
        var rightSamples = [Float](repeating: 0, count: fftSize)

        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        let asbd = formatDesc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = Int(asbd?.mChannelsPerFrame ?? 2)
        let isNonInterleaved = ((asbd?.mFormatFlags ?? 0) & kAudioFormatFlagIsNonInterleaved) != 0

        if channels >= 2 && !isNonInterleaved && floatCount >= fftSize * 2 {
            for i in 0..<fftSize {
                leftSamples[i] = floatPtr[i * 2]
                rightSamples[i] = floatPtr[i * 2 + 1]
            }
        } else if channels >= 2 && isNonInterleaved && floatCount >= fftSize * 2 {
            let half = floatCount / 2
            let count = min(fftSize, half)
            for i in 0..<count {
                leftSamples[i] = floatPtr[i]
                rightSamples[i] = floatPtr[half + i]
            }
        } else {
            let count = min(fftSize, floatCount)
            for i in 0..<count {
                leftSamples[i] = floatPtr[i]
                rightSamples[i] = floatPtr[i]
            }
        }

        var rmsLeft: Float = 0
        vDSP_rmsqv(leftSamples, 1, &rmsLeft, vDSP_Length(fftSize))
        var rmsRight: Float = 0
        vDSP_rmsqv(rightSamples, 1, &rmsRight, vDSP_Length(fftSize))
        let rms = max(rmsLeft, rmsRight)

        let leftBands = compute64Bands(leftSamples)
        let rightBands = compute64Bands(rightSamples)
        var spectrum128 = [Float]()
        spectrum128.reserveCapacity(128)
        spectrum128.append(contentsOf: leftBands)
        spectrum128.append(contentsOf: rightBands)

        onFrame?(spectrum128, rms)
    }

    private func compute64Bands(_ input: [Float]) -> [Float] {
        guard let fftSetup else { return [Float](repeating: 0, count: 64) }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var splitComplex = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                windowed.withUnsafeBytes { rawBytes in
                    let complexPtr = rawBytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(halfN))
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        var bands = [Float](repeating: 0, count: 64)
        for b in 0..<64 {
            let startFrac = pow(Double(b) / 64.0, 1.75)
            let endFrac = pow(Double(b + 1) / 64.0, 1.75)
            let i0 = max(1, min(halfN - 1, Int(startFrac * Double(halfN - 1))))
            let i1 = max(i0 + 1, min(halfN, Int(endFrac * Double(halfN - 1)) + 1))

            var sum: Float = 0
            for idx in i0..<i1 {
                sum += magnitudes[idx]
            }
            let avg = sum / Float(max(1, i1 - i0))

            let scaled = log10f(1.0 + avg * 2.2) * 0.72
            bands[b] = min(1.0, max(0.0, scaled))
        }
        return bands
    }
}

@MainActor
public class AudioVisualizerEngine: ObservableObject {
    public static let shared = AudioVisualizerEngine()

    @Published public private(set) var status: AudioCaptureStatus = .stopped
    @Published public private(set) var isExternalAudioPlaying: Bool = false

    public var onSpectrumUpdate: (([Float]) -> Void)?

    private var stream: SCStream?
    private let processor = AudioFFTProcessor()
    private let audioQueue = DispatchQueue(label: "com.marcalecs.nimbscape.audiofft", qos: .userInteractive)
    private var lastExternalAudioDate: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()

    private init() {
        processor.onFrame = { [weak self] spectrum, rms in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if rms > 0.012 {
                    self.lastExternalAudioDate = Date()
                    if !self.isExternalAudioPlaying {
                        self.isExternalAudioPlaying = true
                    }
                } else if self.isExternalAudioPlaying, Date().timeIntervalSince(self.lastExternalAudioDate) > 1.5 {
                    self.isExternalAudioPlaying = false
                }
                self.onSpectrumUpdate?(spectrum)
            }
        }

        let preferences = AppPreferences.shared
        Publishers.CombineLatest(preferences.$audioVisualizerEnabled, preferences.$muteOnExternalAudio)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] vizEnabled, muteExt in
                if vizEnabled || muteExt {
                    self?.startIfNeeded()
                } else {
                    self?.stop()
                }
            }
            .store(in: &cancellables)
    }

    public func startIfNeeded() {
        guard status == .stopped || status == .permissionDenied else { return }
        status = .starting

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    self.status = .error("No display available for audio capture")
                    return
                }

                let ownPID = ProcessInfo.processInfo.processIdentifier
                let excludedApps = content.applications.filter { $0.processID == ownPID }
                let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2

                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
                try newStream.addStreamOutput(self.processor, type: .audio, sampleHandlerQueue: self.audioQueue)
                try await newStream.startCapture()

                self.stream = newStream
                self.status = .running
            } catch {
                let msg = error.localizedDescription
                if msg.lowercased().contains("declined") || msg.lowercased().contains("permission") || msg.lowercased().contains("tcc") {
                    self.status = .permissionDenied
                } else {
                    self.status = .error(msg)
                }
            }
        }
    }

    public func stop() {
        let activeStream = stream
        stream = nil
        status = .stopped
        isExternalAudioPlaying = false
        if let activeStream {
            Task {
                try? await activeStream.stopCapture()
            }
        }
    }
}
