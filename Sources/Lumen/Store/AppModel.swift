import AppKit
import SwiftUI
import Observation
import Photos

/// Central observable state for the whole app.
@MainActor
@Observable
final class AppModel {
    // Library
    private(set) var allPhotos: [Photo] = [] { didSet { libraryVersion &+= 1 } }
    private(set) var rootFolders: [URL] = []
    var isScanning = false
    private(set) var isLoadingLibrary = false

    // Photos Library (Apple Photos / iCloud) — kept physically separate from the
    // file/NAS `allPhotos` so reconcile/folder-tree/watcher never touch assets.
    private(set) var assetPhotos: [Photo] = [] { didSet { assetsVersion &+= 1 } }
    private(set) var photosAccess: PhotosAccessState = .unknown
    private(set) var photosAlbums: [PhotosAlbumRef] = []
    // Assets of the currently-open Photos album (loaded lazily on selection).
    // Observed (NOT @ObservationIgnored) so the grid refreshes when it lands.
    private var assetAlbumPhotos: [Photo] = [] { didSet { assetsVersion &+= 1 } }
    @ObservationIgnored private var currentAssetAlbumId: String?

    // Cheap monotonic counters used to invalidate memoized derived collections.
    @ObservationIgnored private var libraryVersion = 0
    @ObservationIgnored private var albumsVersion = 0
    @ObservationIgnored private var indexVersion = 0
    @ObservationIgnored private var assetsVersion = 0

    // Navigation / filtering
    /// What the sidebar highlights — updates instantly so keyboard navigation
    /// stays responsive.
    var selectedSidebar: SidebarItem = .allPhotos {
        didSet { scheduleSidebarCommit() }
    }
    /// What the grid actually shows — debounced, so arrowing through folders
    /// doesn't recompute/redraw the grid on every transient selection.
    private(set) var committedSidebar: SidebarItem = .allPhotos {
        didSet {
            switch committedSidebar {
            case .photosLibrary: loadPhotosLibraryIfNeeded()
            case .photosAlbum(let id): loadPhotosAlbum(id)
            default: break
            }
        }
    }
    @ObservationIgnored private var sidebarCommitWork: DispatchWorkItem?

