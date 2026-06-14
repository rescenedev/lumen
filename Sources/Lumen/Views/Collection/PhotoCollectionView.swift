import SwiftUI
import AppKit

/// AppKit NSCollectionView wrapped for SwiftUI — true cell reuse so a 60k-photo
/// grid scrolls without building a giant view tree.
struct PhotoCollectionView: NSViewRepresentable {
    let model: AppModel
    let token: Int                 // visibleSignature — changes when the list changes
    let navToken: Int              // changes on user navigation — resets scroll to top
    let isSorting: Bool            // true while a big scope sorts off-main
    let metaVersion: Int           // changes when favorites/ratings/labels change
    let thumbnailSize: Double
    let selection: Set<Photo.ID>
    let anchor: Photo.ID?
    let viewerActive: Bool         // true while the full-screen viewer is open

    private static let captionHeight: CGFloat = 20

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = AdaptiveFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        layout.captionHeight = Self.captionHeight
        layout.targetItemWidth = thumbnailSize

        let cv = LumenCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.register(PhotoCollectionItem.self, forItemWithIdentifier: PhotoCollectionItem.identifier)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator

        let dbl = NSClickGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handleDoubleClick(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        cv.addGestureRecognizer(dbl)

        let coord = context.coordinator
        cv.onKey = { [weak coord] key in coord?.handleKey(key) ?? false }
        cv.onChar = { [weak coord] ch in coord?.handleChar(ch) ?? false }
        cv.onArrow = { [weak coord, weak cv] dx, dy, shift in
            guard let coord, let cv else { return false }
            return coord.handleArrow(dx: dx, dy: dy, shift: shift, in: cv)
        }
        cv.onJump = { [weak coord, weak cv] kind, shift in
            guard let coord, let cv else { return false }
            return coord.handleJump(kind, shift: shift, in: cv)
        }
        cv.menuProvider = { [weak coord, weak cv] event in
            guard let coord, let cv else { return nil }
            let pt = cv.convert(event.locationInWindow, from: nil)
            return coord.menu(at: cv.indexPathForItem(at: pt), in: cv)
        }

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        // Recompute the column count whenever the clip (visible) width changes —
        // window resize, sidebar/inspector toggle. Resize the collection view to
        // the clip width FIRST: invalidateLayout alone recomputes columns but
        // doesn't widen the doc view, so the grid stays at the old column count
        // with empty space on the right. Setting cv width = clip width makes it
        // fill the scroll view, then the layout lays out columns across it.
        scroll.contentView.postsFrameChangedNotifications = true
        coord.clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView,
            queue: .main) { [weak cv, weak scroll] _ in
                guard let cv, let scroll else { return }
                let clipWidth = scroll.contentView.bounds.width
                if abs(cv.frame.width - clipWidth) > 0.5 {
                    cv.setFrameSize(NSSize(width: clipWidth, height: cv.frame.height))
                }
                cv.collectionViewLayout?.invalidateLayout()
            }

