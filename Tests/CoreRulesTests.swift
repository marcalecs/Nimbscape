import Foundation

func runCoreRulesTests() {
    TestRunner.test("battery percent from capacities") {
        expect(CoreRules.batteryPercent(current: 22, max: 100) == 22)
        expect(CoreRules.batteryPercent(current: 4500, max: 5000) == 90)
        expect(CoreRules.batteryPercent(current: 7, max: 0) == 7)
    }

    TestRunner.test("catalog paths can't escape the widget folder") {
        expect(CoreRules.isSafeRelativePath("index.html"))
        expect(CoreRules.isSafeRelativePath("assets/app.js"))
        expect(!CoreRules.isSafeRelativePath(""))
        expect(!CoreRules.isSafeRelativePath("/etc/passwd"))
        expect(!CoreRules.isSafeRelativePath("../../secret"))
        expect(!CoreRules.isSafeRelativePath("a/../../b"))
    }

    TestRunner.test("download cleanup removes orphans and .part, never recent files") {
        let now = Date(timeIntervalSince1970: 100_000)
        let old = now.addingTimeInterval(-3600), fresh = now.addingTimeInterval(-60)
        let refs: Set<String> = ["/hd/a.mp4"]
        expect(!CoreRules.shouldRemoveDownloadedFile(path: "/hd/a.mp4", referenced: refs, modified: old, now: now, gracePeriod: 600))
        expect(CoreRules.shouldRemoveDownloadedFile(path: "/hd/b.mp4", referenced: refs, modified: old, now: now, gracePeriod: 600))
        expect(CoreRules.shouldRemoveDownloadedFile(path: "/hd/a.mp4.part", referenced: refs, modified: old, now: now, gracePeriod: 600))
        expect(!CoreRules.shouldRemoveDownloadedFile(path: "/hd/b.mp4", referenced: refs, modified: fresh, now: now, gracePeriod: 600))
    }

    TestRunner.test("month grid starts on the right weekday") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2   // Monday
        let nov20 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        let days = CoreRules.monthDays(for: nov20, calendar: calendar)
        // 1 Nov 2026 is a Sunday → six blank Monday-first columns
        expect(days.prefix(6).allSatisfy { $0 == nil })
        expect(days[6].map { calendar.component(.day, from: $0) } == 1)
        expect(days.compactMap { $0 }.count == 30)
        expect(CoreRules.weekdaySymbols(calendar: calendar).count == 7)
    }
}
