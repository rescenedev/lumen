import Foundation
@testable import LumenKit

/// Tests for the cold-cache browsing fixes (2026-07 "loading is slow" report):
///
/// 1. `DecodeGate` — cross-lane in-flight dedupe. The display, viewport-prefetch,
///    and warming lanes could all read+decode the SAME original simultaneously
///    (up to 3 full NAS/USB reads per visible photo on a cold cache).
/// 2. `BrowsingActivityGate` — warming must stay suspended for as long as
///    user-facing decodes are in flight, not for a fixed 2.5 s window that
///    expires mid-fill and lets warming steal disk I/O back.
/// 3. `warmChunkRanges` — the warm queue enqueues operations in bounded chunks
///    instead of holding ~66k BlockOperations resident for hours.
func thumbnailCoordinationTests() {

    // MARK: DecodeGate

    test("DecodeGate: first acquirer owns the key, concurrent acquirer waits until release") {
        let gate = DecodeGate()
        check(gate.acquireOrWait("k", timeout: 1), "first caller must own the decode")

        let waiterDone = DispatchSemaphore(value: 0)
        var waiterOwned: Bool?
        var waitedMs: Double = 0
        DispatchQueue.global().async {
            let t0 = CFAbsoluteTimeGetCurrent()
            waiterOwned = gate.acquireOrWait("k", timeout: 5)
            waitedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            waiterDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.15)   // let the waiter block
        gate.release("k")
        checkEqual(waiterDone.wait(timeout: .now() + 2), .success, "waiter must unblock on release")
        checkEqual(waiterOwned, false, "second caller must NOT own — it waited for the owner")
        check(waitedMs >= 100, "waiter should actually have blocked (waited \(waitedMs)ms)")
    }

    test("DecodeGate: distinct keys don't contend") {
        let gate = DecodeGate()
        check(gate.acquireOrWait("a", timeout: 1))
        let t0 = CFAbsoluteTimeGetCurrent()
        check(gate.acquireOrWait("b", timeout: 1), "different key must acquire immediately")
        check(CFAbsoluteTimeGetCurrent() - t0 < 0.5, "no blocking for a different key")
        gate.release("a"); gate.release("b")
    }

    test("DecodeGate: waiter times out and proceeds; its non-ownership must not clear the owner") {
        let gate = DecodeGate()
        check(gate.acquireOrWait("k", timeout: 1))
        // Times out (owner never releases within the window) — returns false.
        checkEqual(gate.acquireOrWait("k", timeout: 0.1), false)
        // The key is still owned: a third caller must still wait, proving the
        // timed-out waiter didn't corrupt the in-flight entry.
        checkEqual(gate.acquireOrWait("k", timeout: 0.1), false)
        gate.release("k")
        check(gate.acquireOrWait("k", timeout: 1), "after release the key is acquirable again")
        gate.release("k")
    }

    test("DecodeGate: release wakes ALL waiters") {
        let gate = DecodeGate()
        check(gate.acquireOrWait("k", timeout: 1))
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<4 {
            DispatchQueue.global().async {
                _ = gate.acquireOrWait("k", timeout: 5)
                done.signal()
            }
        }
        Thread.sleep(forTimeInterval: 0.15)
        gate.release("k")
        for i in 0..<4 {
            checkEqual(done.wait(timeout: .now() + 2), .success, "waiter \(i) must wake")
        }
    }

    // MARK: BrowsingActivityGate

    test("BrowsingActivityGate: suspends on begin, resumes only after last end + grace") {
        var suspended = false
        let stateLock = NSLock()
        let gate = BrowsingActivityGate(grace: 0.1) { on in
            stateLock.lock(); suspended = on; stateLock.unlock()
        }
        func isSuspended() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return suspended }

        gate.begin()
        check(isSuspended(), "warming must suspend when display work starts")
        gate.begin()
        gate.end()
        Thread.sleep(forTimeInterval: 0.25)
        check(isSuspended(), "one decode still in flight — must stay suspended past the grace period")
        gate.end()
        check(isSuspended(), "grace period: still suspended immediately after the last end")
        Thread.sleep(forTimeInterval: 0.3)
        check(!isSuspended(), "must resume after the last end + grace")
    }

    test("BrowsingActivityGate: new begin during grace cancels the pending resume") {
        var suspended = false
        let stateLock = NSLock()
        let gate = BrowsingActivityGate(grace: 0.15) { on in
            stateLock.lock(); suspended = on; stateLock.unlock()
        }
        func isSuspended() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return suspended }

        gate.begin(); gate.end()          // resume scheduled in 0.15s
        gate.begin()                      // …but new work arrives first
        Thread.sleep(forTimeInterval: 0.3)
        check(isSuspended(), "pending resume must be cancelled by the new begin")
        gate.end()
        Thread.sleep(forTimeInterval: 0.3)
        check(!isSuspended())
    }

    test("BrowsingActivityGate: touch() suspends and auto-resumes when idle (legacy yield behavior)") {
        var suspended = false
        let stateLock = NSLock()
        let gate = BrowsingActivityGate(grace: 0.1) { on in
            stateLock.lock(); suspended = on; stateLock.unlock()
        }
        func isSuspended() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return suspended }

        gate.touch()
        check(isSuspended(), "touch must suspend immediately")
        Thread.sleep(forTimeInterval: 0.3)
        check(!isSuspended(), "touch with no active work must auto-resume after grace")
    }

    test("BrowsingActivityGate: unbalanced end is clamped, doesn't wedge the counter") {
        var suspended = false
        let stateLock = NSLock()
        let gate = BrowsingActivityGate(grace: 0.05) { on in
            stateLock.lock(); suspended = on; stateLock.unlock()
        }
        gate.end()          // stray end with no begin
        gate.begin()
        gate.end()
        Thread.sleep(forTimeInterval: 0.25)
        stateLock.lock(); let s = suspended; stateLock.unlock()
        check(!s, "a stray end() must not leave the counter negative (begin would never suspend-count to 0)")
    }

    // MARK: Warm chunking

    test("warmChunkRanges: covers the whole range in bounded chunks, in order") {
        let ranges = ThumbnailCache.warmChunkRanges(total: 1000, chunkSize: 400)
        checkEqual(ranges.map { [$0.lowerBound, $0.upperBound] }, [[0, 400], [400, 800], [800, 1000]])
    }

    test("warmChunkRanges: exact multiple and empty totals") {
        checkEqual(ThumbnailCache.warmChunkRanges(total: 800, chunkSize: 400).count, 2)
        check(ThumbnailCache.warmChunkRanges(total: 0, chunkSize: 400).isEmpty)
        checkEqual(ThumbnailCache.warmChunkRanges(total: 3, chunkSize: 400).map { [$0.lowerBound, $0.upperBound] }, [[0, 3]])
    }

    test("warmChunkRanges: guards a nonsensical chunk size") {
        checkEqual(ThumbnailCache.warmChunkRanges(total: 10, chunkSize: 0).map { [$0.lowerBound, $0.upperBound] }, [[0, 10]],
                   "chunkSize <= 0 must degrade to a single chunk, not loop forever")
    }
}
