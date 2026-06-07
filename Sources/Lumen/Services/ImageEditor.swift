import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Crop + resize, encoded to a destination file. The ONLY pixel-touching code in
/// Lumen — and it never modifies the source in place: callers write to a NEW
/// file (non-destructive). "Overwrite original" is a separate, explicit caller
/// choice (write to temp → replace), gated behind a confirmation in the UI.
enum ImageEditor {
    struct Edit: Equatable {
        /// Crop in normalized, top-left-origin coords (0…1). nil = no crop.
        var cropNorm: CGRect?
        /// Target long-edge in pixels for the (cropped) result. nil = keep size.
        var longEdge: Int?
    }

    /// Final pixel dimensions for an edit applied to a source of `pixelSize`.
    /// Pure (no I/O) so it's unit-testable and drives the UI's size readout.
    static func outputSize(source pixelSize: CGSize, edit: Edit) -> CGSize {
        var w = pixelSize.width, h = pixelSize.height
        if let c = edit.cropNorm {
            w = (pixelSize.width * c.width).rounded()
            h = (pixelSize.height * c.height).rounded()
        }
        if let edge = edit.longEdge, edge > 0, max(w, h) > CGFloat(edge) {
            let scale = CGFloat(edge) / max(w, h)
            w = (w * scale).rounded()
            h = (h * scale).rounded()
        }
        return CGSize(width: max(1, w), height: max(1, h))
    }

    /// Apply `edit` to `source` and write to `dest`. Returns false on any failure
    /// (and leaves `dest` untouched). Never writes to `source`.
    @discardableResult
    static func process(source: URL, edit: Edit, to dest: URL, quality: CGFloat = 0.92) -> Bool {
        guard var cg = orientedCGImage(source) else { return false }

        if let c = edit.cropNorm {
            let px = CGRect(x: (c.minX * CGFloat(cg.width)).rounded(),
                            y: (c.minY * CGFloat(cg.height)).rounded(),
                            width: (c.width * CGFloat(cg.width)).rounded(),
                            height: (c.height * CGFloat(cg.height)).rounded())
                .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard px.width >= 1, px.height >= 1, let cropped = cg.cropping(to: px) else { return false }
            cg = cropped
        }

        if let edge = edit.longEdge, edge > 0, max(cg.width, cg.height) > edge {
            let scale = CGFloat(edge) / CGFloat(max(cg.width, cg.height))
            let target = CGSize(width: (CGFloat(cg.width) * scale).rounded(),
                                height: (CGFloat(cg.height) * scale).rounded())
            if let resized = resize(cg, to: target) { cg = resized }
        }

        return write(cg, to: dest, quality: quality)
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
                               gridRows: Int? = nil) -> CGImage? {
        let imgs = sources.compactMap { loadCGImage($0, maxPixel: sourceMaxPixel) }
        return composite(imgs, layout: layout, gapFraction: gapFraction, background: background,
                         longEdge: longEdge, gridRows: gridRows)
    }

    /// Composite already-decoded images into one. Lets callers reuse cached
    /// thumbnails for an instant preview (no disk decode on open).
    static func composite(_ imgs: [CGImage], layout: CombineLayout, gapFraction: CGFloat,
                          background: CGColor, longEdge: Int? = nil, gridRows: Int? = nil) -> CGImage? {
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
        return ctx.makeImage()
    }

    @discardableResult
    static func combine(sources: [URL], layout: CombineLayout, gapFraction: CGFloat,
                        background: CGColor, sourceMaxPixel: Int?, to dest: URL,
                        gridRows: Int? = nil) -> Bool {
        guard let cg = renderCombined(sources: sources, layout: layout, gapFraction: gapFraction,
                                      background: background, sourceMaxPixel: sourceMaxPixel,
                                      gridRows: gridRows) else { return false }
        return write(cg, to: dest, quality: 0.92)
    }

    /// A non-clobbering "<name> (edited).<ext>" sibling URL.
    static func editedCopyURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
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
