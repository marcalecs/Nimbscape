import Foundation

/// Minimal dependency-free test harness (Command Line Tools ship neither XCTest nor a usable
/// Swift Testing setup). `make test` compiles Sources/Core with Tests/ and runs it.
enum TestRunner {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var current = ""

    static func test(_ name: String, _ body: () throws -> Void) {
        current = name
        do { try body() } catch { failures.append("\(name): threw \(error)") }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    TestRunner.checks += 1
    if !condition() { TestRunner.failures.append("\(TestRunner.current) — \(file):\(line) \(message())") }
}

func expectClose(_ a: CGFloat, _ b: CGFloat, accuracy: CGFloat = 0.001, file: StaticString = #fileID, line: UInt = #line) {
    expect(abs(a - b) <= accuracy, "\(a) ≠ \(b)", file: file, line: line)
}
