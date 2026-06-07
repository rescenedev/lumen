import AppKit
import Photos

/// Loads thumbnails and full images for Photos-library assets via PhotoKit.
/// Thumbnails come from local representations (no iCloud download); full images
/// allow on-demand iCloud download. PhotoKit manages its own cache, so we don't
/// duplicate asset thumbnails into Lumen's on-disk thumbnail cache (decision #1).
final class PhotosImageLoader {
    static let shared = PhotosImageLoader()

    private let manager = PHCachingImageManager()
    private var assetsById: [String: PHAsset] = [:]
    private let lock = NSLock()

    private init() {}

    /// Register the assets from a library fetch so lookups by id are O(1).
    func register(_ assets: [String: PHAsset]) {
        lock.lock(); assetsById = assets; lock.unlock()
    }

    private func asset(for url: URL) -> PHAsset? {
        guard let id = url.photosAssetLocalIdentifier else { return nil }
        lock.lock(); let cached = assetsById[id]; lock.unlock()
        if let cached { return cached }
        // Fallback: fetch by id (e.g. before the full library load has registered).
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Local thumbnail sized for the grid — never triggers an iCloud download.
    func thumbnail(for url: URL, maxPixel: Int) async -> NSImage? {
        guard let asset = asset(for: url) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // single callback → safe continuation
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false       // thumbnails are local
        options.isSynchronous = false
        return await requestImage(asset, target: CGSize(width: maxPixel, height: maxPixel), options: options)
    }

    /// Full image for the viewer; downloads the original from iCloud on demand.
    func fullImage(for url: URL) async -> NSImage? {
        guard let asset = asset(for: url) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await requestImage(asset, target: PHImageManagerMaximumSize, options: options)
    }

    private func requestImage(_ asset: PHAsset, target: CGSize,
                              options: PHImageRequestOptions) async -> NSImage? {
        await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFit, options: options) { image, _ in
                // highQualityFormat delivers once, but guard against any extra call.
                if resumed { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
