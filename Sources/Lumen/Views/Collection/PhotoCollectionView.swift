import SwiftUI
import AppKit

/// AppKit NSCollectionView wrapped for SwiftUI — true cell reuse so a 60k-photo
/// grid scrolls without building a giant view tree.
struct PhotoCollectionView: NSViewRepresentable {
    let model: AppModel
    let token: Int                 // visibleSignature — changes when the list changes
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

        let dbl = NSClickGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handleDoubleClick(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        cv.addGestureRecognizer(dbl)

        let coord = context.coordinator
        cv.onKey = { [weak coord] key in coord?.handleKey(key) ?? false }
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

        coord.appliedToken = token
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
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: AppModel
        var photos: [Photo] = []
        var indexByID: [Photo.ID: Int] = [:]
        var appliedToken = -1
        var appliedSorting = false
        var appliedMetaVersion = -1
        var appliedSelection: Set<Photo.ID> = []
        var appliedAnchor: Photo.ID?
        var appliedViewerActive = false
        private var syncingSelection = false

        init(model: AppModel) { self.model = model }

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
                           favorite: model.isFavorite(photo),
                           rating: model.rating(photo), label: model.label(photo))
            return item
        }

        /// Update favorite/rating/label badges on the visible cells in place,
        /// without a reload (so in-flight/loaded thumbnails are preserved).
        func refreshVisibleBadges(_ cv: NSCollectionView) {
            for ip in cv.indexPathsForVisibleItems() {
                guard photos.indices.contains(ip.item),
                      let item = cv.item(at: ip) as? PhotoCollectionItem else { continue }
                let photo = photos[ip.item]
                item.updateBadges(favorite: model.isFavorite(photo),
                                  rating: model.rating(photo), label: model.label(photo))
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
            }
        }

        func applySelection(_ cv: NSCollectionView, _ selection: Set<Photo.ID>) {
            let ips = Set(selection.compactMap { indexByID[$0] }.map { IndexPath(item: $0, section: 0) })
            appliedSelection = selection
            guard ips != cv.selectionIndexPaths else { return }
            syncingSelection = true
            cv.deselectItems(at: cv.selectionIndexPaths)
            cv.selectItems(at: ips, scrollPosition: [])
            syncingSelection = false
        }

        @objc func handleDoubleClick(_ g: NSClickGestureRecognizer) {
            guard let cv = g.view as? NSCollectionView else { return }
            let pt = g.location(in: cv)
            if let ip = cv.indexPathForItem(at: pt), photos.indices.contains(ip.item) {
                model.openViewer(photos[ip.item])
            }
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
final class AdaptiveFlowLayout: NSCollectionViewFlowLayout {
    var targetItemWidth: CGFloat = 170
    var captionHeight: CGFloat = 36

    override func prepare() {
        if let cv = collectionView {
            let insets = sectionInset.left + sectionInset.right
            let available = max(0, cv.bounds.width - insets)
            let g = minimumInteritemSpacing
            let cols = max(1, Int((available + g) / (targetItemWidth + g)))
            let w = max(40, floor((available - CGFloat(cols - 1) * g) / CGFloat(cols)))
            itemSize = NSSize(width: w, height: w + captionHeight)
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        collectionView?.bounds.width != newBounds.width
            || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

/// NSCollectionView subclass routing custom keys + context menus to the coordinator.
final class LumenCollectionView: NSCollectionView {
    var onKey: ((LumenKey) -> Bool)?
    var menuProvider: ((NSEvent) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let handled: Bool
        switch event.keyCode {
        case 49: handled = onKey?(.space) ?? false    // space
        case 36, 76: handled = onKey?(.enter) ?? false // return / enter
        case 51, 117: handled = onKey?(.delete) ?? false // delete / fwd-delete
        default: handled = false
        }
        if !handled { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event) ?? super.menu(for: event)
    }
}

enum LumenKey { case space, enter, delete }