    private func scheduleSidebarCommit() {
        guard selectedSidebar != committedSidebar else { return }
        sidebarCommitWork?.cancel()
        let target = selectedSidebar
        let work = DispatchWorkItem { [weak self] in self?.committedSidebar = target }
        sidebarCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Photos to draw from for the current scope: a Photos album, the whole Apple
    /// Photos library, or the file/NAS library.
    private var sourcePhotos: [Photo] {
        switch committedSidebar {
        case .photosAlbum: return assetAlbumPhotos
        case .photosLibrary: return assetPhotos
        default: return allPhotos
        }
    }

    /// Lazily request access and load the Photos library (and album list) the
    /// first time a Photos source is opened. Idempotent; safe to call repeatedly.
    func loadPhotosLibraryIfNeeded() {
        guard assetPhotos.isEmpty, photosAccess != .loading, photosAccess != .denied else { return }
        photosAccess = .loading
        Task {
            let status = await PhotosLibraryService.authorize()
            switch status {
            case .authorized, .limited:
                let photos = await PhotosLibraryService.fetchAllImages()
                self.assetPhotos = photos
                self.photosAccess = (status == .limited) ? .limited : .authorized
                self.photosAlbums = await PhotosLibraryService.fetchAlbums()
            default:
                self.photosAccess = .denied
            }
        }
    }

    /// Load one Photos album's assets on demand (cached per album id).
    func loadPhotosAlbum(_ id: String) {
        if photosAccess == .unknown { loadPhotosLibraryIfNeeded() }
        guard currentAssetAlbumId != id else { return }
        currentAssetAlbumId = id
        assetAlbumPhotos = []
        Task {
            let photos = await PhotosLibraryService.fetchAssets(inAlbumId: id)
            if self.currentAssetAlbumId == id { self.assetAlbumPhotos = photos }
        }
    }
    var sortOrder: SortOrder = .dateNewest
    var searchText = ""
    var thumbnailSize: Double = 320
    var filter = FilterState()
    var groupByMonth = false

    // Presentation + multi-selection
    var viewMode: ViewMode = .grid { didSet { persistSettings() } }
    var selection: Set<Photo.ID> = []
    var selectionAnchor: Photo.ID?

    // Viewer
    var viewerPhotos: [Photo] = []
    var viewerIndex: Int?
    var showExifOverlay = false
    var compareSecondary: Photo?

    // Deletion
    var photosPendingDeletion: [Photo] = []
    var showDeleteConfirmation = false

    // Sheets / dialogs
    var showNewAlbumSheet = false
    var newAlbumNameDraft = ""
    @ObservationIgnored private var newAlbumPhotos: [Photo] = []
    var showRenameSheet = false
    var renameTargets: [Photo] = []
    var showAbout = false
    var showShortcuts = false

    // Crop & resize editor (non-destructive by default).
    var editTarget: Photo?
    var showEditor = false

    /// Open the crop/resize editor for a file-backed photo. Apple Photos assets
    /// have no editable file, so they're skipped.
    func startEdit(_ photo: Photo) {
        guard !photo.isAsset else { showToast("Apple Photos 항목은 편집할 수 없습니다 (파일 사진만 가능)."); return }
        editTarget = photo
        showEditor = true
    }

    // Combine multiple photos into one (non-destructive → new file).
    var combineTargets: [Photo] = []
    var showCombine = false

    func startCombine(_ photos: [Photo]) {
        let files = photos.filter { !$0.isAsset }
        guard files.count >= 2 else {
            showToast("합치려면 파일 사진 2장 이상을 선택하세요.")
            return
        }
        combineTargets = files
        showCombine = true
    }

    func didCombine(output: URL) {
        revealNewFile(output)
        showToast("합친 이미지 저장됨 · \(output.deletingLastPathComponent().lastPathComponent)/\(output.lastPathComponent)")
    }

    // Batch resize/canvas → export many photos at once (non-destructive copies).
    var batchTargets: [Photo] = []
    var showBatchResize = false

    func startBatchResize(_ photos: [Photo]) {
        let files = photos.filter { !$0.isAsset }
        guard !files.isEmpty else {
            showToast("리사이즈할 파일 사진을 선택하세요 (Apple Photos 제외).")
            return
        }
        batchTargets = files
        showBatchResize = true
    }

    func didBatchResize(count: Int, folder: URL) {
        showToast("\(count)장 내보냄 · \(folder.lastPathComponent)")
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Make a just-written file visible: add it to the library, jump to All Photos
    /// (a file scope — the result won't show under an Apple Photos source), and
    /// select + scroll to it.
    func revealNewFile(_ url: URL) {
        let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let photo = Photo(url: url,
                          byteSize: Int64(rv?.fileSize ?? 0),
                          creationDate: rv?.creationDate,
                          modificationDate: rv?.contentModificationDate)
        if !allPhotos.contains(where: { $0.url == url }) {
            allPhotos = allPhotos + [photo]
            persistLibraryCache()            // off-main; FSEvents watcher reconciles folder state
        }
        if committedSidebar.isPhotosLibrarySource { selectedSidebar = .allPhotos }
        selectOnly(photo)
        selectionAnchor = photo.id
    }

    /// Called after the editor writes. Refreshes caches/grid so the result shows.
    func didEdit(source: URL, output: URL, overwrote: Bool) {
        if overwrote {
            // Same path, new pixels → drop cached decodes and force the grid to
            // re-request thumbnails.
            ThumbnailCache.shared.clear()
            FullImageLoader.shared.clear()
            allPhotos = allPhotos            // bump libraryVersion → grid reloads
            showToast("원본을 편집본으로 덮어썼습니다 · \(source.lastPathComponent)")
        } else {
            revealNewFile(output)            // add + select + scroll to the new copy
            showToast("편집본 저장됨 · \(output.lastPathComponent)")
        }
    }

    // Transient status toast (friendly error/info messages).
    private(set) var toast: String?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    func showToast(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }
    func dismissToast() { toastWork?.cancel(); toast = nil }

    // Metadata
    private(set) var metaRevision = 0
    private(set) var albums: [Album] = [] { didSet { albumsVersion &+= 1 } }

    // Incrementally-maintained sidebar counts (so favoriting one photo doesn't
    // rescan the whole library).
    private(set) var favoritesCount = 0
    private(set) var labelCounts: [ColorLabel: Int] = [:]

    // Background full-library thumbnail warming. In its own observable so its
    // frequent progress ticks don't re-render the grid/sidebar.
    @ObservationIgnored let warming = WarmingMonitor()

    // Folder presentation (hierarchical tree by default)
    var folderTreeView = true { didSet { persistSettings() } }

    // Background indexes
    private(set) var exif: [String: ExifInfo] = [:] { didSet { indexVersion &+= 1 } }
    private(set) var duplicatePaths: Set<String> = [] { didSet { indexVersion &+= 1 } }

    // Settings
    var confirmBeforeDelete = true { didSet { persistSettings() } }
    var slideshowInterval: Double = 3.5 { didSet { persistSettings() } }

    @ObservationIgnored private let store = MetadataStore()
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private let recentKey = "lumen.recentRoots"

    init() {
        albums = store.albums
        loadSettings()
        watcher = FolderWatcher { [weak self] in self?.rescanRoots() }
        reopenRecentFolders()
        // Demo/screenshot hook: auto-open a folder on launch (no effect normally).
        if let demo = ProcessInfo.processInfo.environment["LUMEN_OPEN_FOLDER"] {
            importURLs([URL(fileURLWithPath: demo)])
        }
    }

    // MARK: - Per-photo metadata

    func meta(_ photo: Photo) -> PhotoMeta { store.meta(for: photo.url.path) }
    func isFavorite(_ photo: Photo) -> Bool { meta(photo).favorite }
    func rating(_ photo: Photo) -> Int { meta(photo).rating }
    func label(_ photo: Photo) -> ColorLabel { meta(photo).label }
    func tags(_ photo: Photo) -> [String] { meta(photo).tags }

    private func bumpMeta() { metaRevision &+= 1 }

    func toggleFavorite(_ photo: Photo) {
        setFavorite([photo], !isFavorite(photo))
    }

    func toggleFavorites(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        let shouldFavorite = photos.contains { !isFavorite($0) }
        setFavorite(photos, shouldFavorite)
    }

    func setFavorite(_ photos: [Photo], _ value: Bool) {
        guard !photos.isEmpty else { return }
        for photo in photos where isFavorite(photo) != value {
            store.update(photo.url.path) { $0.favorite = value }
            favoritesCount += value ? 1 : -1   // incremental — no full rescan
        }
        bumpMeta()
    }

    /// In the viewer (Space key): if the photo isn't a favorite, favorite it
    /// and advance to the next; if it already is, un-favorite it and stay so
    /// you can correct a mistake by stepping back.
    func favoriteAndAdvanceViewer() {
        guard let photo = currentViewerPhoto else { return }
        if isFavorite(photo) {
            setFavorite([photo], false)
        } else {
            setFavorite([photo], true)
            if canStepForward { viewerStep(1) }
        }
    }

    func setRating(_ value: Int, for photos: [Photo]) {
        for photo in photos { store.update(photo.url.path) { $0.rating = value } }
        bumpMeta()
    }

    // MARK: - Culling (reject flag)

    func isRejected(_ photo: Photo) -> Bool { meta(photo).rejected }

    func toggleRejected(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        let shouldReject = photos.contains { !isRejected($0) }
        for photo in photos where isRejected(photo) != shouldReject {
            store.update(photo.url.path) { $0.rejected = shouldReject }
        }
        bumpMeta()
    }

    func setLabel(_ label: ColorLabel, for photos: [Photo]) {
        for photo in photos {
            let old = self.label(photo)
            guard old != label else { continue }
            store.update(photo.url.path) { $0.label = label }
            if old != .none { labelCounts[old, default: 0] -= 1 }
            if label != .none { labelCounts[label, default: 0] += 1 }
        }
        bumpMeta()
    }

    func addTag(_ tag: String, to photos: [Photo]) {
        let clean = tag.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        for photo in photos {
            store.update(photo.url.path) { if !$0.tags.contains(clean) { $0.tags.append(clean) } }
        }
        bumpMeta()
    }

    func removeTag(_ tag: String, from photos: [Photo]) {
        for photo in photos { store.update(photo.url.path) { $0.tags.removeAll { $0 == tag } } }
        bumpMeta()
    }

    func allTags() -> [(tag: String, count: Int)] { store.allTags() }

    /// Kick off background warming of the on-disk thumbnail cache for every
    /// photo, so navigating to any folder is instant even on a NAS.
    private func startThumbnailWarming() {
        let entries = allPhotos.map {
            (url: $0.url, mtime: $0.modificationDate?.timeIntervalSince1970 ?? 0)
        }
        ThumbnailCache.shared.warmDiskCache(entries) { [weak self] remaining, folder in
            self?.warming.update(remaining: remaining, folder: folder)
        }
    }

    /// Full recompute of the favorite/label counts — only on library changes
    /// (import, delete, rename), not on individual metadata edits.
    private func recomputeMetaCounts() {
        var favorites = 0
        var labels: [ColorLabel: Int] = [:]
        for photo in allPhotos {
            let m = store.meta(for: photo.url.path)
            if m.favorite { favorites += 1 }
            if m.label != .none { labels[m.label, default: 0] += 1 }
        }
        favoritesCount = favorites
        labelCounts = labels
    }

    // MARK: - Albums

    func createAlbum(named name: String, with photos: [Photo] = []) {
        let album = store.addAlbum(named: name.isEmpty ? "Untitled Album" : name)
        if !photos.isEmpty { store.addToAlbum(album.id, paths: photos.map { $0.url.path }) }
        albums = store.albums
    }

    func renameAlbum(_ id: UUID, to name: String) {
        store.renameAlbum(id, to: name); albums = store.albums
    }

    func deleteAlbum(_ id: UUID) {
        if selectedSidebar == .album(id) { selectedSidebar = .allPhotos }
        store.deleteAlbum(id); albums = store.albums
    }

    func addToAlbum(_ id: UUID, photos: [Photo]) {
        store.addToAlbum(id, paths: photos.map { $0.url.path }); albums = store.albums
    }

    func startNewAlbum(with photos: [Photo], suggestedName: String = "") {
        newAlbumPhotos = photos; newAlbumNameDraft = suggestedName; showNewAlbumSheet = true
    }

    func confirmNewAlbum() {
        createAlbum(named: newAlbumNameDraft, with: newAlbumPhotos); newAlbumPhotos = []
    }

    func removeFromAlbum(_ id: UUID, photos: [Photo]) {
        store.removeFromAlbum(id, paths: photos.map { $0.url.path }); albums = store.albums
    }

    // MARK: - Derived collections

    var photoFolders: [URL] {
        stats.folderCounts.keys
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var availableFileTypes: [String] {
        Set(allPhotos.map { $0.fileExtension }).sorted()
    }

    var availableCameras: [String] {
        Set(exif.values.compactMap { $0.cameraDisplay }).sorted()
    }

    /// Photos restricted to the current sidebar scope. Preserves the input
    /// order (which is already sorted) except for album scope, which can use
    /// its own manual order.
    private func scoped(_ photos: [Photo]) -> [Photo] {
        switch committedSidebar {
        case .allPhotos, .photosLibrary, .photosAlbum:
            return photos
        case .favorites:
            return photos.filter { isFavorite($0) }
        case .recentlyAdded:
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            return photos.filter { ($0.creationDate ?? .distantPast) >= cutoff }
        case .onThisDay:
            let cal = Calendar.current
            let today = cal.dateComponents([.month, .day], from: Date())
            return photos.filter {
                guard let date = $0.creationDate else { return false }
                let c = cal.dateComponents([.month, .day], from: date)
                return c.month == today.month && c.day == today.day
            }
        case .duplicates:
            return photos.filter { duplicatePaths.contains($0.url.path) }
        case .label(let label):
            return photos.filter { meta($0).label == label }
        case .album(let id):
            guard let album = albums.first(where: { $0.id == id }) else { return [] }
            let membership = Set(album.photoPaths)
            return photos.filter { membership.contains($0.url.path) }  // sorted later
        case .tag(let tag):
            return photos.filter { meta($0).tags.contains(tag) }
        case .folder(let url):
            // Folder + descendants via the folder index (iterate folders, not photos).
            let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
            let byFolder = directPhotosByFolder
            var result: [Photo] = []
            for (folderPath, folderPhotos) in byFolder
            where folderPath == url.path || folderPath.hasPrefix(prefix) {
                result.append(contentsOf: folderPhotos)
            }
            return result  // sorted later
        }
    }

    private func filtered(_ photos: [Photo]) -> [Photo] {
        guard filter.isActive else { return photos }
        return photos.filter { photo in
            if let type = filter.fileType, photo.fileExtension != type { return false }
            let m = meta(photo)
            if filter.minRating > 0, m.rating < filter.minRating { return false }
            if let label = filter.label, m.label != label { return false }
            if filter.favoritesOnly, !m.favorite { return false }
            if filter.hideRejected, m.rejected { return false }
            if filter.gpsOnly, !(exif[photo.url.path]?.hasGPS ?? false) { return false }
            if let camera = filter.camera, exif[photo.url.path]?.cameraDisplay != camera { return false }
            return true
        }
    }

    // Small LRU of recent scope results so flipping between folders is instant
    // (not just the single most-recent one).
    @ObservationIgnored private var visibleCacheMap: [Int: [Photo]] = [:]
    @ObservationIgnored private var visibleCacheOrder: [Int] = []
    @ObservationIgnored private let visibleCacheCapacity = 4

    /// True when the current view's contents depend on per-photo metadata, so a
    /// favorite/rating/label edit should invalidate the cached list. Most views
    /// (All Photos, a folder) don't — so culling stays fast.
    @ObservationIgnored private var viewDependsOnMeta: Bool {
        switch committedSidebar {
        case .favorites, .label, .tag: return true
        default: break
        }
        if filter.favoritesOnly || filter.minRating > 0 || filter.label != nil { return true }
        // Search can match tags.
        return !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True when the current view's contents depend on the EXIF index — so a
    /// background indexing pass shouldn't reload a plain folder/All-Photos grid.
    @ObservationIgnored private var viewDependsOnExif: Bool {
        if case .duplicates = committedSidebar { return true }
        if filter.gpsOnly || filter.camera != nil { return true }
        return !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A cheap hash of every input that affects `visiblePhotos`.
    @ObservationIgnored private var visibleSignature: Int {
        var hasher = Hasher()
        hasher.combine(libraryVersion)
        hasher.combine(assetsVersion)
        hasher.combine(albumsVersion)
        hasher.combine(committedSidebar)
        hasher.combine(sortOrder)
        hasher.combine(searchText)
        hasher.combine(filter)
        if viewDependsOnExif { hasher.combine(indexVersion) }
        if viewDependsOnMeta { hasher.combine(metaRevision) }
        return hasher.finalize()
    }

    /// Cheap token that changes only when `visiblePhotos` would change — use it
    /// to trigger prefetching without diffing the whole array.
    var visibleToken: Int { visibleSignature }

    /// True while a large scope's sort is running on a background thread (the
    /// grid shows the previous content + a spinner until it lands).
    private(set) var isSortingVisible = false

    @ObservationIgnored private var lastVisible: [Photo] = []
    @ObservationIgnored private var sortTask: Task<Void, Never>?
    @ObservationIgnored private var sortInFlightKey = -1
    @ObservationIgnored private let asyncSortThreshold = 4000

    /// Scope + filter + search WITHOUT sorting (cheap; safe on the main thread).
    private func gatherUnsorted() -> [Photo] {
        var result = filtered(scoped(sourcePhotos))
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            let names = lowerNames
            result = result.filter { photo in
                (names[photo.url]?.contains(query) ?? false)
                || meta(photo).tags.contains { $0.lowercased().contains(query) }
                || (exif[photo.url.path]?.cameraDisplay?.lowercased().contains(query) ?? false)
            }
        }
        return result
    }

    /// Apply the active sort. Album scope keeps its manual order unless sorted.
    private func sortVisible(_ gathered: [Photo]) -> [Photo] {
        if case .album(let id) = committedSidebar, sortOrder == .dateNewest,
           let album = albums.first(where: { $0.id == id }) {
            let order = Dictionary(uniqueKeysWithValues: album.photoPaths.enumerated().map { ($1, $0) })
            return gathered.sorted { (order[$0.url.path] ?? 0) < (order[$1.url.path] ?? 0) }
        }
        return sortOrder.sorted(gathered)
    }

    private func cacheVisible(_ key: Int, _ result: [Photo]) {
        visibleCacheMap[key] = result
        visibleCacheOrder.append(key)
        if visibleCacheOrder.count > visibleCacheCapacity {
            visibleCacheMap.removeValue(forKey: visibleCacheOrder.removeFirst())
        }
    }

    /// Final ordered list shown in the detail area. Small scopes sort inline;
    /// large ones sort off the main thread to keep navigation snappy.
    var visiblePhotos: [Photo] {
        let key = visibleSignature
        if let hit = visibleCacheMap[key] { lastVisible = hit; return hit }

        let gathered = gatherUnsorted()
        let isAlbum: Bool = { if case .album = committedSidebar { return true }; return false }()

        if gathered.count <= asyncSortThreshold || isAlbum {
            let sorted = sortVisible(gathered)
            cacheVisible(key, sorted)
            lastVisible = sorted
            return sorted
        }

        // Large: sort off-main; show the previous list + spinner until ready.
        if sortInFlightKey != key {
            sortInFlightKey = key
            let order = sortOrder
            sortTask?.cancel()
            sortTask = Task { [weak self] in
                await MainActor.run { self?.isSortingVisible = true }
                let sorted = await Task.detached(priority: .userInitiated) { order.sorted(gathered) }.value
                guard let self else { return }
                if self.visibleSignature == key {
                    self.cacheVisible(key, sorted)
                    self.lastVisible = sorted
                }
                self.sortInFlightKey = -1
                self.isSortingVisible = false
            }
        }
        return lastVisible
    }

    // Library statistics (folders, recently-added, on-this-day) — depends only
    // on the library, recomputed on import/delete. Favorite/label counts are
    // tracked incrementally in `favoritesCount` / `labelCounts`.
    struct LibraryStats {
        var recentlyAdded = 0
        var onThisDay = 0
        var folderCounts: [URL: Int] = [:]
    }

    @ObservationIgnored private var statsCache = LibraryStats()
    @ObservationIgnored private var statsCacheKey = -1

    var stats: LibraryStats {
        if libraryVersion == statsCacheKey { return statsCache }

        var s = LibraryStats()
        let cal = Calendar.current
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let today = cal.dateComponents([.month, .day], from: Date())
        for photo in allPhotos {
            s.folderCounts[photo.folderURL, default: 0] += 1
            if let date = photo.creationDate {
                if date >= cutoff { s.recentlyAdded += 1 }
                let c = cal.dateComponents([.month, .day], from: date)
                if c.month == today.month && c.day == today.day { s.onThisDay += 1 }
            }
        }
        statsCache = s
        statsCacheKey = libraryVersion
        return s
    }

    // MARK: - Folder tree

    @ObservationIgnored private var folderTreeCache: [FolderNode] = []
    @ObservationIgnored private var folderTreeCacheKey = -1

    var folderTree: [FolderNode] {
        if libraryVersion == folderTreeCacheKey { return folderTreeCache }
        let result = buildFolderTree()
        folderTreeCache = result
        folderTreeCacheKey = libraryVersion
        return result
    }

    private func buildFolderTree() -> [FolderNode] {
        let direct = stats.folderCounts
        guard !direct.isEmpty else { return [] }

        // Every folder to show: each folder-with-photos plus its ancestors up to
        // the imported root that contains it.
        var nodeURLs = Set<URL>()
        for folder in direct.keys {
            let root = rootFolders.first {
                folder.path == $0.path || folder.path.hasPrefix($0.path + "/")
            }
            var u = folder
            while true {
                nodeURLs.insert(u)
                if let root, u.path == root.path { break }
                let parent = u.deletingLastPathComponent()
                if parent == u { break }
                u = parent
                if root == nil { break }
            }
        }

        // Build a parent → children map once (O(folders)).
        var childrenMap: [String: [URL]] = [:]
        for url in nodeURLs {
            let parent = url.deletingLastPathComponent().path
            if nodeURLs.contains(where: { $0.path == parent }) {
                childrenMap[parent, default: []].append(url)
            }
        }

        // Counts accumulate bottom-up through the recursion (no per-node rescan).
        func makeNode(_ url: URL) -> FolderNode {
            let kids = (childrenMap[url.path] ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map(makeNode)
            let count = (direct[url] ?? 0) + kids.reduce(0) { $0 + $1.count }
            return FolderNode(url: url, name: url.lastPathComponent, count: count,
                              children: kids.isEmpty ? nil : kids)
        }

        let roots = nodeURLs
            .filter { !nodeURLs.contains($0.deletingLastPathComponent()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return roots.map(makeNode)
    }

    /// Photos grouped by month for the timeline layout.
    var monthGroups: [(title: String, photos: [Photo])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: visiblePhotos) { photo -> Date in
            let date = photo.creationDate ?? .distantPast
            return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? .distantPast
        }
        return groups.keys.sorted(by: >).map { key in
            (title: Self.monthFormatter.string(from: key), photos: groups[key] ?? [])
        }
    }

    /// Photos that have GPS coordinates, for the map.
    var geotaggedPhotos: [(photo: Photo, latitude: Double, longitude: Double)] {
        visiblePhotos.compactMap { photo in
            guard let info = exif[photo.url.path], let lat = info.latitude, let lon = info.longitude else { return nil }
            return (photo, lat, lon)
        }
    }

    // MARK: - Photos-library map (computed off-main; assets carry location in PhotoKit)

    /// Max pins fed to the map for a Photos source. MapKit clustering collapses
    /// dense areas, so we can show many; the cap just bounds the upfront annotation
    /// build (and the off-main location scan) for pathological libraries.
    static let assetMapPinLimit = 10000

    private(set) var assetMapPins: [(photo: Photo, latitude: Double, longitude: Double)] = []
    private(set) var isLoadingAssetMap = false
    private(set) var assetMapTruncated = false
    @ObservationIgnored private var assetMapKey = -1

    /// Scan the current Photos scope's geotagged assets on a background thread and
    /// stream pins to the map in batches, so the map shows immediately and fills
    /// in progressively (reading 70k `PHAsset.location`s on the main thread froze
    /// the app). Capped at `assetMapPinLimit`.
    func ensureAssetMapPins() {
        guard committedSidebar.isPhotosLibrarySource else { return }
        let key = visibleSignature
        guard assetMapKey != key else { return }
        assetMapKey = key
        isLoadingAssetMap = true
        assetMapPins = []
        assetMapTruncated = false
        let photos = visiblePhotos
        let limit = Self.assetMapPinLimit
        Task.detached(priority: .userInitiated) { [weak self] in
            var batch: [(photo: Photo, latitude: Double, longitude: Double)] = []
            var total = 0
            for photo in photos {
                guard let c = PhotosImageLoader.shared.location(for: photo.url) else { continue }
                batch.append((photo: photo, latitude: c.latitude, longitude: c.longitude))
                total += 1
                if batch.count >= 40 || total >= limit {
                    let chunk = batch; batch = []
                    await MainActor.run { self?.appendAssetMapPins(chunk, forKey: key) }
                }
                if total >= limit {
                    await MainActor.run { self?.finishAssetMap(forKey: key, truncated: true) }
                    return
                }
            }
            let chunk = batch
            await MainActor.run {
                self?.appendAssetMapPins(chunk, forKey: key)
                self?.finishAssetMap(forKey: key, truncated: false)
            }
        }
    }

    private func appendAssetMapPins(_ pins: [(photo: Photo, latitude: Double, longitude: Double)], forKey key: Int) {
        guard assetMapKey == key, !pins.isEmpty else { return }   // ignore a stale scan
        assetMapPins.append(contentsOf: pins)
    }

    private func finishAssetMap(forKey key: Int, truncated: Bool) {
        guard assetMapKey == key else { return }
        assetMapTruncated = truncated
        isLoadingAssetMap = false
    }

    var totalCount: Int { allPhotos.count }
    var visibleCount: Int { visiblePhotos.count }

    // MARK: - Selection

    var selectedPhotos: [Photo] { allPhotos.filter { selection.contains($0.id) } }

    // O(1) photo lookup by id, rebuilt only when the library changes.
    @ObservationIgnored private var idIndexCache: [URL: Photo] = [:]
    @ObservationIgnored private var idIndexKey = -1
    @ObservationIgnored private var photoByID: [URL: Photo] {
        if libraryVersion == idIndexKey { return idIndexCache }
        idIndexCache = Dictionary(allPhotos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        idIndexKey = libraryVersion
        return idIndexCache
    }

    func photo(for id: Photo.ID) -> Photo? { photoByID[id] }

    // Photos grouped by their immediate folder, so folder scope is O(result)
    // instead of an O(library) prefix scan on every folder click.
    @ObservationIgnored private var folderIndexCache: [String: [Photo]] = [:]
    @ObservationIgnored private var folderIndexKey = -1
    @ObservationIgnored private var directPhotosByFolder: [String: [Photo]] {
        if libraryVersion == folderIndexKey { return folderIndexCache }
        folderIndexCache = Dictionary(grouping: allPhotos) { $0.folderURL.path }
        folderIndexKey = libraryVersion
        return folderIndexCache
    }

    // Pre-lowercased filenames for fast search, rebuilt only on library change.
    @ObservationIgnored private var lowerNameCache: [URL: String] = [:]
    @ObservationIgnored private var lowerNameKey = -1
    @ObservationIgnored private var lowerNames: [URL: String] {
        if libraryVersion == lowerNameKey { return lowerNameCache }
        lowerNameCache = Dictionary(allPhotos.map { ($0.url, $0.filename.lowercased()) },
                                    uniquingKeysWith: { a, _ in a })
        lowerNameKey = libraryVersion
        return lowerNameCache
    }

    var primarySelectedPhoto: Photo? {
        let id = selectionAnchor ?? selection.first
        guard let id else { return nil }
        return photoByID[id]
    }

    func selectOnly(_ photo: Photo) { selection = [photo.id]; selectionAnchor = photo.id }

    func toggleSelection(_ photo: Photo) {
        if selection.contains(photo.id) { selection.remove(photo.id) } else { selection.insert(photo.id) }
        selectionAnchor = photo.id
    }

    func extendSelection(to photo: Photo, in ordered: [Photo]) {
        guard let anchor = selectionAnchor,
              let a = ordered.firstIndex(where: { $0.id == anchor }),
              let b = ordered.firstIndex(of: photo) else { selectOnly(photo); return }
        selection.formUnion(ordered[min(a, b)...max(a, b)].map { $0.id })
    }

    func selectAll(_ ordered: [Photo]) { selection = Set(ordered.map { $0.id }); selectionAnchor = ordered.last?.id }
    func clearSelection() { selection = []; selectionAnchor = nil }

    func actionTargets(for photo: Photo) -> [Photo] {
        if selection.count > 1, selection.contains(photo.id) { return selectedPhotos }
        return [photo]
    }

    // MARK: - Importing

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Photos to Lumen"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let newRoots = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        Task { await scan(adding: urls, newRoots: newRoots) }
    }

    private func scan(adding urls: [URL], newRoots: [URL]) async {
        isScanning = true
        let scanned = await Task.detached(priority: .userInitiated) { PhotoScanner.expand(urls: urls) }.value

        var seen = Set(allPhotos.map { $0.url })
        var merged = allPhotos
        var added: [Photo] = []
        for photo in scanned where !seen.contains(photo.url) {
            merged.append(photo); seen.insert(photo.url); added.append(photo)
        }
        allPhotos = merged
        for root in newRoots where !rootFolders.contains(root) { rootFolders.append(root) }

        persistRecentFolders()
        watcher?.watch(rootFolders.filter { FileManager.default.fileExists(atPath: $0.path) })
        recomputeMetaCounts()
        persistLibraryCache()
        isScanning = false

        if !exif.isEmpty { await indexExif(for: added) }  // full index is deferred until needed
        startThumbnailWarming()
    }

    /// Reconcile the in-memory library with what's on disk for the given roots.
    /// Photos under offline roots (e.g. an unmounted NAS) are left untouched.
    /// Whether a (currently missing) root sits on a network/NAS volume, in which
    /// case it's treated as temporarily offline rather than renamed/moved away.
    /// An unmounted volume can't be stat'd, so we fall back to the path shape.
    nonisolated static func isOfflineNetworkRoot(_ root: URL) -> Bool {
        if let local = try? root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal {
            return local == false
        }
        return root.path.hasPrefix("/Volumes/")
    }

    private func reconcile(roots: [URL]) async {
        guard !roots.isEmpty else { return }

        // Incremental: reuse cached photos for folders whose mtime is unchanged.
        let cachedByFolder = Dictionary(grouping: allPhotos) { $0.folderURL.path }
        let knownMtimes = LibraryCache.loadFolderMtimes()
        let result = await Task.detached(priority: .utility) {
            IncrementalScanner.scan(roots: roots, knownMtimes: knownMtimes, cachedByFolder: cachedByFolder)
        }.value
        let scanned = result.photos
        Task.detached(priority: .background) { LibraryCache.saveFolderMtimes(result.folderMtimes) }

        let prefixes = roots.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        func underScannedRoot(_ photo: Photo) -> Bool {
            prefixes.contains { photo.url.path.hasPrefix($0) }
        }

        let knownURLs = Set(allPhotos.map { $0.url })
        let added = scanned.filter { !knownURLs.contains($0.url) }
        let scannedURLs = Set(scanned.map { $0.url })
        let removed = allPhotos.filter { underScannedRoot($0) && !scannedURLs.contains($0.url) }

        // Photos not under any *currently scanned* root split into two groups:
        //   • genuinely offline — their root is an unreachable network/NAS volume
        //     (e.g. unmounted). Keep these so the library still shows them.
        //   • orphaned — their root is a *local* folder that no longer exists,
        //     i.e. it was renamed/moved/deleted in Finder. The old paths are
        //     phantoms; keeping them leaves stale, fractured sidebar folders.
        //     Prune them (the new paths come back in as `added`).
        let missingRoots = rootFolders.filter { !roots.contains($0) }
        let preservableRoots = missingRoots.filter(Self.isOfflineNetworkRoot)
        func isPreservableOffline(_ photo: Photo) -> Bool {
            preservableRoots.contains { photo.url.path.hasPrefix($0.path + "/") }
        }
        let offline = allPhotos.filter { !underScannedRoot($0) && isPreservableOffline($0) }
        let prunedLocal = allPhotos.filter { !underScannedRoot($0) && !isPreservableOffline($0) }

        // Only mutate the library when something actually changed — otherwise a
        // no-op launch reconcile would bump the version and force the grid to
        // reload (throwing away in-flight thumbnail decodes).
        if !added.isEmpty || !removed.isEmpty || !prunedLocal.isEmpty {
            let dropped = removed + prunedLocal
            for photo in dropped { exif.removeValue(forKey: photo.url.path) }
            duplicatePaths.subtract(dropped.map { $0.url.path })
            allPhotos = offline + scanned
            recomputeMetaCounts()
            persistLibraryCache()
        }

        // Forget vanished *local* roots so they stop being re-watched/persisted
        // and disappear from the sidebar. Network roots stay — they may remount.
        let vanishedLocalRoots = missingRoots.filter { !Self.isOfflineNetworkRoot($0) }
        if !vanishedLocalRoots.isEmpty {
            rootFolders.removeAll { vanishedLocalRoots.contains($0) }
            persistRecentFolders()
        }
        watcher?.watch(roots)

        if !exif.isEmpty, !added.isEmpty { await indexExif(for: added) }
        startThumbnailWarming()
    }

    private(set) var isIndexingExif = false

    /// Index EXIF for any photos that don't have it yet — called on demand when
    /// the Map or an EXIF-based filter is first used, so a plain browse session
    /// never reads 50k files.
    func ensureExifIndex() {
        guard !isIndexingExif else { return }
        let missing = allPhotos.filter { exif[$0.url.path] == nil }
        guard !missing.isEmpty else { return }
        isIndexingExif = true
        let urls = missing.map { $0.url }
        Task {
            let added = await Task.detached(priority: .utility) { ExifIndexer.index(urls) }.value
            var merged = exif
            for (key, value) in added { merged[key] = value }
            exif = merged
            persistExifCache()
            isIndexingExif = false
        }
    }

    /// Index EXIF for just the given (new) photos and merge into the cache.
    private func indexExif(for photos: [Photo]) async {
        guard !photos.isEmpty else { persistExifCache(); return }
        let urls = photos.map { $0.url }
        let added = await Task.detached(priority: .utility) { ExifIndexer.index(urls) }.value
        var merged = exif
        for (key, value) in added { merged[key] = value }
        exif = merged
        persistExifCache()
    }

    private func persistLibraryCache() {
        let snapshot = allPhotos
        Task.detached(priority: .background) { LibraryCache.savePhotos(snapshot) }
    }

    private func persistExifCache() {
        let snapshot = exif
        Task.detached(priority: .background) { LibraryCache.saveExif(snapshot) }
    }

    // MARK: - Duplicates (on-demand — never scans the whole NAS automatically)

    var isFindingDuplicates = false

    func findDuplicates() {
        guard !isFindingDuplicates, !allPhotos.isEmpty else { return }
        isFindingDuplicates = true
        let photos = allPhotos
        Task {
            let dupes = await Task.detached(priority: .utility) {
                DuplicateFinder.duplicatePaths(in: photos)
            }.value
            duplicatePaths = dupes
            isFindingDuplicates = false
            if !dupes.isEmpty { selectedSidebar = .duplicates }
        }
    }

    /// Folder watcher callback.
    private func rescanRoots() {
        let available = rootFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        Task { await reconcile(roots: available) }
    }

    func clearLibrary() {
        allPhotos = []; rootFolders = []
        clearSelection(); viewerIndex = nil
        selectedSidebar = .allPhotos
        exif = [:]; duplicatePaths = []
        favoritesCount = 0; labelCounts = [:]
        watcher?.stop()
        ThumbnailCache.shared.clear()
        LibraryCache.clear()
        persistRecentFolders()
    }

    // MARK: - Viewer control

    func openViewer(_ photo: Photo) {
        let photos = visiblePhotos
        guard let index = photos.firstIndex(of: photo) else { return }
        viewerPhotos = photos; viewerIndex = index; selectOnly(photo)
    }

    func closeViewer() {
        if let index = viewerIndex, viewerPhotos.indices.contains(index) { selectOnly(viewerPhotos[index]) }
        viewerIndex = nil; compareSecondary = nil
    }

    func openCompare(_ photos: [Photo]) {
        guard photos.count >= 2 else { return }
        viewerPhotos = [photos[0]]; viewerIndex = 0; compareSecondary = photos[1]
    }

    var currentViewerPhoto: Photo? {
        guard let index = viewerIndex, viewerPhotos.indices.contains(index) else { return nil }
        return viewerPhotos[index]
    }

    func viewerStep(_ delta: Int) {
        guard let index = viewerIndex else { return }
        let next = index + delta
        guard viewerPhotos.indices.contains(next) else { return }
        viewerIndex = next
    }

    var canStepBack: Bool { (viewerIndex ?? 0) > 0 }
    var canStepForward: Bool { guard let i = viewerIndex else { return false }; return i < viewerPhotos.count - 1 }

    // MARK: - OS integration

    func revealInFinder(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(photos.map { $0.url })
    }

    func openWithDefaultApp(_ photo: Photo) { NSWorkspace.shared.open(photo.url) }

    func copyToPasteboard(_ photo: Photo) { copyToPasteboard([photo]) }

    func copyToPasteboard(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(photos.map { $0.url as NSURL })
        if photos.count == 1, let image = NSImage(contentsOf: photos[0].url) { pasteboard.writeObjects([image]) }
    }

    func share(_ photos: [Photo]) {
        guard !photos.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        Exporter.share(photos, from: view)
    }

    func setWallpaper(_ photo: Photo) { Exporter.setWallpaper(photo) }

    // MARK: - Export

    private func chooseDirectory(prompt: String, _ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = prompt; panel.title = prompt
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }

    func exportOriginals(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        chooseDirectory(prompt: "Export Here") { dir in _ = Exporter.copyOriginals(photos, to: dir) }
    }

    func exportResized(_ photos: [Photo], maxPixel: Int) {
        guard !photos.isEmpty else { return }
        chooseDirectory(prompt: "Export Here") { dir in _ = Exporter.exportResized(photos, maxPixel: maxPixel, to: dir) }
    }

    func exportZip(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lumen Export.zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url {
            Task.detached { _ = Exporter.zip(photos, to: url) }
        }
    }

    // MARK: - Folder actions

    var showFolderRenameSheet = false
    var folderRenameDraft = ""
    @ObservationIgnored private var folderRenameURL: URL?

    /// All photos in a folder and its descendants.
    func photosInFolder(_ url: URL) -> [Photo] {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return allPhotos.filter { $0.url.path.hasPrefix(prefix) }
    }

    func isRootFolder(_ url: URL) -> Bool { rootFolders.contains(url) }

    func openFolderInFinder(_ url: URL) { NSWorkspace.shared.open(url) }
    func revealFolderInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func copyPath(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
    }

    func createAlbumFromFolder(_ url: URL) {
        startNewAlbum(with: photosInFolder(url), suggestedName: url.lastPathComponent)
    }

    func findDuplicates(in url: URL) {
        guard !isFindingDuplicates else { return }
        isFindingDuplicates = true
        let photos = photosInFolder(url)
        Task {
            let dupes = await Task.detached(priority: .utility) {
                DuplicateFinder.duplicatePaths(in: photos)
            }.value
            duplicatePaths = dupes
            isFindingDuplicates = false
            if !dupes.isEmpty { selectedSidebar = .duplicates }
        }
    }

    /// Remove a root folder from the library (stops tracking it; files untouched).
    func removeRootFolder(_ url: URL) {
        guard rootFolders.contains(url) else { return }
        rootFolders.removeAll { $0 == url }
        let prefix = url.path + "/"
        let removed = allPhotos.filter { $0.url.path == url.path || $0.url.path.hasPrefix(prefix) }
        allPhotos.removeAll { $0.url.path == url.path || $0.url.path.hasPrefix(prefix) }
        for photo in removed { exif.removeValue(forKey: photo.url.path); duplicatePaths.remove(photo.url.path) }
        if case .folder(let sel) = selectedSidebar, sel == url || sel.path.hasPrefix(prefix) {
            selectedSidebar = .allPhotos
        }
        recomputeMetaCounts()
        persistRecentFolders()
        persistLibraryCache()
        persistExifCache()
        watcher?.watch(rootFolders.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    func startRenameFolder(_ url: URL) {
        folderRenameURL = url
        folderRenameDraft = url.lastPathComponent
        showFolderRenameSheet = true
    }

    func confirmRenameFolder() {
        guard let url = folderRenameURL else { return }
        renameFolder(url, to: folderRenameDraft)
        folderRenameURL = nil
    }

    /// Rename a folder on disk and update all in-memory paths, metadata, and caches.
    private func renameFolder(_ url: URL, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != url.lastPathComponent,
              !clean.contains("/") else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(clean)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            NSLog("Lumen: folder rename failed: \(error.localizedDescription)")
            showToast("Couldn’t rename folder: \(error.localizedDescription)")
            return
        }

        let oldPrefix = url.path + "/"
        let newPrefix = dest.path + "/"
        func remap(_ path: String) -> String {
            path.hasPrefix(oldPrefix) ? newPrefix + path.dropFirst(oldPrefix.count) : path
        }

        // Photos
        allPhotos = allPhotos.map { photo in
            guard photo.url.path.hasPrefix(oldPrefix) else { return photo }
            return photo.relocated(to: URL(fileURLWithPath: remap(photo.url.path)))
        }
        // EXIF index + duplicates
        exif = Dictionary(uniqueKeysWithValues: exif.map { (remap($0.key), $0.value) })
        duplicatePaths = Set(duplicatePaths.map(remap))
        // User metadata + albums
        store.renamePrefix(from: oldPrefix, to: newPrefix)
        albums = store.albums

        // Roots / selection
        if let idx = rootFolders.firstIndex(of: url) {
            rootFolders[idx] = dest
            persistRecentFolders()
        }
        if case .folder(let sel) = selectedSidebar {
            if sel == url { selectedSidebar = .folder(dest) }
            else if sel.path.hasPrefix(oldPrefix) {
                selectedSidebar = .folder(URL(fileURLWithPath: remap(sel.path)))
            }
        }

        recomputeMetaCounts()
        persistLibraryCache()
        persistExifCache()
        watcher?.watch(rootFolders.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: - Batch rename

    func startRename(_ photos: [Photo]) {
        renameTargets = photos.filter { !$0.isAsset }   // assets have no file to rename
        guard !renameTargets.isEmpty else { return }
        showRenameSheet = true
    }

    func rename(_ photos: [Photo], pattern: String, startIndex: Int) {
        var index = startIndex
        for photo in sortOrder.sorted(photos) where !photo.isAsset {
            let ext = photo.url.pathExtension
            let newName = RenamePattern.filename(pattern: pattern, index: index, ext: ext)
            let newURL = photo.folderURL.appendingPathComponent(newName)
            index += 1
            guard newURL != photo.url, !FileManager.default.fileExists(atPath: newURL.path) else { continue }
            do {
                try FileManager.default.moveItem(at: photo.url, to: newURL)
                store.rename(from: photo.url.path, to: newURL.path)
            } catch {
                NSLog("Lumen rename failed: \(error.localizedDescription)")
                showToast("Couldn’t rename “\(photo.filename)”: \(error.localizedDescription)")
            }
        }
        rescanRoots()
        albums = store.albums
        bumpMeta()
    }

    // MARK: - Deletion (move to Trash)

    var deletionTargets: [Photo] {
        if let viewed = currentViewerPhoto { return [viewed] }
        if !selectedPhotos.isEmpty { return selectedPhotos }
        if let primary = primarySelectedPhoto { return [primary] }
        return []
    }

    func requestDeletion(_ photos: [Photo]) {
        // Photos-library assets aren't files — Phase 1 is read-only, so never
        // route them to Trash. (Phase 4 may add PhotoKit deletion.)
        let photos = photos.filter { !$0.isAsset }
        guard !photos.isEmpty else { return }
        photosPendingDeletion = photos
        if confirmBeforeDelete {
            showDeleteConfirmation = true
        } else {
            confirmDeletion()
        }
    }

    var deletionMessage: String {
        let count = photosPendingDeletion.count
        if count == 1, let name = photosPendingDeletion.first?.filename {
            return "“\(name)” will be moved to the Trash."
        }
        return "\(count) photos will be moved to the Trash."
    }

    func confirmDeletion() {
        let photos = photosPendingDeletion
        photosPendingDeletion = []
        guard !photos.isEmpty else { return }

        let ordered = visiblePhotos
        let firstIndex = photos.compactMap { ordered.firstIndex(of: $0) }.min()

        var trashed = Set<URL>()
        for photo in photos {
            do {
                try FileManager.default.trashItem(at: photo.url, resultingItemURL: nil)
                trashed.insert(photo.url)
            } catch {
                NSLog("Lumen: failed to trash \(photo.url.path): \(error.localizedDescription)")
            }
        }
        guard !trashed.isEmpty else { return }

        store.forget(paths: trashed.map { $0.path })
        albums = store.albums
        allPhotos.removeAll { trashed.contains($0.url) }
        for url in trashed { exif.removeValue(forKey: url.path); duplicatePaths.remove(url.path) }
        recomputeMetaCounts()
        bumpMeta()
        persistLibraryCache()   // save the post-delete library so a relaunch can't reload the trashed files

        if viewerIndex != nil {
            viewerPhotos.removeAll { trashed.contains($0.url) }
            if viewerPhotos.isEmpty { viewerIndex = nil }
            else if let index = viewerIndex { viewerIndex = min(index, viewerPhotos.count - 1) }
        }

        let remaining = visiblePhotos
        if let index = firstIndex, !remaining.isEmpty {
            selectOnly(remaining[min(index, remaining.count - 1)])
        } else {
            clearSelection()
        }
    }

    // MARK: - Persistence

    private func persistRecentFolders() {
        UserDefaults.standard.set(rootFolders.map { $0.path }, forKey: recentKey)
    }

    private func reopenRecentFolders() {
        let paths = UserDefaults.standard.array(forKey: recentKey) as? [String] ?? []
        guard !paths.isEmpty else { return }

        // Keep every saved root, even if its volume (e.g. a NAS) is offline right
        // now — so it's never forgotten and reloads automatically when it's back.
        let urls = paths.map { URL(fileURLWithPath: $0) }
        rootFolders = urls
        isLoadingLibrary = true

        // Window appears immediately; load the cached library off the main thread.
        Task {
            let cached = await Task.detached(priority: .userInitiated) { LibraryCache.loadPhotos() }.value
            let cachedExif = await Task.detached(priority: .userInitiated) { LibraryCache.loadExif() }.value
            if let cached, !cached.isEmpty {
                allPhotos = cached
                if let cachedExif { exif = cachedExif }
                recomputeMetaCounts()
            }
            isLoadingLibrary = false

            let available = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !available.isEmpty { await reconcile(roots: available) }
        }
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "lumen.viewMode"), let mode = ViewMode(rawValue: raw) { viewMode = mode }
        if defaults.object(forKey: "lumen.confirmDelete") != nil {
            confirmBeforeDelete = defaults.bool(forKey: "lumen.confirmDelete")
        }
        if defaults.object(forKey: "lumen.slideshowInterval") != nil {
            slideshowInterval = defaults.double(forKey: "lumen.slideshowInterval")
        }
        if defaults.object(forKey: "lumen.folderTreeView") != nil {
            folderTreeView = defaults.bool(forKey: "lumen.folderTreeView")
        }
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(viewMode.rawValue, forKey: "lumen.viewMode")
        defaults.set(confirmBeforeDelete, forKey: "lumen.confirmDelete")
        defaults.set(slideshowInterval, forKey: "lumen.slideshowInterval")
        defaults.set(folderTreeView, forKey: "lumen.folderTreeView")
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
}
