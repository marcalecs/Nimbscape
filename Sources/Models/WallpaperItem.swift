import Foundation

public enum WallpaperType: String, Codable, CaseIterable, Sendable {
    case video
    case web
    case url
    case image
}

public enum WallpaperSource: String, Codable, CaseIterable, Sendable {
    case builtIn
    case localImport
    case steamWorkshop
    case webURL
}

public enum WallpaperAlignment: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
    case stretch

    public var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        }
    }
}

public enum ProjectPropertyType: String, Codable, Sendable {
    case slider
    case bool
    case color
    case text
    case combo
}

public struct ProjectPropertySpec: Identifiable, Codable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public var text: String
    public var type: ProjectPropertyType
    public var defaultValue: String
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var options: [String: String]?

    public init(
        key: String,
        text: String,
        type: ProjectPropertyType,
        defaultValue: String,
        min: Double? = nil,
        max: Double? = nil,
        step: Double? = nil,
        options: [String: String]? = nil
    ) {
        self.key = key
        self.text = text
        self.type = type
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.step = step
        self.options = options
    }
}

public struct WallpaperProperties: Codable, Equatable, Sendable {
    public var speed: Float = 1.0
    public var fpsCap: Int = 60
    public var alignment: WallpaperAlignment = .fill
    public var hue: Double = 0
    public var brightness: Double = 1.0
    public var contrast: Double = 1.0
    public var saturation: Double = 1.0
    public var customProps: [String: String] = [:]

    public static let `default` = WallpaperProperties()

    public var hasColorAdjustments: Bool {
        abs(hue) > 0.01
            || abs(brightness - 1.0) > 0.01
            || abs(contrast - 1.0) > 0.01
            || abs(saturation - 1.0) > 0.01
    }

    public init(
        speed: Float = 1.0,
        fpsCap: Int = 60,
        alignment: WallpaperAlignment = .fill,
        hue: Double = 0,
        brightness: Double = 1.0,
        contrast: Double = 1.0,
        saturation: Double = 1.0,
        customProps: [String: String] = [:]
    ) {
        self.speed = speed
        self.fpsCap = fpsCap
        self.alignment = alignment
        self.hue = hue
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.customProps = customProps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.speed = try c.decodeIfPresent(Float.self, forKey: .speed) ?? 1.0
        self.fpsCap = try c.decodeIfPresent(Int.self, forKey: .fpsCap) ?? 60
        self.alignment = try c.decodeIfPresent(WallpaperAlignment.self, forKey: .alignment) ?? .fill
        self.hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        self.brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0
        self.contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1.0
        self.saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        self.customProps = try c.decodeIfPresent([String: String].self, forKey: .customProps) ?? [:]
    }
}

public struct WallpaperItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var type: WallpaperType
    public var pathOrURL: String
    public var previewPath: String?
    public var isBuiltIn: Bool
    public var isFavorite: Bool
    public var tags: [String]
    public var resolutionLabel: String?
    public var fileSizeBytes: Int64?
    public var source: WallpaperSource
    public var properties: WallpaperProperties
    public var projectPropertySpecs: [ProjectPropertySpec]
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        type: WallpaperType,
        pathOrURL: String,
        previewPath: String? = nil,
        isBuiltIn: Bool = false,
        isFavorite: Bool = false,
        tags: [String] = [],
        resolutionLabel: String? = nil,
        fileSizeBytes: Int64? = nil,
        source: WallpaperSource? = nil,
        properties: WallpaperProperties = WallpaperProperties(),
        projectPropertySpecs: [ProjectPropertySpec] = [],
        addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.pathOrURL = pathOrURL
        self.previewPath = previewPath
        self.isBuiltIn = isBuiltIn
        self.isFavorite = isFavorite
        self.tags = tags
        self.resolutionLabel = resolutionLabel
        self.fileSizeBytes = fileSizeBytes
        if let source {
            self.source = source
        } else if isBuiltIn {
            self.source = .builtIn
        } else if type == .url {
            self.source = .webURL
        } else {
            self.source = .localImport
        }
        self.properties = properties
        self.projectPropertySpecs = projectPropertySpecs
        self.addedAt = addedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.type = try c.decode(WallpaperType.self, forKey: .type)
        self.pathOrURL = try c.decode(String.self, forKey: .pathOrURL)
        self.previewPath = try c.decodeIfPresent(String.self, forKey: .previewPath)
        self.isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        self.isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.resolutionLabel = try c.decodeIfPresent(String.self, forKey: .resolutionLabel)
        self.fileSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        if let decodedSource = try c.decodeIfPresent(WallpaperSource.self, forKey: .source) {
            self.source = decodedSource
        } else if self.isBuiltIn {
            self.source = .builtIn
        } else if self.type == .url {
            self.source = .webURL
        } else {
            self.source = .localImport
        }
        self.properties = try c.decodeIfPresent(WallpaperProperties.self, forKey: .properties) ?? WallpaperProperties()
        self.projectPropertySpecs = try c.decodeIfPresent([ProjectPropertySpec].self, forKey: .projectPropertySpecs) ?? []
        self.addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }

    public var formattedFileSize: String? {
        guard let bytes = fileSizeBytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
