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

/// Cell content: square thumbnail (aspect-fill, rounded) with a selection
/// ring, favorite badge, color-label dot, filename, and rating stars.
///
/// The thumbnail lives in a CALayer (`imageLayer.contents`) so resizing is a
/// GPU rescale: drawing the bitmap in draw(_:) meant a CPU re-interpolation of
/// every visible cell on each size change — a measured ~350ms main-thread
/// stall per thumbnail-slider tick / window resize at 67k photos. The view's
/// own draw(_:) now only paints cheap vectors and text (accent frame,
/// placeholder, badges, caption) — image pixels never pass through it.
final class PhotoGridCellView: NSView {
    var image: NSImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = image
            CATransaction.commit()
        }
    }
    var filename = ""
    var favorite = false
    var rating = 0
    var labelColor: NSColor?
    var rejected = false
    var selected = false
    var selectionActive = false   // any photo selected → dim the non-selected ones
    var failed = false            // file couldn't be decoded (corrupt/unreadable)
    var thumbSize: CGFloat = 170

    private let imageLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.borderWidth = 1
        imageLayer.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        // Without this, a resize stretches the overlay's OLD contents (giant
        // ghost badges/captions) instead of redrawing them at the new size.
        overlayLayer.needsDisplayOnBoundsChange = true
    }
    required init?(coder: NSCoder) { fatalError() }

    convenience init() { self.init(frame: .zero) }

    override var wantsUpdateLayer: Bool { false }   // keep draw(_:) for the overlays

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving the window to a display with a different scale must re-render
        // the layers at the new density or thumbnails/badges turn blurry.
        let scale = window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = scale
        overlayLayer.contentsScale = scale
        overlayLayer.setNeedsDisplay()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Subview layers would sit below the view's drawn content — adding the
        // image layer as a sublayer keeps it above the accent frame (drawn) and
        // below the badges (also drawn, in a higher overlay pass? no — see
        // draw(_:): badges paint into the view's layer, which renders BELOW
        // sublayers, so badges get their own layer on top).
        if imageLayer.superlayer == nil {
            layer?.addSublayer(imageLayer)
            layer?.addSublayer(overlayLayer)
            overlayLayer.delegate = overlayPainter
            overlayPainter.cell = self
        }
        let scale = window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = scale
        overlayLayer.contentsScale = scale
    }

    /// Badges/dim/caption render above the image in their own layer; its draw
    /// is cheap vectors + one line of text (no image interpolation).
    private let overlayLayer = CALayer()
    private let overlayPainter = OverlayPainter()

    private final class OverlayPainter: NSObject, CALayerDelegate {
        weak var cell: PhotoGridCellView?
        func draw(_ layer: CALayer, in ctx: CGContext) {
            guard let cell else { return }
            let g = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            cell.drawOverlays()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The photo square (origin bottom-left, caption band below).
    private var photoRect: NSRect {
        let s = bounds.width
        let capH = max(0, bounds.height - s)   // clamp: height can be < width mid-resize
        let thumbRect = NSRect(x: 1, y: capH + 1, width: s - 2, height: s - 2)
        let inset: CGFloat = selected ? 6 : 0
        return thumbRect.insetBy(dx: inset, dy: inset)
    }
    private var photoRadius: CGFloat { selected ? 5 : 8 }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCellLayers()
        needsDisplay = true
        overlayLayer.setNeedsDisplay()
    }

    func refresh() {
        layoutCellLayers()
        needsDisplay = true
        overlayLayer.setNeedsDisplay()
    }

    private func layoutCellLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = photoRect
        imageLayer.cornerRadius = photoRadius
        imageLayer.borderWidth = selected ? 0 : 1
        overlayLayer.frame = bounds
        CATransaction.commit()
    }

    /// Base content (renders BELOW the image layer): accent frame + placeholder.
    override func draw(_ dirtyRect: NSRect) {
        let s = bounds.width
        let capH = max(0, bounds.height - s)   // clamp: height can be < width mid-resize
        let thumbRect = NSRect(x: 1, y: capH + 1, width: s - 2, height: s - 2)

        if selected {
            // Accent frame revealed around the inset photo (Apple Photos style).
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: thumbRect, xRadius: 8, yRadius: 8).fill()
        }

        // Loading placeholder — or a broken-file mark when decode failed
        // (corrupt/zero-filled files), so they don't masquerade as loading.
        if image == nil {
            let rect = photoRect
            NSColor.white.withAlphaComponent(0.045).setFill()
            NSBezierPath(roundedRect: rect, xRadius: photoRadius, yRadius: photoRadius).fill()
            let glyph = failed ? Badge.broken : Badge.placeholder
            let gs = min(s * 0.30, 56)
            glyph.draw(in: NSRect(x: rect.midX - gs / 2, y: rect.midY - gs / 2, width: gs, height: gs))
        }
    }

    /// Overlay content (renders ABOVE the image layer): dim, badges, caption.
    fileprivate func drawOverlays() {
        let s = bounds.width
        let capH = max(0, bounds.height - s)   // clamp: height can be < width mid-resize
        let rect = photoRect
        let clip = NSBezierPath(roundedRect: rect, xRadius: photoRadius, yRadius: photoRadius)

        // Dim the non-selected photos while a selection is active.
        if selectionActive && !selected {
            NSColor.black.withAlphaComponent(0.5).setFill()
            clip.fill()
        }

        // Checkmark badge (top-left) — only while multi-selecting, so a single
        // "view this one" selection stays clean (just the accent frame).
        if selected && selectionActive {
            let bs: CGFloat = 22
            let br = NSRect(x: rect.minX + 6, y: rect.maxY - bs - 6, width: bs, height: bs)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: br.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: br).fill()
            let c = Badge.check
            c.draw(in: NSRect(x: br.midX - c.size.width / 2, y: br.midY - c.size.height / 2,
                              width: c.size.width, height: c.size.height))
        }

        // Favorite badge — top-right of the photo.
        if favorite {
            let bs: CGFloat = 24
            let br = NSRect(x: rect.maxX - bs - 5, y: rect.maxY - bs - 5, width: bs, height: bs)
            NSColor.systemPink.setFill()
            NSBezierPath(ovalIn: br).fill()
            let h = Badge.heart
            h.draw(in: NSRect(x: br.midX - h.size.width / 2, y: br.midY - h.size.height / 2,
                              width: h.size.width, height: h.size.height))
        }

        // Rejected — dim the photo and mark it with a red ✕ (bottom-right).
        if rejected {
            NSColor.black.withAlphaComponent(0.45).setFill()
            clip.fill()
            let bs: CGFloat = 22
            let br = NSRect(x: rect.maxX - bs - 5, y: rect.minY + 5, width: bs, height: bs)
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
            let dr = NSRect(x: rect.minX + 6, y: rect.minY + 6, width: d, height: d)
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
            let startX = rect.midX - totalW / 2
            let y = rect.minY + 7
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
                self.cell.refresh()
            }
        }
        cell.refresh()
    }

    func updateSize(_ size: CGFloat) {
        cell.thumbSize = size
        cell.refresh()
    }

    /// Update the "a selection exists" dim state without reloading the image.
    func setSelectionActive(_ active: Bool) {
        guard cell.selectionActive != active else { return }
        cell.selectionActive = active
        cell.refresh()
    }

    /// Update favorite/rating/label/reject badges without reloading the image.
    func updateBadges(favorite: Bool, rating: Int, label: ColorLabel, rejected: Bool) {
        guard cell.favorite != favorite || cell.rating != rating
                || cell.labelColor != label.nsColor || cell.rejected != rejected else { return }
        cell.favorite = favorite
        cell.rating = rating
        cell.labelColor = label.nsColor
        cell.rejected = rejected
        cell.refresh()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken += 1
        cell.image = nil
    }

    override var isSelected: Bool {
        didSet { cell.selected = isSelected; cell.refresh() }
    }
}