        coord.appliedToken = token
        coord.appliedNavToken = navToken
        coord.reload(cv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let cv = scroll.documentView as? LumenCollectionView else { return }
        let coord = context.coordinator

        if let layout = cv.collectionViewLayout as? AdaptiveFlowLayout,
           layout.targetItemWidth != thumbnailSize {
            layout.targetItemWidth = thumbnailSize
            layout.invalidateLayout()
        }

        if token != coord.appliedToken {
            coord.appliedToken = token
            coord.reload(cv)
        } else if coord.appliedSorting && !isSorting {
            coord.reload(cv)            // async sort just landed — refresh content
        } else if metaVersion != coord.appliedMetaVersion {
            coord.refreshVisibleBadges(cv)   // favorites/ratings/labels — no reload
        }

        // Navigating somewhere else starts at the top; library edits within
        // the same view (delete/import → token change) keep the position.
        // Scrolling now AND after the layout pass is deliberate: reloadData's
        // deferred layout restores the previous offset, overwriting a scroll
        // issued inside updateNSView — the async one wins that race.
        if navToken != coord.appliedNavToken {
            coord.appliedNavToken = navToken
            let toTop = { [weak scroll] in
                guard let scroll else { return }
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            toTop()
            DispatchQueue.main.async(execute: toTop)
        }
        coord.appliedSorting = isSorting
        coord.appliedMetaVersion = metaVersion

        if selection != coord.appliedSelection {
            coord.applySelection(cv, selection)
        }

        if let anchor, anchor != coord.appliedAnchor, let idx = coord.indexByID[anchor] {
            coord.appliedAnchor = anchor
            cv.animator().scrollToItems(at: [IndexPath(item: idx, section: 0)],
                                        scrollPosition: .nearestHorizontalEdge)
        }

        // When the viewer closes, the grid must reclaim keyboard focus or its
        // built-in arrow-key navigation stays dead (SwiftUI's viewer overlay
        // had taken first responder and never hands it back). Defer so it runs
        // after SwiftUI finishes tearing down the overlay's focus.
        if coord.appliedViewerActive && !viewerActive {
            DispatchQueue.main.async { [weak cv] in
                guard let cv, let window = cv.window else { return }
                if window.firstResponder !== cv { window.makeFirstResponder(cv) }
            }
        }
        coord.appliedViewerActive = viewerActive
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
                             NSCollectionViewPrefetching {
        let model: AppModel
        var photos: [Photo] = []
        var indexByID: [Photo.ID: Int] = [:]
        var appliedToken = -1
        var appliedNavToken = -1
        var appliedSorting = false
        var appliedMetaVersion = -1
        var appliedSelection: Set<Photo.ID> = []
        var appliedAnchor: Photo.ID?
        var appliedViewerActive = false
        var clipObserver: NSObjectProtocol?
        private var syncingSelection = false

        init(model: AppModel) { self.model = model }
        deinit { if let o = clipObserver { NotificationCenter.default.removeObserver(o) } }

        func reload(_ cv: NSCollectionView) {
            photos = model.visiblePhotos
            indexByID = Dictionary(photos.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            cv.reloadData()
            applySelection(cv, model.selection)
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            photos.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: PhotoCollectionItem.identifier,
                                               for: indexPath) as! PhotoCollectionItem
            guard photos.indices.contains(indexPath.item) else { return item }
            let photo = photos[indexPath.item]
            item.configure(photo: photo, size: CGFloat(model.thumbnailSize),
                           selected: model.selection.contains(photo.id),
                           selectionActive: model.selection.count > 1,
                           favorite: model.isFavorite(photo),
                           rating: model.rating(photo), label: model.label(photo),
                           rejected: model.isRejected(photo))
            return item
        }

        // Viewport-driven prefetch: NSCollectionView asks ahead of the scroll
        // direction, so only cells about to appear decode — not the whole list.
        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let tier = ThumbnailCache.tier(forPointSize: model.thumbnailSize)
            let entries: [ThumbnailCache.Entry] = indexPaths.compactMap { ip in
                guard photos.indices.contains(ip.item) else { return nil }
                let photo = photos[ip.item]
                return (url: photo.url, mtime: photo.cacheMtime)
            }
            ThumbnailCache.shared.prefetchItems(entries, maxPixel: tier)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            let tier = ThumbnailCache.tier(forPointSize: model.thumbnailSize)
            let urls = indexPaths.compactMap { photos.indices.contains($0.item) ? photos[$0.item].url : nil }
            ThumbnailCache.shared.cancelPrefetchItems(urls, maxPixel: tier)
        }

        /// Update favorite/rating/label badges on the visible cells in place,
        /// without a reload (so in-flight/loaded thumbnails are preserved).
        func refreshVisibleBadges(_ cv: NSCollectionView) {
            for ip in cv.indexPathsForVisibleItems() {
                guard photos.indices.contains(ip.item),
                      let item = cv.item(at: ip) as? PhotoCollectionItem else { continue }
                let photo = photos[ip.item]
                item.updateBadges(favorite: model.isFavorite(photo),
                                  rating: model.rating(photo), label: model.label(photo),
                                  rejected: model.isRejected(photo))
            }
        }

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged(cv)
        }
        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged(cv)
        }

        private func selectionChanged(_ cv: NSCollectionView) {
            guard !syncingSelection else { return }
            let sel = Set(cv.selectionIndexPaths.compactMap { photos.indices.contains($0.item) ? photos[$0.item].id : nil })
            appliedSelection = sel
            model.selection = sel
            if let last = cv.selectionIndexPaths.max(by: { $0.item < $1.item }), photos.indices.contains(last.item) {
                model.selectionAnchor = photos[last.item].id
                appliedAnchor = photos[last.item].id
                cursorIndex = last.item
            }
            refreshSelectionActive(cv)
        }

