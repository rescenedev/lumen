import Foundation
import CoreGraphics
@testable import LumenKit

/// Pure output-size math for the crop/resize editor (drives the UI readout and
/// the actual pixel op). I/O encoding isn't unit-tested (needs real image files).
func imageEditorTests() {
    let src = CGSize(width: 4000, height: 3000)

    test("noEditKeepsSize") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, longEdge: nil))
        check(s == src, "got \(s)")
    }

    test("cropOnly") {
        // Center half-size crop → half each dimension.
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: crop, longEdge: nil))
        check(s == CGSize(width: 2000, height: 1500), "got \(s)")
    }

    test("resizeDownByLongEdge") {
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, longEdge: 2000))
        check(s == CGSize(width: 2000, height: 1500), "got \(s)")
    }

    test("resizeNeverUpscales") {
        // longEdge larger than the source's long edge → unchanged.
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: nil, longEdge: 8000))
        check(s == src, "got \(s)")
    }

    test("cropThenResize") {
        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)   // 2000×1500
        let s = ImageEditor.outputSize(source: src, edit: .init(cropNorm: crop, longEdge: 1000))
        check(s == CGSize(width: 1000, height: 750), "got \(s)")
    }

    test("editedCopyURLAddsSuffix") {
        let u = ImageEditor.editedCopyURL(for: URL(fileURLWithPath: "/tmp/lumen-no-such/photo.jpg"))
        check(u.lastPathComponent == "photo (edited).jpg", "got \(u.lastPathComponent)")
    }
}
