import Photos
import UIKit

/// A pickable bundle to organize (all photos, a smart album, or a user album).
struct OrganizeScope: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let count: Int
    let collection: PHAssetCollection?   // nil = all photos
    let cover: PHAsset?

    // Include cover/count so a changed cover actually re-renders the card.
    // (hash stays id-only — equal scopes still share an id, which is all Hashable needs.)
    static func == (a: OrganizeScope, b: OrganizeScope) -> Bool {
        a.id == b.id && a.count == b.count && a.cover?.localIdentifier == b.cover?.localIdentifier
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Loads the device photo library (PhotoKit) and serves thumbnails / full images.
/// This is the iOS equivalent of the macOS scanner — the app's library source.
@MainActor @Observable final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    var albums: [PHAssetCollection] = []
    var scopes: [OrganizeScope] = []
    var hasAnyPhotos = false
    var authorized = false
    var loaded = false

    /// localIdentifiers already filed into "Lumen". Cached from the last snapshot so
    /// scope filtering never re-hits PhotoKit on the main thread.
    @ObservationIgnored private var keptIDs: Set<String> = []
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// localIdentifiers in the order they were favorited (most recent first).
    /// PhotoKit doesn't expose a "date favorited", so we record it ourselves and
    /// persist it, to show 즐겨찾기 newest-favorited-first.
    @ObservationIgnored private var favoriteOrder: [String] =
        UserDefaults.standard.stringArray(forKey: "lumen.favoriteOrder") ?? []
    @ObservationIgnored private var favGen = 0   // bumped on every toggle, to drop stale reloads
    private let manager = PHCachingImageManager()

    private func saveFavoriteOrder() { UserDefaults.standard.set(favoriteOrder, forKey: "lumen.favoriteOrder") }

    /// Warm the cover-size thumbnail cache for an asset so it renders immediately.
    private func prewarm(_ asset: PHAsset) {
        let px = 300 * UIScreen.main.scale
        manager.startCachingImages(for: [asset], targetSize: CGSize(width: px, height: px),
                                   contentMode: .aspectFill, options: nil)
    }

    /// Sort assets so the ones in `order` come first (in that order), rest after.
    nonisolated private static func ordered(_ assets: [PHAsset], by order: [String]) -> [PHAsset] {
        guard !order.isEmpty else { return assets }
        var rank = [String: Int](); for (i, id) in order.enumerated() { rank[id] = i }
        return assets.enumerated().sorted {
            (rank[$0.element.localIdentifier] ?? Int.max, $0.offset) < (rank[$1.element.localIdentifier] ?? Int.max, $1.offset)
        }.map { $0.element }
    }

    override init() { super.init() }

    func load() async {
        // Only prompt when the user hasn't decided yet — re-requesting an already
        // granted/denied library just re-shows the system sheet needlessly.
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await withCheckedContinuation { c in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
            }
        }
        authorized = (status == .authorized || status == .limited)
        // Populate scopes BEFORE marking loaded, so the home never flashes the
        // "사진이 없어요" empty state while photos are still being fetched.
        if authorized {
            await reload()
            if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        }
        loaded = true
    }

    /// PhotoKit changed (a favorite toggled, a photo deleted, an external edit) —
    /// rebuild so covers/counts stay fresh. Debounced to coalesce bursts.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard authorized else { return }
            reloadTask?.cancel()
            reloadTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }

    /// Re-read the library (after an organize session: new "Lumen" album, changed
    /// counts, deletions). Runs the fetch off-main so returning home never stutters.
    func refresh() {
        guard authorized else { return }
        Task { await reload() }
    }

    /// Instant, optimistic update of the 즐겨찾기 scope cover/count right when the
    /// user toggles a favorite, so the home reflects it immediately instead of
    /// waiting for PhotoKit's notification + a full reload. The reload still runs
    /// afterwards to make counts/order exact.
    func bumpFavorite(_ asset: PHAsset, added: Bool) {
        favGen += 1
        let id = asset.localIdentifier
        favoriteOrder.removeAll { $0 == id }
        if added { favoriteOrder.insert(id, at: 0) }     // most-recent favorite first
        saveFavoriteOrder()

        guard let i = scopes.firstIndex(where: { $0.collection?.assetCollectionSubtype == .smartAlbumFavorites })
        else { return }
        let s = scopes[i]
        if added {
            scopes[i] = OrganizeScope(id: s.id, title: s.title, symbol: s.symbol,
                                      count: s.count + 1, collection: s.collection, cover: asset)
        } else if max(0, s.count - 1) == 0 {
            scopes.remove(at: i)                          // no favorites left → drop the scope
        } else {
            // Re-pick the cover as the newest remaining favorite (excluding this one).
            var cover = s.cover
            if s.cover?.localIdentifier == id {
                cover = favoriteOrder.first.flatMap {
                    PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
                }
                if cover == nil, let c = s.collection {
                    PHAsset.fetchAssets(in: c, options: Self.imageOptions()).enumerateObjects { a, _, stop in
                        if a.localIdentifier != id { cover = a; stop.pointee = true }
                    }
                }
                if let cover { prewarm(cover) }   // cache the new cover so it appears instantly
            }
            scopes[i] = OrganizeScope(id: s.id, title: s.title, symbol: s.symbol,
                                      count: s.count - 1, collection: s.collection, cover: cover)
        }
    }

    /// All the PhotoKit work happens on a background thread; only the final
    /// assignment of published state touches the main actor.
    private func reload() async {
        let gen = favGen
        let order = favoriteOrder
        let snap = await Task.detached(priority: .userInitiated) { Self.computeSnapshot(favoriteOrder: order) }.value
        // A favorite was toggled while we were computing — this snapshot is stale,
        // drop it and let the newer toggle's reload win (keeps the optimistic state).
        guard gen == favGen else { return }
        albums = snap.albums
        keptIDs = snap.keptIDs
        scopes = snap.scopes
        hasAnyPhotos = snap.hasAnyPhotos
        // Keep the next few 즐겨찾기 covers warm so un-favoriting swaps instantly.
        favoriteOrder.prefix(3)
            .compactMap { PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject }
            .forEach { prewarm($0) }
    }

    // MARK: - Snapshot (built off the main thread)

    private struct Snapshot {
        var albums: [PHAssetCollection]
        var keptIDs: Set<String>
        var scopes: [OrganizeScope]
        var hasAnyPhotos: Bool
    }

    /// Images only, newest first, optionally excluding already-kept (Lumen) photos
    /// via a predicate so PhotoKit computes count/firstObject without us enumerating.
    nonisolated private static func imageOptions(excluding kept: Set<String> = []) -> PHFetchOptions {
        let o = PHFetchOptions()
        if kept.isEmpty {
            o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        } else {
            o.predicate = NSPredicate(format: "mediaType == %d AND NOT (localIdentifier IN %@)",
                                      PHAssetMediaType.image.rawValue, Array(kept))
        }
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return o
    }

    /// Build the scope list off-main using only fetch counts + firstObject — no
    /// enumerating thousands of assets — so it stays fast on big/iCloud libraries.
    nonisolated private static func computeSnapshot(favoriteOrder: [String] = []) -> Snapshot {
        var albums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { c, _, _ in albums.append(c) }

        // Kept = members of the "Lumen" album (usually small).
        var keptIDs = Set<String>()
        if let lumen = albums.first(where: { $0.localizedTitle == "Lumen" }) {
            PHAsset.fetchAssets(in: lumen, options: imageOptions()).enumerateObjects { a, _, _ in keptIDs.insert(a.localIdentifier) }
        }
        let opts = imageOptions(excluding: keptIDs)

        var out: [OrganizeScope] = []
        let all = PHAsset.fetchAssets(with: opts)
        let hasAny = all.count > 0
        if all.count > 0 {
            out.append(.init(id: "all", title: "전체 사진", symbol: "photo.on.rectangle",
                             count: all.count, collection: nil, cover: all.firstObject))
        }

        func smart(_ subtype: PHAssetCollectionSubtype, _ title: String, _ symbol: String, order: [String] = []) {
            guard let c = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
            else { return }
            let r = PHAsset.fetchAssets(in: c, options: opts)
            guard r.count > 0 else { return }
            // Favorites: trust our own order for the cover so a just-toggled favorite
            // (whose async commit may not be in this fetch yet) still shows correctly.
            var cover = r.firstObject
            if let top = order.first, let a = PHAsset.fetchAssets(withLocalIdentifiers: [top], options: nil).firstObject {
                cover = a
            }
            out.append(.init(id: c.localIdentifier, title: title, symbol: symbol,
                             count: r.count, collection: c, cover: cover))
        }
        smart(.smartAlbumFavorites, "즐겨찾기", "heart", order: favoriteOrder)
        smart(.smartAlbumRecentlyAdded, "최근 추가", "clock")
        smart(.smartAlbumScreenshots, "스크린샷", "camera.viewfinder")

        // Skip the Lumen album itself — it's the destination, not a queue to sort.
        for c in albums where c.localizedTitle != "Lumen" {
            let r = PHAsset.fetchAssets(in: c, options: opts)
            if r.count > 0 {
                out.append(.init(id: c.localIdentifier, title: c.localizedTitle ?? "앨범", symbol: "rectangle.stack",
                                 count: r.count, collection: c, cover: r.firstObject))
            }
        }
        return Snapshot(albums: albums, keptIDs: keptIDs, scopes: out, hasAnyPhotos: hasAny)
    }

    /// The asset list for a scope, already-kept photos removed. Fetched off-main so
    /// tapping a scope opens without freezing.
    func assets(for scope: OrganizeScope) async -> [PHAsset] {
        let kept = keptIDs
        let collection = scope.collection
        let order = (scope.collection?.assetCollectionSubtype == .smartAlbumFavorites) ? favoriteOrder : []
        return await Task.detached(priority: .userInitiated) {
            let opts = Self.imageOptions(excluding: kept)
            let result = collection.map { PHAsset.fetchAssets(in: $0, options: opts) } ?? PHAsset.fetchAssets(with: opts)
            var arr: [PHAsset] = []
            arr.reserveCapacity(result.count)
            result.enumerateObjects { a, _, _ in arr.append(a) }
            return order.isEmpty ? arr : Self.ordered(arr, by: order)
        }.value
    }

    // MARK: - Albums (organize destination)

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

    /// Add a photo to the Lumen album right away (create it the first time), so the
    /// album exists during the session — no need to wait for a summary "apply".
    @ObservationIgnored private var lumenCollection: PHAssetCollection?
    func addToLumen(_ asset: PHAsset) async {
        if lumenCollection == nil { lumenCollection = await lumenAlbum() }
        guard let c = lumenCollection else { return }
        await addAssets([asset], to: c)
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

    /// Progressive image stream — yields a fast (possibly degraded, local) image
    /// first, then the full-quality one, downloading from iCloud if needed. Use it
    /// while browsing so iCloud photos show a thumbnail immediately instead of a
    /// blank grey box.
    func imageStream(_ asset: PHAsset, points: CGFloat, mode: PHImageContentMode) -> AsyncStream<UIImage> {
        let px = points * UIScreen.main.scale
        let target = CGSize(width: px, height: px)
        let mgr = manager
        return AsyncStream { continuation in
            let opt = PHImageRequestOptions()
            opt.deliveryMode = .opportunistic          // fast local thumb → then full
            opt.isNetworkAccessAllowed = true          // download iCloud originals
            opt.resizeMode = .fast
            let id = mgr.requestImage(for: asset, targetSize: target, contentMode: mode, options: opt) { img, info in
                if let img { continuation.yield(img) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let done = info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) ?? false
                if !degraded || done { continuation.finish() }
            }
            continuation.onTermination = { _ in mgr.cancelImageRequest(id) }
        }
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