        /// Toggle the "dim the non-selected" treatment on every visible cell when a
        /// selection appears/disappears (cells that stay unselected don't otherwise
        /// redraw on a selection change).
        private func refreshSelectionActive(_ cv: NSCollectionView) {
            let active = model.selection.count > 1   // only dim during multi-select
            for case let item as PhotoCollectionItem in cv.visibleItems() {
                item.setSelectionActive(active)
            }
        }

        func applySelection(_ cv: NSCollectionView, _ selection: Set<Photo.ID>) {
            let ips = Set(selection.compactMap { indexByID[$0] }.map { IndexPath(item: $0, section: 0) })
            appliedSelection = selection
            defer { refreshSelectionActive(cv) }
            let current = cv.selectionIndexPaths
            guard ips != current else { return }
            // Only touch the items that actually changed — re-selecting the whole
            // block on every Shift+arrow caused a momentary freeze.
            syncingSelection = true
            let toRemove = current.subtracting(ips)
            let toAdd = ips.subtracting(current)
            if !toRemove.isEmpty { cv.deselectItems(at: toRemove) }
            if !toAdd.isEmpty { cv.selectItems(at: toAdd, scrollPosition: []) }
            syncingSelection = false
        }

        @objc func handleDoubleClick(_ g: NSClickGestureRecognizer) {
            guard let cv = g.view as? NSCollectionView else { return }
            let pt = g.location(in: cv)
            if let ip = cv.indexPathForItem(at: pt), photos.indices.contains(ip.item) {
                model.openViewer(photos[ip.item])
            }
        }

        // The keyboard "cursor" cell — where the next arrow move starts from.
        var cursorIndex: Int?

        /// Columns currently laid out (so up/down move a true grid row, and Shift
        /// builds a rectangle instead of an index range). Counted from the real
        /// item frames — the first row's items share a Y — so it can never be off
        /// by one the way back-computing from widths/insets could.
        private func columns(_ cv: NSCollectionView) -> Int {
            guard let layout = cv.collectionViewLayout, !photos.isEmpty,
                  let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
            else { return 1 }
            let y0 = first.frame.minY
            var count = 0
            for i in 0..<min(photos.count, 256) {
                guard let a = layout.layoutAttributesForItem(at: IndexPath(item: i, section: 0)) else { break }
                if abs(a.frame.minY - y0) < 1 { count += 1 } else { break }
            }
            return max(1, count)
        }

        /// Grid-aware arrow navigation. ←/→ move linearly through the sequence,
        /// wrapping to the next/previous row at the edges (Finder/Photos style);
        /// ↑/↓ move by a row in the same column. Shift extends a RECTANGULAR block
        /// from the anchor to the cursor (so ⇧↓ from a 2-wide selection makes a
        /// 2×2, not a full index range).
        func handleArrow(dx: Int, dy: Int, shift: Bool, in cv: NSCollectionView) -> Bool {
            guard !photos.isEmpty else { return false }
            let cols = columns(cv)
            let anchorIdx = model.selectionAnchor.flatMap { indexByID[$0] } ?? cursorIndex ?? 0
            let cur = cursorIndex ?? anchorIdx
            let next: Int
            if dy != 0 {
                // Vertical: move one row, keeping the column (clamped to the grid).
                let lastRow = (photos.count - 1) / cols
                let row = min(max(0, cur / cols + dy), lastRow)
                next = min(row * cols + cur % cols, photos.count - 1)
            } else {
                // Horizontal: linear next/prev, wrapping across row boundaries.
                next = min(max(0, cur + dx), photos.count - 1)
            }
            applyMove(to: next, anchorIdx: anchorIdx, shift: shift, cols: cols, in: cv)
            return true
        }

        /// Home / End / Page Up / Page Down. Home/End jump to the first/last
        /// photo; the page keys move by one viewport of rows. Shift extends the
        /// rectangular block from the anchor, matching arrow-key behaviour.
        func handleJump(_ kind: JumpKind, shift: Bool, in cv: NSCollectionView) -> Bool {
            guard !photos.isEmpty else { return false }
            let cols = columns(cv)
            let anchorIdx = model.selectionAnchor.flatMap { indexByID[$0] } ?? cursorIndex ?? 0
            let cur = cursorIndex ?? anchorIdx
            let page = max(1, visibleRows(cv)) * cols
            let next: Int
            switch kind {
            case .home: next = 0
            case .end: next = photos.count - 1
            case .pageUp: next = max(0, cur - page)
            case .pageDown: next = min(photos.count - 1, cur + page)
            }
            applyMove(to: next, anchorIdx: anchorIdx, shift: shift, cols: cols, in: cv)
            return true
        }

