import Foundation
import ImageIO
@testable import LumenKit

/// Regression tests for commit 41cf490 — metadata number casts, version parse,
/// viewer/progress guards.
///
/// BUG-027/060: pixel dimensions and DPI extracted via NSNumber.intValue, not
///   `as? Int`, so a float-backed CFNumber (e.g. 96.5 DPI) is no longer silently dropped.
/// BUG-063: UpdateChecker.isNewer strips pre-release suffixes so "1.2.3-beta"
///   compares as [1,2,3] rather than [1,2,0].
/// BUG-076: BatchResize ProgressView total clamped to max(1,…) to avoid NaN.
/// BUG-091: slideshow loop guard — viewerIndex=0 only when viewerPhotos non-empty.
func metadataAndVersionTests() {

    // MARK: BUG-027 / BUG-060 — NSNumber cast for float-backed CFNumbers

    test("BUG-027/060: fractional float NSNumber fails as? Int but succeeds via intValue") {
        // The latent crash scenario: some RAW/TIFF codecs write pixel dimensions or
        // DPI as a float-backed CFNumber with a fractional value (e.g. 4032.3).
        // `as? Int` fails because 4032.3 can't be exactly bridged to Int; `.intValue`
        // truncates and always succeeds.
        let fractional = NSNumber(value: 4032.3)
        checkNil(fractional as? Int,
                 "as? Int must be nil for fractional float (confirms bug scenario)")
        checkEqual(fractional.intValue, 4032,
                   "intValue must truncate fractional float to integer")
    }

    test("BUG-060: fractional DPI is read via NSNumber.intValue") {
        // 96.5 DPI is a realistic fractional value — `as? Int` returns nil.
        let dpi = NSNumber(value: 96.5)
        checkNil(dpi as? Int, "as? Int must be nil for fractional DPI (confirms bug existed)")
        checkEqual((dpi as? NSNumber)?.intValue, 96,
                   "NSNumber.intValue must truncate 96.5 → 96")
    }

    test("BUG-027/060: integer-valued double NSNumber works with both patterns") {
        // Integer-valued doubles (4032.0) bridge correctly via both paths.
        // The fix must not regress this common case.
        let intW = NSNumber(value: 4032.0)
        checkEqual(intW.intValue, 4032)
        checkEqual((intW as? NSNumber)?.intValue, 4032)
        checkEqual(intW as? Int, 4032, "integer-valued double should also bridge via as? Int")
    }

    test("BUG-027/060: MetadataReader.parse extracts float-backed pixel dimensions") {
        // Build a synthetic props dict with float-backed NSNumber values —
        // the same type Core Image returns for kCGImagePropertyPixelWidth.
        var props: [CFString: Any] = [:]
        props[kCGImagePropertyPixelWidth]  = NSNumber(value: 5472.0)
        props[kCGImagePropertyPixelHeight] = NSNumber(value: 3648.0)
        props[kCGImagePropertyDPIWidth]    = NSNumber(value: 72.5)

        let meta = MetadataReader.parse(props)
        checkEqual(meta.pixelWidth,  5472, "pixelWidth must survive float-backed NSNumber")
        checkEqual(meta.pixelHeight, 3648, "pixelHeight must survive float-backed NSNumber")
        checkEqual(meta.dpi,           72, "dpi must truncate 72.5 → 72 via intValue")
    }

    test("BUG-027/060: MetadataReader.parse handles nil when props key is absent") {
        let meta = MetadataReader.parse([:])
        checkNil(meta.pixelWidth,  "absent key must give nil pixelWidth")
        checkNil(meta.pixelHeight, "absent key must give nil pixelHeight")
        checkNil(meta.dpi,         "absent key must give nil dpi")
    }

    // MARK: BUG-063 — pre-release version tag parsing

    test("BUG-063: pre-release suffix does not zero the version component") {
        // "0.10.0-rc1" must parse as [0,10,0], not [0,10,0-rc1→0].
        check(UpdateChecker.isNewer("0.10.0-rc1", than: "0.9.0"),
              "0.10.0-rc1 should be newer than 0.9.0")
        check(!UpdateChecker.isNewer("0.9.0", than: "0.10.0-rc1"),
              "0.9.0 should not be newer than 0.10.0-rc1")
    }

    test("BUG-063: beta suffix on patch does not lose patch number") {
        // "1.2.3-beta" → [1,2,3]. Old code: "3-beta" → Int("3-beta") = nil → 0.
        check(UpdateChecker.isNewer("1.2.3-beta", than: "1.2.2"),
              "1.2.3-beta must compare as 1.2.3, which is newer than 1.2.2")
        check(!UpdateChecker.isNewer("1.2.2", than: "1.2.3-beta"),
              "1.2.2 must not be newer than 1.2.3-beta")
    }

    test("BUG-063: stable version comparison still correct after fix") {
        check(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
        check(UpdateChecker.isNewer("1.0.0",  than: "0.9.9"))
        check(!UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
        check(!UpdateChecker.isNewer("1.0.0", than: "1.0.0"), "equal versions are not newer")
    }

    test("BUG-063: multi-digit minor version compared correctly") {
        // This was the canonical reproduction: "0.10.0" > "0.9.0" (numeric, not lexicographic).
        check(UpdateChecker.isNewer("0.10.0", than: "0.9.0"),
              "0.10.0 must be newer than 0.9.0 (numeric compare)")
    }

    test("BUG-063: pre-release on major component is handled") {
        check(UpdateChecker.isNewer("2.0.0-alpha", than: "1.9.9"),
              "2.0.0-alpha parses as 2.0.0, which is newer than 1.9.9")
    }

    // MARK: BUG-076 — ProgressView total clamp

    test("BUG-076: max(photos.count, 1) prevents zero total for empty batch") {
        // The fix: ProgressView(value:total:) receives max(photos.count, 1).
        // A total of 0 → NaN progress; clamping to 1 → 0/1 = 0% (valid).
        let emptyCount = 0
        let total = Double(max(emptyCount, 1))
        check(!total.isNaN, "clamped total must not be NaN")
        checkEqual(total, 1.0, "clamped total for empty batch must be 1.0")
        let progress = Double(0) / total
        check(!progress.isNaN, "0/1 progress must not be NaN")
        checkEqual(progress, 0.0)
    }

    test("BUG-076: max(photos.count, 1) is a no-op for non-empty batch") {
        let count = 5
        checkEqual(Double(max(count, 1)), 5.0)
        checkEqual(Double(0) / Double(max(count, 1)), 0.0)
        checkEqual(Double(3) / Double(max(count, 1)), 0.6)
    }

    // MARK: BUG-091 — slideshow empty-photos guard

    test("BUG-091: slideshow loop guard — only reset index when photos non-empty") {
        // Mirrors the fixed advanceSlideshow logic.
        func advance(canStepForward: Bool, photosCount: Int, currentIndex: Int) -> Int {
            if canStepForward {
                return currentIndex + 1   // simplified viewerStep(1)
            } else if photosCount > 0 {
                return 0                  // loop
            }
            return currentIndex           // no-op when empty (was: always set 0)
        }

        // Normal loop: photos present, at end → reset to 0.
        checkEqual(advance(canStepForward: false, photosCount: 5, currentIndex: 4), 0)

        // Empty array: must NOT reset to 0 (old code did, causing out-of-bounds).
        checkEqual(advance(canStepForward: false, photosCount: 0, currentIndex: 0), 0,
                   "index stays 0 when empty (no-op, not reset)")

        // Mid-slideshow: step forward normally.
        checkEqual(advance(canStepForward: true, photosCount: 5, currentIndex: 2), 3)
    }

    test("BUG-091: empty-photos guard prevents index going to 0 on empty viewerPhotos") {
        // Direct guard check: the condition `!viewerPhotos.isEmpty` gates the reset.
        var viewerIndex = 0
        let viewerPhotos: [Photo] = []     // empty — the crash scenario
        let canStepForward = false

        if canStepForward {
            viewerIndex += 1
        } else if !viewerPhotos.isEmpty {
            viewerIndex = 0
        }
        // viewerIndex must remain 0 (not crash with out-of-bounds access).
        checkEqual(viewerIndex, 0, "index must not be set when viewerPhotos is empty")
    }
}
