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

    /// Merge assets from a library/album fetch so lookups by id are O(1).
    /// (Merging, not replacing, so loading an album doesn't drop the full-library
    /// map — both scopes share one id→asset table.)
    func register(_ assets: [String: PHAsset]) {
        lock.lock(); for (id, asset) in assets { assetsById[id] = asset }; lock.unlock()
    }

    private func asset(for url: URL) -> PHAsset? {
        guard let id = url.photosAssetLocalIdentifier else { return nil }
        lock.lock(); let cached = assetsById[id]; lock.unlock()
        if let cached { return cached }
        // Fallback: fetch by id (e.g. before the full library load has registered).
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// The asset's GPS coordinate, read straight from PhotoKit (no file reads),
    /// for the map. Cache-only (no per-asset DB fetch) since the map scans the
    /// whole scope — a fetch-per-asset fallback would be catastrophic. nil if the
    /// asset isn't registered or has no location.
    func location(for url: URL) -> (latitude: Double, longitude: Double)? {
        guard let id = url.photosAssetLocalIdentifier else { return nil }
        lock.lock(); let asset = assetsById[id]; lock.unlock()
        guard let loc = asset?.location else { return nil }
        return (loc.coordinate.latitude, loc.coordinate.longitude)
    }

    /// Thumbnail sized for the grid. Network access is allowed so iCloud-only
    /// photos (Optimize Mac Storage) still show — PhotoKit fetches a small
    /// thumbnail representation, not the full original (that stays viewer-only).
    func thumbnail(for url: URL, maxPixel: Int) async -> NSImage? {
        guard let asset = asset(for: url) else { return nil }
        let options = PHImageRequestOptions()
        // Mirror the (working) full-image request — same deliveryMode and DEFAULT
        // resizeMode, just a smaller target. A non-default resizeMode (.fast/.exact)
        // was making PhotoKit hand back a blank placeholder for some assets.
        // skipDegraded waits past the tiny low-quality first frame.
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await requestImage(asset, target: CGSize(width: maxPixel, height: maxPixel),
                                  options: options, skipDegraded: true)
    }

    /// Full image for the viewer; downloads the original from iCloud on demand.
    func fullImage(for url: URL) async -> NSImage? {
        guard let asset = asset(for: url) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await requestImage(asset, target: PHImageManagerMaximumSize,
                                  options: options, skipDegraded: true)
    }

    /// Runs a PhotoKit image request as async. When `skipDegraded` is true we wait
    /// past the low-quality placeholder for the real image, but always resume on a
    /// nil/cancelled/failed result so the continuation can never leak.
    private func requestImage(_ asset: PHAsset, target: CGSize,
                              options: PHImageRequestOptions, skipDegraded: Bool) async -> NSImage? {
        await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFit, options: options) { image, info in
                if resumed { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                if skipDegraded && degraded && image != nil && !cancelled && !failed { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
