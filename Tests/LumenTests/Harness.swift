import Foundation

/// A tiny, zero-dependency test harness. macOS Command Line Tools ship neither
/// XCTest nor swift-testing, so we provide just enough to register tests, run
/// assertions, and exit non-zero on failure. Assertions record-and-continue
/// (like XCTAssert) rather than throwing, so one test can report many failures.
enum Harness {
    private(set) static var passed = 0
    private(set) static var failed = 0
    static var currentTest = ""
    private static var failuresInCurrent = 0
    static var lines: [String] = []

    static func run(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        failuresInCurrent = 0
        do {
            try body()
        } catch {
            recordFailure("threw error: \(error)", file: #file, line: #line)
        }
        if failuresInCurrent == 0 {
            passed += 1
        } else {
            failed += 1
        }
    }

    static func recordFailure(_ message: String, file: StaticString, line: UInt) {
        failuresInCurrent += 1
        let short = URL(fileURLWithPath: "\(file)").lastPathComponent
        lines.append("  ✗ [\(currentTest)] \(message)  (\(short):\(line))")
    }

    /// Print the summary and return a process exit code.
    static func finish() -> Int32 {
        for line in lines { print(line) }
        let total = passed + failed
        print("\n────────────────────────────────────────")
        if failed == 0 {
            print("✅ All \(total) tests passed.")
            return 0
        } else {
            print("❌ \(failed) failed, \(passed) passed (\(total) total).")
            return 1
        }
    }
}

/// Register and immediately run a single test case.
func test(_ name: String, _ body: () throws -> Void) {
    Harness.run(name, body)
}

// MARK: - Assertions (record-and-continue)

func check(_ condition: Bool, _ message: @autoclosure () -> String = "expected true",
           file: StaticString = #file, line: UInt = #line) {
    if !condition { Harness.recordFailure(message(), file: file, line: line) }
}

func checkEqual<V: Equatable>(_ actual: V, _ expected: V, _ message: @autoclosure () -> String = "",
                              file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        let extra = message().isEmpty ? "" : " — \(message())"
        Harness.recordFailure("expected \(expected) but got \(actual)\(extra)", file: file, line: line)
    }
}

func checkNotEqual<V: Equatable>(_ a: V, _ b: V, _ message: @autoclosure () -> String = "",
                                 file: StaticString = #file, line: UInt = #line) {
    if a == b { Harness.recordFailure("expected values to differ, both were \(a)", file: file, line: line) }
}

func checkNil<V>(_ value: V?, _ message: @autoclosure () -> String = "expected nil",
                 file: StaticString = #file, line: UInt = #line) {
    if value != nil { Harness.recordFailure("\(message()) but got \(value!)", file: file, line: line) }
}

func checkNotNil<V>(_ value: V?, _ message: @autoclosure () -> String = "expected non-nil",
                    file: StaticString = #file, line: UInt = #line) {
    if value == nil { Harness.recordFailure(message(), file: file, line: line) }
}
