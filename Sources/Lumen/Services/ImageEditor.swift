// Cross-platform (macOS + iOS): only CoreGraphics/CoreImage/ImageIO/CoreText +
// Foundation. No AppKit/UIKit — this is the portable editing/combine/watermark
// engine the iOS app reuses verbatim.
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Crop + resize, encoded to a destination file. The ONLY pixel-touching code in
/// Lumen — and it never modifies the source in place: callers write to a NEW
/// file (non-destructive). "Overwrite original" is a separate, explicit caller
/// choice (write to temp → replace), gated behind a confirmation in the UI.
enum ImageEditor {
    struct Edit: Equatable {
        /// Crop in normalized, top-left-origin coords (0…1) of the *rotated* image.
        /// nil = no crop.
        var cropNorm: CGRect?
        /// Target output width/height in pixels. Both nil → keep the cropped size.
        /// One set → resize to that axis (aspect preserved, never upscaled). Both
        /// set → exact canvas of that size with the image fit inside (no upscale)
        /// and the remainder padded with the background.
        var targetWidth: Int?
        var targetHeight: Int?
        /// 90° clockwise rotations (0…3) applied before crop. Default none.
        var rotationQuarters: Int = 0
        /// Fine straighten angle in degrees (clockwise). Auto-crops to remove the
        /// blank corners the rotation exposes. Default none.
        var straightenDegrees: Double = 0
        /// Mirror horizontally (applied with the rotation). Default off.
        var flipH: Bool = false
        /// Where the image sits inside a padded canvas (0…1, top-left origin).
        /// Only matters when both target dimensions create margins. Default center.
        var contentAlign: CGPoint = CGPoint(x: 0.5, y: 0.5)
    }

    /// Final pixel dimensions for an edit applied to a source of `pixelSize`.
    /// Pure (no I/O) so it's unit-testable and drives the UI's size readout.
    static func outputSize(source pixelSize: CGSize, edit: Edit) -> CGSize {
        var w = pixelSize.width, h = pixelSize.height
        if edit.rotationQuarters % 2 != 0 { swap(&w, &h) }   // 90°/270° swap dimensions
        if edit.straightenDegrees != 0 {                     // auto-crop removes blank corners
            let s = straightenCropSize(w, h, degrees: edit.straightenDegrees)
            w = s.width.rounded(); h = s.height.rounded()
        }
        if let c = edit.cropNorm {
            w = (w * c.width).rounded()
            h = (h * c.height).rounded()
        }
        let cw = max(1, w), ch = max(1, h)
        switch (edit.targetWidth, edit.targetHeight) {
        case (nil, nil):
            return CGSize(width: cw, height: ch)
        case let (tw?, nil) where tw > 0:
            let s = min(CGFloat(tw) / cw, 1)
            return CGSize(width: (cw * s).rounded(), height: (ch * s).rounded())
        case let (nil, th?) where th > 0:
            let s = min(CGFloat(th) / ch, 1)
            return CGSize(width: (cw * s).rounded(), height: (ch * s).rounded())
        case let (tw?, th?) where tw > 0 && th > 0:
            return CGSize(width: tw, height: th)            // exact canvas (padded as needed)
        default:
            return CGSize(width: cw, height: ch)
        }
    }

    /// Apply `edit` to `source` and write to `dest`. Returns false on any failure
    /// (and leaves `dest` untouched). Never writes to `source`.
    @discardableResult
    static func process(source: URL, edit: Edit, to dest: URL, quality: CGFloat = 0.92,
                        background: CGColor = CGColor(gray: 1, alpha: 1),
                        caption: Caption? = nil, logo: Logo? = nil) -> Bool {
        guard var cg = orientedCGImage(source) else { return false }

        if let rotated = transformed(cg, quarters: edit.rotationQuarters, flipH: edit.flipH) { cg = rotated }
        if edit.straightenDegrees != 0, let s = straightened(cg, degrees: edit.straightenDegrees) { cg = s }

        if let c = edit.cropNorm {
            let px = CGRect(x: (c.minX * CGFloat(cg.width)).rounded(),
                            y: (c.minY * CGFloat(cg.height)).rounded(),
                            width: (c.width * CGFloat(cg.width)).rounded(),
                            height: (c.height * CGFloat(cg.height)).rounded())
                .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard px.width >= 1, px.height >= 1, let cropped = cg.cropping(to: px) else { return false }
            cg = cropped
        }

        let cw = CGFloat(cg.width), ch = CGFloat(cg.height)
        switch (edit.targetWidth, edit.targetHeight) {
        case let (tw?, th?) where tw > 0 && th > 0:
            if let canvas = paddedCanvas(cg, width: tw, height: th,
                                         align: edit.contentAlign, background: background) { cg = canvas }
        case let (tw?, nil) where tw > 0:
            let s = min(CGFloat(tw) / cw, 1)
            if s < 1, let r = resize(cg, to: CGSize(width: (cw * s).rounded(), height: (ch * s).rounded())) { cg = r }
        case let (nil, th?) where th > 0:
            let s = min(CGFloat(th) / ch, 1)
            if s < 1, let r = resize(cg, to: CGSize(width: (cw * s).rounded(), height: (ch * s).rounded())) { cg = r }
        default:
            break
        }

        if caption != nil || logo != nil { cg = watermarked(cg, caption: caption, logo: logo) }
        return write(cg, to: dest, quality: quality)
    }

