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
    var assets: [PHAsset] = []
    var albums: [PHAssetCollection] = []
    var scopes: [OrganizeScope] = []
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
        let order = favoriteOrder
        let snap = await Task.detached(priority: .userInitiated) { Self.computeSnapshot(favoriteOrder: order) }.value
        assets = snap.assets
        albums = snap.albums
        keptIDs = snap.keptIDs
        scopes = snap.scopes
        // Keep the next few 즐겨찾기 covers warm so un-favoriting swaps instantly.
        favoriteOrder.prefix(3)
            .compactMap { PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject }
            .forEach { prewarm($0) }
    }

    // MARK: - Snapshot (built off the main thread)

    private struct Snapshot {
        var assets: [PHAsset]
        var albums: [PHAssetCollection]
        var keptIDs: Set<String>
        var scopes: [OrganizeScope]
    }

    nonisolated private static func imageOptions() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return o
    }

    nonisolated private static func fetchAll(in collection: PHAssetCollection) -> [PHAsset] {
        var arr: [PHAsset] = []
        PHAsset.fetchAssets(in: collection, options: imageOptions()).enumerateObjects { a, _, _ in arr.append(a) }
        return arr
    }

    /// Read everything we need in one off-main pass: all photos, the album list,
    /// the "already kept" id set, and the resulting scopes (kept photos removed so
    /// an interrupted session resumes instead of restarting).
    nonisolated private static func computeSnapshot(favoriteOrder: [String] = []) -> Snapshot {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var allAssets: [PHAsset] = []
        PHAsset.fetchAssets(with: .image, options: opts).enumerateObjects { a, _, _ in allAssets.append(a) }

        var albums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { c, _, _ in albums.append(c) }

        var keptIDs = Set<String>()
        if let lumen = albums.first(where: { $0.localizedTitle == "Lumen" }) {
            fetchAll(in: lumen).forEach { keptIDs.insert($0.localIdentifier) }
        }
        func remaining(_ list: [PHAsset]) -> [PHAsset] { list.filter { !keptIDs.contains($0.localIdentifier) } }

        var out: [OrganizeScope] = []
        let allRemaining = remaining(allAssets)
        if !allRemaining.isEmpty {
            out.append(.init(id: "all", title: "전체 사진", symbol: "photo.on.rectangle",
                             count: allRemaining.count, collection: nil, cover: allRemaining.first))
        }

        func smart(_ subtype: PHAssetCollectionSubtype, _ title: String, _ symbol: String, order: [String] = []) {
            guard let c = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
            else { return }
            var rem = remaining(fetchAll(in: c))
            if !order.isEmpty { rem = ordered(rem, by: order) }   // favorites: newest-favorited first
            if !rem.isEmpty {
                out.append(.init(id: c.localIdentifier, title: title, symbol: symbol,
                                 count: rem.count, collection: c, cover: rem.first))
            }
        }
        smart(.smartAlbumFavorites, "즐겨찾기", "heart", order: favoriteOrder)
        smart(.smartAlbumRecentlyAdded, "최근 추가", "clock")
        smart(.smartAlbumScreenshots, "스크린샷", "camera.viewfinder")

        // Skip the Lumen album itself — it's the destination, not a queue to sort.
        for c in albums where c.localizedTitle != "Lumen" {
            let rem = remaining(fetchAll(in: c))
            if !rem.isEmpty {
                out.append(.init(id: c.localIdentifier, title: c.localizedTitle ?? "앨범", symbol: "rectangle.stack",
                                 count: rem.count, collection: c, cover: rem.first))
            }
        }
        return Snapshot(assets: allAssets, albums: albums, keptIDs: keptIDs, scopes: out)
    }

    /// The asset list for a scope, already-kept photos removed. Fetched off-main so
    /// tapping a scope opens without freezing.
    func assets(for scope: OrganizeScope) async -> [PHAsset] {
        let kept = keptIDs
        let collection = scope.collection
        let base = assets
        let order = (scope.collection?.assetCollectionSubtype == .smartAlbumFavorites) ? favoriteOrder : []
        return await Task.detached(priority: .userInitiated) {
            let source = collection.map { Self.fetchAll(in: $0) } ?? base
            let filtered = source.filter { !kept.contains($0.localIdentifier) }
            return order.isEmpty ? filtered : Self.ordered(filtered, by: order)
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
