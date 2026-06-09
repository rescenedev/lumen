import AppKit

/// Pre-tinted badge symbols, rendered once and reused (no per-draw tinting).
private enum Badge {
    static let heart = tinted("heart.fill", .white, pointSize: 12)
    static let star = tinted("star.fill", .systemYellow, pointSize: 9)
    static let check = tinted("checkmark", .white, pointSize: 12)
    static let reject = tinted("xmark", .white, pointSize: 11)
    static let placeholder = tinted("photo", NSColor(white: 1, alpha: 0.16), pointSize: 44)
    static let broken = tinted("exclamationmark.triangle.fill",
                               NSColor.systemYellow.withAlphaComponent(0.85), pointSize: 26)

    static func tinted(_ name: String, _ color: NSColor, pointSize: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let out = NSImage(size: base.size)
        out.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: base.size)
        base.draw(in: rect)
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}

/// Custom-drawn cell content: square thumbnail (aspect-fill, rounded) with a
/// selection ring, favorite badge, color-label dot, filename, and rating stars.
final class PhotoGridCellView: NSView {
    var image: NSImage?
    var filename = ""
    var favorite = false
    var rating = 0
    var labelColor: NSColor?
    var rejected = false
    var selected = false
    var selectionActive = false   // any photo selected → dim the non-selected ones
    var failed = false            // file couldn't be decoded (corrupt/unreadable)
    var thumbSize: CGFloat = 170

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Bottom-left origin (default, non-flipped) so NSImage draws right-side up.
        // Drive sizing off the actual cell width so thumbnails fill the cell.
        let s = bounds.width
        let capH = bounds.height - s          // caption band height
        let radius: CGFloat = 8
        // Thumbnail occupies the top square; caption band is below it.
        let thumbRect = NSRect(x: 1, y: capH + 1, width: s - 2, height: s - 2)
        let clip = NSBezierPath(roundedRect: thumbRect, xRadius: radius, yRadius: radius)

        // When selected, the photo shrinks a little to reveal an accent frame
        // (Apple Photos style); a checkmark makes it unmistakable.
        let inset: CGFloat = selected ? 6 : 0
        let photoRect = thumbRect.insetBy(dx: inset, dy: inset)
        let photoRadius: CGFloat = max(3, radius - inset * 0.5)
        let photoClip = NSBezierPath(roundedRect: photoRect, xRadius: photoRadius, yRadius: photoRadius)

        if selected {
            NSColor.controlAccentColor.setFill()
            clip.fill()                       // accent frame behind the inset photo
        }

        // Loading placeholder — or a broken-file mark when decode failed
        // (corrupt/zero-filled files), so they don't masquerade as loading.
        if image == nil {
            NSColor.white.withAlphaComponent(0.045).setFill()
            photoClip.fill()
            let g = failed ? Badge.broken : Badge.placeholder
            let gs = min(s * 0.30, 56)
            g.draw(in: NSRect(x: photoRect.midX - gs / 2, y: photoRect.midY - gs / 2, width: gs, height: gs))
        }

        if let image {
            NSGraphicsContext.saveGraphicsState()
            photoClip.addClip()
            let isz = image.size
            if isz.width > 0, isz.height > 0 {
                let scale = max(photoRect.width / isz.width, photoRect.height / isz.height)
                let dw = isz.width * scale, dh = isz.height * scale
                let r = NSRect(x: photoRect.midX - dw / 2, y: photoRect.midY - dh / 2, width: dw, height: dh)
                image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Dim the non-selected photos while a selection is active.
        if selectionActive && !selected {
            NSColor.black.withAlphaComponent(0.5).setFill()
            photoClip.fill()
        }

        if selected {
            // Checkmark badge (top-left) — only while multi-selecting, so a single
            // "view this one" selection stays clean (just the accent frame).
            if selectionActive {
                let bs: CGFloat = 22
                let br = NSRect(x: photoRect.minX + 6, y: photoRect.maxY - bs - 6, width: bs, height: bs)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: br.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: br).fill()
                let c = Badge.check
                c.draw(in: NSRect(x: br.midX - c.size.width / 2, y: br.midY - c.size.height / 2,
                                  width: c.size.width, height: c.size.height))
            }
        } else {
            NSColor.black.withAlphaComponent(0.10).setStroke()
            photoClip.lineWidth = 1
            photoClip.stroke()
        }

        // Favorite badge — top-right of the photo.
        if favorite {
            let bs: CGFloat = 24
            let br = NSRect(x: photoRect.maxX - bs - 5, y: photoRect.maxY - bs - 5, width: bs, height: bs)
            NSColor.systemPink.setFill()
            NSBezierPath(ovalIn: br).fill()
            let h = Badge.heart
            h.draw(in: NSRect(x: br.midX - h.size.width / 2, y: br.midY - h.size.height / 2,
                              width: h.size.width, height: h.size.height))
        }

        // Rejected — dim the photo and mark it with a red ✕ (bottom-right).
        if rejected {
            NSColor.black.withAlphaComponent(0.45).setFill()
            photoClip.fill()
            let bs: CGFloat = 22
            let br = NSRect(x: photoRect.maxX - bs - 5, y: photoRect.minY + 5, width: bs, height: bs)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: br.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: br).fill()
            let x = Badge.reject
            x.draw(in: NSRect(x: br.midX - x.size.width / 2, y: br.midY - x.size.height / 2,
                              width: x.size.width, height: x.size.height))
        }

