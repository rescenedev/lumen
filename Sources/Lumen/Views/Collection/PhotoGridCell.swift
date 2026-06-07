import AppKit

/// Pre-tinted badge symbols, rendered once and reused (no per-draw tinting).
private enum Badge {
    static let heart = tinted("heart.fill", .white, pointSize: 12)
    static let star = tinted("star.fill", .systemYellow, pointSize: 9)
    static let placeholder = tinted("photo", NSColor(white: 1, alpha: 0.16), pointSize: 44)

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
    var selected = false
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

        // Loading placeholder: a faint card with a small photo glyph — reads as
        // "loading", not an ugly gray slab or an empty ghost.
        if image == nil {
            NSColor.white.withAlphaComponent(0.045).setFill()
            clip.fill()
            let g = Badge.placeholder
            let gs = min(s * 0.30, 56)
            g.draw(in: NSRect(x: thumbRect.midX - gs / 2, y: thumbRect.midY - gs / 2, width: gs, height: gs))
        }

        if let image {
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            let isz = image.size
            if isz.width > 0, isz.height > 0 {
                let scale = max(thumbRect.width / isz.width, thumbRect.height / isz.height)
                let dw = isz.width * scale, dh = isz.height * scale
                let r = NSRect(x: thumbRect.midX - dw / 2, y: thumbRect.midY - dh / 2, width: dw, height: dh)
                image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if selected {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: thumbRect.insetBy(dx: 1.5, dy: 1.5), xRadius: radius, yRadius: radius)
            ring.lineWidth = 3
            ring.stroke()
        } else {
            NSColor.black.withAlphaComponent(0.10).setStroke()
            clip.lineWidth = 1
            clip.stroke()
        }

        // Favorite badge — top-right of the thumbnail.
        if favorite {
            let bs: CGFloat = 24
            let br = NSRect(x: thumbRect.maxX - bs - 5, y: thumbRect.maxY - bs - 5, width: bs, height: bs)
            NSColor.systemPink.setFill()
            NSBezierPath(ovalIn: br).fill()
            let h = Badge.heart
            h.draw(in: NSRect(x: br.midX - h.size.width / 2, y: br.midY - h.size.height / 2,
                              width: h.size.width, height: h.size.height))
        }

        // Color label — small dot in the thumbnail's bottom-left corner.
        if let labelColor {
            let d: CGFloat = 11
            let dr = NSRect(x: thumbRect.minX + 6, y: thumbRect.minY + 6, width: d, height: d)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: dr.insetBy(dx: -1.5, dy: -1.5)).fill()
            labelColor.setFill()
            NSBezierPath(ovalIn: dr).fill()
        }

        // Caption band (below the thumbnail): filename centered, rating beneath.
        let nameY = capH - 16
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]
        (filename as NSString).draw(in: NSRect(x: 3, y: nameY, width: s - 6, height: 15),
                                    withAttributes: attrs)

        if rating > 0 {
            let star = Badge.star
            let sw = star.size.width + 1
            let startX = (s - CGFloat(rating) * sw) / 2
            for i in 0..<rating {
                star.draw(at: NSPoint(x: startX + CGFloat(i) * sw, y: max(0, nameY - 11)), from: .zero,
                          operation: .sourceOver, fraction: 1)
            }
        }
    }
}

/// Collection-view item wrapping the custom cell with async thumbnail loading
/// and reuse-safe cancellation.
final class PhotoCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCollectionItem")

    private let cell = PhotoGridCellView()
    private var loadToken = 0

    override func loadView() { view = cell }

    func configure(photo: Photo, size: CGFloat, selected: Bool,
                   favorite: Bool, rating: Int, label: ColorLabel) {
        cell.filename = photo.filename
        cell.favorite = favorite
        cell.rating = rating
        cell.labelColor = label.nsColor
        cell.selected = selected
        cell.thumbSize = size
        cell.image = nil

        loadToken += 1
        let token = loadToken
        let maxPixel = ThumbnailCache.gridMaxPixel
        if let cached = ThumbnailCache.shared.cached(for: photo.url, maxPixel: maxPixel) {
            cell.image = cached
        } else {
            ThumbnailCache.shared.thumbnail(for: photo.url, maxPixel: maxPixel) { [weak self] img in
                guard let self, self.loadToken == token else { return }
                self.cell.image = img
                self.cell.needsDisplay = true
            }
        }
        cell.needsDisplay = true
    }

    func updateSize(_ size: CGFloat) {
        cell.thumbSize = size
        cell.needsDisplay = true
    }

    /// Update favorite/rating/label/selection badges without reloading the image.
    func updateBadges(favorite: Bool, rating: Int, label: ColorLabel) {
        guard cell.favorite != favorite || cell.rating != rating || cell.labelColor != label.nsColor else { return }
        cell.favorite = favorite
        cell.rating = rating
        cell.labelColor = label.nsColor
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
