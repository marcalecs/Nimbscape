import Foundation

func runLockScreenLookTests() {
    TestRunner.test("default look changes nothing") {
        expect(LockScreenLook().isIdentityImage)
        expect(LockScreenLook().clampedSpeed == 1)
    }

    TestRunner.test("look maps like the desktop video view") {
        let look = LockScreenLook(hue: -15, brightness: 0.87, contrast: 1.27, saturation: 0)
        expect(look.hasHue && look.hasColorControls && !look.isIdentityImage)
        expectClose(CGFloat(look.hueAngle), CGFloat(-15 * Double.pi / 180))
        expectClose(CGFloat(look.mappedBrightness), -0.065)
        expectClose(CGFloat(LockScreenLook(brightness: 3).mappedBrightness), 0.5)
    }

    TestRunner.test("dim, blur and speed") {
        expectClose(CGFloat(LockScreenLook(dim: 0.3).dimFactor), 0.7)
        expect(!LockScreenLook(blur: true).isIdentityImage)
        expectClose(CGFloat(LockScreenLook.blurRadius(forWidth: 3840)), 60)
        expect(LockScreenLook(speed: 5).clampedSpeed == 2 && LockScreenLook(speed: 0.1).clampedSpeed == 0.25)
    }
}