        /// Commit a navigation move: update the cursor, compute the new selection
        /// (single item, or a rectangular block when extending with Shift), and
        /// scroll the target into view.
        private func applyMove(to next: Int, anchorIdx: Int, shift: Bool, cols: Int,
                               in cv: NSCollectionView) {
            cursorIndex = next
            let indices: Set<Int>
            if shift {
                indices = rectBlock(anchorIdx, next, cols: cols)
            } else {
                indices = [next]
                if photos.indices.contains(next) {
                    model.selectionAnchor = photos[next].id
                    appliedAnchor = photos[next].id
                }
            }
            let sel = Set(indices.compactMap { photos.indices.contains($0) ? photos[$0].id : nil })
            model.selection = sel
            applySelection(cv, sel)
            cv.scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }

        /// Number of fully/partly visible rows in the current viewport — the
        /// page size for Page Up / Page Down.
        private func visibleRows(_ cv: NSCollectionView) -> Int {
            guard let layout = cv.collectionViewLayout as? AdaptiveFlowLayout else { return 1 }
            let rowHeight = layout.itemSize.height + layout.minimumLineSpacing
            guard rowHeight > 0 else { return 1 }
            let viewport = cv.enclosingScrollView?.documentVisibleRect.height ?? cv.bounds.height
            return max(1, Int(viewport / rowHeight))
        }

        private func rectBlock(_ a: Int, _ b: Int, cols: Int) -> Set<Int> {
            let r0 = min(a / cols, b / cols), r1 = max(a / cols, b / cols)
            let c0 = min(a % cols, b % cols), c1 = max(a % cols, b % cols)
            var out = Set<Int>()
            for r in r0...r1 { for c in c0...c1 {
                let i = r * cols + c
                if i < photos.count { out.insert(i) }
            } }
            return out
        }

        func handleKey(_ key: LumenKey) -> Bool {
            let list = model.visiblePhotos
            switch key {
            case .space:
                guard let p = model.primarySelectedPhoto ?? list.first,
                      let i = list.firstIndex(of: p) else { return false }
                QuickLookPreview.shared.toggle(urls: list.map { $0.url }, startAt: i)
                return true
            case .enter:
                guard let p = model.primarySelectedPhoto ?? list.first else { return false }
                model.openViewer(p)
                return true
            case .delete:
                let targets = model.deletionTargets
                guard !targets.isEmpty else { return false }
                model.requestDeletion(targets)
                return true
            case .escape:
                guard !model.selection.isEmpty else { return false }
                model.clearSelection()
                return true
            }
        }

        /// Fast culling on the selected photos: 0–5 sets the rating, X toggles the
        /// reject flag, F toggles favorite.
        func handleChar(_ ch: Character) -> Bool {
            let targets = model.selectedPhotos
            guard !targets.isEmpty else { return false }
            switch ch {
            case "0"..."5":
                model.setRating(Int(String(ch)) ?? 0, for: targets)
                return true
            case "x", "X":
                model.toggleRejected(targets)
                return true
            case "f", "F":
                model.toggleFavorites(targets)
                return true
            default:
                return false
            }
        }

        func menu(at indexPath: IndexPath?, in cv: NSCollectionView) -> NSMenu? {
            guard let indexPath, photos.indices.contains(indexPath.item) else { return nil }
            let photo = photos[indexPath.item]
            if !model.selection.contains(photo.id) {
                model.selectOnly(photo)
                applySelection(cv, model.selection)
            }
            return PhotoMenuBuilder.build(for: photo, model: model)
        }
    }
}

/// Flow layout that grows items to fill the row width (like SwiftUI's adaptive
/// grid) instead of leaving big distributed gaps. `targetItemWidth` is the
/// minimum desired width; actual width expands to fill the columns that fit.
/// Uniform grid with O(1) per-item frame math. This replaced an
/// NSCollectionViewFlowLayout subclass: FlowLayout recomputes attributes for
/// every item on each invalidation, which measured ~330ms of main-thread stall
/// at 67k photos whenever the thumbnail slider moved or the window resized.
/// All cells share one size, so frames are pure arithmetic on the index.
final class AdaptiveFlowLayout: NSCollectionViewLayout {
    var targetItemWidth: CGFloat = 170
    var captionHeight: CGFloat = 36
    var minimumInteritemSpacing: CGFloat = 6
    var minimumLineSpacing: CGFloat = 4
    var sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

