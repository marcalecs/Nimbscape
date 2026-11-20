import Foundation
import CoreGraphics

/// Kinds of desktop widgets that can sit on top of a wallpaper.
public enum OverlayWidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case clock
    case system
    case nowPlaying
    case weather
    case calendar
    /// An HTML widget installed from the widget catalog (see `OverlayWidget.customID`).
    case custom

    public var id: String { rawValue }

    /// Built-in kinds shown in the gallery.
    public static var builtIn: [OverlayWidgetKind] { [.clock, .system, .nowPlaying, .weather, .calendar] }

    public var displayName: String {
        switch self {
        case .clock: return "Clock & Date"
        case .system: return "System"
        case .nowPlaying: return "Now Playing"
        case .weather: return "Weather"
        case .calendar: return "Calendar"
        case .custom: return "Store Widget"
        }
    }

    public var symbolName: String {
        switch self {
        case .clock: return "clock"
        case .system: return "cpu"
        case .nowPlaying: return "music.note"
        case .weather: return "cloud.sun"
        case .calendar: return "calendar"
        case .custom: return "puzzlepiece.extension"
        }
    }
}

/// Visual treatment of a widget card.
public enum OverlayWidgetStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case glass
    case minimal

    public var id: String { rawValue }
    public var displayName: String { self == .glass ? "Glass" : "Minimal" }
}

/// Clock face variants.
public enum OverlayClockFace: String, Codable, CaseIterable, Identifiable, Sendable {
    case large
    case compact
    case seconds

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .large: return "Large"
        case .compact: return "Compact"
        case .seconds: return "With Seconds"
        }
    }
}

/// One widget placed on a display. `center` is normalized to the screen (0...1, origin top-left).
public struct OverlayWidget: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var kind: OverlayWidgetKind
    public var center: CGPoint
    public var scale: Double = 1.0
    public var style: OverlayWidgetStyle = .glass
    public var clockFace: OverlayClockFace = .large
    /// City for the weather widget.
    public var city: String = ""
    /// Catalog widget ID for `.custom` widgets.
    public var customID: String?

    public init(kind: OverlayWidgetKind, center: CGPoint) {
        self.kind = kind
        self.center = center
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(OverlayWidgetKind.self, forKey: .kind)
        center = try c.decodeIfPresent(CGPoint.self, forKey: .center) ?? CGPoint(x: 0.5, y: 0.5)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        style = try c.decodeIfPresent(OverlayWidgetStyle.self, forKey: .style) ?? .glass
        clockFace = try c.decodeIfPresent(OverlayClockFace.self, forKey: .clockFace) ?? .large
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        customID = try c.decodeIfPresent(String.self, forKey: .customID)
    }
}

/// Native particle effects drawn over any wallpaper (video included).
public enum OverlayParticles: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case snow
    case rain
    case fireflies
    case embers

    public var id: String { rawValue }
    /// Effects offered in the editor. Fireflies/embers stay decodable for saved layouts but are retired.
    public static var selectable: [OverlayParticles] { [.none, .snow, .rain] }
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .snow: return "Snow"
        case .rain: return "Rain"
        case .fireflies: return "Fireflies"
        case .embers: return "Embers"
        }
    }
}

/// Effects layered over the wallpaper content.
public struct OverlayEffects: Codable, Equatable, Sendable {
    public var particles: OverlayParticles = .none
    /// 0...1, intensity of the particle effect.
    public var particleDensity: Double = 0.5
    /// 0...0.8, black dimming over the wallpaper.
    public var dim: Double = 0
    /// Frosted blur over the wallpaper.
    public var blur: Bool = false

    public init() {}

    public var isEmpty: Bool { particles == .none && dim <= 0.001 && !blur }
}

/// Everything layered on top of one wallpaper.
public struct OverlayConfig: Codable, Equatable, Sendable {
    public var widgets: [OverlayWidget] = []
    public var effects = OverlayEffects()

    public init() {}

    public var isEmpty: Bool { widgets.isEmpty && effects.isEmpty }
}
