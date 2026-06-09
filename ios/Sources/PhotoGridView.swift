import SwiftUI
import Photos
import UIKit

/// Native UICollectionView photo grid: lazy cells + continuous pinch-to-zoom that
/// reflows like the Photos app. SwiftUI's LazyVGrid only does integer columns, so
/// its pinch can't be smooth — UICollectionView resizes items continuously.
struct PhotoGridView: UIViewRepresentable {
    let source: GridSource
    let manager: PHCachingImageManager
    var reloadKey: Int = 0
    var topInset: CGFloat = 52
    var onTap: (Int) -> Void
    var onBack: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = InterpolatingGridLayout()
        layout.spacing = 2
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.contentInsetAdjustmentBehavior = .always
        cv.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 28, right: 0)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator   // warm thumbs ahead of fast scrolls
        cv.register(ThumbCell.self, forCellWithReuseIdentifier: "c")

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        cv.addGestureRecognizer(pinch)
        let edge = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleEdge(_:)))
        edge.edges = .left
        cv.addGestureRecognizer(edge)
        cv.panGestureRecognizer.require(toFail: edge)

        context.coordinator.collectionView = cv
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.reloadKey != reloadKey {
            context.coordinator.reloadKey = reloadKey
            cv.reloadData()
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
                             UICollectionViewDataSourcePrefetching {
        var parent: PhotoGridView
        var reloadKey = -1
        weak var collectionView: UICollectionView?
        private var pinchStartCols: CGFloat = 4

        init(_ parent: PhotoGridView) { self.parent = parent }

        /// One target for cells AND prefetching — snapped to the shared prewarm size
        /// at the default zoom so all three hit the same cache entries.
        private func thumbTarget(_ cv: UICollectionView) -> CGSize {
            let cols = (cv.collectionViewLayout as? InterpolatingGridLayout)?.cols ?? 4
            let edge = cv.bounds.width / max(cols, 1) * UIScreen.main.scale
            let raw = CGSize(width: edge, height: edge)
            return abs(raw.width - PhotoLibrary.gridThumbTarget.width) < 1 ? PhotoLibrary.gridThumbTarget : raw
        }

        private func assets(at indexPaths: [IndexPath]) -> [PHAsset] {
            indexPaths.compactMap { $0.item < parent.source.count ? parent.source.asset($0.item) : nil }
        }

        func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { parent.source.count }

        func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "c", for: ip) as! ThumbCell
            let asset = parent.source.asset(ip.item)
            cell.configure(asset, manager: parent.manager, target: thumbTarget(cv))
            return cell
        }

        // Fast scroll: start decoding/downloading thumbs before their cells appear,
        // and stop when the scroll direction changes away from them.
        func collectionView(_ cv: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            parent.manager.startCachingImages(for: assets(at: indexPaths), targetSize: thumbTarget(cv),
                                              contentMode: .aspectFill, options: PhotoLibrary.gridThumbOptions())
        }

        func collectionView(_ cv: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            parent.manager.stopCachingImages(for: assets(at: indexPaths), targetSize: thumbTarget(cv),
                                             contentMode: .aspectFill, options: PhotoLibrary.gridThumbOptions())
        }

        func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
            cv.deselectItem(at: ip, animated: false)
            parent.onTap(ip.item)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let cv = collectionView, let layout = cv.collectionViewLayout as? InterpolatingGridLayout else { return }
            switch g.state {
            case .began:
                pinchStartCols = layout.cols
            case .changed:
                // pinch out (scale>1) → fewer/bigger columns; fractional → continuous reflow
                layout.cols = min(max(pinchStartCols / g.scale, 2), 9)
                layout.invalidateLayout()
            case .ended, .cancelled:
                let snapped = min(max(layout.cols.rounded(), 2), 9)
                UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                    layout.cols = snapped
                    layout.invalidateLayout()
                    cv.layoutIfNeeded()
                }
            default:
                break
            }
        }

        @objc func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
            if g.state == .recognized || g.state == .ended { parent.onBack() }
        }
    }
}

