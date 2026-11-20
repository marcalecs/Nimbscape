import Foundation

runOverlayLayoutTests()
runCoreRulesTests()
runOverlayModelTests()
runLockScreenTimelineTests()
runLockScreenLookTests()

if TestRunner.failures.isEmpty {
    print("✅ \(TestRunner.checks) checks passed")
    exit(0)
} else {
    print("❌ \(TestRunner.failures.count) of \(TestRunner.checks) checks failed:")
    TestRunner.failures.forEach { print("  • \($0)") }
    exit(1)
}
