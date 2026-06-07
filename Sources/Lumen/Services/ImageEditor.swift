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
}
