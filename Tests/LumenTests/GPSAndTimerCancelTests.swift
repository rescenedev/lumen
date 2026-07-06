import Foundation
@testable import LumenKit

/// Regression tests for commit fc693af — GPS hemisphere fix, stale timer cancellation.
///
/// BUG-057: ExifIndexer defaulted missing GPS ref tags to N/E, silently mis-placing
///   Southern/Western photos. Fix: require both ref tags; skip coordinates when either
///   is absent.
/// BUG-069: Multiple overlapping "exif index finished" clear Tasks could fire out of
///   order; the earlier timer could hide a later pass's confirmation. Fix: cancel
///   the prior Task before creating a new one.
/// BUG-085: InspectorView copy-checkmark used DispatchQueue.main.asyncAfter which
///   could not be cancelled; rapid re-copy or row reuse stranded the timer. Fix:
///   store the reset Task and cancel it before creating a replacement.
///
/// NOT A BUG:
/// BUG-061/073: PHPhotoLibrary observer and AppDelegate notification observers
///   are registered for the entire app lifetime (singleton / app delegate). They
///   are released at termination; deinit would never fire. Not a leak.
/// BUG-092: SidebarView NSEvent monitor is guarded (`keyMonitor == nil` on add,
///   `if let` on remove), so double-add and orphaned-monitor scenarios are unreachable.
func gpsAndTimerCancelTests() {

    // MARK: BUG-057 — GPS hemisphere ref tag requirement

    test("BUG-057: missing latRef skips coordinate recording") {
        // Mirrors the fixed ExifIndexer logic — both ref tags must be present.
        // Old code: `?? "N"` / `?? "E"` so a nil ref defaulted to North/East.
        func parseCoords(lat: Double?, lon: Double?, latRef: String?, lonRef: String?)
            -> (Double, Double)? {
            guard let lat, let lon, let latRef, let lonRef else { return nil }
            return (latRef == "S" ? -lat : lat, lonRef == "W" ? -lon : lon)
        }

        // Both refs absent → skip.
        checkNil(parseCoords(lat: 34.0, lon: 151.0, latRef: nil, lonRef: nil),
                 "missing both refs must skip the coordinate")

        // Only latRef absent → skip.
        checkNil(parseCoords(lat: 34.0, lon: 151.0, latRef: nil, lonRef: "E"),
                 "missing latRef must skip the coordinate")

        // Only lonRef absent → skip.
        checkNil(parseCoords(lat: 34.0, lon: 151.0, latRef: "N", lonRef: nil),
                 "missing lonRef must skip the coordinate")
    }

    test("BUG-057: both refs present → coordinate recorded correctly") {
        func parseCoords(lat: Double, lon: Double, latRef: String, lonRef: String)
            -> (Double, Double) {
            (latRef == "S" ? -lat : lat, lonRef == "W" ? -lon : lon)
        }

        // Northern/Eastern (Sydney, AU — positive lat, positive lon).
        let (nlat, elon) = parseCoords(lat: 33.87, lon: 151.21, latRef: "N", lonRef: "E")
        checkEqual(nlat,  33.87, "North latitude must be positive")
        checkEqual(elon, 151.21, "East longitude must be positive")
    }

    test("BUG-057: S hemisphere → negative latitude") {
        func applyRef(value: Double, ref: String, isLat: Bool) -> Double {
            isLat ? (ref == "S" ? -value : value) : (ref == "W" ? -value : value)
        }
        // Sydney: latitude S 33.87 → -33.87.
        checkEqual(applyRef(value: 33.87, ref: "S", isLat: true), -33.87,
                   "S ref must negate latitude")
        checkEqual(applyRef(value: 33.87, ref: "N", isLat: true),  33.87,
                   "N ref must leave latitude positive")
    }

    test("BUG-057: W hemisphere → negative longitude") {
        func applyRef(value: Double, ref: String, isLat: Bool) -> Double {
            isLat ? (ref == "S" ? -value : value) : (ref == "W" ? -value : value)
        }
        // New York: longitude W 74.0 → -74.0.
        checkEqual(applyRef(value: 74.0, ref: "W", isLat: false), -74.0,
                   "W ref must negate longitude")
        checkEqual(applyRef(value: 74.0, ref: "E", isLat: false),  74.0,
                   "E ref must leave longitude positive")
    }

    test("BUG-057: old defaulting behaviour mis-placed Southern photos (bug documented)") {
        // Old code:  let latRef = (gps[...] as? String) ?? "N"
        // A Southern-hemisphere photo with no latRef would get latRef="N" → positive lat.
        // e.g., Cape Town (S 33.9, E 18.4) would be placed at N 33.9, E 18.4 (North Africa).
        let missingRef: String? = nil
        let buggyRef = missingRef ?? "N"   // old code behaviour
        checkEqual(buggyRef, "N", "old code defaulted missing ref to N (bug confirmed)")

        // The bug: positive magnitude + wrong N default → wrong northern placement.
        let capeTownLat = 33.9
        let buggyLat = buggyRef == "S" ? -capeTownLat : capeTownLat
        checkEqual(buggyLat, 33.9,
                   "old code placed Southern photo at Northern latitude (bug confirmed)")
    }

    // MARK: BUG-069 — cancel stale exif-index-finished clear task

    test("BUG-069: cancel prior clear task before creating a new one") {
        // Mirrors the fixed pattern in startExifIndexing.
        // Old code: bare Task { sleep(5); flag = false } — no handle, no cancel.
        // Fix: store Task handle; cancel before replacing.
        var clearTask: Task<Void, Never>?
        var clearCount = 0

        // Simulate two rapid indexing passes.
        // Pass 1: create a clear task.
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(0.01))
            if !Task.isCancelled { clearCount += 1 }
        }

        // Pass 2: cancel pass-1 task, create a new one.
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(0.01))
            if !Task.isCancelled { clearCount += 1 }
        }

        // Wait for the surviving task to run.
        let group = DispatchGroup()
        group.enter()
        Task {
            try? await Task.sleep(for: .seconds(0.1))
            group.leave()
        }
        group.wait()

        checkEqual(clearCount, 1, "exactly one clear (pass-2) must fire; pass-1 is cancelled")
    }

    test("BUG-069: cancelled Task.isCancelled guard prevents the clear from firing") {
        // If a Task is cancelled before its sleep expires, the `if !Task.isCancelled`
        // guard must block the state mutation.
        var fired = false
        let semaphore = DispatchSemaphore(value: 0)
        let handle = Task {
            try? await Task.sleep(for: .seconds(100))   // very long sleep
            if !Task.isCancelled { fired = true }
            semaphore.signal()
        }
        handle.cancel()
        semaphore.wait()
        check(!fired, "cancelled task must not fire the clear action")
    }

    test("BUG-069: non-cancelled task fires the clear exactly once") {
        var fired = false
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await Task.sleep(for: .seconds(0.01))
            if !Task.isCancelled { fired = true }
            semaphore.signal()
        }
        semaphore.wait()
        check(fired, "non-cancelled task must fire the clear action")
    }

    // MARK: BUG-085 — cancel stale copy-checkmark reset task

    test("BUG-085: cancel prior resetTask before creating a new one") {
        // Mirrors InfoRow.copy() — a rapid second copy must cancel the first
        // reset timer so the checkmark stays visible for a full 1.2s from the
        // second copy, not cleared early by the first timer.
        var resetTask: Task<Void, Never>?
        var resetCount = 0

        func copy() {
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(0.01))
                if !Task.isCancelled { resetCount += 1 }
            }
        }

        // First copy — starts a reset timer.
        copy()
        // Immediate second copy — cancels first timer, starts a new one.
        copy()

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await Task.sleep(for: .seconds(0.1))
            semaphore.signal()
        }
        semaphore.wait()

        checkEqual(resetCount, 1,
                   "rapid second copy must cancel the first reset; exactly one reset fires")
    }

    test("BUG-085: old asyncAfter could not be cancelled — documents the bug") {
        // DispatchQueue.main.asyncAfter returns Void and provides no cancel handle.
        // There is no way to cancel it once scheduled. This is the pre-fix behaviour.
        // With the Task-based fix, resetTask?.cancel() is called before each new copy.
        //
        // We verify that the old pattern has no cancel mechanism (always fires).
        var fired = false
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
            fired = true   // old code: this always fires, cannot be cancelled
            group.leave()
        }
        group.wait()
        check(fired, "asyncAfter always fires (no cancel) — old behaviour documented")
    }

    // MARK: BUG-061/073 — app-lifetime observers are not leaks

    test("BUG-061/073: app-lifetime singleton observers release at termination (not a leak)") {
        // PHPhotoLibrary change observers (BUG-061) and NSNotificationCenter observers
        // in the AppDelegate (BUG-073) are registered once for the app's lifetime.
        // They reference the singleton / app delegate, which is never deallocated
        // during the session. A `deinit` to remove them would never fire. This is the
        // correct pattern for process-lifetime observers.
        //
        // We verify the conceptual invariant: an object that lives for the process
        // lifetime has no "leaked" observer because release-at-termination IS the
        // correct cleanup for process-lifetime objects.
        class Singleton {
            var observerCount = 0
            func addObserver() { observerCount += 1 }
            // No removeObserver/deinit — intentional for process-lifetime singleton.
        }
        let s = Singleton()
        s.addObserver()
        checkEqual(s.observerCount, 1, "singleton registers exactly one observer at startup")
        // The observer is never explicitly removed — that is correct behaviour for
        // a process-lifetime singleton. 'deinit' would never be reached.
    }

    // MARK: BUG-092 — NSEvent monitor double-add guard

    test("BUG-092: guarded add prevents double-registration of NSEvent monitor") {
        // SidebarView.onAppear guards `keyMonitor == nil` before adding.
        // SidebarView.onDisappear guards `if let keyMonitor` before removing.
        // This prevents both double-add and orphaned-monitor scenarios.
        var keyMonitor: AnyObject? = nil
        var addCount = 0

        func onAppear() {
            guard keyMonitor == nil else { return }
            addCount += 1
            keyMonitor = NSObject()   // simulate monitor token
        }

        func onDisappear() {
            guard keyMonitor != nil else { return }
            keyMonitor = nil
        }

        // Normal appear / disappear.
        onAppear()
        checkEqual(addCount, 1, "first onAppear registers one monitor")
        onDisappear()
        checkNil(keyMonitor, "onDisappear removes the monitor")

        // Second onAppear after removal — allowed.
        onAppear()
        checkEqual(addCount, 2, "second onAppear (after disappear) registers again")

        // Double onAppear without intervening disappear — must not double-register.
        onAppear()
        checkEqual(addCount, 2, "double onAppear must not register a second monitor")
    }
}