        // Color label — dot in the photo's bottom-left corner.
        if let labelColor {
            let d: CGFloat = 11
            let dr = NSRect(x: photoRect.minX + 6, y: photoRect.minY + 6, width: d, height: d)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: dr.insetBy(dx: -1.5, dy: -1.5)).fill()
            labelColor.setFill()
            NSBezierPath(ovalIn: dr).fill()
        }

        // Rating — overlay at the photo's bottom-center.
        if rating > 0 {
            let star = Badge.star
            let sw = star.size.width + 1
            let totalW = CGFloat(rating) * sw
            let startX = photoRect.midX - totalW / 2
            let y = photoRect.minY + 7
            let pill = NSRect(x: startX - 5, y: y - 3, width: totalW + 9, height: star.size.height + 6)
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            for i in 0..<rating {
                star.draw(at: NSPoint(x: startX + CGFloat(i) * sw, y: y), from: .zero,
                          operation: .sourceOver, fraction: 1)
            }
        }

        // Caption band (below the thumbnail): just the filename, centered.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]
        (filename as NSString).draw(in: NSRect(x: 3, y: capH - 16, width: s - 6, height: 15),
                                    withAttributes: attrs)
    }
}

/// Collection-view item wrapping the custom cell with async thumbnail loading
/// and reuse-safe cancellation.
final class PhotoCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCollectionItem")

    private let cell = PhotoGridCellView()
    private var loadToken = 0

    override func loadView() { view = cell }

    func configure(photo: Photo, size: CGFloat, selected: Bool, selectionActive: Bool,
                   favorite: Bool, rating: Int, label: ColorLabel, rejected: Bool) {
        cell.filename = photo.filename
        cell.favorite = favorite
        cell.rating = rating
        cell.labelColor = label.nsColor
        cell.rejected = rejected
        cell.selected = selected
        cell.selectionActive = selectionActive
        cell.thumbSize = size
        cell.image = nil
        cell.failed = false

        loadToken += 1
        let token = loadToken
        let maxPixel = ThumbnailCache.tier(forPointSize: size)
        if let cached = ThumbnailCache.shared.cached(for: photo.url, maxPixel: maxPixel) {
            cell.image = cached
        } else {
            // A different tier already in memory beats a placeholder — show it
            // now (drawing rescales) and swap in the exact tier when it lands.
            let other = maxPixel == ThumbnailCache.gridMaxPixel ? 256 : ThumbnailCache.gridMaxPixel
            if let nearby = ThumbnailCache.shared.cached(for: photo.url, maxPixel: other) {
                cell.image = nearby
            }
            ThumbnailCache.shared.thumbnail(for: photo.url, maxPixel: maxPixel,
                                            mtime: photo.cacheMtime) { [weak self] img in
                guard let self, self.loadToken == token else { return }
                if let img {
                    self.cell.image = img
                } else if self.cell.image == nil {
                    self.cell.failed = true   // decode failed — mark as broken
                }
                self.cell.needsDisplay = true
            }
        }
        cell.needsDisplay = true
    }

    func updateSize(_ size: CGFloat) {
        cell.thumbSize = size
        cell.needsDisplay = true
    }

    /// Update the "a selection exists" dim state without reloading the image.
    func setSelectionActive(_ active: Bool) {
        guard cell.selectionActive != active else { return }
        cell.selectionActive = active
        cell.needsDisplay = true
    }

    /// Update favorite/rating/label/reject badges without reloading the image.
    func updateBadges(favorite: Bool, rating: Int, label: ColorLabel, rejected: Bool) {
        guard cell.favorite != favorite || cell.rating != rating
                || cell.labelColor != label.nsColor || cell.rejected != rejected else { return }
        cell.favorite = favorite
        cell.rating = rating
        cell.labelColor = label.nsColor
        cell.rejected = rejected
        cell.needsDisplay = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken += 1
        cell.image = nil
    }

    override var isSelected: Bool {
        didSet { cell.selected = isSelected; cell.needsDisplay = true }
    }
}
