import Cocoa
import CoreGraphics

public enum DisplayLayoutMode: String, Codable, CaseIterable, Sendable {
    case perDisplay
    case clone
    case stretch

    public var displayName: String {
        switch self {
        case .perDisplay: return "Per Display"
        case .clone: return "Clone"
        case .stretch: return "Stretch"
        }
    }

    public var subtitle: String {
        switch self {
        case .perDisplay: return "Independent wallpaper and properties on each monitor"
        case .clone: return "Synchronized single wallpaper mirrored on all displays"
        case .stretch: return "One continuous wallpaper spanned across all displays"
        }
    }

    public var symbolName: String {
        switch self {
        case .perDisplay: return "display.2"
        case .clone: return "rectangle.on.rectangle"
        case .stretch: return "arrow.left.and.right.square"
        }
    }
}

public struct DisplayInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayID: CGDirectDisplayID
    public let name: String
    public let index: Int
    public let frame: CGRect
    public let scaleFactor: CGFloat
    public let isMain: Bool

    public var resolutionText: String {
        let pixelW = Int(frame.width * scaleFactor)
        let pixelH = Int(frame.height * scaleFactor)
        return "\(pixelW)×\(pixelH)"
    }

    public var logicalResolutionText: String {
        "\(Int(frame.width))×\(Int(frame.height))"
    }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let num = deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(num.uint32Value)
        }
        return CGMainDisplayID()
    }

    var stableDisplayID: String {
        let id = self.displayID
        if let uuidUnmanaged = CGDisplayCreateUUIDFromDisplayID(id) {
            let uuid = uuidUnmanaged.takeRetainedValue()
            if let str = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String? {
                return str
            }
        }
        return String(id)
    }

    func toDisplayInfo(index: Int) -> DisplayInfo {
        DisplayInfo(
            id: self.stableDisplayID,
            displayID: self.displayID,
            name: self.localizedName,
            index: index,
            frame: self.frame,
            scaleFactor: self.backingScaleFactor,
            isMain: self == NSScreen.main
        )
    }
}
