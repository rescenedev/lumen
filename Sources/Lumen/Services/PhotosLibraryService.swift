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

/// A Photos-library album (user album or the Favorites smart album), surfaced to
/// the sidebar without leaking PhotoKit types into the view layer.
struct PhotosAlbumRef: Identifiable, Hashable {
    let id: String          // PHAssetCollection.localIdentifier
    let title: String
    let count: Int          // image count
    let isFavorites: Bool
}

/// Thin wrapper over PhotoKit for reading the system Photos library (which syncs
/// with iCloud Photos). Read-only; images only (no video in Phase 1).
enum PhotosLibraryService {
    // Cache the album collections from `fetchAlbums` so opening one doesn't
    // re-fetch by localIdentifier — which is unreliable for *smart* albums
    // (e.g. Favorites), returning nil and an empty grid.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var collectionsById: [String: PHAssetCollection] = [:]

    // Synchronous accessors: NSLock.lock/unlock are `noasync`, so the async
    // fetch closures go through these instead of locking inline.
    private static func cacheCollections(_ collected: [String: PHAssetCollection]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        collectionsById = collected
    }

    private static func cachedCollection(_ id: String) -> PHAssetCollection? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return collectionsById[id]
    }

    // Per-album fetch result cache. Re-entering an album (after visiting
    // others) otherwise re-runs the PhotoKit query every time — measured
    // 120→400ms per open. Invalidated wholesale on any library change via
    // PhotosLibraryObserver. LRU-bounded so memory stays flat.
    nonisolated(unsafe) private static var assetCache: [String: [Photo]] = [:]
    nonisolated(unsafe) private static var assetCacheOrder: [String] = []
    private static let assetCacheLimit = 12

    private static func cachedAssets(_ id: String) -> [Photo]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return assetCache[id]
    }

    private static func storeAssets(_ id: String, _ photos: [Photo]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if assetCache[id] == nil { assetCacheOrder.append(id) }
        assetCache[id] = photos
        if assetCacheOrder.count > assetCacheLimit {
            assetCache.removeValue(forKey: assetCacheOrder.removeFirst())
        }
    }

    /// Drop the album fetch cache (PhotoKit library changed, or a forced refresh).
    static func invalidateAssetCache() {
        cacheLock.lock(); assetCache.removeAll(); assetCacheOrder.removeAll(); cacheLock.unlock()
    }
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

    /// List the Favorites smart album + user albums that contain images.
    static func fetchAlbums() async -> [PhotosAlbumRef] {
        await Task.detached(priority: .userInitiated) {
            let imageOnly = PHFetchOptions()
            imageOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

            var refs: [PhotosAlbumRef] = []
            var collected: [String: PHAssetCollection] = [:]
            func add(_ collection: PHAssetCollection, isFavorites: Bool) {
                let count = PHAsset.fetchAssets(in: collection, options: imageOnly).count
                guard count > 0 else { return }
                collected[collection.localIdentifier] = collection
                refs.append(PhotosAlbumRef(id: collection.localIdentifier,
                                           title: collection.localizedTitle ?? "Untitled",
                                           count: count, isFavorites: isFavorites))
            }

            // Favorites first, then user albums alphabetically.
            let faves = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            faves.enumerateObjects { c, _, _ in add(c, isFavorites: true) }

            var userAlbums: [PHAssetCollection] = []
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                .enumerateObjects { c, _, _ in userAlbums.append(c) }
            for c in userAlbums.sorted(by: {
                ($0.localizedTitle ?? "").localizedStandardCompare($1.localizedTitle ?? "") == .orderedAscending
            }) { add(c, isFavorites: false) }

            cacheCollections(collected)
            return refs
        }.value
    }

    /// Fetch the image assets in one album (newest first) as synthetic-URL
    /// `Photo`s, registering their PHAssets with the image loader.
    static func fetchAssets(inAlbumId id: String) async -> [Photo] {
        if let hit = cachedAssets(id) { return hit }   // skip the PhotoKit query on re-entry
        return await Task.detached(priority: .userInitiated) {
            let cached = cachedCollection(id)
            let collection = cached ?? PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil).firstObject
            guard let collection else { return [] }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let result = PHAsset.fetchAssets(in: collection, options: options)

            var photos: [Photo] = []
            var assetsById: [String: PHAsset] = [:]
            photos.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                photos.append(Photo.asset(localIdentifier: asset.localIdentifier,
                                          creationDate: asset.creationDate,
                                          modificationDate: asset.modificationDate))
                assetsById[asset.localIdentifier] = asset
            }
            PhotosImageLoader.shared.register(assetsById)
            Self.storeAssets(id, photos)
            return photos
        }.value
    }
}

/// Observes the system Photos library and drops Lumen's album fetch cache on
/// any change, so a photo added/removed in Photos is reflected on next open.
/// PhotoKit calls back on a private queue; `invalidateAssetCache` is lock-guarded.
final class PhotosLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotosLibraryObserver()
    private var registered = false

    func start() {
        guard !registered else { return }
        registered = true
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        PhotosLibraryService.invalidateAssetCache()
    }
}
