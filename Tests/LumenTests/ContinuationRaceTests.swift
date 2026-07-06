import Foundation
@testable import LumenKit

/// Regression tests for commit 56277b3 — PhotoKit/drop continuation races.
///
/// BUG-005/006: PhotosImageLoader's withCheckedContinuation handlers protected
///   the `resumed` flag with a plain `var` — a data race when PhotoKit delivers
///   degraded then final frames on concurrent threads.
///   Fix: NSLock wraps every read-modify of `resumed`.
///
/// BUG-019: EmptyStateView.handleDrop appended to `urls` from arbitrary
///   background queues with no synchronization.
///   Fix: NSLock serializes all `urls.append` calls.
///
/// The private methods on PhotosImageLoader require real PHAsset objects, so
/// we test the synchronization invariant directly rather than through PhotoKit:
/// verify that a lock-protected resume-once flag is correct under contention.
func continuationRaceTests() {

    // MARK: BUG-005/006 — resume-once invariant under concurrent callers

    test("BUG-005/006: lock-guarded resume fires exactly once under 100 concurrent callers") {
        let lock = NSLock()
        var resumed = false
        var resumeCount = 0

        let group = DispatchGroup()
        // Simulate 100 concurrent "PhotoKit callbacks" all racing to resume.
        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                lock.lock()
                if !resumed {
                    resumed = true
                    resumeCount += 1
                }
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        checkEqual(resumeCount, 1,
                   "continuation must be resumed exactly once; got \(resumeCount)")
    }

    test("BUG-005/006: unprotected resume-once is a documented race (control test)") {
        // This test documents WHY the lock was needed: without it, concurrent
        // writes to `resumed` are undefined behaviour in Swift. We can't reliably
        // *trigger* the race deterministically in a test, but we can show the
        // protected version is provably correct.
        //
        // This passes trivially (sequential execution), confirming the test
        // infra is running correctly — not that the race is absent.
        var resumed = false
        var resumeCount = 0
        // Sequential invocations — no concurrency, so no race.
        for _ in 0..<10 {
            if !resumed { resumed = true; resumeCount += 1 }
        }
        checkEqual(resumeCount, 1, "sequential resume-once should fire exactly once")
    }

    test("BUG-006: degraded-skip path does not block terminal resume") {
        // Models the corrected logic: skip degraded placeholder, but always
        // resume on the final/cancelled/failed frame.
        let lock = NSLock()
        var resumed = false
        var resumeCount = 0

        func handleFrame(isDegraded: Bool, isCancelled: Bool, isFailed: Bool,
                         imagePresent: Bool, skipDegraded: Bool) {
            // Replicated from the fixed PhotosImageLoader code path.
            if skipDegraded && isDegraded && imagePresent && !isCancelled && !isFailed {
                return  // still waiting for the high-quality final frame
            }
            lock.lock()
            if !resumed { resumed = true; resumeCount += 1 }
            lock.unlock()
        }

        // Frame 1: degraded placeholder — must be skipped.
        handleFrame(isDegraded: true, isCancelled: false, isFailed: false,
                    imagePresent: true, skipDegraded: true)
        checkEqual(resumeCount, 0, "degraded frame must not resume the continuation")

        // Frame 2: final high-quality — must resume exactly once.
        handleFrame(isDegraded: false, isCancelled: false, isFailed: false,
                    imagePresent: true, skipDegraded: true)
        checkEqual(resumeCount, 1, "final frame must resume the continuation once")

        // Frame 3: spurious extra call (PhotoKit can fire more than twice) — must be ignored.
        handleFrame(isDegraded: false, isCancelled: false, isFailed: false,
                    imagePresent: true, skipDegraded: true)
        checkEqual(resumeCount, 1, "duplicate final-frame callback must not double-resume")
    }

    test("BUG-006: cancelled/failed frame resumes even when skipDegraded is true") {
        // If only degraded frames arrive and then PhotoKit cancels the request,
        // the old code leaked the continuation (it only resumed on non-degraded).
        // The fix ensures failed/cancelled frames always break out of the guard.
        let lock = NSLock()
        var resumed = false
        var resumeCount = 0

        func handleFrame(isDegraded: Bool, isCancelled: Bool, isFailed: Bool,
                         imagePresent: Bool, skipDegraded: Bool) {
            if skipDegraded && isDegraded && imagePresent && !isCancelled && !isFailed {
                return
            }
            lock.lock()
            if !resumed { resumed = true; resumeCount += 1 }
            lock.unlock()
        }

        // Degraded placeholder — skip.
        handleFrame(isDegraded: true, isCancelled: false, isFailed: false,
                    imagePresent: true, skipDegraded: true)
        checkEqual(resumeCount, 0, "degraded placeholder skipped")

        // PhotoKit cancels — must resume (was: continuation leaked).
        handleFrame(isDegraded: false, isCancelled: true, isFailed: false,
                    imagePresent: false, skipDegraded: true)
        checkEqual(resumeCount, 1, "cancelled request must still resume the continuation")
    }

    test("BUG-006: nil-image final frame resumes (no leak for missing-from-iCloud photos)") {
        let lock = NSLock()
        var resumed = false
        var resumeCount = 0

        func handleFrame(isDegraded: Bool, isCancelled: Bool, isFailed: Bool,
                         imagePresent: Bool, skipDegraded: Bool) {
            if skipDegraded && isDegraded && imagePresent && !isCancelled && !isFailed {
                return
            }
            lock.lock()
            if !resumed { resumed = true; resumeCount += 1 }
            lock.unlock()
        }

        // Nil image with no error — not degraded, not cancelled, imagePresent=false.
        handleFrame(isDegraded: false, isCancelled: false, isFailed: false,
                    imagePresent: false, skipDegraded: true)
        checkEqual(resumeCount, 1, "nil-image frame must resume (not leak) the continuation")
    }

    // MARK: BUG-019 — concurrent drop-handler URL accumulation

    test("BUG-019: lock-serialized concurrent url.append is race-free") {
        let lock = NSLock()
        var urls: [URL] = []
        let count = 100
        let group = DispatchGroup()

        // Simulate `count` concurrent NSItemProvider callbacks each appending a URL
        // (replicates EmptyStateView.handleDrop's fixed logic).
        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                let url = URL(fileURLWithPath: "/tmp/lumen-drop-\(i).jpg")
                lock.lock()
                urls.append(url)
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        checkEqual(urls.count, count,
                   "expected \(count) URLs from concurrent appends, got \(urls.count)")
    }

    test("BUG-019: all providers are represented in final url list") {
        let lock = NSLock()
        var urls: [URL] = []
        let group = DispatchGroup()
        let paths = (0..<20).map { "/tmp/photo-\($0).jpg" }

        for path in paths {
            group.enter()
            DispatchQueue.global().async {
                let url = URL(fileURLWithPath: path)
                lock.lock()
                urls.append(url)
                lock.unlock()
                group.leave()
            }
        }
        group.wait()

        let gathered = Set(urls.map(\.path))
        let expected = Set(paths)
        check(gathered == expected,
              "missing URLs: \(expected.subtracting(gathered))")
    }
}
