import Photos
import UIKit

/// Loads the device photo library (PhotoKit) and serves thumbnails / full images.
/// This is the iOS equivalent of the macOS scanner — the app's library source.
@MainActor @Observable final class PhotoLibrary {
    var assets: [PHAsset] = []
    var albums: [PHAssetCollection] = []
    var authorized = false
    var loaded = false

    private let manager = PHCachingImageManager()

    func load() async {
        let status = await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
        }
        authorized = (status == .authorized || status == .limited)
        loaded = true
        guard authorized else { return }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: opts)
        var arr: [PHAsset] = []
        arr.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in arr.append(a) }
        assets = arr
        loadAlbums()
    }

    // MARK: - Albums (for up-swipe classification)

    func loadAlbums() {
        let r = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var arr: [PHAssetCollection] = []
        r.enumerateObjects { c, _, _ in arr.append(c) }
        albums = arr
    }

    func createAlbum(_ title: String) async -> PHAssetCollection? {
        var placeholder: PHObjectPlaceholder?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                placeholder = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: title).placeholderForCreatedAssetCollection
            }
        } catch { return nil }
        guard let id = placeholder?.localIdentifier,
              let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        albums.append(c)
        return c
    }

    func addAssets(_ assets: [PHAsset], to collection: PHAssetCollection) async {
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: collection)?.addAssets(assets as NSArray)
        }
    }

    /// The single "Lumen" album — up-swiped photos land here for the user to sort
    /// later. Found by title or created on demand.
    func lumenAlbum() async -> PHAssetCollection? {
        if let existing = albums.first(where: { $0.localizedTitle == "Lumen" }) { return existing }
        return await createAlbum("Lumen")
    }

    /// Square thumbnail for the grid. `.highQualityFormat` → exactly one callback
    /// (safe to bridge to a continuation).
    func thumbnail(_ asset: PHAsset, points: CGFloat) async -> UIImage? {
        let px = points * 3
        return await request(asset, target: CGSize(width: px, height: px), mode: .aspectFill,
                             delivery: .highQualityFormat).map { $0 }
    }

    /// Downsized full image (oriented) for editing/combine.
    func cgImage(_ asset: PHAsset, maxPixel: CGFloat = 2000) async -> CGImage? {
        await request(asset, target: CGSize(width: maxPixel, height: maxPixel), mode: .aspectFit,
                      delivery: .highQualityFormat)?.cgImage
    }

    private func request(_ asset: PHAsset, target: CGSize, mode: PHImageContentMode,
                         delivery: PHImageRequestOptionsDeliveryMode) async -> UIImage? {
        await withCheckedContinuation { c in
            let opt = PHImageRequestOptions()
            opt.deliveryMode = delivery
            opt.isNetworkAccessAllowed = true       // fetch iCloud originals if needed
            opt.resizeMode = .fast
            manager.requestImage(for: asset, targetSize: target, contentMode: mode, options: opt) { img, _ in
                c.resume(returning: img)
            }
        }
    }
}
