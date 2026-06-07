import Photos

/// Coarse access state for the Photos library, surfaced to the UI without
/// leaking PhotoKit types into the view layer.
enum PhotosAccessState: Equatable {
    case unknown      // not requested yet
    case loading      // request / fetch in flight
    case authorized   // full access
    case limited      // user granted a subset
    case denied       // denied or restricted
}

/// Thin wrapper over PhotoKit for reading the system Photos library (which syncs
/// with iCloud Photos). Read-only; images only (no video in Phase 1).
enum PhotosLibraryService {
    /// Request library access, returning the resulting authorization status.
    static func authorize() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Fetch every image asset as a synthetic-URL `Photo` (newest first) and
    /// register the PHAssets with the image loader. Runs off the main thread.
    static func fetchAllImages() async -> [Photo] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: options)

            var photos: [Photo] = []
            var assetsById: [String: PHAsset] = [:]
            photos.reserveCapacity(result.count)
            assetsById.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                photos.append(Photo.asset(localIdentifier: asset.localIdentifier,
                                          creationDate: asset.creationDate,
                                          modificationDate: asset.modificationDate))
                assetsById[asset.localIdentifier] = asset
            }
            PhotosImageLoader.shared.register(assetsById)
            return photos
        }.value
    }
}
