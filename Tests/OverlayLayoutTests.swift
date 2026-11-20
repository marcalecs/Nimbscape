import Foundation
import CoreGraphics

func runOverlayLayoutTests() {
    let canvas = CGSize(width: 1000, height: 800)
    let insets = OverlayLayout.Insets(top: 40, leading: 10, bottom: 60, trailing: 10)

    TestRunner.test("clamp keeps a widget inside the safe area") {
        let c = OverlayLayout.clamp(center: CGPoint(x: 5, y: 5), size: CGSize(width: 100, height: 50), canvas: canvas, insets: insets)
        expectClose(c.x, 60)    // 10 + 100/2
        expectClose(c.y, 65)    // 40 + 50/2
        let d = OverlayLayout.clamp(center: CGPoint(x: 990, y: 790), size: CGSize(width: 100, height: 50), canvas: canvas, insets: insets)
        expectClose(d.x, 940)   // 1000 - 10 - 50
        expectClose(d.y, 715)   // 800 - 60 - 25
    }

    TestRunner.test("clamp leaves an inside position untouched") {
        let p = CGPoint(x: 500, y: 400)
        expect(OverlayLayout.clamp(center: p, size: CGSize(width: 100, height: 100), canvas: canvas, insets: insets) == p)
    }

    TestRunner.test("clamp centers a widget larger than the safe area") {
        let c = OverlayLayout.clamp(center: .zero, size: CGSize(width: 2000, height: 50), canvas: canvas, insets: insets)
        expectClose(c.x, 500)
    }

    let other = CGRect(x: 100, y: 100, width: 200, height: 100)   // minX 100, maxX 300, minY 100, maxY 200

    TestRunner.test("snap aligns left edges within the threshold") {
        var state = OverlayLayout.SnapState()
        // proposed frame minX = 103 (3 pt off the other's left edge), far below it vertically
        let r = OverlayLayout.snap(proposed: CGPoint(x: 153, y: 600), size: CGSize(width: 100, height: 50),
                                   others: [other], canvas: canvas, speed: 0, state: &state)
        expectClose(r.center.x, 150)
        expect(r.guideX == 100)
    }

    TestRunner.test("snap ignores targets beyond the threshold") {
        var state = OverlayLayout.SnapState()
        let r = OverlayLayout.snap(proposed: CGPoint(x: 170, y: 600), size: CGSize(width: 100, height: 50),
                                   others: [other], canvas: canvas, speed: 0, state: &state)
        expect(r.guideX == nil)
        expectClose(r.center.x, 170)
    }

    TestRunner.test("snap places a facing widget beside another with the gap") {
        var state = OverlayLayout.SnapState()
        // overlapping vertically, left edge 3 pt from other.maxX + gap (308)
        let r = OverlayLayout.snap(proposed: CGPoint(x: 361, y: 150), size: CGSize(width: 100, height: 50),
                                   others: [other], canvas: canvas, speed: 0, state: &state)
        expectClose(r.center.x, 358)   // minX 308
        expect(r.guideX == 308)
    }

    TestRunner.test("snap is off while moving fast or with ⌘") {
        var state = OverlayLayout.SnapState()
        let p = CGPoint(x: 153, y: 600)
        let fast = OverlayLayout.snap(proposed: p, size: CGSize(width: 100, height: 50), others: [other], canvas: canvas, speed: 2000, state: &state)
        expect(fast.center == p && fast.guideX == nil)
        let cmd = OverlayLayout.snap(proposed: p, size: CGSize(width: 100, height: 50), others: [other], canvas: canvas, speed: 0, disabled: true, state: &state)
        expect(cmd.center == p && cmd.guideX == nil)
    }

    TestRunner.test("a guide just left can't be caught again during the cooldown") {
        var state = OverlayLayout.SnapState()
        let t0 = Date(timeIntervalSince1970: 1000)
        let size = CGSize(width: 100, height: 50)
        _ = OverlayLayout.snap(proposed: CGPoint(x: 153, y: 600), size: size, others: [other], canvas: canvas, speed: 0, now: t0, state: &state)
        expect(state.stuckX == 100)
        // pulled away → released into cooldown
        _ = OverlayLayout.snap(proposed: CGPoint(x: 190, y: 600), size: size, others: [other], canvas: canvas, speed: 0, now: t0.addingTimeInterval(0.1), state: &state)
        expect(state.stuckX == nil)
        let back = OverlayLayout.snap(proposed: CGPoint(x: 152, y: 600), size: size, others: [other], canvas: canvas, speed: 0, now: t0.addingTimeInterval(0.2), state: &state)
        expect(back.guideX != 100, "cooldown should block x=100")
        let later = OverlayLayout.snap(proposed: CGPoint(x: 152, y: 600), size: size, others: [other], canvas: canvas, speed: 0, now: t0.addingTimeInterval(1), state: &state)
        expect(later.guideX == 100, "cooldown should have expired")
    }

    TestRunner.test("resizing from a corner keeps the opposite corner fixed") {
        let start = CGRect(x: 400, y: 300, width: 100, height: 50)
        let r = OverlayLayout.resize(start: start, baseSize: CGSize(width: 100, height: 50), corner: .bottomRight,
                                     translation: CGSize(width: 50, height: 0), others: [], canvas: canvas, insets: insets)
        expectClose(CGFloat(r.scale), 1.5)
        expectClose(r.center.x - 75, 400)     // left edge stays at 400
        expectClose(r.center.y - 37.5, 300)   // top edge stays at 300
        let l = OverlayLayout.resize(start: start, baseSize: CGSize(width: 100, height: 50), corner: .topLeft,
                                     translation: CGSize(width: -100, height: 0), others: [], canvas: canvas, insets: insets)
        expectClose(l.center.x + CGFloat(l.scale) * 50, 500)   // right edge stays at 500
        expectClose(l.center.y + CGFloat(l.scale) * 25, 350)   // bottom edge stays at 350
    }

    TestRunner.test("resizing snaps the moving edge and respects limits") {
        let start = CGRect(x: 100, y: 300, width: 100, height: 50)
        let snapped = OverlayLayout.resize(start: start, baseSize: CGSize(width: 100, height: 50), corner: .bottomRight,
                                           translation: CGSize(width: 97, height: 0), others: [other], canvas: canvas, insets: insets)
        expect(snapped.guideX == 300, "right edge should snap to other.maxX")
        expectClose(CGFloat(snapped.scale), 2)
        let tiny = OverlayLayout.resize(start: start, baseSize: CGSize(width: 100, height: 50), corner: .bottomRight,
                                        translation: CGSize(width: -95, height: -45), others: [], canvas: canvas, insets: insets)
        expectClose(CGFloat(tiny.scale), CGFloat(OverlayLayout.minScale))
        let huge = OverlayLayout.resize(start: start, baseSize: CGSize(width: 100, height: 50), corner: .bottomRight,
                                        translation: CGSize(width: 5000, height: 0), others: [], canvas: canvas, insets: insets)
        expect(huge.scale <= OverlayLayout.maxScale)
        expect(huge.center.x + CGFloat(huge.scale) * 50 <= canvas.width - insets.trailing + 0.001, "stays inside the barrier")
    }
}
