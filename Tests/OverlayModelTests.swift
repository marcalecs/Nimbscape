import Foundation
import CoreGraphics

func runOverlayModelTests() {
    TestRunner.test("overlay config round-trips through JSON") {
        var config = OverlayConfig()
        var widget = OverlayWidget(kind: .custom, center: CGPoint(x: 0.25, y: 0.75))
        widget.customID = "pomodoro"
        widget.scale = 1.4
        config.widgets = [widget, OverlayWidget(kind: .clock, center: CGPoint(x: 0.5, y: 0.3))]
        config.effects.particles = .rain
        config.effects.dim = 0.2
        let decoded = try JSONDecoder().decode(OverlayConfig.self, from: JSONEncoder().encode(config))
        expect(decoded == config)
    }

    TestRunner.test("older saved widgets decode with defaults") {
        let json = #"{"kind":"weather","center":[0.1,0.2]}"#
        let widget = try JSONDecoder().decode(OverlayWidget.self, from: Data(json.utf8))
        expect(widget.kind == .weather)
        expect(widget.scale == 1 && widget.style == .glass && widget.city.isEmpty && widget.customID == nil)
    }

    TestRunner.test("only snow and rain are offered as effects") {
        expect(OverlayParticles.selectable == [.none, .snow, .rain])
    }

    TestRunner.test("empty configs are recognized") {
        expect(OverlayConfig().isEmpty)
        var c = OverlayConfig(); c.effects.blur = true
        expect(!c.isEmpty)
    }
}
