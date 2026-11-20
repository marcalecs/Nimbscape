import Foundation

func runLockScreenTimelineTests() {
    TestRunner.test("files are always at least five minutes long") {
        for duration in LockScreenTimeline.PlayDuration.allCases {
            let flags = LockScreenTimeline.advanceFlags(fps: 60, playSeconds: Double(duration.rawValue))
            expect(flags.count >= 300 * 60, "\(duration) gave \(flags.count) frames")
        }
    }

    TestRunner.test("30 s plays normally, eases out, then holds") {
        let flags = LockScreenTimeline.advanceFlags(fps: 60, playSeconds: 30)
        expect(flags.prefix(30 * 60).allSatisfy { $0 }, "first 30 s advance every frame")
        let ease = flags[(30 * 60)..<(30 * 60 + 90)]
        let advancing = ease.filter { $0 }.count
        expect(advancing > 10 && advancing < 90, "ease-out slows down: \(advancing) of 90 advance")
        expect(flags.suffix(60).allSatisfy { !$0 }, "the end holds the last frame")
    }

    TestRunner.test("ease-out repeats grow over time") {
        let flags = Array(LockScreenTimeline.advanceFlags(fps: 60, playSeconds: 30)[(30 * 60)..<(30 * 60 + 90)])
        let firstHalf = flags.prefix(45).filter { $0 }.count
        let secondHalf = flags.suffix(45).filter { $0 }.count
        expect(firstHalf > secondHalf, "\(firstHalf) vs \(secondHalf)")
    }

    TestRunner.test("5 min plays the whole file without holding") {
        let flags = LockScreenTimeline.advanceFlags(fps: 30, playSeconds: 300)
        expect(flags.allSatisfy { $0 })
    }
}
