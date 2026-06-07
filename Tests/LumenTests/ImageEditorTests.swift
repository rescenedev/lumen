import Foundation
import CoreGraphics
@testable import LumenKit

/// Pure output-size math for the crop/resize editor (drives the UI readout and
/// the actual pixel op). I/O encoding isn't unit-tested (needs real image files).
func imageEditorTests() {
    let src = CGSize(width: 4000, height: 3000)

    test("noEditKeepsSize") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil))
        check(s == src, "got \(s)")
    }

    test("cropOnly") {
        // Center half-size crop → half each dimension.
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: crop))
        check(s == CGSize(width: 2000, height: 1500), "got \(s)")
    }

    test("resizeByWidth") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, targetWidth: 2000, targetHeight: nil))
        check(s == CGSize(width: 2000, height: 1500), "got \(s)")
    }

    test("resizeByHeight") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, targetWidth: nil, targetHeight: 1500))
        check(s == CGSize(width: 2000, height: 1500), "got \(s)")
    }

    test("resizeSingleAxisNeverUpscales") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, targetWidth: 8000, targetHeight: nil))
        check(s == src, "got \(s)")
    }

    test("canvasIsExactSizeWithPadding") {
        // Both dimensions → output is exactly that canvas (image fit + padded).
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, targetWidth: 5000, targetHeight: 5000))
        check(s == CGSize(width: 5000, height: 5000), "got \(s)")
    }

    test("cropThenResizeByWidth") {
        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)   // 2000×1500
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: crop, targetWidth: 1000, targetHeight: nil))
        check(s == CGSize(width: 1000, height: 750), "got \(s)")
    }

    test("rotate90SwapsDimensions") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, rotationQuarters: 1))
        check(s == CGSize(width: 3000, height: 4000), "got \(s)")
    }

    test("rotate180KeepsDimensions") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, rotationQuarters: 2))
        check(s == src, "got \(s)")
    }

    test("rotateThenCropThenResize") {
        // 4000×3000 → rotate 90° → 3000×4000 → crop half → 1500×2000 → width 1000 → 1000×1333.
        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: crop, targetWidth: 1000, targetHeight: nil, rotationQuarters: 3))
        check(s == CGSize(width: 1000, height: 1333), "got \(s)")
    }

    test("straightenZeroIsNoCrop") {
        let s = ImageEditor.straightenCropSize(4000, 3000, degrees: 0)
        check(s == CGSize(width: 4000, height: 3000), "got \(s)")
    }

    test("straightenShrinksToInscribed") {
        // A non-zero tilt must auto-crop to something strictly smaller, but not absurd.
        let s = ImageEditor.straightenCropSize(4000, 3000, degrees: 10)
        check(s.width < 4000 && s.height < 3000, "got \(s)")
        check(s.width > 3000 && s.height > 2200, "too small: \(s)")
    }

    test("straightenAppliesInOutputSize") {
        let plain = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil))
        let tilted = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, straightenDegrees: 8))
        check(tilted.width < plain.width && tilted.height < plain.height, "got \(tilted) vs \(plain)")
    }

    test("flipKeepsDimensions") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, flipH: true))
        check(s == src, "got \(s)")
    }

    test("editedCopyURLAddsSuffix") {
        let u = ImageEditor.editedCopyURL(for: URL(fileURLWithPath: "/tmp/lumen-no-such/photo.jpg"))
        check(u.lastPathComponent == "photo (edited).jpg", "got \(u.lastPathComponent)")
    }

    test("combineHorizontalNormalizesHeight") {
        // Two images normalized to the taller height (100), placed side by side.
        let r = ImageEditor.combinedLayout([CGSize(width: 100, height: 50),
                                            CGSize(width: 200, height: 100)],
                                           layout: .horizontal, gapFraction: 0)
        check(r.canvas == CGSize(width: 400, height: 100), "got \(r.canvas)")
        check(r.rects.count == 2)
    }

    test("combineVerticalNormalizesWidth") {
        let r = ImageEditor.combinedLayout([CGSize(width: 100, height: 50),
                                            CGSize(width: 50, height: 50)],
                                           layout: .vertical, gapFraction: 0)
        // common width 100; heights 50 and 100 → canvas 100×150
        check(r.canvas == CGSize(width: 100, height: 150), "got \(r.canvas)")
    }

    test("combineGridIsSquarish") {
        // 3 square images → 2 columns × 2 rows of 100px cells = 200×200, 3 rects.
        let r = ImageEditor.combinedLayout(Array(repeating: CGSize(width: 100, height: 100), count: 3),
                                           layout: .grid, gapFraction: 0)
        check(r.canvas == CGSize(width: 200, height: 200), "got \(r.canvas)")
        check(r.rects.count == 3)
    }

    test("combineGridExplicitRows") {
        // 6 square images forced to 3 rows → 2 cols, 200×300, evenly [2,2,2].
        let r = ImageEditor.combinedLayout(Array(repeating: CGSize(width: 100, height: 100), count: 6),
                                           layout: .grid, gapFraction: 0, gridRows: 3)
        check(r.canvas == CGSize(width: 200, height: 300), "got \(r.canvas)")
        check(r.rects.count == 6)
        // Last cell sits in the bottom row, second column.
        check(r.rects[5] == CGRect(x: 100, y: 200, width: 100, height: 100), "got \(r.rects[5])")
    }

    test("combineGridPartialRowCentered") {
        // 4 photos in 3 rows → rows [2,1,1]; widest row = 2 cols (200 wide).
        // The lone cells in rows 2 and 3 are centered (x = 50).
        let r = ImageEditor.combinedLayout(Array(repeating: CGSize(width: 100, height: 100), count: 4),
                                           layout: .grid, gapFraction: 0, gridRows: 3)
        check(r.canvas == CGSize(width: 200, height: 300), "got \(r.canvas)")
        check(r.rects.count == 4)
        check(r.rects[2] == CGRect(x: 50, y: 100, width: 100, height: 100), "got \(r.rects[2])")
        check(r.rects[3] == CGRect(x: 50, y: 200, width: 100, height: 100), "got \(r.rects[3])")
    }

    test("combineGridRowsClampedToCount") {
        // Asking for 5 rows with only 3 photos clamps to 3 rows → single column.
        let r = ImageEditor.combinedLayout(Array(repeating: CGSize(width: 100, height: 100), count: 3),
                                           layout: .grid, gapFraction: 0, gridRows: 5)
        check(r.canvas == CGSize(width: 100, height: 300), "got \(r.canvas)")
    }
}
