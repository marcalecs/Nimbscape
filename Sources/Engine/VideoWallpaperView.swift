import Cocoa
import AVFoundation
import CoreImage

public class VideoWallpaperView: NSView {
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var ownsPlayer: Bool = true
    private var playbackSpeed: Float = 1.0
    private var isCurrentlyPaused: Bool = false
    private var currentProperties: WallpaperProperties = .default
    /// Still frame shown over the video while it is paused; cross-fading it in and out makes
    /// stop/start transitions smooth and hides the decoder warm-up when playback resumes.
    private var stillLayer: CALayer?

    /// The player this view renders (its own or the shared Clone/Stretch player).
    public var renderedPlayer: AVQueuePlayer? { queuePlayer }

    /// Whether a still frame currently covers the video (fully or while fading).
    public var isShowingStill: Bool { stillLayer != nil }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerUsesCoreImageFilters = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    public func loadVideo(
        url: URL,
        isMuted: Bool,
        volume: Float,
        isPaused: Bool,
        properties: WallpaperProperties = .default,
        globalFPSCap: Int = 60
    ) {
        cleanup()
        ownsPlayer = true

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: playerItem)

        self.queuePlayer = player
        self.playerLooper = looper

        attachPlayerLayer(for: player)

        player.isMuted = isMuted
        player.volume = volume
        self.isCurrentlyPaused = isPaused

        applyProperties(properties, globalFPSCap: globalFPSCap)

        if !isPaused {
            player.rate = playbackSpeed
        }
    }

    public func attachSharedPlayer(
        _ player: AVQueuePlayer,
        isPaused: Bool,
        properties: WallpaperProperties = .default,
        globalFPSCap: Int = 60
    ) {
        cleanup()
        ownsPlayer = false
        self.queuePlayer = player
        self.isCurrentlyPaused = isPaused

        attachPlayerLayer(for: player)
        applyProperties(properties, globalFPSCap: globalFPSCap)
    }

    private func attachPlayerLayer(for player: AVQueuePlayer) {
        let avLayer = AVPlayerLayer(player: player)
        avLayer.videoGravity = videoGravity(for: currentProperties.alignment)
        avLayer.isOpaque = true
        avLayer.frame = self.bounds
        self.layer?.addSublayer(avLayer)
        self.playerLayer = avLayer
    }

    public func applyProperties(_ properties: WallpaperProperties, globalFPSCap: Int = 60) {
        currentProperties = properties
        playbackSpeed = max(0.25, min(2.0, properties.speed))

        playerLayer?.videoGravity = videoGravity(for: properties.alignment)

        if ownsPlayer, let player = queuePlayer, !isCurrentlyPaused {
            player.rate = playbackSpeed
        }

        applyColorFilters(properties)
    }

    private func videoGravity(for alignment: WallpaperAlignment) -> AVLayerVideoGravity {
        switch alignment {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        }
    }

    private func applyColorFilters(_ props: WallpaperProperties) {
        guard props.hasColorAdjustments else {
            self.layer?.filters = nil
            if layerUsesCoreImageFilters {
                layerUsesCoreImageFilters = false
            }
            return
        }

        if !layerUsesCoreImageFilters {
            layerUsesCoreImageFilters = true
        }

        var filters: [CIFilter] = []

        if abs(props.hue) > 0.01, let hueFilter = CIFilter(name: "CIHueAdjust") {
            hueFilter.setValue(props.hue * .pi / 180.0, forKey: kCIInputAngleKey)
            filters.append(hueFilter)
        }

        if abs(props.brightness - 1.0) > 0.01
            || abs(props.contrast - 1.0) > 0.01
            || abs(props.saturation - 1.0) > 0.01,
           let colorControls = CIFilter(name: "CIColorControls") {
            let mappedBrightness = max(-0.5, min(0.5, (props.brightness - 1.0) * 0.5))
            colorControls.setValue(mappedBrightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(props.contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(props.saturation, forKey: kCIInputSaturationKey)
            filters.append(colorControls)
        }

        self.layer?.filters = filters.isEmpty ? nil : filters
    }

    public func play() {
        isCurrentlyPaused = false
        if ownsPlayer {
            queuePlayer?.rate = playbackSpeed
        }
    }

    public func pause() {
        isCurrentlyPaused = true
        if ownsPlayer {
            queuePlayer?.pause()
        }
    }

    public func setLiveSpeedFactor(_ factor: Float) {
        guard ownsPlayer, let player = queuePlayer else { return }
        if factor <= 0.01 {
            isCurrentlyPaused = true
            player.pause()
        } else {
            isCurrentlyPaused = false
            player.rate = playbackSpeed * factor
        }
    }

    public func setMuted(_ muted: Bool) {
        if ownsPlayer {
            queuePlayer?.isMuted = muted
        }
    }

    public func setVolume(_ volume: Float) {
        if ownsPlayer {
            queuePlayer?.volume = volume
        }
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = self.bounds
        stillLayer?.frame = self.bounds
        CATransaction.commit()
    }

    public var hasFailedDecoder: Bool {
        queuePlayer?.status == .failed || queuePlayer?.currentItem?.status == .failed
    }

    public func recoverAfterWake() {
        playerLayer?.setNeedsDisplay()
        if ownsPlayer, !isCurrentlyPaused, let player = queuePlayer {
            player.rate = playbackSpeed
        }
    }

    public func ensurePlayingIfExpected() {
        guard ownsPlayer, !isCurrentlyPaused, let player = queuePlayer else { return }
        if player.rate == 0 || player.timeControlStatus == .paused {
            player.rate = playbackSpeed
        }
    }

    // MARK: - Still-frame cross-fade

    /// Fades `image` in over the video. With `duration` 0 the still appears at once.
    public func showStill(_ image: CGImage, fadeDuration duration: TimeInterval) {
        let still = stillLayer ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = image
        still.frame = bounds
        still.contentsGravity = stillGravity(for: currentProperties.alignment)
        still.masksToBounds = true
        if stillLayer == nil {
            still.opacity = 0
            layer?.addSublayer(still)
            stillLayer = still
        }
        CATransaction.commit()
        fade(still, to: 1, duration: duration, completion: nil)
    }

    /// Fades the still out to reveal the live video, then removes it.
    public func hideStill(fadeDuration duration: TimeInterval) {
        guard let still = stillLayer else { return }
        fade(still, to: 0, duration: duration) { [weak self, weak still] in
            guard let self, let still, self.stillLayer === still, still.opacity == 0 else { return }
            still.removeFromSuperlayer()
            self.stillLayer = nil
        }
    }

    private func fade(_ target: CALayer, to opacity: Float, duration: TimeInterval, completion: (@MainActor () -> Void)?) {
        let from = target.presentation()?.opacity ?? target.opacity
        target.removeAnimation(forKey: "nimbscape.still")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.opacity = opacity
        CATransaction.commit()
        guard duration > 0 else {
            completion?()
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(animation, forKey: "nimbscape.still")
        if let completion {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    private func stillGravity(for alignment: WallpaperAlignment) -> CALayerContentsGravity {
        switch alignment {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        }
    }

    public func cleanup() {
        if ownsPlayer {
            queuePlayer?.pause()
            queuePlayer?.removeAllItems()
            playerLooper?.disableLooping()
        }
        playerLooper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        stillLayer?.removeFromSuperlayer()
        stillLayer = nil
        queuePlayer = nil
    }
}
