import AppKit
import Photos
import UniformTypeIdentifiers

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

    /// The PHAsset behind a synthetic asset URL. Exposed so the exporter can
    /// reach the asset's resources without duplicating the id→asset cache.
    func phAsset(for url: URL) -> PHAsset? { asset(for: url) }

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

    /// Rich metadata for an asset, read from PhotoKit (and iCloud on demand).
    /// Dimensions/dates/size/kind come from the asset + its resource (instant);
    /// camera EXIF & GPS come from the image data (may download from iCloud).
    func metadata(for url: URL) async -> ImageMetadata {
        guard let asset = asset(for: url) else { return ImageMetadata() }
        var meta = ImageMetadata()
        meta.pixelWidth = asset.pixelWidth
        meta.pixelHeight = asset.pixelHeight
        meta.sourceLabel = "Apple Photos"
        if let loc = asset.location {
            meta.gpsCoordinate = (loc.coordinate.latitude, loc.coordinate.longitude)
        }
        // Original filename, type and byte size from the primary resource.
        if let resource = PHAssetResource.assetResources(for: asset).first {
            meta.kind = (resource.uniformTypeIdentifier as String?)
                .flatMap { UTType($0)?.preferredFilenameExtension?.uppercased() }
                ?? (resource.originalFilename as NSString).pathExtension.uppercased()
            if let size = resource.value(forKey: "fileSize") as? Int64 { meta.byteSize = size }
        }
        // EXIF/camera from the image data (network allowed for iCloud-only assets).
        if let data = await imageData(asset) {
            let exif = MetadataReader.read(data: data)
            // Keep PhotoKit's dimensions/size/kind; fold in the camera + GPS fields.
            meta.cameraMake = exif.cameraMake; meta.cameraModel = exif.cameraModel
            meta.lens = exif.lens; meta.focalLength = exif.focalLength
            meta.aperture = exif.aperture; meta.shutterSpeed = exif.shutterSpeed
            meta.iso = exif.iso; meta.dateTaken = exif.dateTaken
            if meta.gpsCoordinate == nil { meta.gpsCoordinate = exif.gpsCoordinate }
            if meta.byteSize == nil { meta.byteSize = Int64(data.count) }
        }
        return meta
    }

    /// Fetch an asset's image data (original), allowing iCloud download.
    private func imageData(_ asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            // PhotoKit may invoke this handler on an arbitrary (and, across
            // degraded/final deliveries, potentially concurrent) thread, so the
            // resume-once guard must be synchronized — a plain `var` is a data race.
            let lock = NSLock()
            var resumed = false
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                lock.lock()
                if resumed { lock.unlock(); return }
                resumed = true
                lock.unlock()
                continuation.resume(returning: data)
            }
        }
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
            // Synchronize the resume-once guard: the handler can fire on any
            // thread and, for degraded+final deliveries, concurrently — an
            // unsynchronized `var` is a data race (and could double-resume).
            let lock = NSLock()
            var resumed = false
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                // Wait past the low-quality placeholder, but only when a real
                // final frame is still coming (image present, not cancelled/failed).
                if skipDegraded && degraded && image != nil && !cancelled && !failed { return }
                lock.lock()
                if resumed { lock.unlock(); return }
                resumed = true
                lock.unlock()
                continuation.resume(returning: image)
            }
        }
    }
}
