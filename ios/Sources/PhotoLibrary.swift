import Photos
import UIKit
import SwiftUI
import AVFoundation

/// Lazy access to a scope's photos. Backed by a PHFetchResult (no array built up
/// front, so opening 전체 사진 is instant), or by a pre-ordered array for 즐겨찾기.
struct GridSource {
    let count: Int
    private let provider: (Int) -> PHAsset
    private let warmed = WarmFlag()   // sources are memoized — warm exactly once
    init(count: Int, _ provider: @escaping (Int) -> PHAsset) { self.count = count; self.provider = provider }
    func asset(_ i: Int) -> PHAsset { provider(i) }

    private final class WarmFlag { var done = false }

    /// Resolve the backing fetch off the main thread so the first cell draw doesn't
    /// pay for it mid-slide. Safe to call before the grid renders. Idempotent:
    /// persistent tab panes re-init on every parent body eval and call this each
    /// time — only the first call spawns work.
    func warm() {
        guard count > 0, !warmed.done else { return }
        warmed.done = true
        Task.detached(priority: .userInitiated) { _ = self.asset(0) }
    }

    /// Lazily resolves a PHFetchResult on first access and memoizes it. Building a
    /// fetch (predicate over a big library) costs a few ms-to-tens-of-ms, so we
    /// defer it off the album-open's critical path: the grid only resolves it when
    /// the first cell actually draws, never on tap.
    final class LazyFetch {
        private let build: () -> PHFetchResult<PHAsset>
        private var cached: PHFetchResult<PHAsset>?
        private let lock = NSLock()
        init(_ build: @escaping () -> PHFetchResult<PHAsset>) { self.build = build }
        func get() -> PHFetchResult<PHAsset> {
            lock.lock(); defer { lock.unlock() }
            if let c = cached { return c }
            let r = build(); cached = r; return r
        }
    }

    /// Build a source backed by a lazily-resolved fetch. `count` is supplied up front
    /// (already known from the snapshot) so construction touches no PhotoKit at all.
    static func lazy(count: Int, _ build: @escaping () -> PHFetchResult<PHAsset>) -> GridSource {
        let lazy = LazyFetch(build)
        let n = count
        return GridSource(count: n) { i in lazy.get().object(at: min(i, max(n - 1, 0))) }
    }
}

/// Memoizes a built array on first access (e.g. the sorted 즐겨찾기 list).
final class LazyArray {
    private let build: () -> [PHAsset]
    private var cached: [PHAsset]?
    private let lock = NSLock()
    init(_ build: @escaping () -> [PHAsset]) { self.build = build }
    func get() -> [PHAsset] {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let a = build(); cached = a; return a
    }
}