    /// Computed in prepare(); `itemSize` stays public — keyboard paging reads it.
    private(set) var itemSize = NSSize(width: 170, height: 206)
    private var cols = 1
    private var count = 0

    /// Lay the grid out to the SCROLL VIEW's clip width, not the collection
    /// view's own bounds. `collectionViewContentSize.width` feeds back into the
    /// CV's frame, so keying off `cv.bounds.width` is self-referential: once the
    /// CV is narrower than the window (e.g. after a programmatic resize) it can
    /// stay stuck at a low column count. The clip view always reflects the real
    /// available width.
    private var layoutWidth: CGFloat {
        collectionView?.enclosingScrollView?.contentView.bounds.width
            ?? collectionView?.bounds.width ?? 0
    }

    override func prepare() {
        guard let cv = collectionView else { return }
        let available = max(0, layoutWidth - sectionInset.left - sectionInset.right)
        let g = minimumInteritemSpacing
        cols = max(1, Int((available + g) / (targetItemWidth + g)))
        let w = max(40, floor((available - CGFloat(cols - 1) * g) / CGFloat(cols)))
        itemSize = NSSize(width: w, height: w + captionHeight)
        count = cv.numberOfItems(inSection: 0)   // single-section grid
    }

    override var collectionViewContentSize: NSSize {
        let rows = (count + cols - 1) / max(cols, 1)
        let height = sectionInset.top + sectionInset.bottom
            + CGFloat(rows) * itemSize.height + CGFloat(max(0, rows - 1)) * minimumLineSpacing
        return NSSize(width: layoutWidth, height: height)
    }

    private func frame(at index: Int) -> NSRect {
        let row = index / cols, col = index % cols
        return NSRect(x: sectionInset.left + CGFloat(col) * (itemSize.width + minimumInteritemSpacing),
                      y: sectionInset.top + CGFloat(row) * (itemSize.height + minimumLineSpacing),
                      width: itemSize.width, height: itemSize.height)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0, cols > 0 else { return [] }
        let rowHeight = itemSize.height + minimumLineSpacing
        let firstRow = max(0, Int((rect.minY - sectionInset.top) / rowHeight))
        let lastRow = max(firstRow, Int((rect.maxY - sectionInset.top) / rowHeight))
        let start = min(count, firstRow * cols)
        let end = min(count, (lastRow + 1) * cols)
        guard start < end else { return [] }
        return (start..<end).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < count || count == 0 else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame(at: indexPath.item)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        collectionView?.bounds.width != newBounds.width
    }
}

/// NSCollectionView subclass routing custom keys + context menus to the coordinator.
final class LumenCollectionView: NSCollectionView {
    var onKey: ((LumenKey) -> Bool)?
    var onArrow: ((_ dx: Int, _ dy: Int, _ shift: Bool) -> Bool)?
    var onJump: ((_ kind: JumpKind, _ shift: Bool) -> Bool)?
    var onChar: ((Character) -> Bool)?         // culling: 0–5 rate, x reject, f favorite
    var menuProvider: ((NSEvent) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        var handled = false
        switch event.keyCode {
        case 49: handled = onKey?(.space) ?? false       // space
        case 36, 76: handled = onKey?(.enter) ?? false   // return / enter
        case 51, 117: handled = onKey?(.delete) ?? false // delete / fwd-delete
        case 53: handled = onKey?(.escape) ?? false      // esc
        case 123: handled = onArrow?(-1, 0, shift) ?? false  // ←
        case 124: handled = onArrow?(1, 0, shift) ?? false   // →
        case 125: handled = onArrow?(0, 1, shift) ?? false   // ↓
        case 126: handled = onArrow?(0, -1, shift) ?? false  // ↑
        case 115: handled = onJump?(.home, shift) ?? false       // Home
        case 119: handled = onJump?(.end, shift) ?? false        // End
        case 116: handled = onJump?(.pageUp, shift) ?? false     // Page Up
        case 121: handled = onJump?(.pageDown, shift) ?? false   // Page Down
        default: break
        }
        // Plain character keys (no Command) drive fast culling.
        if !handled, !event.modifierFlags.contains(.command),
           let ch = event.charactersIgnoringModifiers?.first {
            handled = onChar?(ch) ?? false
        }
        if !handled { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event) ?? super.menu(for: event)
    }
}

enum LumenKey { case space, enter, delete, escape }
enum JumpKind { case home, end, pageUp, pageDown }
