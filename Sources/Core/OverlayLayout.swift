import Foundation
import CoreGraphics

/// Pure geometry for placing desktop widgets: the safe-area barrier, Figma-style snapping and
/// corner resizing. No UI types, so it can be unit-tested on its own.
public enum OverlayLayout {
    /// Space widgets must stay out of (menu bar, Dock, screen edges), in canvas points.
    public struct Insets: Equatable, Sendable {
        public var top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat
        public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
            self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
        }
        public static let zero = Insets(top: 0, leading: 0, bottom: 0, trailing: 0)
    }

    /// Snapping is caught within this distance, in points.
    public static let snapDistance: CGFloat = 5
    /// No snapping while the pointer moves faster than this (points per second).
    public static let snapMaxSpeed: CGFloat = 650
    /// A guide that was just left can't be caught again for this long.
    public static let snapCooldown: TimeInterval = 0.4
    /// Spacing when widgets snap side by side or stacked.
    public static let gap: CGFloat = 8
    public static let minScale: Double = 0.5
    public static let maxScale: Double = 2.2

    // MARK: Barrier

    /// Moves `center` so a widget of `size` stays fully inside the canvas minus `insets`.
    /// A widget larger than the safe area is centered in it.
    public static func clamp(center: CGPoint, size: CGSize, canvas: CGSize, insets: Insets) -> CGPoint {
        func axis(_ value: CGFloat, half: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            guard high - low > half * 2 else { return (low + high) / 2 }
            return min(high - half, max(low + half, value))
        }
        return CGPoint(
            x: axis(center.x, half: size.width / 2, low: insets.leading, high: canvas.width - insets.trailing),
            y: axis(center.y, half: size.height / 2, low: insets.top, high: canvas.height - insets.bottom)
        )
    }

    // MARK: Snapping

    /// Guides each axis currently sits on, and guides recently left (cooling down).
    public struct SnapState: Equatable, Sendable {
        public var stuckX: CGFloat?
        public var stuckY: CGFloat?
        public var cooldownX: [CGFloat: Date] = [:]
        public var cooldownY: [CGFloat: Date] = [:]
        public init() {}
    }

    public struct SnapResult: Equatable, Sendable {
        public var center: CGPoint
        /// Vertical guide line (x position), if snapped horizontally.
        public var guideX: CGFloat?
        /// Horizontal guide line (y position), if snapped vertically.
        public var guideY: CGFloat?
    }

    /// Aligns edges and centers with other widgets, places the widget beside one it faces (with
    /// `gap`), and centers it on the screen. The position always comes from the pointer
    /// (`proposed`), so leaving a guide never makes the widget jump.
    public static func snap(
        proposed: CGPoint,
        size: CGSize,
        others: [CGRect],
        canvas: CGSize,
        speed: CGFloat,
        disabled: Bool = false,
        now: Date = Date(),
        state: inout SnapState
    ) -> SnapResult {
        func release(_ stuck: inout CGFloat?, _ cooldown: inout [CGFloat: Date]) {
            if let left = stuck { cooldown[left] = now.addingTimeInterval(snapCooldown) }
            stuck = nil
        }
        guard !disabled, speed < snapMaxSpeed else {
            release(&state.stuckX, &state.cooldownX)
            release(&state.stuckY, &state.cooldownY)
            return SnapResult(center: proposed)
        }

        let frame = CGRect(x: proposed.x - size.width / 2, y: proposed.y - size.height / 2, width: size.width, height: size.height)
        var xTargets: [(mine: CGFloat, guide: CGFloat)] = [(frame.midX, canvas.width / 2)]
        var yTargets: [(mine: CGFloat, guide: CGFloat)] = [(frame.midY, canvas.height / 2)]
        for o in others where o.width > 0 {
            xTargets += [(frame.minX, o.minX), (frame.maxX, o.maxX), (frame.midX, o.midX)]
            yTargets += [(frame.minY, o.minY), (frame.maxY, o.maxY), (frame.midY, o.midY)]
            if frame.minY < o.maxY && frame.maxY > o.minY {       // facing left/right
                xTargets += [(frame.minX, o.maxX + gap), (frame.maxX, o.minX - gap)]
            }
            if frame.minX < o.maxX && frame.maxX > o.minX {       // facing up/down
                yTargets += [(frame.minY, o.maxY + gap), (frame.maxY, o.minY - gap)]
            }
        }

        func resolve(_ targets: [(mine: CGFloat, guide: CGFloat)], stuck: inout CGFloat?, cooldown: inout [CGFloat: Date]) -> (delta: CGFloat, guide: CGFloat)? {
            cooldown = cooldown.filter { $0.value > now }
            let usable = targets.filter { target in !cooldown.keys.contains { abs($0 - target.guide) < 0.5 } }
            guard let best = usable.min(by: { abs($0.guide - $0.mine) < abs($1.guide - $1.mine) }),
                  abs(best.guide - best.mine) <= snapDistance else {
                release(&stuck, &cooldown)
                return nil
            }
            if let current = stuck, abs(current - best.guide) > 0.5 { cooldown[current] = now.addingTimeInterval(snapCooldown) }
            stuck = best.guide
            return (best.guide - best.mine, best.guide)
        }

        var result = SnapResult(center: proposed)
        if let x = resolve(xTargets, stuck: &state.stuckX, cooldown: &state.cooldownX) {
            result.center.x += x.delta
            result.guideX = x.guide
        }
        if let y = resolve(yTargets, stuck: &state.stuckY, cooldown: &state.cooldownY) {
            result.center.y += y.delta
            result.guideY = y.guide
        }
        return result
    }

    // MARK: Corner resize

    public enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
        /// Direction the dragged corner moves away from the anchor (+1 right/down, -1 left/up).
        public var sx: CGFloat { self == .topRight || self == .bottomRight ? 1 : -1 }
        public var sy: CGFloat { self == .bottomLeft || self == .bottomRight ? 1 : -1 }
    }

    public struct ResizeResult: Equatable, Sendable {
        public var scale: Double
        public var center: CGPoint
        public var guideX: CGFloat?
        public var guideY: CGFloat?
    }

    /// Resizes a widget (aspect kept) by dragging `corner`; the opposite corner of `start` stays
    /// fixed. The moving vertical edge (then horizontal) snaps to other widgets' edges, and the
    /// size is limited by the safe area and the scale range.
    public static func resize(
        start: CGRect,
        baseSize: CGSize,
        corner: Corner,
        translation: CGSize,
        others: [CGRect],
        canvas: CGSize,
        insets: Insets,
        snapping: Bool = true
    ) -> ResizeResult {
        let anchor = CGPoint(x: corner.sx > 0 ? start.minX : start.maxX, y: corner.sy > 0 ? start.minY : start.maxY)
        let dragged = CGPoint(x: (corner.sx > 0 ? start.maxX : start.minX) + translation.width,
                              y: (corner.sy > 0 ? start.maxY : start.minY) + translation.height)
        var scale = max(abs(dragged.x - anchor.x) / baseSize.width, abs(dragged.y - anchor.y) / baseSize.height)
        var guideX: CGFloat?, guideY: CGFloat?

        if snapping {
            let edgeX = anchor.x + corner.sx * baseSize.width * scale
            let edgeY = anchor.y + corner.sy * baseSize.height * scale
            let xs = others.filter { $0.width > 0 }.flatMap { [$0.minX, $0.maxX, $0.minX - gap, $0.maxX + gap] }
            let ys = others.filter { $0.width > 0 }.flatMap { [$0.minY, $0.maxY, $0.minY - gap, $0.maxY + gap] }
            if let x = xs.min(by: { abs($0 - edgeX) < abs($1 - edgeX) }), abs(x - edgeX) <= snapDistance {
                scale = abs(x - anchor.x) / baseSize.width
                guideX = x
            } else if let y = ys.min(by: { abs($0 - edgeY) < abs($1 - edgeY) }), abs(y - edgeY) <= snapDistance {
                scale = abs(y - anchor.y) / baseSize.height
                guideY = y
            }
        }

        let roomX = corner.sx > 0 ? canvas.width - insets.trailing - anchor.x : anchor.x - insets.leading
        let roomY = corner.sy > 0 ? canvas.height - insets.bottom - anchor.y : anchor.y - insets.top
        scale = min(scale, roomX / baseSize.width, roomY / baseSize.height, CGFloat(maxScale))
        scale = max(scale, CGFloat(minScale))

        let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        let center = CGPoint(x: anchor.x + corner.sx * size.width / 2, y: anchor.y + corner.sy * size.height / 2)
        return ResizeResult(scale: Double(scale), center: center, guideX: guideX, guideY: guideY)
    }
}
