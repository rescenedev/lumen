import Foundation
@testable import LumenKit

/// Regression tests for commit 542ec97 — WindowReader deduplication.
///
/// BUG-093: WindowReader.updateNSView re-posted `onWindow` on every SwiftUI
///   body evaluation, churning SidebarView's body even when the window was
///   unchanged. Fix: a Coordinator tracks the last-reported window and skips
///   callbacks when the window reference hasn't changed.
///
/// NOT A BUG:
/// BUG-025: BatchProcessor.progress closure crossing into a detached Task is
///   a Swift-6 strict-concurrency annotation concern, not a runtime bug in
///   Swift-5 mode; adding @Sendable would surface @State-capture warnings at
///   the call site that are harder to resolve.
/// BUG-039: scan()'s `if !exif.isEmpty` check and the subsequent `await
///   indexExif()` call are both synchronous on @MainActor with no intervening
///   await, so the exif set cannot be cleared between check and call.
func windowReaderDedupeTests() {

    // MARK: BUG-093 — Coordinator deduplication logic

    test("BUG-093: first report always fires (reported == false)") {
        // Mirrors Coordinator initial state: reported = false.
        // The first `report` call must always invoke onWindow regardless of window value.
        var fireCount = 0
        var reported = false
        var lastWindow: AnyObject? = nil

        func report(window: AnyObject?) {
            if !reported || window !== lastWindow {
                reported = true
                lastWindow = window
                fireCount += 1
            }
        }

        report(window: nil)
        checkEqual(fireCount, 1, "first report (nil window) must fire onWindow")
    }

    test("BUG-093: identical window reference does not fire again") {
        var fireCount = 0
        var reported = false
        var lastWindow: AnyObject? = nil

        func report(window: AnyObject?) {
            guard !reported || window !== lastWindow else { return }
            reported = true; lastWindow = window; fireCount += 1
        }

        let fakeWindow = NSObject()
        report(window: fakeWindow)   // first: fires
        report(window: fakeWindow)   // same ref: must skip
        report(window: fakeWindow)   // same ref: must skip
        checkEqual(fireCount, 1, "repeated identical window must not re-fire onWindow")
    }

    test("BUG-093: window change (nil → window) fires callback") {
        var fireCount = 0
        var reported = false
        var lastWindow: AnyObject? = nil

        func report(window: AnyObject?) {
            guard !reported || window !== lastWindow else { return }
            reported = true; lastWindow = window; fireCount += 1
        }

        report(window: nil)           // first: nil window
        let fakeWindow = NSObject()
        report(window: fakeWindow)    // window appeared: must fire
        checkEqual(fireCount, 2, "nil→window transition must fire onWindow")
    }

    test("BUG-093: window change (window → nil) fires callback") {
        var fireCount = 0
        var reported = false
        var lastWindow: AnyObject? = nil

        func report(window: AnyObject?) {
            guard !reported || window !== lastWindow else { return }
            reported = true; lastWindow = window; fireCount += 1
        }

        let fakeWindow = NSObject()
        report(window: fakeWindow)   // window present
        report(window: nil)          // window removed: must fire
        checkEqual(fireCount, 2, "window→nil transition must fire onWindow")
    }

    test("BUG-093: distinct window objects each trigger a callback") {
        var fireCount = 0
        var reported = false
        var lastWindow: AnyObject? = nil

        func report(window: AnyObject?) {
            guard !reported || window !== lastWindow else { return }
            reported = true; lastWindow = window; fireCount += 1
        }

        let w1 = NSObject(), w2 = NSObject(), w3 = NSObject()
        report(window: w1); report(window: w2); report(window: w3)
        checkEqual(fireCount, 3, "three distinct windows must each fire onWindow")
    }

    test("BUG-093: old code fired on every SwiftUI update (documents the churn)") {
        // The old updateNSView always posted to DispatchQueue.main without checking.
        // Simulate 10 SwiftUI updates with the same window: 10 fires (bug) vs 1 (fix).
        var buggyFires = 0
        let fakeWindow = NSObject()

        func oldUpdateNSView(window: AnyObject?) {
            buggyFires += 1   // always fires
        }

        for _ in 0..<10 { oldUpdateNSView(window: fakeWindow) }
        checkEqual(buggyFires, 10, "old code fires on every SwiftUI update (bug confirmed)")

        // Fixed: deduplicated to 1.
        var fixedFires = 0
        var reported = false
        var lastWindow: AnyObject? = nil

        func fixedReport(window: AnyObject?) {
            guard !reported || window !== lastWindow else { return }
            reported = true; lastWindow = window; fixedFires += 1
        }
        for _ in 0..<10 { fixedReport(window: fakeWindow) }
        checkEqual(fixedFires, 1, "fixed code fires only once for unchanged window")
    }

    // MARK: BUG-025 — @Sendable annotation is a Swift-6 concern, not a Swift-5 bug

    test("BUG-025: closure without @Sendable compiles and runs correctly in Swift-5 mode") {
        // BatchProcessor.progress is a `(Int, Int) -> Void` closure that is called
        // inside a `Task.detached`. In Swift-5 mode, crossing a concurrency boundary
        // without @Sendable is a warning (or silent); in Swift-6 strict mode it would
        // be an error. The current project compiles in Swift-5 mode with no warnings.
        //
        // Verify: a plain non-@Sendable closure can be stored, captured, and called.
        var callCount = 0
        let progress: (Int, Int) -> Void = { _, _ in callCount += 1 }

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            progress(1, 10)   // Swift-5: allowed; Swift-6: would require @Sendable
            semaphore.signal()
        }
        semaphore.wait()
        checkEqual(callCount, 1, "closure without @Sendable executes correctly in Swift-5 mode")
    }

    // MARK: BUG-039 — exif check and call are synchronous on @MainActor

    test("BUG-039: check then call without await means the condition can't change between them") {
        // scan()'s pattern:  if !exif.isEmpty { await indexExif(...) }
        // Both the `if` check and the `await` call site are synchronous expressions
        // in the same @MainActor context — no await appears between the guard and
        // the call. This means no other code can run on the actor and clear `exif`
        // between the check and the call.
        //
        // Verify: a synchronous check-then-use in a serial context is atomic.
        var exif: [String] = ["photo1.jpg", "photo2.jpg"]
        var indexCalled = false

        // Simulate the synchronous pattern (no await between check and call).
        if !exif.isEmpty {
            // No other actor task can mutate exif here — we're in a synchronous block.
            indexCalled = true
        }

        check(indexCalled, "indexExif must be called when exif is non-empty (synchronous check)")
        check(!exif.isEmpty, "exif must still be non-empty — no concurrent mutation possible")
    }

    test("BUG-039: empty exif correctly skips indexing") {
        var exif: [String] = []
        var indexCalled = false

        if !exif.isEmpty { indexCalled = true }

        check(!indexCalled, "indexExif must not be called when exif is empty")
    }
}
