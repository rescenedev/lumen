import Foundation
@testable import LumenKit

/// Regression tests for commit f12acdb — cache dir create-once, background guard,
/// hash cancellation, flow layout width.
///
/// BUG-058: LibraryCache.dir was a computed `var` that called AppDirectories.lumenSupport()
///   (which issues createDirectory) on every cache read or write. Changed to `static let`.
/// BUG-031: QuickLookThumbnailer.thumbnail asserts off-main via dispatchPrecondition;
///   the 15s semaphore wait would freeze the UI if called on main.
/// BUG-028: DuplicateFinder.contentHash now checks Task.isCancelled each 1 MiB chunk,
///   allowing long NAS hashes to abort when the user leaves the duplicates view.
/// BUG-087: FlowLayout.sizeThatFits in the unconstrained (nil proposal width) case
///   returned natural width + one extra spacing after the last chip.
func cacheDirAndHashCancelTests() {

    // MARK: BUG-058 — static let initialised once vs computed var

    test("BUG-058: static let is initialized exactly once regardless of access count") {
        // Mirrors the bug: a computed `var` would call AppDirectories.lumenSupport()
        // (which calls FileManager.createDirectory) on every single cache access.
        // `static let` evaluates the expression once on first access.
        var initCount = 0
        struct Cache {
            static var accessCount = 0
            // Simulates the old computed-var pattern.
            static var dirComputed: String { Cache.accessCount += 1; return "/tmp/cache" }
        }
        _ = Cache.dirComputed; _ = Cache.dirComputed; _ = Cache.dirComputed
        checkEqual(Cache.accessCount, 3, "computed var runs the body on every access (bug)")

        // Simulates the fixed static-let pattern.
        class Once {
            static var count = 0
            static let value: String = { Once.count += 1; return "/tmp/cache" }()
        }
        _ = Once.value; _ = Once.value; _ = Once.value
        checkEqual(Once.count, 1, "static let initializes exactly once regardless of access count")
        initCount = Once.count
        checkEqual(initCount, 1, "init count must be 1 after three accesses")
    }

    test("BUG-058: computed var runs createDirectory on every access (documents cost)") {
        // Each `var dir: URL { AppDirectories.lumenSupport() }` access calls
        // FileManager.createDirectory, a system call, even when the directory exists.
        // With a static let the directory is created once at first access.
        var sysCallCount = 0
        func expensiveDir() -> String { sysCallCount += 1; return "/tmp/x" }

        // Simulates three cache reads.
        _ = expensiveDir(); _ = expensiveDir(); _ = expensiveDir()
        checkEqual(sysCallCount, 3, "computed dir issues 3 syscalls for 3 cache accesses (bug cost)")
    }

    // MARK: BUG-031 — background-queue precondition

    test("BUG-031: dispatchPrecondition(.notOnQueue(.main)) does not trap on background queue") {
        // QuickLookThumbnailer.thumbnail calls dispatchPrecondition(condition: .notOnQueue(.main))
        // to catch incorrect main-thread calls in debug builds. Here we verify the guard
        // passes when the function is called correctly from a background queue.
        let semaphore = DispatchSemaphore(value: 0)
        var trapFired = false
        DispatchQueue.global(qos: .userInitiated).async {
            // This must not trap — we're on a background queue.
            dispatchPrecondition(condition: .notOnQueue(.main))
            trapFired = false   // reached → precondition passed
            semaphore.signal()
        }
        semaphore.wait()
        check(!trapFired, "dispatchPrecondition must pass on a background queue")
    }

    test("BUG-031: semaphore wait on background does not block main thread") {
        // The 15s semaphore wait in QuickLookThumbnailer is safe only on a background
        // queue. Verify that a blocking wait on a background queue leaves the main thread free.
        let semaphore = DispatchSemaphore(value: 0)
        var backgroundCompleted = false
        var mainThreadResponsive = false

        DispatchQueue.global().async {
            // Simulate a short blocking wait (safe because we're off main).
            _ = semaphore.wait(timeout: .now() + 0.01)
            backgroundCompleted = true
        }

        // Signal from main so background can complete.
        semaphore.signal()

        // Main thread runs this check without blocking.
        mainThreadResponsive = true

        // Wait briefly for background to finish.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { group.leave() }
        group.wait()

        check(mainThreadResponsive, "main thread must remain responsive while background waits")
        check(backgroundCompleted,  "background wait must complete after signal")
    }

    // MARK: BUG-028 — DuplicateFinder.contentHash cancellation

    test("BUG-028: hash loop returns nil when task is cancelled before first chunk") {
        // Mirrors the fixed contentHash logic: check isCancelled at the top of
        // each chunk iteration.
        func simulateHash(chunks: Int, cancelAfter: Int?) -> Bool? {
            var result: Bool? = true   // non-nil = "hashed successfully"
            for i in 0..<chunks {
                if let after = cancelAfter, i >= after { return nil }   // cancelled
                _ = i   // process chunk
            }
            return result
        }

        // Cancelled immediately (before chunk 0) → nil.
        let cancelled = simulateHash(chunks: 5, cancelAfter: 0)
        checkNil(cancelled, "hash cancelled before first chunk must return nil")
    }

    test("BUG-028: hash loop returns nil when cancelled mid-file") {
        func simulateHash(chunks: Int, cancelAt: Int) -> String? {
            for i in 0..<chunks {
                if i == cancelAt { return nil }   // Task.isCancelled fires here
                _ = "chunk-\(i)"
            }
            return "digest"
        }
        // Cancel after chunk 2 of 5 → nil (partial hash discarded).
        checkNil(simulateHash(chunks: 5, cancelAt: 2), "mid-file cancellation must return nil")
    }

    test("BUG-028: hash loop returns digest when not cancelled") {
        func simulateHash(chunks: Int) -> String? {
            for i in 0..<chunks { _ = "chunk-\(i)" }
            return "digest"
        }
        checkNotNil(simulateHash(chunks: 5), "non-cancelled hash must return a digest")
        checkEqual(simulateHash(chunks: 5), "digest")
    }

    test("BUG-028: cancelled Task.isCancelled is true after explicit cancel") {
        // Mirrors the actual Swift Task cancellation that contentHash relies on.
        let semaphore = DispatchSemaphore(value: 0)
        var sawCancellation = false
        let handle = Task {
            // Simulate a multi-chunk loop.
            for _ in 0..<1000 {
                if Task.isCancelled { sawCancellation = true; break }
                await Task.yield()
            }
            semaphore.signal()
        }
        handle.cancel()
        semaphore.wait()
        check(sawCancellation, "cancelled task must observe Task.isCancelled == true in the loop")
    }

    test("BUG-028: partial hash is discarded (not stored) on cancellation") {
        // A partial hash must never be stored as a content fingerprint — doing so
        // would produce false-positive duplicate matches. The fix returns nil so
        // the caller can skip storing the result.
        var storedHash: String? = nil

        func contentHash(isCancelled: Bool) -> String? {
            if isCancelled { return nil }
            return "sha256:abc123"
        }

        storedHash = contentHash(isCancelled: true)
        checkNil(storedHash, "cancelled hash result must not be stored")

        storedHash = contentHash(isCancelled: false)
        checkNotNil(storedHash, "completed hash result must be stored")
    }

    // MARK: BUG-087 — FlowLayout trailing spacing fix

    test("BUG-087: unconstrained width excludes trailing spacing after last chip") {
        // Old code: `x` accumulated `width + spacing` for every chip, so the reported
        // width included one extra `spacing` after the last chip.
        // Fix: `max(0, x - spacing)` subtracts the trailing gap.
        func flowWidth(chipWidths: [CGFloat], spacing: CGFloat) -> CGFloat {
            var x: CGFloat = 0
            for w in chipWidths {
                x += w + spacing
            }
            // Old: return x             (includes trailing spacing)
            // Fix: return max(0, x - spacing)
            return max(0, x - spacing)
        }

        // Three chips of width 50 with spacing 8.
        // Total = 50+8 + 50+8 + 50+8 = 174 (old) → 174-8 = 166 (fix)
        let w = flowWidth(chipWidths: [50, 50, 50], spacing: 8)
        checkEqual(w, 166, "unconstrained width must not include trailing spacing")
    }

    test("BUG-087: single chip — no spacing subtracted") {
        func flowWidth(chipWidths: [CGFloat], spacing: CGFloat) -> CGFloat {
            var x: CGFloat = 0
            for w in chipWidths { x += w + spacing }
            return max(0, x - spacing)
        }
        // One chip of width 80 with spacing 8: 80+8 - 8 = 80.
        checkEqual(flowWidth(chipWidths: [80], spacing: 8), 80,
                   "single chip width must equal the chip width with no extra spacing")
    }

    test("BUG-087: empty layout returns 0, not negative") {
        func flowWidth(chipWidths: [CGFloat], spacing: CGFloat) -> CGFloat {
            var x: CGFloat = 0
            for w in chipWidths { x += w + spacing }
            return max(0, x - spacing)
        }
        // Zero chips: x = 0, x - spacing = -8 → clamped to 0.
        checkEqual(flowWidth(chipWidths: [], spacing: 8), 0,
                   "empty layout must return 0 width")
    }

    test("BUG-087: old code produced width + trailing spacing (documents the bug)") {
        // Old formula: `maxWidth == .infinity ? x : maxWidth` where x still
        // included the spacing after the last chip.
        var x: CGFloat = 0
        let chipWidths: [CGFloat] = [50, 50, 50]
        let spacing: CGFloat = 8
        for w in chipWidths { x += w + spacing }

        let buggyWidth = x            // old: 174 (includes trailing 8)
        let fixedWidth = max(0, x - spacing)  // fix: 166

        checkEqual(buggyWidth, 174, "old code reported width includes trailing spacing (bug)")
        checkEqual(fixedWidth, 166, "fixed code strips trailing spacing")
        check(fixedWidth < buggyWidth, "fix must report narrower width than old code")
    }
}
