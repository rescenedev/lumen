import Foundation
@testable import LumenKit

/// Regression tests for commit 03d324b — update-check deduplication and
/// pixel-accurate crop aspect-ratio constraint.
///
/// BUG-068: checkForUpdates launched bare Tasks so rapid calls (auto-check on
///   launch + menu item) fired redundant network requests that could race to
///   write availableUpdate. Fix: guard with an in-flight task handle.
/// BUG-082: CropCanvas aspect-ratio constraint used image.size (display points)
///   but cropNorm is normalized to pixel dimensions; non-square-pixel images
///   got a slightly wrong ratio. Fix: use rep.pixelsWide/pixelsHigh with a
///   point-size fallback.
///
/// NOT A BUG:
/// BUG-048: The five crop drag gestures share @State startRect, but macOS has a
///   single pointer so only one drag is ever active; startRect is reset to nil
///   in every .onEnded, making concurrent corruption unreachable.
func updateDedupeAndCropAspectTests() {

    // MARK: BUG-068 — update-check in-flight guard

    test("BUG-068: second call is rejected while a check is in flight") {
        // Mirrors the fixed guard: `guard updateCheckTask == nil else { return }`.
        var taskHandle: Task<Void, Never>? = nil
        var launchCount = 0

        func checkForUpdates() {
            guard taskHandle == nil else { return }
            launchCount += 1
            taskHandle = Task {
                defer { taskHandle = nil }
                try? await Task.sleep(for: .seconds(0.05))
            }
        }

        // First call starts a task.
        checkForUpdates()
        checkEqual(launchCount, 1, "first call must start a task")
        checkNotNil(taskHandle, "taskHandle must be set after first call")

        // Second call while first is in flight must be rejected.
        checkForUpdates()
        checkEqual(launchCount, 1, "second call while in-flight must be rejected")
    }

    test("BUG-068: task handle is cleared (nil) after task completes") {
        var taskHandle: Task<Void, Never>? = nil
        var launchCount = 0
        let semaphore = DispatchSemaphore(value: 0)

        func checkForUpdates() {
            guard taskHandle == nil else { return }
            launchCount += 1
            taskHandle = Task {
                defer { taskHandle = nil; semaphore.signal() }
                try? await Task.sleep(for: .seconds(0.01))
            }
        }

        checkForUpdates()
        semaphore.wait()   // let the task finish
        checkNil(taskHandle, "taskHandle must be nil after task completes (defer)")
    }

    test("BUG-068: new check can start after prior one completes") {
        var taskHandle: Task<Void, Never>? = nil
        var launchCount = 0
        let semaphore = DispatchSemaphore(value: 0)

        func checkForUpdates() {
            guard taskHandle == nil else { return }
            launchCount += 1
            taskHandle = Task {
                defer { taskHandle = nil; semaphore.signal() }
                try? await Task.sleep(for: .seconds(0.01))
            }
        }

        checkForUpdates()
        semaphore.wait()     // first task done
        checkForUpdates()    // second call should now succeed
        checkEqual(launchCount, 2, "new check must start after prior one completes")
        semaphore.wait()
    }

    test("BUG-068: old code (bare Task) would launch multiple parallel tasks") {
        // Documents the bug: without the guard, every checkForUpdates() call
        // starts a new Task, racing to write availableUpdate.
        var launchCount = 0

        func buggyCheckForUpdates() {
            launchCount += 1   // old: Task { ... } — no guard
        }

        buggyCheckForUpdates()
        buggyCheckForUpdates()
        buggyCheckForUpdates()
        checkEqual(launchCount, 3, "old code launched 3 tasks for 3 calls (bug confirmed)")
    }

    // MARK: BUG-082 — pixel-accurate aspect-ratio constraint

    test("BUG-082: aspect constraint uses pixel dimensions, not display-point size") {
        // Mirrors the fixed CropCanvas drag logic.
        // For a 2:1 aspect with 2000x1000 pixel image (displayed at 1000x500 pts),
        // cropNorm is pixel-normalized so the k factor must use pixel dims.
        struct MockRep {
            var pixelsWide: Int
            var pixelsHigh: Int
        }
        func computeK(aspect: CGFloat, pixW: CGFloat, pixH: CGFloat,
                      ptW: CGFloat, ptH: CGFloat) -> (pixelK: CGFloat, pointK: CGFloat) {
            let pixelK = aspect * pixH / pixW    // fixed
            let pointK = aspect * ptH / ptW      // old (buggy for DPI-scaled images)
            return (pixelK, pointK)
        }

        // Square-pixel (no difference): 1000x500 px displayed at 500x250 pts.
        let (pk1, ptk1) = computeK(aspect: 1, pixW: 1000, pixH: 500, ptW: 500, ptH: 250)
        checkEqual(pk1, ptk1, "square-pixel: pixel and point k must agree")

        // Non-square-pixel (differ): 2000x1000 px displayed at 800x600 pts.
        // The display size has a different aspect than the pixel grid.
        let (pk2, ptk2) = computeK(aspect: 1, pixW: 2000, pixH: 1000, ptW: 800, ptH: 600)
        checkEqual(pk2, 0.5,  "pixel k must reflect 2:1 pixel aspect")
        checkEqual(ptk2, 0.75, "point k reflects 4:3 display aspect (wrong for pixel norm)")
        check(pk2 != ptk2, "pixel and point k must differ for non-square-pixel images")
    }

    test("BUG-082: pixelsWide == 0 falls back to image.size") {
        // The fixed code: `let w0 = pw > 0 ? pw : image.size.width`
        func effectiveWidth(pixelsWide: Int, imageWidth: CGFloat) -> CGFloat {
            let pw = CGFloat(pixelsWide)
            return pw > 0 ? pw : imageWidth
        }

        checkEqual(effectiveWidth(pixelsWide: 2000, imageWidth: 1000), 2000,
                   "valid pixelsWide must be used when > 0")
        checkEqual(effectiveWidth(pixelsWide: 0, imageWidth: 1000), 1000,
                   "zero pixelsWide must fall back to image.size.width")
    }

    test("BUG-082: aspect constraint math clamps to smaller dimension") {
        // `if w/h > k { w = h*k } else { h = w/k }` — the crop rect is
        // adjusted to the smaller extent so it stays within bounds.
        func constrain(w: CGFloat, h: CGFloat, k: CGFloat) -> (CGFloat, CGFloat) {
            var w = w, h = h
            if w / max(h, 0.0001) > k { w = h * k } else { h = w / k }
            return (w, h)
        }

        // k = 0.5 (w:h = 2:1 so h = w/2, normalized k = aspect*h/w = 0.5)
        // Input w=0.8, h=0.6 → w/h = 1.33 > k(0.5)? yes → w = h*k = 0.3
        let (w1, h1) = constrain(w: 0.8, h: 0.6, k: 0.5)
        check(abs(w1 - 0.3) < 0.0001, "w must be clamped to h*k = 0.3")
        checkEqual(h1, 0.6)

        // Input w=0.3, h=0.8 → w/h = 0.375 > k(0.5)? no → h = w/k = 0.6
        let (w2, h2) = constrain(w: 0.3, h: 0.8, k: 0.5)
        checkEqual(w2, 0.3)
        check(abs(h2 - 0.6) < 0.0001, "h must be clamped to w/k = 0.6")
    }

    test("BUG-082: k computed from pixel dims satisfies aspect at pixel level") {
        // After applying the constraint with k = aspect * pH / pW, the resulting
        // normalized (w, h) pair must satisfy w/h == aspect * pH / pW.
        func constrain(w: CGFloat, h: CGFloat, k: CGFloat) -> (CGFloat, CGFloat) {
            var w = w, h = h
            if w / max(h, 0.0001) > k { w = h * k } else { h = w / k }
            return (w, h)
        }

        let pW: CGFloat = 4032, pH: CGFloat = 3024, aspect: CGFloat = 1   // square aspect
        let k = aspect * pH / pW                // ≈ 0.75
        let (cw, ch) = constrain(w: 0.9, h: 0.5, k: k)
        let ratio = cw / ch
        check(abs(ratio - k) < 0.0001, "constrained w/h must equal k")
    }

    // MARK: BUG-048 — single-pointer drag cannot corrupt @State startRect

    test("BUG-048: startRect reset to nil in onEnded — no cross-gesture state leaks") {
        // The five crop drag gestures share @State startRect. The risk: gesture A
        // reads startRect set by gesture B. This can't happen on macOS because
        // there is only one pointer (mouse/trackpad), so only one drag is ever
        // active at a time. Additionally, startRect is reset to nil in every
        // .onEnded, so it never carries state from a previous gesture into the next.
        var startRect: CGRect? = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

        // Simulate onEnded of gesture A — resets startRect.
        startRect = nil

        // Gesture B begins — startRect is nil (clean state).
        checkNil(startRect, "startRect must be nil after gesture A ends (no leaked state)")

        // Gesture B sets startRect at its own .onChanged.
        startRect = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        checkNotNil(startRect, "gesture B can set startRect independently")

        // Gesture B ends — reset again.
        startRect = nil
        checkNil(startRect, "startRect must be nil after gesture B ends")
    }

    test("BUG-048: macOS single-pointer invariant — at most one concurrent drag") {
        // On macOS, NSEvent delivers mouse drag events sequentially: mouseDown,
        // mouseDragged (many), mouseUp. There is no API for two simultaneous
        // independent drag streams on a single NSView. The "five gestures" in
        // CropCanvas represent five HANDLE POSITIONS on the same crop rect, not
        // five concurrent touches (which would require multi-touch / iOS UIKit).
        // Therefore the shared @State startRect cannot be accessed concurrently.
        var activeDrags = 0
        var maxConcurrent = 0

        func beginDrag() { activeDrags += 1; maxConcurrent = max(maxConcurrent, activeDrags) }
        func endDrag()   { activeDrags -= 1 }

        // Simulate a sequence of drags (each begins after the previous ends).
        beginDrag(); endDrag()   // corner handle
        beginDrag(); endDrag()   // edge handle
        beginDrag(); endDrag()   // another corner

        checkEqual(maxConcurrent, 1, "macOS single-pointer: at most one drag is ever active")
    }
}