/// How the user albums are ordered on the home.
enum AlbumSort: String, CaseIterable {
    case recent, name, count
    var label: String {
        switch self {
        case .recent: String(localized: "기본순")
        case .name: String(localized: "이름순")
        case .count: String(localized: "사진 많은순")
        }
    }
}

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
    var albumSort: AlbumSort = AlbumSort(rawValue: UserDefaults.standard.string(forKey: "lumen.albumSort") ?? "") ?? .recent {
        didSet {
            UserDefaults.standard.set(albumSort.rawValue, forKey: "lumen.albumSort")
            resortScopes()   // instant — just reorder, no re-fetch
        }
    }

    private func isSystemScope(_ s: OrganizeScope) -> Bool {
        guard let c = s.collection else { return true }          // 전체
        if c.localizedTitle == "Lumen" { return true }
        return c.assetCollectionSubtype != .albumRegular         // smart albums stay pinned
    }

    /// Reorder the user albums in place by the current sort — no PhotoKit re-fetch.
    private func resortScopes() {
        let system = scopes.filter { isSystemScope($0) }
        var user = scopes.filter { !isSystemScope($0) }
        switch albumSort {
        case .recent:
            var rank = [String: Int](); for (i, c) in albums.enumerated() { rank[c.localIdentifier] = i }
            user.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        case .name:  user.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .count: user.sort { $0.count > $1.count }
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { scopes = system + user }
    }

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
    let manager = PHCachingImageManager()        // shared with the grid so prewarming hits its cache

    private func saveFavoriteOrder() { UserDefaults.standard.set(favoriteOrder, forKey: "lumen.favoriteOrder") }

    /// Album-cover request size in points. Cards are ~165-250pt wide, so 220pt
    /// covers them at full sharpness — the old 300pt square decoded ~2x the pixels.
    static let coverPoints: CGFloat = 220

    /// Warm the cover-size thumbnail cache for an asset so it renders immediately.
    /// MUST mirror ScopeCard's request exactly (same target px AND same options) —
    /// PHCachingImageManager treats different options as different cache entries.
    private func prewarm(_ asset: PHAsset) {
        let px = Self.coverPoints * UIScreen.main.scale
        manager.startCachingImages(for: [asset], targetSize: CGSize(width: px, height: px),
                                   contentMode: .aspectFill, options: Self.viewerOptions())
    }

    /// Request options for grid thumbnails. Prewarming and the cells MUST use the
    /// SAME options or PHCachingImageManager treats them as different requests and
    /// the prewarm cache never gets hit (the grid then re-decodes everything).
    static func gridThumbOptions() -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }

    /// The target size a 4-column grid cell requests — prewarm must match it exactly.
    static var gridThumbTarget: CGSize {
        let edge = (UIScreen.main.bounds.width / 4) * UIScreen.main.scale
        return CGSize(width: edge, height: edge)
    }

    /// Full-screen viewer target = the actual screen in pixels. Requesting more
    /// (e.g. a square 1200pt → 3600px on 3x) decodes ~5-7x the pixels we can show,
    /// which is most of the per-swipe latency.
    static var viewerTarget: CGSize {
        let b = UIScreen.main.bounds.size, s = UIScreen.main.scale
        return CGSize(width: b.width * s, height: b.height * s)
    }

    /// Same rule as the grid: the viewer's prewarm and its on-screen request must
    /// share options + target or the cache is never hit.
    static func viewerOptions() -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }

    /// Assets currently warmed at viewer size. Viewer images are ~12MB each
    /// (full screen px), so photos we've swiped past MUST leave the cache —
    /// start-only caching grows by hundreds of MB over a long organize session.
    @ObservationIgnored private var viewerWarm: [String: PHAsset] = [:]

    /// Warm full-screen images for the photos around the one being viewed, so a
    /// swipe lands on an already-decoded (and, for iCloud, already-downloaded)
    /// image instead of a spinner. Keeps only the current window warm.
    func prewarmViewer(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        let newIDs = Set(assets.map(\.localIdentifier))
        let stale = viewerWarm.values.filter { !newIDs.contains($0.localIdentifier) }
        if !stale.isEmpty {
            manager.stopCachingImages(for: stale, targetSize: Self.viewerTarget,
                                      contentMode: .aspectFit, options: Self.viewerOptions())
        }
        viewerWarm = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        manager.startCachingImages(for: assets, targetSize: Self.viewerTarget,
                                   contentMode: .aspectFit, options: Self.viewerOptions())
    }

    /// First `limit` assets of a scope — computed OFF the main actor (the fetch +
    /// object materialization is the costly part on a big/iCloud library).
    nonisolated private static func prewarmAssets(scope: OrganizeScope, kept: Set<String>,
                                                  order: [String], limit: Int) -> [PHAsset] {
        let isLumen = scope.collection?.localizedTitle == "Lumen"
        let opts = isLumen ? imageOptions() : imageOptions(excluding: kept)
        if scope.collection?.assetCollectionSubtype == .smartAlbumFavorites, let c = scope.collection {
            var arr: [PHAsset] = []
            PHAsset.fetchAssets(in: c, options: opts).enumerateObjects { a, _, _ in arr.append(a) }
            return Array(ordered(arr, by: order).prefix(limit))
        }
        let result = scope.collection.map { PHAsset.fetchAssets(in: $0, options: opts) } ?? PHAsset.fetchAssets(with: opts)
        let n = min(result.count, limit)
        guard n > 0 else { return [] }
        return (0..<n).map { result.object(at: $0) }
    }

    /// Warm the first screenful of a scope's thumbnails. Runs entirely off the main
    /// thread so tapping an album NEVER blocks the open animation — the grid loads
    /// its visible cells lazily on its own; this just gives them a warm cache.
    func prewarmScope(_ scope: OrganizeScope) {
        let kept = keptIDs, order = favoriteOrder, mgr = manager
        let target = Self.gridThumbTarget, opts = Self.gridThumbOptions()
        Task.detached(priority: .userInitiated) {
            let assets = Self.prewarmAssets(scope: scope, kept: kept, order: order, limit: 40)
            guard !assets.isEmpty else { return }
            mgr.startCachingImages(for: assets, targetSize: target, contentMode: .aspectFill, options: opts)
        }
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
        // Only the 즐겨찾기 source bakes in the order — dropping ALL sources here
        // made every persistent pane rebuild + re-fetch on each ★ toggle.
        if let fav = scopes.first(where: { $0.collection?.assetCollectionSubtype == .smartAlbumFavorites }) {
            sourceCache.removeValue(forKey: fav.id)
        }

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
        let sort = albumSort
        let snap = await Task.detached(priority: .userInitiated) { Self.computeSnapshot(favoriteOrder: order, sort: sort) }.value
        // A favorite was toggled while we were computing — this snapshot is stale,
        // drop it and let the newer toggle's reload win (keeps the optimistic state).
        guard gen == favGen else { return }
        albums = snap.albums
        keptIDs = snap.keptIDs
        scopes = snap.scopes
        hasAnyPhotos = snap.hasAnyPhotos
        sourceCache.removeAll()   // sources captured the old keptIDs/order — rebuild lazily
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

    /// Photos AND videos, newest first, optionally excluding already-kept (Lumen)
    /// items via a predicate so PhotoKit computes count/firstObject without us
    /// enumerating.
    nonisolated private static func imageOptions(excluding kept: Set<String> = []) -> PHFetchOptions {
        let o = PHFetchOptions()
        let media = "(mediaType == %d OR mediaType == %d)"
        if kept.isEmpty {
            o.predicate = NSPredicate(format: media,
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        } else {
            o.predicate = NSPredicate(format: media + " AND NOT (localIdentifier IN %@)",
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue, Array(kept))
        }
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return o
    }

    /// Build the scope list off-main using only fetch counts + firstObject — no
    /// enumerating thousands of assets — so it stays fast on big/iCloud libraries.
    nonisolated private static func computeSnapshot(favoriteOrder: [String] = [], sort: AlbumSort = .recent) -> Snapshot {
        var albums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { c, _, _ in albums.append(c) }

        // Kept = members of the "Lumen" album (usually small).
        let lumenAlbum = albums.first(where: { $0.localizedTitle == "Lumen" })
        var keptIDs = Set<String>()
        if let lumen = lumenAlbum {
            PHAsset.fetchAssets(in: lumen, options: imageOptions()).enumerateObjects { a, _, _ in keptIDs.insert(a.localIdentifier) }
        }
        let opts = imageOptions(excluding: keptIDs)

        var out: [OrganizeScope] = []
        let all = PHAsset.fetchAssets(with: opts)
        let hasAny = all.count > 0
        if all.count > 0 {
            out.append(.init(id: "all", title: String(localized: "전체 사진"), symbol: "photo.on.rectangle",
                             count: all.count, collection: nil, cover: all.firstObject))
        }
        // Lumen (the keep destination) right next to 전체 — shows its own members.
        if let lumen = lumenAlbum {
            let r = PHAsset.fetchAssets(in: lumen, options: imageOptions())
            if r.count > 0 {
                out.append(.init(id: lumen.localIdentifier, title: "Lumen", symbol: "tray.full.fill",
                                 count: r.count, collection: lumen, cover: r.firstObject))
            }
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
        smart(.smartAlbumFavorites, String(localized: "즐겨찾기"), "heart", order: favoriteOrder)
        smart(.smartAlbumRecentlyAdded, String(localized: "최근 추가"), "clock")
        smart(.smartAlbumScreenshots, String(localized: "스크린샷"), "camera.viewfinder")
        smart(.smartAlbumVideos, String(localized: "동영상"), "video")

        // User albums (Lumen already shown above), in the chosen order.
        var entries = albums.filter { $0.localizedTitle != "Lumen" }
            .map { (c: $0, r: PHAsset.fetchAssets(in: $0, options: opts)) }
            .filter { $0.r.count > 0 }
        switch sort {
        case .recent: break
        case .name:  entries.sort { ($0.c.localizedTitle ?? "") < ($1.c.localizedTitle ?? "") }
        case .count: entries.sort { $0.r.count > $1.r.count }
        }
        for e in entries {
            out.append(.init(id: e.c.localIdentifier, title: e.c.localizedTitle ?? String(localized: "이름 없는 앨범"), symbol: "rectangle.stack",
                             count: e.r.count, collection: e.c, cover: e.r.firstObject))
        }
        return Snapshot(albums: albums, keptIDs: keptIDs, scopes: out, hasAnyPhotos: hasAny)
    }

    /// Memoized per-scope sources: the persistent tab panes (and re-opened albums)
    /// re-ask for the same scope's source on every body evaluation — handing back
    /// the already-resolved fetch makes that free, instead of re-resolving a 60k
    /// fetch each time. Cleared whenever the library snapshot changes.
    @ObservationIgnored private var sourceCache: [String: GridSource] = [:]

    /// The asset list for a scope, already-kept photos removed. Fetched off-main so
    /// tapping a scope opens without freezing.
    func gridSource(for scope: OrganizeScope) -> GridSource {
        if let s = sourceCache[scope.id], s.count == scope.count { return s }
        let s = makeGridSource(for: scope)
        sourceCache[scope.id] = s
        return s
    }

    /// A guaranteed-fresh source (drops the memoized one) — used right after an
    /// organize session so the grid reflects deletions/un-favorites immediately,
    /// without waiting for PhotoKit's change notification.
    func freshGridSource(for scope: OrganizeScope) -> GridSource {
        sourceCache[scope.id] = nil
        return gridSource(for: scope)
    }

    /// A lazy source for a scope. Non-favorites use the PHFetchResult directly
    /// (instant — no enumeration), so opening a big album doesn't show a loader.
    /// 즐겨찾기 needs custom order, so it materializes its (small) list.
    private func makeGridSource(for scope: OrganizeScope) -> GridSource {
        // The Lumen album IS the kept photos, so don't exclude them there.
        let isLumen = scope.collection?.localizedTitle == "Lumen"
        let kept = keptIDs
        let order = favoriteOrder
        let coll = scope.collection
        if coll?.assetCollectionSubtype == .smartAlbumFavorites, let c = coll {
            // 즐겨찾기 needs our custom order, so materialize its (small) list — but
            // lazily and memoized, so the fetch+sort happens once on first draw,
            // not on tap and not per cell.
            let box = LazyArray {
                var arr: [PHAsset] = []
                PHAsset.fetchAssets(in: c, options: Self.imageOptions(excluding: kept))
                    .enumerateObjects { a, _, _ in arr.append(a) }
                return Self.ordered(arr, by: order)
            }
            return GridSource(count: scope.count) { i in
                let a = box.get()
                return a[min(i, max(a.count - 1, 0))]
            }
        }
        // Everything else: lazily-resolved PHFetchResult. Construction touches no
        // PhotoKit at all (count is the already-known scope.count), so opening even a
        // 60k album never blocks the tap — the fetch resolves when the first cell draws.
        return GridSource.lazy(count: scope.count) {
            let opts = isLumen ? Self.imageOptions() : Self.imageOptions(excluding: kept)
            return coll.map { PHAsset.fetchAssets(in: $0, options: opts) } ?? PHAsset.fetchAssets(with: opts)
        }
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

    /// AVPlayerItem for a video asset, downloading from iCloud if needed.
    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { c in
            let o = PHVideoRequestOptions()
            o.isNetworkAccessAllowed = true
            o.deliveryMode = .automatic
            manager.requestPlayerItem(forVideo: asset, options: o) { item, _ in
                c.resume(returning: item)
            }
        }
    }

    /// Undo helper: pull a photo back out of the Lumen album. Never creates the
    /// album — if it doesn't exist, there's nothing to remove from.
    func removeFromLumen(_ asset: PHAsset) async {
        if lumenCollection == nil { lumenCollection = albums.first(where: { $0.localizedTitle == "Lumen" }) }
        guard let c = lumenCollection else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: c)?.removeAssets([asset] as NSArray)
        }
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
        return imageStream(asset, target: CGSize(width: px, height: px), mode: mode)
    }

    /// Same stream with an exact pixel target — the viewer uses `viewerTarget` here
    /// so its requests hit the `prewarmViewer` cache.
    func imageStream(_ asset: PHAsset, target: CGSize, mode: PHImageContentMode) -> AsyncStream<UIImage> {
        let mgr = manager
        return AsyncStream { continuation in
            let opt = Self.viewerOptions()             // opportunistic + network + fast
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