/// A grid layout with a *fractional* column count. It interpolates each cell's
/// frame between the floor- and ceil-column grids, so changing `cols` continuously
/// (during a pinch) reflows smoothly — no snapping at column boundaries.
final class InterpolatingGridLayout: UICollectionViewLayout {
    var cols: CGFloat = 4
    var spacing: CGFloat = 2
    private var contentHeight: CGFloat = 0

    private struct P { let w: CGFloat; let lo: Int; let hi: Int; let t: CGFloat; let cwLo: CGFloat; let cwHi: CGFloat }

    private func params() -> P? {
        guard let cv = collectionView, cv.bounds.width > 0 else { return nil }
        let w = cv.bounds.width
        let c = min(max(cols, 2), 9)
        let lo = Int(floor(c)); let hi = min(lo + 1, 9); let t = c - CGFloat(lo)
        func cw(_ n: Int) -> CGFloat { (w - CGFloat(n - 1) * spacing) / CGFloat(n) }
        return P(w: w, lo: lo, hi: hi, t: t, cwLo: cw(lo), cwHi: cw(hi))
    }

    private func frame(_ i: Int, _ n: Int, _ cw: CGFloat) -> CGRect {
        let c = i % n, r = i / n
        return CGRect(x: CGFloat(c) * (cw + spacing), y: CGFloat(r) * (cw + spacing), width: cw, height: cw)
    }

    private func interp(_ i: Int, _ p: P) -> CGRect {
        let a = frame(i, p.lo, p.cwLo), b = frame(i, p.hi, p.cwHi), t = p.t
        return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView, let p = params() else { return }
        let n = cv.numberOfItems(inSection: 0)
        let rowsLo = (n + p.lo - 1) / max(p.lo, 1), rowsHi = (n + p.hi - 1) / max(p.hi, 1)
        let hLo = CGFloat(rowsLo) * (p.cwLo + spacing) - spacing
        let hHi = CGFloat(rowsHi) * (p.cwHi + spacing) - spacing
        contentHeight = max(0, hLo + (hHi - hLo) * p.t)
    }

    override var collectionViewContentSize: CGSize { CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight) }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let cv = collectionView, let p = params() else { return nil }
        let n = cv.numberOfItems(inSection: 0)
        let rowH = (p.cwLo + (p.cwHi - p.cwLo) * p.t) + spacing
        let firstRow = max(0, Int(rect.minY / rowH) - 2)
        let lastRow = Int(rect.maxY / rowH) + 2
        let start = max(0, firstRow * p.lo)
        let end = min(n, (lastRow + 1) * p.hi)
        guard start < end else { return [] }
        return (start..<end).map { i in
            let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
            a.frame = interp(i, p)
            return a
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let p = params() else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        a.frame = interp(indexPath.item, p)
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

/// One square thumbnail cell with a favorite heart.
final class ThumbCell: UICollectionViewCell {
    let imageView = UIImageView()
    private let heart = UIImageView(image: UIImage(systemName: "heart.fill"))
    private var assetID: String?
    private var requestID: PHImageRequestID = 0
    private weak var manager: PHCachingImageManager?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        heart.tintColor = .white
        heart.preferredSymbolConfiguration = .init(pointSize: 11, weight: .bold)
        heart.layer.shadowColor = UIColor.black.cgColor
        heart.layer.shadowOpacity = 0.5
        heart.layer.shadowRadius = 2
        heart.layer.shadowOffset = .zero
        heart.isHidden = true
        heart.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(heart)
        NSLayoutConstraint.activate([
            heart.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            heart.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ asset: PHAsset, manager: PHCachingImageManager, target: CGSize) {
        assetID = asset.localIdentifier
        self.manager = manager
        heart.isHidden = !asset.isFavorite
        let opt = PhotoLibrary.gridThumbOptions()
        let id = asset.localIdentifier
        requestID = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: opt) { [weak self] img, _ in
            guard let self, self.assetID == id, let img else { return }
            self.imageView.image = img
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if requestID != 0 { manager?.cancelImageRequest(requestID); requestID = 0 }
        imageView.image = nil
        assetID = nil
    }
}
