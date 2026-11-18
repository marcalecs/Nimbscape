import Cocoa
import CoreImage
import ImageIO

public class ImageWallpaperView: NSView {
    private var imageLayer: CALayer?
    private var currentProperties: WallpaperProperties = .default
    private var isAnimatedGIF: Bool = false
    private var isCurrentlyPaused: Bool = false

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

    public func loadImage(url: URL, properties: WallpaperProperties = .default, isPaused: Bool = false) {
        cleanup()
        self.currentProperties = properties
        self.isCurrentlyPaused = isPaused

        let bitmapLayer = CALayer()
        bitmapLayer.frame = self.bounds
        bitmapLayer.contentsGravity = contentsGravity(for: properties.alignment)

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 1 {
            let count = CGImageSourceGetCount(source)
            var frames: [CGImage] = []
            var delays: [Double] = []
            var totalDuration: Double = 0

            for i in 0..<count {
                guard let cgImg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                frames.append(cgImg)
                let delay = Self.gifFrameDelay(source: source, index: i)
                delays.append(delay)
                totalDuration += delay
            }

            if !frames.isEmpty {
                isAnimatedGIF = true
                bitmapLayer.contents = frames[0]

                var keyTimes: [NSNumber] = []
                var elapsed: Double = 0
                let safeTotal = max(0.05, totalDuration)
                for d in delays {
                    keyTimes.append(NSNumber(value: elapsed / safeTotal))
                    elapsed += d
                }

                let anim = CAKeyframeAnimation(keyPath: "contents")
                anim.values = frames
                anim.keyTimes = keyTimes
                anim.duration = safeTotal
                anim.repeatCount = .infinity
                anim.calculationMode = .discrete
                anim.isRemovedOnCompletion = false
                bitmapLayer.add(anim, forKey: "nimbscape.gif")
            }
        } else if let image = NSImage(contentsOf: url) {
            isAnimatedGIF = false
            bitmapLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? image
        }

        self.layer?.addSublayer(bitmapLayer)
        self.imageLayer = bitmapLayer

        applyProperties(properties)
        if isPaused {
            pause()
        }
    }

    private static func gifFrameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gifDict[kCGImagePropertyGIFDelayTime] as? Double
        let raw = unclamped ?? clamped ?? 0.1
        return raw < 0.02 ? 0.1 : raw
    }

    public func applyProperties(_ properties: WallpaperProperties) {
        currentProperties = properties
        imageLayer?.contentsGravity = contentsGravity(for: properties.alignment)
        if isAnimatedGIF, !isCurrentlyPaused {
            imageLayer?.speed = max(0.25, min(2.0, properties.speed))
        }
        applyColorFilters(properties)
    }

    public func play() {
        isCurrentlyPaused = false
        guard isAnimatedGIF, let layer = imageLayer else { return }
        if layer.speed == 0 {
            let pausedTime = layer.timeOffset
            layer.speed = max(0.25, min(2.0, currentProperties.speed))
            layer.timeOffset = 0
            layer.beginTime = 0
            let timeSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            layer.beginTime = timeSincePause
        } else {
            layer.speed = max(0.25, min(2.0, currentProperties.speed))
        }
    }

    public func pause() {
        isCurrentlyPaused = true
        guard isAnimatedGIF, let layer = imageLayer, layer.speed != 0 else { return }
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
    }

    public func setLiveSpeedFactor(_ factor: Float) {
        guard isAnimatedGIF, let layer = imageLayer else { return }
        if factor <= 0.01 {
            pause()
        } else {
            isCurrentlyPaused = false
            layer.speed = max(0.05, currentProperties.speed * factor)
        }
    }

    private func contentsGravity(for alignment: WallpaperAlignment) -> CALayerContentsGravity {
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

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer?.frame = self.bounds
        CATransaction.commit()
    }

    public func cleanup() {
        imageLayer?.removeAllAnimations()
        imageLayer?.removeFromSuperlayer()
        imageLayer = nil
        isAnimatedGIF = false
    }
}
