import SwiftUI
import Photos
import UIKit

/// Native UICollectionView photo grid: lazy cells + continuous pinch-to-zoom that
/// reflows like the Photos app. SwiftUI's LazyVGrid only does integer columns, so
/// its pinch can't be smooth — UICollectionView resizes items continuously.
struct PhotoGridView: UIViewRepresentable {
    let assets: [PHAsset]
    var topInset: CGFloat = 52
    var onTap: (Int) -> Void
    var onBack: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = GridFlowLayout()
        layout.minimumLineSpacing = 2
        layout.minimumInteritemSpacing = 2
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.contentInsetAdjustmentBehavior = .always
        cv.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 28, right: 0)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
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
        if context.coordinator.assets.map(\.localIdentifier) != assets.map(\.localIdentifier) {
            context.coordinator.assets = assets
            cv.reloadData()
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: PhotoGridView
        var assets: [PHAsset]
        weak var collectionView: UICollectionView?
        let manager = PHCachingImageManager()
        private var pinchStartEdge: CGFloat = 0

        init(_ parent: PhotoGridView) { self.parent = parent; self.assets = parent.assets }

        func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { assets.count }

        func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "c", for: ip) as! ThumbCell
            let asset = assets[ip.item]
            cell.configure(asset, manager: manager,
                           edge: (cv.collectionViewLayout as? GridFlowLayout)?.itemSize.width ?? 96)
            return cell
        }

        func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
            cv.deselectItem(at: ip, animated: false)
            parent.onTap(ip.item)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let cv = collectionView, let layout = cv.collectionViewLayout as? GridFlowLayout else { return }
            switch g.state {
            case .began:
                pinchStartEdge = layout.targetEdge
            case .changed:
                let w = cv.bounds.width
                layout.targetEdge = min(max(pinchStartEdge * g.scale, w / 9.0), w / 2.05)  // 2…9 columns
                layout.invalidateLayout()
            default:
                break
            }
        }

        @objc func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
            if g.state == .recognized || g.state == .ended { parent.onBack() }
        }
    }
}

/// Flow layout whose `targetEdge` (desired item side) is set continuously by the
/// pinch; `prepare` snaps it to a whole number of columns that fills the width.
final class GridFlowLayout: UICollectionViewFlowLayout {
    var targetEdge: CGFloat = 96

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let w = cv.bounds.width
        let spacing = minimumInteritemSpacing
        let cols = max(2, min(9, Int((w + spacing) / (targetEdge + spacing))))
        let edge = (w - CGFloat(cols - 1) * spacing) / CGFloat(cols)
        itemSize = CGSize(width: floor(edge), height: floor(edge))
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }
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

    func configure(_ asset: PHAsset, manager: PHCachingImageManager, edge: CGFloat) {
        assetID = asset.localIdentifier
        self.manager = manager
        heart.isHidden = !asset.isFavorite
        let scale = UIScreen.main.scale
        let target = CGSize(width: edge * scale, height: edge * scale)
        let opt = PHImageRequestOptions()
        opt.deliveryMode = .opportunistic
        opt.resizeMode = .fast
        opt.isNetworkAccessAllowed = true
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
