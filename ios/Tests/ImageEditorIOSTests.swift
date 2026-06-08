import XCTest
import CoreGraphics
// ImageEditor.swift is compiled into this test bundle directly (see project.yml),
// so it's in-module — no import needed. These run on the iOS simulator, proving
// the shared editing engine behaves the same on iOS as on macOS.
final class ImageEditorIOSTests: XCTestCase {
    let src = CGSize(width: 4000, height: 3000)

    func testNoEditKeepsSize() {
        XCTAssertEqual(ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil)), src)
    }

    func testCropHalvesEachAxis() {
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertEqual(ImageEditor.outputSize(source: src, edit: .init(cropNorm: crop)),
                       CGSize(width: 2000, height: 1500))
    }

    func testResizeByWidthNeverUpscales() {
        XCTAssertEqual(ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, targetWidth: 2000, targetHeight: nil)),
                       CGSize(width: 2000, height: 1500))
        XCTAssertEqual(ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, targetWidth: 8000, targetHeight: nil)),
                       src)
    }

    func testCanvasIsExactSize() {
        XCTAssertEqual(ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, targetWidth: 5000, targetHeight: 5000)),
                       CGSize(width: 5000, height: 5000))
    }

    func testRotate90SwapsDimensions() {
        XCTAssertEqual(ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, rotationQuarters: 1)),
                       CGSize(width: 3000, height: 4000))
    }

    func testStraightenShrinksToInscribed() {
        let s = ImageEditor.straightenCropSize(4000, 3000, degrees: 10)
        XCTAssertLessThan(s.width, 4000)
        XCTAssertLessThan(s.height, 3000)
        XCTAssertGreaterThan(s.width, 3000)
    }

    func testCombineHorizontalNormalizesHeight() {
        let r = ImageEditor.combinedLayout([CGSize(width: 100, height: 50), CGSize(width: 200, height: 100)],
                                           layout: .horizontal, gapFraction: 0)
        XCTAssertEqual(r.canvas, CGSize(width: 400, height: 100))
        XCTAssertEqual(r.rects.count, 2)
    }

    func testCombineGridExplicitRows() {
        let r = ImageEditor.combinedLayout(Array(repeating: CGSize(width: 100, height: 100), count: 6),
                                           layout: .grid, gapFraction: 0, gridRows: 3)
        XCTAssertEqual(r.canvas, CGSize(width: 200, height: 300))
        XCTAssertEqual(r.rects.count, 6)
    }

    func testRawSavesAsJPGAndCannotOverwrite() {
        let raw = URL(fileURLWithPath: "/tmp/lumen-no-such/IMG_1234.ARW")
        XCTAssertEqual(ImageEditor.outputExtension(for: raw), "jpg")
        XCTAssertEqual(ImageEditor.editedCopyURL(for: raw).lastPathComponent, "IMG_1234 (edited).jpg")
        XCTAssertFalse(ImageEditor.canOverwrite(raw))
    }

    func testPngKeepsFormat() {
        let png = URL(fileURLWithPath: "/tmp/lumen-no-such/shot.png")
        XCTAssertEqual(ImageEditor.outputExtension(for: png), "png")
        XCTAssertTrue(ImageEditor.canOverwrite(png))
    }

    /// End-to-end pixel path on iOS: synthesize an image, combine two copies,
    /// confirm a valid CGImage of the expected size comes back.
    func testCompositeProducesImage() {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let img = ctx.makeImage()!
        let out = ImageEditor.composite([img, img], layout: .horizontal, gapFraction: 0,
                                        background: CGColor(gray: 1, alpha: 1))
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.width, 400)
        XCTAssertEqual(out?.height, 100)
    }
}
