import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import LumenKit

/// Characterization tests for `ImageEditor.orientedCGImage` — the edit/save
/// decode path (crash-audit finding: it full-decoded and then made a SECOND
/// full-resolution copy through CIContext for EXIF-rotated photos, doubling
/// peak memory on the save path). These tests pin the *visual* behavior so
/// the implementation can switch to a single-decode strategy safely:
/// dimensions and pixel placement must match a CoreImage reference transform
/// for every EXIF orientation.
func imageEditorOrientationTests() {

    let fm = FileManager.default

    /// Writes a WxH JPEG whose four quadrants have distinct solid colors, with
    /// the given EXIF orientation tag. Returns the temp URL.
    func makeJPEG(width: Int, height: Int, orientation: Int) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "test", code: 1)
        }
        let w = CGFloat(width), h = CGFloat(height)
        // Quadrant colors (CG bottom-left origin): BL red, BR green, TL blue, TR white.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        guard let img = ctx.makeImage() else { throw NSError(domain: "test", code: 2) }

        let url = fm.temporaryDirectory
            .appendingPathComponent("lumen-orient-\(orientation)-\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                         1, nil) else {
            throw NSError(domain: "test", code: 3)
        }
        let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
                                      kCGImageDestinationLossyCompressionQuality: 1.0]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 4) }
        return url
    }

    /// RGBA8 pixel at (x, y) — row 0 is the TOP row of the rendered image.
    func pixel(_ cg: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int)? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        // CGContext raster rows run bottom-up relative to draw space; flip so
        // callers can reason in top-left-origin display coordinates.
        let row = cg.height - 1 - y
        let p = data.advanced(by: row * bpr + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    /// Reference: decode without transform, then bake orientation via CoreImage
    /// (the historical implementation's math).
    func ciReference(_ url: URL, orientation: Int32) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        guard orientation != 1 else { return cg }
        let ci = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    func closeEnough(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Bool {
        abs(a.r - b.r) <= 24 && abs(a.g - b.g) <= 24 && abs(a.b - b.b) <= 24
    }

    // Orientations that swap displayed width/height: 5–8.
    for orientation in [1, 3, 6, 8] {
        test("orientedCGImage orientation \(orientation): dimensions and quadrant pixels match CI reference") {
            let url = try makeJPEG(width: 96, height: 64, orientation: orientation)
            defer { try? fm.removeItem(at: url) }

            guard let got = ImageEditor.orientedCGImage(url) else {
                check(false, "orientedCGImage returned nil for orientation \(orientation)")
                return
            }
            guard let ref = ciReference(url, orientation: Int32(orientation)) else {
                check(false, "CI reference returned nil for orientation \(orientation)")
                return
            }
            checkEqual(got.width, ref.width, "width (orientation \(orientation))")
            checkEqual(got.height, ref.height, "height (orientation \(orientation))")
            if orientation >= 5 {
                checkEqual(got.width, 64, "5–8 must swap displayed dimensions")
                checkEqual(got.height, 96, "5–8 must swap displayed dimensions")
            }

            // Compare the center of each display quadrant against the reference.
            let qw = got.width / 4, qh = got.height / 4
            for (x, y) in [(qw, qh), (3 * qw, qh), (qw, 3 * qh), (3 * qw, 3 * qh)] {
                guard let g = pixel(got, x, y), let r = pixel(ref, x, y) else {
                    check(false, "pixel sampling failed at (\(x),\(y))")
                    continue
                }
                check(closeEnough(g, r),
                      "orientation \(orientation) pixel (\(x),\(y)) got \(g) expected ~\(r)")
            }
        }
    }

    test("orientedCGImage: upright image decodes at native size") {
        let url = try makeJPEG(width: 96, height: 64, orientation: 1)
        defer { try? fm.removeItem(at: url) }
        let got = ImageEditor.orientedCGImage(url)
        checkEqual(got?.width, 96)
        checkEqual(got?.height, 64)
    }
}
