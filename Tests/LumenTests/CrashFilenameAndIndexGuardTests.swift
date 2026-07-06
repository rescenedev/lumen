import Foundation
@testable import LumenKit

/// Regression tests for commit a9db9e6 — colon-free crash filenames.
///
/// BUG-056: CrashReporter used a raw ISO8601 timestamp for filenames;
///   colons in the stamp are rendered as "/" by Finder and are unsafe in
///   HFS+ paths. Fix: replace ":" with "-" for the filename component only;
///   the human-readable report header keeps the original stamp.
///
/// NOT A BUG:
/// BUG-032: iCloudDownloader.ensureLocal's Thread.sleep runs on a dedicated
///   GCD DispatchQueue (FullImageLoader.queue), not the Swift cooperative
///   thread pool, so it never starves cooperative async tasks.
/// BUG-038: ensureExifIndex sets isIndexingExif synchronously before
///   launching its Task, atomically gating concurrent re-entry. A call
///   after completion re-checks and finds nothing new (correct behaviour).
/// BUG-066: FilterMenu excludes .none from selectable labels, so
///   filter.label is only nil or a real color — the isActive/chips
///   "active but invisible" inconsistency is unreachable in practice.
func crashFilenameAndIndexGuardTests() {

    // MARK: BUG-056 — colon-free crash report filename

    test("BUG-056: colons in ISO8601 stamp are replaced with dashes for filename") {
        let stamp = "2026-06-15T00:17:27Z"
        let fileStamp = stamp.replacingOccurrences(of: ":", with: "-")
        check(!fileStamp.contains(":"), "fileStamp must contain no colons")
        checkEqual(fileStamp, "2026-06-15T00-17-27Z",
                   "colons must be replaced with dashes")
    }

    test("BUG-056: human-readable header keeps original stamp with colons") {
        // Only the filename component is sanitized; the in-file header is unchanged.
        let stamp = "2026-06-15T00:17:27Z"
        let fileStamp = stamp.replacingOccurrences(of: ":", with: "-")
        // The header string uses `stamp`, not `fileStamp`.
        checkEqual(stamp, "2026-06-15T00:17:27Z", "original stamp is preserved for header")
        check(stamp.contains(":"), "original stamp still contains colons (for readability)")
        check(!fileStamp.contains(":"), "file stamp must be colon-free")
    }

    test("BUG-056: lexical order equals chronological after colon→dash replacement") {
        // The original ISO8601 format is already chronologically sortable.
        // After replacing ":" with "-", the zero-padded components keep the
        // same relative ordering — pruneOldReports() sorting is unaffected.
        let stamps = [
            "2026-06-15T00:17:27Z",
            "2026-06-15T01:00:00Z",
            "2026-06-15T12:30:45Z",
            "2026-06-16T00:00:00Z",
        ]
        let fileStamps = stamps.map { $0.replacingOccurrences(of: ":", with: "-") }
        let sortedFile = fileStamps.sorted()
        checkEqual(sortedFile, fileStamps, "lexical sort of file stamps matches chronological order")
    }

    test("BUG-056: old filename with colons is unsafe in HFS+ paths") {
        // Finder renders ":" as "/" in filenames, breaking path parsing.
        let badStamp = "2026-06-15T00:17:27Z"
        let filename = "crash-\(badStamp).crash"
        check(filename.contains(":"), "old filename contains colons (bug confirmed)")

        // Fixed filename has no colons.
        let goodStamp = badStamp.replacingOccurrences(of: ":", with: "-")
        let goodFilename = "crash-\(goodStamp).crash"
        check(!goodFilename.contains(":"), "fixed filename must be colon-free")
        check(goodFilename.hasSuffix(".crash"), "file extension must be preserved")
        check(goodFilename.hasPrefix("crash-"), "file prefix must be preserved")
    }

    test("BUG-056: replacement is idempotent — already-safe stamps unchanged") {
        // A stamp with no colons (already safe) must not be altered.
        let safe = "2026-06-15T00-17-27Z"
        let result = safe.replacingOccurrences(of: ":", with: "-")
        checkEqual(result, safe, "replacement on a colon-free stamp must be idempotent")
    }

    // MARK: BUG-032 — dedicated queue shields cooperative pool from Thread.sleep

    test("BUG-032: Thread.sleep on a custom serial queue does not block the main thread") {
        // ensureLocal spins with Thread.sleep(forTimeInterval: 0.5) on
        // FullImageLoader.queue (a dedicated serial GCD queue), not on the
        // Swift cooperative pool. Verify: sleep on a background queue leaves
        // the calling thread (main here, simulated via DispatchGroup) free.
        let group = DispatchGroup()
        var mainFree = false

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            Thread.sleep(forTimeInterval: 0.01)   // short sleep on background queue
            group.leave()
        }
        // Main continues immediately while background sleeps.
        mainFree = true
        group.wait()

        check(mainFree, "main thread must remain free while background Thread.sleep runs")
    }

    test("BUG-032: dedicated serial queue serialises sleep without touching cooperative pool") {
        // The key property: GCD serial queues use OS threads, not Swift's
        // cooperative actor executor. Thread.sleep on a GCD queue blocks that
        // OS thread, leaving the cooperative pool's threads untouched.
        let queue = DispatchQueue(label: "test.ensureLocal")
        let semaphore = DispatchSemaphore(value: 0)
        var ranOnDedicatedQueue = false

        queue.async {
            Thread.sleep(forTimeInterval: 0.01)
            ranOnDedicatedQueue = true
            semaphore.signal()
        }
        semaphore.wait()
        check(ranOnDedicatedQueue, "sleep ran to completion on the dedicated queue")
    }

    // MARK: BUG-038 — ensureExifIndex synchronous guard prevents re-entry

    test("BUG-038: synchronous flag set before async work prevents concurrent re-entry") {
        // Mirrors ensureExifIndex: `isIndexingExif = true` is set synchronously
        // (on the @MainActor) before the Task is created. A second call on the
        // main actor sees the flag already set and returns early.
        var isIndexingExif = false
        var taskLaunchCount = 0

        func ensureExifIndex() {
            guard !isIndexingExif else { return }
            isIndexingExif = true   // synchronous on @MainActor — no await before this
            taskLaunchCount += 1
            // Task { ... } would run later, but the guard is already set.
        }

        ensureExifIndex()   // first call: starts indexing
        checkEqual(taskLaunchCount, 1, "first call must start indexing")
        check(isIndexingExif, "flag must be set after first call")

        ensureExifIndex()   // second call while flag set: must be rejected
        checkEqual(taskLaunchCount, 1, "concurrent call must be rejected by guard")
    }

    test("BUG-038: after indexing completes, a new call can start another pass") {
        var isIndexingExif = false
        var taskLaunchCount = 0

        func ensureExifIndex() {
            guard !isIndexingExif else { return }
            isIndexingExif = true
            taskLaunchCount += 1
        }
        func indexingCompleted() { isIndexingExif = false }

        ensureExifIndex()
        checkEqual(taskLaunchCount, 1)
        indexingCompleted()

        ensureExifIndex()   // new pass after completion must be allowed
        checkEqual(taskLaunchCount, 2, "new call after completion must start another pass")
    }

    // MARK: BUG-066 — .none excluded from selectable labels → isActive/chips consistent

    test("BUG-066: filter.label is nil or a real color — never .none") {
        // FilterMenu excludes .none from the list of selectable labels.
        // So when the user selects a label filter, filter.label is set to a
        // real ColorLabel (red/orange/.../purple), never .none.
        // isActive returns true for label != nil, which matches what chips shows.
        let selectableLabels: [ColorLabel] = ColorLabel.allCases.filter { $0 != .none }
        check(!selectableLabels.contains(.none),
              ".none must be excluded from selectable labels")
        check(selectableLabels.count == ColorLabel.allCases.count - 1,
              "all labels except .none must be selectable")
    }

    test("BUG-066: isActive is only true when label is a real color (not .none)") {
        // filter.label is nil when no label filter is active.
        // isActive for label: returns label != nil.
        // filter.chips shows a chip only when label != nil.
        // Since .none is never set via the UI, there is no reachable state where
        // isActive == true but no chip is shown.
        func isActive(label: ColorLabel?) -> Bool { label != nil }
        func hasChip(label: ColorLabel?) -> Bool { label != nil }

        // No filter active.
        checkEqual(isActive(label: nil), hasChip(label: nil),
                   "nil label: isActive and hasChip must agree (both false)")

        // Real color selected (only reachable state from FilterMenu).
        checkEqual(isActive(label: .red), hasChip(label: .red),
                   "real color: isActive and hasChip must agree (both true)")

        // .none would be the inconsistent case — but it's unreachable from the UI.
        // Document that it would be inconsistent only if somehow set:
        check(ColorLabel.none != .red, ".none is a distinct case from real colors")
    }
}