    /// Burn an optional logo and/or caption onto `cg` (used by the single-photo
    /// and batch save paths; the combine path draws into its own canvas).
    static func watermarked(_ cg: CGImage, caption: Caption?, logo: Logo?) -> CGImage {
        guard caption != nil || logo != nil else { return cg }
        let w = cg.width, h = cg.height
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let logo { drawLogo(ctx, logo, w: w, h: h) }
        if let caption { drawCaption(ctx, caption, w: w, h: h) }
        return ctx.makeImage() ?? cg
    }

    /// Fit `cg` (no upscaling) into an exact `width`×`height` canvas, positioned by
    /// `align` (0…1, top-left origin), with the remainder filled by `background`.
    private static func paddedCanvas(_ cg: CGImage, width: Int, height: Int,
                                     align: CGPoint, background: CGColor) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let cw = CGFloat(cg.width), ch = CGFloat(cg.height)
        let scale = min(CGFloat(width) / cw, CGFloat(height) / ch, 1)   // never upscale
        let dw = cw * scale, dh = ch * scale
        let ax = min(max(align.x, 0), 1), ay = min(max(align.y, 0), 1)
        let x = (CGFloat(width) - dw) * ax
        let y = (CGFloat(height) - dh) * (1 - ay)                       // top-origin align → bottom-origin context
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cg, in: CGRect(x: x, y: y, width: dw, height: dh))
        return ctx.makeImage()
    }

    // MARK: - Internals

    /// Oriented CGImage, optionally downsampled to `maxPixel` on the long edge.
    /// Downsampling decodes at the smaller size (fast), so combining many full-res
    /// photos doesn't stall on huge decodes/canvases.
    static func loadCGImage(_ url: URL, maxPixel: Int?) -> CGImage? {
        guard let maxPixel else { return orientedCGImage(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bakes orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// CGImage with EXIF orientation baked in (so it's upright and crop coords map
    /// directly to what the user sees).
    static func orientedCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard orientation != 1 else { return cg }
        let ci = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(orientation))
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    /// Rotate (90° clockwise steps) and/or mirror an upright image. Returns the
    /// same image when there's nothing to do. Used by BOTH the live editor preview
    /// and the saved output, so what the user sees is exactly what's written.
    static func transformed(_ cg: CGImage, quarters: Int, flipH: Bool) -> CGImage? {
        let q = ((quarters % 4) + 4) % 4
        guard q != 0 || flipH else { return cg }
        let w = cg.width, h = cg.height
        let swapDims = (q % 2 != 0)
        let outW = swapDims ? h : w, outH = swapDims ? w : h
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        if flipH { ctx.scaleBy(x: -1, y: 1) }
        ctx.rotate(by: -CGFloat(q) * .pi / 2)            // CG rotates CCW for +; negate for clockwise
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Largest centered, axis-aligned rectangle that still fits inside a w×h
    /// rectangle rotated by `degrees` — i.e. the straighten auto-crop, so there
    /// are no blank corners. (Standard rotate-and-crop geometry.)
    static func straightenCropSize(_ w: CGFloat, _ h: CGFloat, degrees: Double) -> CGSize {
        let a = abs(degrees) * .pi / 180
        guard a > 0.0001, w > 0, h > 0 else { return CGSize(width: w, height: h) }
        let sinA = abs(sin(a)), cosA = abs(cos(a))
        let widthIsLonger = w >= h
        let long = widthIsLonger ? w : h, short = widthIsLonger ? h : w
        var wr: CGFloat, hr: CGFloat
        if short <= 2 * sinA * cosA * long || abs(sinA - cosA) < 1e-10 {
            let x = 0.5 * short
            if widthIsLonger { wr = x / sinA; hr = x / cosA } else { wr = x / cosA; hr = x / sinA }
        } else {
            let cos2a = cosA * cosA - sinA * sinA
            wr = (w * cosA - h * sinA) / cos2a
            hr = (h * cosA - w * sinA) / cos2a
        }
        return CGSize(width: max(1, min(wr, w)), height: max(1, min(hr, h)))
    }

    /// Rotate by a fine `degrees` and crop to the inscribed rectangle (no blank
    /// corners). Used by straightening — preview and save share this.
    static func straightened(_ cg: CGImage, degrees: Double) -> CGImage? {
        guard abs(degrees) > 0.001 else { return cg }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let crop = straightenCropSize(w, h, degrees: degrees)
        let cw = max(1, Int(crop.width.rounded())), ch = max(1, Int(crop.height.rounded()))
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(cw) / 2, y: CGFloat(ch) / 2)
        ctx.rotate(by: CGFloat(degrees) * .pi / 180)         // undo the tilt (clockwise input)
        ctx.translateBy(x: -w / 2, y: -h / 2)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Downscale `cg` so its long edge ≤ `maxPixel` (returns it unchanged if it's
    /// already small). For building a light preview base the editor re-transforms.
    static func downsampled(_ cg: CGImage, maxPixel: Int) -> CGImage {
        let long = max(cg.width, cg.height)
        guard long > maxPixel, maxPixel > 0 else { return cg }
        let scale = CGFloat(maxPixel) / CGFloat(long)
        return resize(cg, to: CGSize(width: (CGFloat(cg.width) * scale).rounded(),
                                     height: (CGFloat(cg.height) * scale).rounded())) ?? cg
    }

    private static func resize(_ cg: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Formats `write` can actually re-encode to. Anything else (RAW, webp, avif,
    /// psd, gif, …) is decoded for editing but saved as JPEG — so the output
    /// extension must be one of these, and overwriting the original isn't allowed
    /// (it would silently change the file's real format).
    static let encodableExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic"]

    /// The extension an edit of `source` should be saved with: keep the source's
    /// when it's re-encodable, else fall back to jpg.
    static func outputExtension(for source: URL) -> String {
        encodableExtensions.contains(source.pathExtension.lowercased()) ? source.pathExtension : "jpg"
    }

    /// Whether the original file can be overwritten in place (same real format).
    static func canOverwrite(_ source: URL) -> Bool {
        encodableExtensions.contains(source.pathExtension.lowercased())
    }

    /// Encode keeping a lossless container for png/tiff/heic, else JPEG.
    private static func write(_ cg: CGImage, to dest: URL, quality: CGFloat) -> Bool {
        let ext = dest.pathExtension.lowercased()
        let utType: UTType
        switch ext {
        case "png": utType = .png
        case "tiff", "tif": utType = .tiff
        case "heic": utType = .heic
        default: utType = .jpeg
        }
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, utType.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(out, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(out)
    }

    // MARK: - Caption / watermark

    /// A text caption burned into the combined image.
    struct Caption {
        var text: String
        var position: Position
        var color: CGColor
        /// Font height as a fraction of the canvas's short edge (so it scales).
        var sizeFraction: CGFloat
        /// Free placement (0…1, top-left origin) — overrides `position` when set,
        /// so the user can drag the caption anywhere on the preview.
        var normPosition: CGPoint? = nil

        enum Position: String, CaseIterable, Identifiable {
            case bottomLeft, bottomCenter, bottomRight, topLeft, topCenter, topRight, center
            var id: String { rawValue }
        }
    }

    /// An image (logo) watermark burned into the combined image.
    struct Logo {
        var image: CGImage
        var position: Caption.Position
        /// Logo height as a fraction of the canvas's short edge.
        var sizeFraction: CGFloat
        var opacity: CGFloat
    }

    /// Draw `logo` into a y-up CGContext sized `w`×`h`, scaled to a fraction of
    /// the short edge and inset from the chosen corner with the given opacity.
    private static func drawLogo(_ ctx: CGContext, _ logo: Logo, w: Int, h: Int) {
        let lw = CGFloat(logo.image.width), lh = CGFloat(logo.image.height)
        guard lw > 0, lh > 0 else { return }
        let canvasShort = CGFloat(min(w, h))
        let dh = max(8, canvasShort * logo.sizeFraction)
        let scale = dh / lh
        let dw = lw * scale
        let pad = canvasShort * 0.035
        let cw = CGFloat(w), ch = CGFloat(h)
        let x: CGFloat
        switch logo.position {
        case .bottomLeft, .topLeft: x = pad
        case .bottomRight, .topRight: x = cw - pad - dw
        case .bottomCenter, .topCenter, .center: x = (cw - dw) / 2
        }
        let y: CGFloat
        switch logo.position {
        case .bottomLeft, .bottomCenter, .bottomRight: y = pad
        case .topLeft, .topCenter, .topRight: y = ch - pad - dh
        case .center: y = (ch - dh) / 2
        }
        ctx.saveGState()
        ctx.setAlpha(min(max(logo.opacity, 0), 1))
        ctx.interpolationQuality = .high
        ctx.draw(logo.image, in: CGRect(x: x, y: y, width: dw, height: dh))
        ctx.restoreGState()
    }

    /// Draw `caption` into a y-up CGContext sized `w`×`h` (CoreText, with a soft
    /// shadow for legibility on any background).
    private static func drawCaption(_ ctx: CGContext, _ caption: Caption, w: Int, h: Int) {
        let text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let canvasShort = CGFloat(min(w, h))
        let fontSize = max(8, canvasShort * caption.sizeFraction)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: caption.color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad = canvasShort * 0.035
        let cw = CGFloat(w), ch = CGFloat(h)

        let textH = ascent + descent
        let x: CGFloat
        let yBaseline: CGFloat
        if let n = caption.normPosition {
            // Free placement: center the text on the point, clamped on-canvas.
            let cx = n.x * cw, cy = (1 - n.y) * ch        // top-left origin → y-up
            x = min(max(cx - lineW / 2, pad), max(pad, cw - pad - lineW))
            let baseFromCenter = cy - textH / 2 + descent
            yBaseline = min(max(baseFromCenter, pad + descent), ch - pad - ascent)
        } else {
            switch caption.position {
            case .bottomLeft, .topLeft: x = pad
            case .bottomRight, .topRight: x = cw - pad - lineW
            case .bottomCenter, .topCenter, .center: x = (cw - lineW) / 2
            }
            switch caption.position {
            case .bottomLeft, .bottomCenter, .bottomRight: yBaseline = pad + descent
            case .topLeft, .topCenter, .topRight: yBaseline = ch - pad - ascent
            case .center: yBaseline = (ch - textH) / 2 + descent
            }
        }

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -canvasShort * 0.004),
                      blur: canvasShort * 0.008, color: CGColor(gray: 0, alpha: 0.6))
        ctx.textPosition = CGPoint(x: x, y: yBaseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Combine (multiple photos → one)

    enum CombineLayout: String, CaseIterable, Identifiable {
        case horizontal, vertical, grid
        var id: String { rawValue }
        var label: String {
            switch self {
            case .horizontal: return "가로 이어붙이기"
            case .vertical: return "세로 이어붙이기"
            case .grid: return "그리드 콜라주"
            }
        }
        var shortLabel: String {
            switch self {
            case .horizontal: return "가로"
            case .vertical: return "세로"
            case .grid: return "그리드"
            }
        }
    }

    /// Pure geometry: where each image goes (top-left origin) and the canvas size.
    /// `gapFraction` is relative to the strip/cell size so spacing scales sensibly.
    /// `gridRows` forces the grid's row count (columns follow from the photo
    /// count); nil keeps the auto square-ish layout.
    static func combinedLayout(_ sizes: [CGSize], layout: CombineLayout,
                               gapFraction: CGFloat, gridRows: Int? = nil) -> (canvas: CGSize, rects: [CGRect]) {
        let safe = sizes.map { CGSize(width: max(1, $0.width), height: max(1, $0.height)) }
        guard !safe.isEmpty else { return (.zero, []) }
        switch layout {
        case .horizontal:
            let h = safe.map(\.height).max() ?? 1
            let gap = h * gapFraction
            var x: CGFloat = 0, rects: [CGRect] = []
            for s in safe { let w = s.width * h / s.height; rects.append(CGRect(x: x, y: 0, width: w, height: h)); x += w + gap }
            return (CGSize(width: max(1, x - gap), height: h), rects)
        case .vertical:
            let w = safe.map(\.width).max() ?? 1
            let gap = w * gapFraction
            var y: CGFloat = 0, rects: [CGRect] = []
            for s in safe { let h = s.height * w / s.width; rects.append(CGRect(x: 0, y: y, width: w, height: h)); y += h + gap }
            return (CGSize(width: w, height: max(1, y - gap)), rects)
        case .grid:
            let n = safe.count
            // Row count: user-chosen, else square-ish. Columns follow.
            let rows = max(1, min(gridRows ?? Int(Double(n).squareRoot().rounded()), n))
            let cols = Int(ceil(Double(n) / Double(rows)))          // widest row
            let cell = safe.map { min($0.width, $0.height) }.sorted()[n / 2]   // median short edge
            let gap = cell * gapFraction
            // Spread n photos over exactly `rows` rows as evenly as possible; the
            // first `rem` rows get one extra so partial rows sit at the bottom.
            let base = n / rows, rem = n % rows
            let canvasW = CGFloat(cols) * cell + CGFloat(cols - 1) * gap
            var rects: [CGRect] = []
            for r in 0..<rows {
                let count = base + (r < rem ? 1 : 0)
                guard count > 0 else { continue }
                let rowW = CGFloat(count) * cell + CGFloat(count - 1) * gap
                let xStart = (canvasW - rowW) / 2                   // center shorter rows
                for c in 0..<count {
                    rects.append(CGRect(x: xStart + CGFloat(c) * (cell + gap),
                                        y: CGFloat(r) * (cell + gap), width: cell, height: cell))
                }
            }
            let canvasH = CGFloat(rows) * cell + CGFloat(rows - 1) * gap
            return (CGSize(width: canvasW, height: canvasH), rects)
        }
    }

    /// Render N sources into one image. Strips keep each photo's aspect; grid cells
    /// are square and aspect-fill (cropped) for a clean collage.
    static func renderCombined(sources: [URL], layout: CombineLayout, gapFraction: CGFloat,
                               background: CGColor, sourceMaxPixel: Int?, longEdge: Int? = nil,
                               gridRows: Int? = nil, caption: Caption? = nil, logo: Logo? = nil) -> CGImage? {
        let imgs = sources.compactMap { loadCGImage($0, maxPixel: sourceMaxPixel) }
        return composite(imgs, layout: layout, gapFraction: gapFraction, background: background,
                         longEdge: longEdge, gridRows: gridRows, caption: caption, logo: logo)
    }

    /// Composite already-decoded images into one. Lets callers reuse cached
    /// thumbnails for an instant preview (no disk decode on open).
    static func composite(_ imgs: [CGImage], layout: CombineLayout, gapFraction: CGFloat,
                          background: CGColor, longEdge: Int? = nil, gridRows: Int? = nil,
                          caption: Caption? = nil, logo: Logo? = nil) -> CGImage? {
        guard imgs.count >= 2 else { return nil }
        let sizes = imgs.map { CGSize(width: $0.width, height: $0.height) }
        let (canvas, rects) = combinedLayout(sizes, layout: layout, gapFraction: gapFraction, gridRows: gridRows)
        var scale: CGFloat = 1
        if let edge = longEdge, edge > 0, max(canvas.width, canvas.height) > CGFloat(edge) {
            scale = CGFloat(edge) / max(canvas.width, canvas.height)
        }
        let cw = max(1, Int((canvas.width * scale).rounded())), ch = max(1, Int((canvas.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        for (i, img) in imgs.enumerated() {
            let r = rects[i]
            // scale + flip Y (CGContext is bottom-left origin)
            let dest = CGRect(x: r.minX * scale, y: CGFloat(ch) - (r.maxY * scale),
                              width: r.width * scale, height: r.height * scale)
            ctx.saveGState()
            ctx.clip(to: dest)
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let sc = max(dest.width / iw, dest.height / ih)   // aspect-fill
            let dw = iw * sc, dh = ih * sc
            ctx.draw(img, in: CGRect(x: dest.midX - dw / 2, y: dest.midY - dh / 2, width: dw, height: dh))
            ctx.restoreGState()
        }
        if let logo { drawLogo(ctx, logo, w: cw, h: ch) }
        if let caption { drawCaption(ctx, caption, w: cw, h: ch) }
        return ctx.makeImage()
    }

    @discardableResult
    static func combine(sources: [URL], layout: CombineLayout, gapFraction: CGFloat,
                        background: CGColor, sourceMaxPixel: Int?, to dest: URL,
                        gridRows: Int? = nil, caption: Caption? = nil, logo: Logo? = nil) -> Bool {
        guard let cg = renderCombined(sources: sources, layout: layout, gapFraction: gapFraction,
                                      background: background, sourceMaxPixel: sourceMaxPixel,
                                      gridRows: gridRows, caption: caption, logo: logo) else { return false }
        return write(cg, to: dest, quality: 0.92)
    }

    /// A non-clobbering "<name> (edited).<ext>" sibling URL. The extension is the
    /// re-encodable one (jpg for RAW/webp/etc.) so the bytes match the name.
    static func editedCopyURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = outputExtension(for: source)
        var candidate = dir.appendingPathComponent("\(base) (edited).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (edited \(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// A non-clobbering "<base>.<ext>" / "<base> N.<ext>" URL in `dir`.
    static func uniqueFileURL(in dir: URL, base: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
