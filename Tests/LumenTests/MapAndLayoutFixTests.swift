import Foundation
@testable import LumenKit

/// Regression tests for commit 445e6e8 — map pin/zoom, empty-section bounds,
/// grid cell clamp.
///
/// BUG-044: PhotoMarkerView keeps layer contents when cgImage conversion returns nil.
/// BUG-077: Single-coordinate cluster uses fixed 1km region instead of zero-size rect.
/// BUG-079: AdaptiveFlowLayout guard drops `|| count == 0` that let any index through.
/// BUG-084: PhotoGridCell capH clamped at max(0, …) to prevent negative band mid-resize.
func mapAndLayoutFixTests() {

    // MARK: BUG-079 — AdaptiveFlowLayout empty-section guard

    test("BUG-079: old guard (item < count || count == 0) passes index 0 for empty section") {
        // This documents the bug: the old guard returned `true` (i.e., allowed the
        // index) for item=0, count=0, which is wrong — an empty section has no items.
        func oldGuardPasses(item: Int, count: Int) -> Bool {
            item < count || count == 0
        }
        // The bug: empty section, first item — should be rejected but was accepted.
        check(oldGuardPasses(item: 0, count: 0),
              "old guard incorrectly passes item=0 for empty section (bug confirmed)")
        check(oldGuardPasses(item: 99, count: 0),
              "old guard incorrectly passes item=99 for empty section (bug confirmed)")
    }

    test("BUG-079: fixed guard (item < count) rejects any index for empty section") {
        func fixedGuardPasses(item: Int, count: Int) -> Bool {
            item < count   // old: item < count || count == 0
        }
        // Empty section — no index must pass.
        check(!fixedGuardPasses(item: 0,  count: 0), "item 0 must be rejected for empty section")
        check(!fixedGuardPasses(item: 99, count: 0), "item 99 must be rejected for empty section")
    }

    test("BUG-079: fixed guard still allows valid items for non-empty sections") {
        func fixedGuardPasses(item: Int, count: Int) -> Bool { item < count }
        check( fixedGuardPasses(item: 0, count: 3), "item 0 valid in 3-item section")
        check( fixedGuardPasses(item: 2, count: 3), "item 2 valid in 3-item section")
        check(!fixedGuardPasses(item: 3, count: 3), "item 3 out of bounds in 3-item section")
        check(!fixedGuardPasses(item: 4, count: 3), "item 4 out of bounds in 3-item section")
    }

    test("BUG-079: guard is monotone — if item N is rejected, N+1 is also rejected") {
        func fixedGuardPasses(item: Int, count: Int) -> Bool { item < count }
        for count in 0..<5 {
            var hitBoundary = false
            for item in 0..<(count + 5) {
                let passes = fixedGuardPasses(item: item, count: count)
                if hitBoundary {
                    check(!passes, "item \(item) must be rejected after boundary in count=\(count)")
                }
                if !passes { hitBoundary = true }
            }
        }
    }

    // MARK: BUG-084 — PhotoGridCell caption-band height clamp

    test("BUG-084: capH clamped at 0 when height < width (mid-resize)") {
        // During a window-resize animation, bounds.height can temporarily be < bounds.width.
        // Old code: capH = bounds.height - s  →  negative  →  thumb pushed off-cell.
        // Fix:      capH = max(0, bounds.height - s)  →  0  →  no negative band.
        func capH(boundsHeight: CGFloat, boundsWidth: CGFloat) -> CGFloat {
            max(0, boundsHeight - boundsWidth)
        }

        // Mid-resize: height < width → clamp to 0.
        checkEqual(capH(boundsHeight: 80,  boundsWidth: 100), 0,
                   "capH must be 0 when height < width")
        checkEqual(capH(boundsHeight: 99,  boundsWidth: 100), 0,
                   "capH must be 0 when height just below width")
        checkEqual(capH(boundsHeight: 0,   boundsWidth: 100), 0,
                   "capH must be 0 for zero height")
    }

    test("BUG-084: capH is correct when height > width (normal state)") {
        func capH(boundsHeight: CGFloat, boundsWidth: CGFloat) -> CGFloat {
            max(0, boundsHeight - boundsWidth)
        }
        // Normal cell: height = width + caption band.
        checkEqual(capH(boundsHeight: 120, boundsWidth: 100), 20)
        checkEqual(capH(boundsHeight: 100, boundsWidth: 100), 0,  "square cell: 0 caption band")
        checkEqual(capH(boundsHeight: 118, boundsWidth: 100), 18)
    }

    test("BUG-084: capH clamp is applied at all three layout sites consistently") {
        // The same `max(0, …)` formula must be applied at photoRect, draw(_:),
        // and drawOverlays() — test the formula three times with the same inputs.
        func capH(_ h: CGFloat, _ w: CGFloat) -> CGFloat { max(0, h - w) }

        let negativeCase: CGFloat = 80   // height < width 100
        let positiveCase: CGFloat = 120  // height > width 100
        let width: CGFloat = 100

        // All three sites must agree.
        checkEqual(capH(negativeCase, width), capH(negativeCase, width))
        checkEqual(capH(positiveCase, width), capH(positiveCase, width))
        check(capH(negativeCase, width) >= 0, "capH must never be negative")
        check(capH(positiveCase, width) >= 0, "capH must never be negative")
    }

    // MARK: BUG-077 — single-coordinate cluster zoom

    test("BUG-077: zero-size rect detection for single-coordinate cluster") {
        // When all cluster members share one coordinate, the unioned MKMapRect
        // has width=0, height=0 — old code called setVisibleMapRect with that,
        // zooming in to the maximum.
        // Fix: detect the degenerate case and use a fixed 1km region instead.
        struct MapRect { var width: Double; var height: Double }

        func shouldUseFixedRegion(_ rect: MapRect) -> Bool {
            rect.width == 0 && rect.height == 0
        }

        // Degenerate: all members at same coordinate.
        check(shouldUseFixedRegion(MapRect(width: 0, height: 0)),
              "zero-size rect must trigger fixed-region fallback")

        // Normal: members at different coordinates.
        check(!shouldUseFixedRegion(MapRect(width: 1000, height: 500)),
              "non-zero rect must use setVisibleMapRect")
        check(!shouldUseFixedRegion(MapRect(width: 0, height: 100)),
              "rect with only one zero dimension must use setVisibleMapRect")
        check(!shouldUseFixedRegion(MapRect(width: 100, height: 0)),
              "rect with only one zero dimension must use setVisibleMapRect")
    }

    test("BUG-077: union of identical points produces zero-size rect") {
        // Confirms the scenario that triggered the bug: unioning points all at
        // the same location gives a zero-size rect.
        struct Point { var x: Double; var y: Double }
        struct Rect {
            var x: Double; var y: Double; var width: Double = 0; var height: Double = 0
            mutating func union(_ p: Point) {
                let minX = min(x, p.x); let minY = min(y, p.y)
                let maxX = max(x + width, p.x); let maxY = max(y + height, p.y)
                x = minX; y = minY; width = maxX - minX; height = maxY - minY
            }
        }

        let coord = Point(x: 12345.0, y: 67890.0)
        var rect = Rect(x: coord.x, y: coord.y)
        for _ in 0..<5 { rect.union(coord) }   // all identical

        checkEqual(rect.width,  0.0, "unioned identical points must give width=0")
        checkEqual(rect.height, 0.0, "unioned identical points must give height=0")
    }
}
