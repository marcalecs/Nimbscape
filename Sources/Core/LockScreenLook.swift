import Foundation

/// The desktop look of a video wallpaper, baked into its lock-screen video: color & tone, speed,
/// dim and blur. Filter values mirror what `VideoWallpaperView` and the overlay apply on screen.
public struct LockScreenLook: Equatable, Sendable {
    public var hue: Double = 0            // degrees
    public var brightness: Double = 1
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var speed: Double = 1
    public var dim: Double = 0            // 0...0.8 black overlay
    public var blur: Bool = false

    public init(hue: Double = 0, brightness: Double = 1, contrast: Double = 1, saturation: Double = 1,
                speed: Double = 1, dim: Double = 0, blur: Bool = false) {
        self.hue = hue; self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
        self.speed = speed; self.dim = dim; self.blur = blur
    }

    public var hasHue: Bool { abs(hue) > 0.01 }
    public var hasColorControls: Bool {
        abs(brightness - 1) > 0.01 || abs(contrast - 1) > 0.01 || abs(saturation - 1) > 0.01
    }
    /// Nothing to apply per frame (speed is handled by the frame schedule).
    public var isIdentityImage: Bool { !hasHue && !hasColorControls && dim <= 0.001 && !blur }

    /// CIHueAdjust angle in radians.
    public var hueAngle: Double { hue * .pi / 180 }
    /// CIColorControls brightness, mapped like the desktop view (±0.5 around 0).
    public var mappedBrightness: Double { max(-0.5, min(0.5, (brightness - 1) * 0.5)) }
    /// Multiplier for RGB after dimming with a black overlay of opacity `dim`.
    public var dimFactor: Double { 1 - min(max(dim, 0), 1) }
    /// Gaussian radius approximating the desktop's frosted blur, scaled to the output width.
    public static func blurRadius(forWidth width: Double) -> Double { 30 * width / 1920 }

    /// Clamped playback speed (same range as the desktop player).
    public var clampedSpeed: Double { max(0.25, min(2, speed)) }
}
