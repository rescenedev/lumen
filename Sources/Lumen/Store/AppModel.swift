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
    private(set) var isScanning = false
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

    /// Perf-probe/test seam: commit a sidebar selection synchronously
    /// (bypassing the 120ms click debounce) and force the visible-list
    /// recompute, returning the synchronous main-thread cost in seconds —
    /// the "folder open" number a user feels as the click-to-grid delay.
    @discardableResult
    func probeCommit(_ item: SidebarItem) -> TimeInterval {
        let t0 = CFAbsoluteTimeGetCurrent()
        selectedSidebar = item
        sidebarCommitWork?.cancel()
        committedSidebar = item
        _ = visiblePhotos
        return CFAbsoluteTimeGetCurrent() - t0
    }

    private func scheduleSidebarCommit() {
        // Cancel BEFORE the equality guard: clicking A → B → back to A within
        // the 120ms window must kill the pending B commit, or the grid shows B
        // while the sidebar highlights A.
        sidebarCommitWork?.cancel()
        guard selectedSidebar != committedSidebar else { return }
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
        // `photosAccess = .loading` is set synchronously (no await between it and
        // the guard), so a second call is gated out before the Task starts — no
        // re-entrant duplicate fetch. The Task inherits @MainActor, so its
        // post-await assignments below run on the main actor.
        guard assetPhotos.isEmpty, photosAccess != .loading, photosAccess != .denied else { return }
        photosAccess = .loading
        Task {
            let status = await PhotosLibraryService.authorize()
            switch status {
            case .authorized, .limited:
                // Follow the library, don't just snapshot it: the observer used
                // to invalidate the service's cache and stop there, so a photo
                // added or deleted in Apple Photos stayed invisible here until
                // the next launch.
                PhotosLibraryObserver.shared.onChange = { [weak self] in
                    Task { @MainActor [weak self] in self?.schedulePhotosRefresh() }
                }
                PhotosLibraryObserver.shared.start()
                let photos = await PhotosLibraryService.fetchAllImages()
                self.assetPhotos = photos
                self.photosAccess = (status == .limited) ? .limited : .authorized
                self.photosAlbums = await PhotosLibraryService.fetchAlbums()
            default:
                self.photosAccess = .denied
            }
        }
    }

    /// True while a Photos album/library scope is fetching from PhotoKit, so the
    /// grid can show "Loading…" instead of an empty "No Photos" state.
    private(set) var isLoadingAssetScope = false

    // MARK: Photos library refresh

    private(set) var isRefreshingPhotos = false
    @ObservationIgnored private var photosRefreshWork: DispatchWorkItem?

    /// A PhotoKit change arrived. Debounced: importing a burst into Photos
    /// fires the observer repeatedly, and each refresh re-fetches the whole
    /// library.
    private func schedulePhotosRefresh() {
        photosRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPhotosLibrary(announce: false) }
        photosRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Re-read the Photos library from PhotoKit: the asset list, the album
    /// list, and whichever album is open. `announce` is false for the automatic
    /// pass — a toast every time Photos touches its own database would be noise.
    func refreshPhotosLibrary(announce: Bool = true) {
        guard photosAccess == .authorized || photosAccess == .limited else {
            // Never loaded (or denied): the normal load path handles both, and
            // asking for access is its job, not a refresh's.
            loadPhotosLibraryIfNeeded()
            return
        }
        guard !isRefreshingPhotos else { return }
        isRefreshingPhotos = true
        Task {
            PhotosLibraryService.invalidateAssetCache()
            let photos = await PhotosLibraryService.fetchAllImages()
            let albums = await PhotosLibraryService.fetchAlbums()
            self.assetPhotos = photos
            self.photosAlbums = albums
            // Re-fetch the open album too, or the grid keeps showing the old
            // contents of the very scope the user is looking at.
            if let open = self.currentAssetAlbumId {
                self.currentAssetAlbumId = nil
                self.loadPhotosAlbum(open)
            }
            self.isRefreshingPhotos = false
            if announce {
                self.showToast("Photos library refreshed · \(photos.count.formatted()) photos")
            }
        }
    }

    /// Load one Photos album's assets on demand (cached per album id).
    func loadPhotosAlbum(_ id: String) {
        if photosAccess == .unknown { loadPhotosLibraryIfNeeded() }
        guard currentAssetAlbumId != id else { return }
        currentAssetAlbumId = id
        assetAlbumPhotos = []
        isLoadingAssetScope = true
        Task {
            let photos = await PhotosLibraryService.fetchAssets(inAlbumId: id)
            if self.currentAssetAlbumId == id {
                self.assetAlbumPhotos = photos
                self.isLoadingAssetScope = false
            }
        }
    }
    /// Whether the currently-shown scope is still fetching its photos — drives
    /// the grid's "Loading…" placeholder for the (async) Photos library/albums.
    var isLoadingVisibleScope: Bool {
        switch committedSidebar {
        case .photosLibrary: return photosAccess == .loading
        case .photosAlbum: return isLoadingAssetScope
        default: return isLoadingLibrary
        }
    }

    var sortOrder: SortOrder = .dateNewest { didSet { persistSettings() } }
    var searchText = ""
    var thumbnailSize: Double = 320
    var filter = FilterState()
    var groupByMonth = false

    // Presentation + multi-selection
    var viewMode: ViewMode = .grid { didSet { persistSettings() } }
    var selection: Set<Photo.ID> = [] { didSet { selectionRevision &+= 1 } }
    var selectionAnchor: Photo.ID?
    @ObservationIgnored private var selectionRevision = 0

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

    // Update notification (notify-only — never auto-installs; see UpdateChecker).
    var availableUpdate: UpdateInfo?
    var updateBannerDismissed = false
    @ObservationIgnored private let updateCheckKey = "lumen.lastUpdateCheck"
    @ObservationIgnored private var updateCheckTask: Task<Void, Never>?

    /// Check GitHub for a newer release. Throttled to once/day unless `force`d
    /// (e.g. from the "Check for Updates…" menu item). Silent on failure.
    func checkForUpdates(force: Bool = false) {
        if !force {
            let last = UserDefaults.standard.double(forKey: updateCheckKey)
            if last > 0, Date().timeIntervalSince1970 - last < 86_400 { return }
        }
        // Skip if a check is already running so rapid calls (auto + menu) don't
        // fire redundant network requests racing to write availableUpdate.
        guard updateCheckTask == nil else { return }
        updateCheckTask = Task {
            defer { updateCheckTask = nil }
            let info = await UpdateChecker.check()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: updateCheckKey)
            if let info {
                availableUpdate = info
                updateBannerDismissed = false
            } else if force {
                showToast(String(localized: "You’re on the latest version (\(UpdateChecker.currentVersion)).", bundle: .lumen))
            }
        }
    }

    // Crop & resize editor (non-destructive by default).
    var editTarget: Photo?
    var showEditor = false

    /// Open the crop/resize editor for a file-backed photo. Apple Photos assets
    /// have no editable file, so they're skipped.
    func startEdit(_ photo: Photo) {
        guard !photo.isAsset else {
            showToast(String(localized: "Apple Photos items can’t be edited (file photos only).", bundle: .lumen))
            return
        }
        editTarget = photo
        showEditor = true
    }

    // Combine multiple photos into one (non-destructive → new file).
    var combineTargets: [Photo] = []
    var showCombine = false

    func startCombine(_ photos: [Photo]) {
        let files = photos.filter { !$0.isAsset }
        guard files.count >= 2 else {
            showToast(String(localized: "Select 2 or more file photos to merge.", bundle: .lumen))
            return
        }
        combineTargets = files
        showCombine = true
    }

    func didCombine(output: URL) {
        revealNewFile(output)
        let location = "\(output.deletingLastPathComponent().lastPathComponent)/\(output.lastPathComponent)"
        showToast(String(localized: "Merged image saved · \(location)", bundle: .lumen))
    }

    // Batch resize/canvas → export many photos at once (non-destructive copies).
    var batchTargets: [Photo] = []
    var showBatchResize = false

    func startBatchResize(_ photos: [Photo]) {
        let files = photos.filter { !$0.isAsset }
        guard !files.isEmpty else {
            showToast(String(localized: "Select file photos to resize (Apple Photos excluded).", bundle: .lumen))
            return
        }
        batchTargets = files
        showBatchResize = true
    }

    func didBatchResize(count: Int, folder: URL) {
        showToast(String(localized: "Exported \(count) photos · \(folder.lastPathComponent)", bundle: .lumen))
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
            refreshDerivedCachesOffMain()
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
            showToast(String(localized: "Original replaced with the edit · \(source.lastPathComponent)", bundle: .lumen))
        } else {
            revealNewFile(output)            // add + select + scroll to the new copy
            showToast(String(localized: "Edit saved · \(output.lastPathComponent)", bundle: .lumen))
        }
    }

    // Transient status toast (friendly error/info messages), with an optional
    // action button (e.g. Undo after a deletion).
    private(set) var toast: String?
    private(set) var toastActionLabel: String?
    @ObservationIgnored private var toastAction: (() -> Void)?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    func showToast(_ message: String, actionLabel: String? = nil,
                   duration: TimeInterval = 3.5, action: (() -> Void)? = nil) {
        toast = message
        toastActionLabel = actionLabel
        toastAction = action
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissToast() }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
    func performToastAction() {
        let action = toastAction
        dismissToast()
        action?()
    }
    func dismissToast() {
        toastWork?.cancel()
        toast = nil
        toastActionLabel = nil
        toastAction = nil
    }

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
    /// Import progress lives in its own observable object so the scan's
    /// several-times-a-second ticks only re-render the status label.
    @ObservationIgnored let scanProgress = ScanMonitor()

    // MARK: - Background-job failures

    /// Photos a background pass could not process, surfaced in the status
    /// popover. Mirrors `JobFailureLog` (which the worker threads write) onto
    /// the main actor so SwiftUI can observe it.
    private(set) var jobFailures: [JobFailure] = []

    func failures(_ kind: JobFailure.Kind) -> [JobFailure] {
        jobFailures.filter { $0.kind == kind }
    }

    /// Pull the log onto the main actor. Coalesced: a failing chunk calls this
    /// once per 200 photos, and the popover only needs to be roughly live.
    @ObservationIgnored private var failureRefreshTask: Task<Void, Never>?
    func refreshJobFailures() {
        guard failureRefreshTask == nil else { return }
        failureRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.failureRefreshTask = nil
            self.jobFailures = JobFailureLog.shared.all()
        }
    }

    func loadJobFailures() { jobFailures = JobFailureLog.shared.all() }

    func clearFailures(_ kind: JobFailure.Kind) {
        JobFailureLog.shared.clear(kind: kind)
        jobFailures = JobFailureLog.shared.all()
    }

    /// Re-run the failed photos of one job.
    ///
    /// Both jobs skip work they believe is already done — the index skips paths
    /// present in `exif`, warming skips thumbnails already on disk — so a retry
    /// is "forget the record of the attempt, then let the normal pass find them
    /// again". That keeps one code path doing the work instead of a second,
    /// subtly different retry path.
    func retryFailures(_ kind: JobFailure.Kind) {
        let paths = Set(failures(kind).map(\.path))
        guard !paths.isEmpty else { return }
        JobFailureLog.shared.clear(kind: kind, paths: paths)
        jobFailures = JobFailureLog.shared.all()

        switch kind {
        case .metadata:
            // Failed reads were cached as empty entries so the main pass would
            // stop re-reading them; dropping those entries is what makes them
            // visible to `ensureExifIndex` again.
            var pruned = exif
            for path in paths { pruned.removeValue(forKey: path) }
            exif = pruned
            ensureExifIndex()
        case .thumbnail:
            // A failed thumbnail was never written to disk, so it is still in
            // the warm pass's todo list — restarting the pass picks it up.
            startThumbnailWarming()
        }
        showToast("Retrying \(paths.count.formatted()) \(kind.label.lowercased()) …")
    }

    func revealFailure(_ failure: JobFailure) {
        revealFolderInFinder(URL(filePath: failure.path, directoryHint: .notDirectory))
    }

    // MARK: Restart / rebuild

    /// Kick the warm pass again. Cheap: it skips every thumbnail already on
    /// disk, so this only picks up what is genuinely still missing — the useful
    /// move when a pass was interrupted or a volume came back.
    func restartThumbnailWarming() {
        startThumbnailWarming()
        showToast("Restarted thumbnail caching")
    }

    /// Throw the thumbnail cache away and build it again from zero. Hours on a
    /// NAS — the caller confirms first.
    func rebuildThumbnailCache() {
        JobFailureLog.shared.clear(kind: .thumbnail)
        jobFailures = JobFailureLog.shared.all()
        ThumbnailCache.shared.cancelWarming()
        ThumbnailCache.shared.clear()          // memory
        Task.detached(priority: .utility) {
            ThumbnailCache.shared.clearDisk()
            await MainActor.run { self.startThumbnailWarming() }
        }
        showToast("Rebuilding every thumbnail — this takes a while")
    }

    /// Discard the metadata index and read every photo again. Same cost shape
    /// as the thumbnail rebuild, and the only way to clear out the empty
    /// entries a failed read leaves behind.
    func rebuildMetadataIndex() {
        guard !isIndexingExif else {
            showToast("Metadata is already being read")
            return
        }
        JobFailureLog.shared.clear(kind: .metadata)
        jobFailures = JobFailureLog.shared.all()
        exif = [:]
        persistExifCache()
        ensureExifIndex()
        showToast("Re-reading metadata for every photo")
    }

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

    // Crash report from a previous session awaiting the user's decision.
    private(set) var pendingCrashReport: URL?
    var showCrashReportAlert = false

    init() {
        albums = store.albums
        store.onFirstWriteFailure = { [weak self] in
            Task { @MainActor in
                self?.showToast(String(localized: "Couldn’t save metadata changes — check disk space (favorites/albums may not persist).", bundle: .lumen))
            }
        }
        loadSettings()
        if let report = CrashReporter.pendingReports().first {
            pendingCrashReport = report
            showCrashReportAlert = true
        }
        watcher = FolderWatcher { [weak self] in self?.rescanRoots() }
        // Failures survive a quit — "저번에 실패한 곳" is only answerable if the
        // previous session's record is still there on the next launch.
        loadJobFailures()
        reopenRecentFolders()
        refreshOfflineRoots()
        observeVolumeMounts()
        // Demo/screenshot hook: auto-open a folder on launch (no effect normally).
        if let demo = ProcessInfo.processInfo.environment["LUMEN_OPEN_FOLDER"] {
            importURLs([URL(fileURLWithPath: demo)])
        }
    }

    // MARK: - Crash reporting (user-initiated only)

    func reportCrashOnGitHub() {
        guard let report = pendingCrashReport else { return }
        if let url = CrashReporter.gitHubIssueURL(for: report) {
            NSWorkspace.shared.open(url)
        }
        CrashReporter.markHandled(report)
        pendingCrashReport = nil
    }

    func dismissCrashReport() {
        guard let report = pendingCrashReport else { return }
        CrashReporter.markHandled(report)
        pendingCrashReport = nil
    }

    // MARK: - Organize history (timeline)

    var showHistory = false

    /// Snapshot of the recorded organizing actions, newest first. Read fresh
    /// each time the History sheet opens (not @Observable — it's a sheet, not
    /// a live grid).
    func operationHistory() -> [OperationLogEntry] { store.recentOperations() }

    /// Revert one logged action (restores the recorded before-state) and
    /// refresh the derived favorite/label counts + the visible grid.
    func undoOperation(_ id: Int64) {
        let affected = store.undoOperation(id)
        guard !affected.isEmpty else { return }
        albums = store.albums
        recomputeMetaCounts()
        bumpMeta()
        showToast(String(localized: "Reverted 1 action", bundle: .lumen))
    }

    func clearOperationHistory() { store.clearOperationHistory() }

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
        let changing = photos.filter { isFavorite($0) != value }
        store.update(paths: changing.map { $0.url.path },
                     logAs: (.favorite, value ? "Favorited" : "Unfavorited")) { $0.favorite = value }
        // Incremental — no full rescan. Clamp at 0: the count is derived and can
        // drift if a favorited photo wasn't in the index at last recompute.
        favoritesCount = max(0, favoritesCount + (value ? 1 : -1) * changing.count)
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
        store.update(paths: photos.map { $0.url.path },
                     logAs: (.rating, value == 0 ? "Cleared rating" : "Rated ★\(value)")) { $0.rating = value }
        bumpMeta()
    }

    // MARK: - Culling (reject flag)

    func isRejected(_ photo: Photo) -> Bool { meta(photo).rejected }

    func toggleRejected(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        let shouldReject = photos.contains { !isRejected($0) }
        store.update(paths: photos.map { $0.url.path },
                     logAs: (.reject, shouldReject ? "Rejected" : "Unrejected")) { $0.rejected = shouldReject }
        bumpMeta()
    }

    func setLabel(_ label: ColorLabel, for photos: [Photo]) {
        let changing = photos.filter { self.label($0) != label }
        for photo in changing {
            let old = self.label(photo)
            if old != .none { labelCounts[old] = max(0, (labelCounts[old] ?? 0) - 1) }
            if label != .none { labelCounts[label, default: 0] += 1 }
        }
        store.update(paths: changing.map { $0.url.path },
                     logAs: (.label, label == .none ? "Cleared label" : "Labeled \(label.title)")) { $0.label = label }
        bumpMeta()
    }

    func addTag(_ tag: String, to photos: [Photo]) {
        let clean = tag.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        store.update(paths: photos.map { $0.url.path },
                     logAs: (.tag, "Tagged “\(clean)”")) {
            if !$0.tags.contains(clean) { $0.tags.append(clean) }
        }
        bumpMeta()
    }

    func removeTag(_ tag: String, from photos: [Photo]) {
        store.update(paths: photos.map { $0.url.path },
                     logAs: (.tag, "Untagged “\(tag)”")) { $0.tags.removeAll { $0 == tag } }
        bumpMeta()
    }

    @ObservationIgnored private var allTagsCache: [(tag: String, count: Int)] = []
    @ObservationIgnored private var allTagsCacheKey = -1
    /// Tag list + counts for the sidebar. Cached on metaRevision (an observed
    /// property, so reading it keeps SidebarView reactive) — store.allTags() scans
    /// the whole metadata mirror and sorts, and SidebarView.tagsSection calls this
    /// on every body evaluation, not just when a tag actually changes.
    func allTags() -> [(tag: String, count: Int)] {
        if allTagsCacheKey == metaRevision { return allTagsCache }
        allTagsCache = store.allTags()
        allTagsCacheKey = metaRevision
        return allTagsCache
    }

    /// Kick off background warming of the on-disk thumbnail cache for every
    /// photo, so navigating to any folder is instant even on a NAS. The scope
    /// the user is currently looking at warms first, then the rest of the library.
    @ObservationIgnored private var warmRestartWork: DispatchWorkItem?

    /// Restart warming, but not more than once per burst. Sizing a pass hashes
    /// every entry in the library (~3s at 107k), and it cancels whatever the
    /// warm queue was doing — so a run of library changes that each called this
    /// directly meant warming was perpetually re-sized and never ran.
    private func scheduleThumbnailWarming() {
        warmRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startThumbnailWarming() }
        warmRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func startThumbnailWarming() {
        var entries = allPhotos.map { (url: $0.url, mtime: $0.cacheMtime) }
        let visible = gatherUnsorted()
        if !visible.isEmpty, visible.count < allPhotos.count {
            let priority = Set(visible.map(\.url))
            var front: [(url: URL, mtime: TimeInterval)] = []
            var back: [(url: URL, mtime: TimeInterval)] = []
            front.reserveCapacity(priority.count)
            for entry in entries {
                if priority.contains(entry.url) { front.append(entry) } else { back.append(entry) }
            }
            entries = front + back
        }
        // One-time: adopt thumbnails built under the old absolute-path key
        // before deciding what still needs building, or the warm pass would
        // re-read from the NAS what is already sitting on disk.
        migrateThumbnailKeysIfNeeded(entries)

        // Match the read pace to where the photos actually live: an SMB read
        // spends its time waiting, so a few more concurrent readers overlap
        // that wait instead of queueing behind it.
        let networkPrefixes = Self.networkVolumePrefixes()
        let onNetwork = !networkPrefixes.isEmpty && entries.contains { entry in
            networkPrefixes.contains { entry.url.path.hasPrefix($0) }
        }
        ThumbnailCache.shared.setWarmLanes(onNetwork ? ThumbnailCache.networkWarmLanes
                                                     : ThumbnailCache.localWarmLanes)
        ThumbnailCache.shared.warmDiskCache(entries) { [weak self] remaining, total, path in
            self?.warming.update(remaining: remaining, total: total, currentPath: path)
        }
        sweepStaleThumbnailsIfDue(entries)
    }

    /// Adopt thumbnails built under the pre-0.5.9 absolute-path key. Once per
    /// install: the rename is cheap but it is a full pass over the library, and
    /// after it there is nothing left keyed the old way.
    private static let thumbnailKeyMigrationKey = "lumen.thumbKeyMigration.v1"
    private func migrateThumbnailKeysIfNeeded(_ entries: [(url: URL, mtime: TimeInterval)]) {
        guard !entries.isEmpty,
              !UserDefaults.standard.bool(forKey: Self.thumbnailKeyMigrationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.thumbnailKeyMigrationKey)
        Task.detached(priority: .utility) {
            let moved = ThumbnailCache.shared.migrateLegacyKeys(entries)
            guard moved > 0 else { return }
            await MainActor.run { [weak self] in
                self?.showToast("Kept \(moved.formatted()) existing thumbnails")
                // The warm pass was sized before the rename landed; re-run it so
                // the adopted entries drop out of the todo list.
                self?.startThumbnailWarming()
            }
        }
    }

    /// Garbage-collect disk-cache thumbnails the library can no longer
    /// reference (orphaned by a volume move or re-copied files — gigabytes
    /// after a 60k-photo move). Throttled to once a day; photos under offline
    /// roots are still in `entries`, so their cache survives a disconnect.
    private static let thumbnailSweepKey = "lumen.lastThumbnailSweep"
    private func sweepStaleThumbnailsIfDue(_ entries: [(url: URL, mtime: TimeInterval)]) {
        let files = entries.filter { $0.url.scheme != Photo.assetScheme }
        guard !files.isEmpty else { return }   // never sweep against an empty library
        let last = UserDefaults.standard.double(forKey: Self.thumbnailSweepKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.thumbnailSweepKey)
        Task.detached(priority: .background) {
            ThumbnailCache.shared.sweepStaleDiskEntries(validEntries: files)
        }
    }

    /// Full recompute of the favorite/label counts — only on library changes
    /// (import, delete, rename), not on individual metadata edits.
    /// Iterates the metadata mirror (photos that HAVE meta — usually a handful),
    /// not the whole library: the 67k-photo loop measured ~80ms on main.
    /// Membership in the library is checked so stale rows don't inflate counts.
    private func recomputeMetaCounts() {
        var favorites = 0
        var labels: [ColorLabel: Int] = [:]
        let index = photoByID
        for (path, m) in store.items {
            guard m.favorite || m.label != .none else { continue }
            // URL(filePath:directoryHint:), NEVER URL(fileURLWithPath:) — the
            // latter stats the path to sniff directories, ~7ms each on a NAS
            // (a few hundred favorited photos would freeze the main thread).
            guard index[URL(filePath: path, directoryHint: .notDirectory)] != nil else { continue }
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

    // Cached: the sidebar body re-sorts this on every evaluation otherwise,
    // and localizedStandardCompare over hundreds of folders isn't free.
    @ObservationIgnored private var photoFoldersCache: [URL] = []
    @ObservationIgnored private var photoFoldersCacheKey = -1
    var photoFolders: [URL] {
        if libraryVersion == photoFoldersCacheKey { return photoFoldersCache }
        photoFoldersCache = stats.folderCounts.keys
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        photoFoldersCacheKey = libraryVersion
        return photoFoldersCache
    }

    // Cached: FilterMenu's body reads these (twice each), and rebuilding the
    // camera set from 60k+ EXIF entries cost ~53ms per read — a measured
    // 106-112ms toolbar body eval on every filter interaction.
    @ObservationIgnored private var fileTypesCache: [String] = []
    @ObservationIgnored private var fileTypesCacheKey = -1
    var availableFileTypes: [String] {
        if libraryVersion == fileTypesCacheKey { return fileTypesCache }
        fileTypesCache = Set(allPhotos.map { $0.fileExtension }).sorted()
        fileTypesCacheKey = libraryVersion
        return fileTypesCache
    }

    @ObservationIgnored private var camerasCache: [String] = []
    @ObservationIgnored private var camerasCacheKey = -1
    var availableCameras: [String] {
        if indexVersion == camerasCacheKey { return camerasCache }
        camerasCache = Set(exif.values.compactMap { $0.cameraDisplay }).sorted()
        camerasCacheKey = indexVersion
        return camerasCache
    }

    /// Photos restricted to the current sidebar scope. Preserves the input
    /// order (which is already sorted) except for album scope, which can use
    /// its own manual order.
    private func scoped(_ photos: [Photo]) -> [Photo] {
        let scope = committedSidebar
        var albumPaths: [String]?
        if case .album(let id) = scope {
            albumPaths = albums.first(where: { $0.id == id })?.photoPaths
        }
        return Self.scopePass(photos, scope: scope,
                              metaByPath: Self.scopeNeedsMeta(scope) ? store.items : [:],
                              duplicatePaths: duplicatePaths,
                              albumPaths: albumPaths,
                              byFolder: directPhotosByFolder)
    }

    /// Whether the scope's membership test reads per-photo metadata (the pass
    /// then needs the metadata mirror snapshot).
    nonisolated static func scopeNeedsMeta(_ scope: SidebarItem) -> Bool {
        switch scope {
        case .favorites, .label, .tag: return true
        default: return false
        }
    }

    /// Whether the scope pass costs O(photos) with per-photo work — these are
    /// the scopes that froze the main thread when entered on a large library
    /// (Favorites measured 94ms at 66.8k photos) and must run off-main there.
    /// Folder is excluded: it walks the folder index, not the photo list.
    nonisolated static func scopeIsExpensive(_ scope: SidebarItem) -> Bool {
        switch scope {
        case .favorites, .recentlyAdded, .onThisDay, .duplicates, .label, .tag, .album:
            return true
        default:
            return false
        }
    }

    /// The scope membership pass as a pure function over value snapshots, so
    /// large libraries can run it OFF the main thread together with the sort.
    /// `albumPaths` is the resolved album membership (nil = album gone → []).
    nonisolated static func scopePass(
        _ photos: [Photo], scope: SidebarItem,
        metaByPath: [String: PhotoMeta],
        duplicatePaths: Set<String>,
        albumPaths: [String]?,
        byFolder: [String: [Photo]],
        now: Date = Date(),
        calendar: Calendar = Calendar.current
    ) -> [Photo] {
        switch scope {
        case .allPhotos, .photosLibrary, .photosAlbum:
            return photos
        case .favorites:
            return photos.filter { metaByPath[$0.url.path]?.favorite ?? false }
        case .recentlyAdded:
            let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
            return photos.filter { ($0.creationDate ?? .distantPast) >= cutoff }
        case .onThisDay:
            let today = calendar.dateComponents([.month, .day], from: now)
            return photos.filter {
                guard let date = $0.creationDate else { return false }
                let c = calendar.dateComponents([.month, .day], from: date)
                return c.month == today.month && c.day == today.day
            }
        case .duplicates:
            return photos.filter { duplicatePaths.contains($0.url.path) }
        case .label(let label):
            return photos.filter { (metaByPath[$0.url.path]?.label ?? .none) == label }
        case .album:
            guard let albumPaths else { return [] }
            let membership = Set(albumPaths)
            return photos.filter { membership.contains($0.url.path) }  // sorted later
        case .tag(let tag):
            return photos.filter { metaByPath[$0.url.path]?.tags.contains(tag) ?? false }
        case .folder(let url):
            // Folder + descendants via the folder index (iterate folders, not photos).
            let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
            var result: [Photo] = []
            for (folderPath, folderPhotos) in byFolder
            where folderPath == url.path || folderPath.hasPrefix(prefix) {
                result.append(contentsOf: folderPhotos)
            }
            return result  // sorted later
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
    // (Computed: @ObservationIgnored is only meaningful on stored properties.)
    private var viewDependsOnMeta: Bool {
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
    private var viewDependsOnExif: Bool {
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
        // Time-relative scopes read Date() — fold the day in so an app left
        // running overnight doesn't keep showing yesterday's "On This Day".
        switch committedSidebar {
        case .recentlyAdded, .onThisDay:
            hasher.combine(Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0)
        default: break
        }
        return hasher.finalize()
    }

    /// Cheap token that changes only when `visiblePhotos` would change — use it
    /// to trigger prefetching without diffing the whole array.
    var visibleToken: Int { visibleSignature }

    /// Changes only when the user navigates somewhere else (scope, sort,
    /// search, filter) — use it to reset scroll position. Unlike
    /// `visibleToken` it ignores library edits (delete/import), where the
    /// scroll position should be kept.
    var navigationToken: Int {
        var hasher = Hasher()
        hasher.combine(committedSidebar)
        hasher.combine(sortOrder)
        hasher.combine(searchText)
        hasher.combine(filter)
        return hasher.finalize()
    }

    /// True while a large scope's sort is running on a background thread (the
    /// grid shows the previous content + a spinner until it lands).
    private(set) var isSortingVisible = false

    @ObservationIgnored private var lastVisible: [Photo] = []
    @ObservationIgnored private var sortTask: Task<Void, Never>?
    @ObservationIgnored private var sortInFlightKey = -1
    @ObservationIgnored private let asyncSortThreshold = 4000

    /// Scope + filter + search WITHOUT sorting (cheap; safe on the main thread).
    /// Used by callers that need the unsorted set (e.g. thumbnail warming) —
    /// `visiblePhotos` runs the same pass off-main for large scopes.
    private func gatherUnsorted() -> [Photo] {
        let base = scoped(sourcePhotos)
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard filter.isActive || !query.isEmpty else { return base }
        return Self.filterAndSearch(base, filter: filter, query: query,
                                    names: query.isEmpty ? [:] : lowerNames,
                                    cams: query.isEmpty ? [:] : lowerCameras,
                                    tags: lowercasedTags(query: query),
                                    metaByPath: store.items, exif: exif)
    }

    private func lowercasedTags(query: String) -> [String: [String]] {
        guard !query.isEmpty else { return [:] }
        return store.items.compactMapValues { $0.tags.isEmpty ? nil : $0.tags.map { $0.lowercased() } }
    }

    /// Filter + search as a pure function over value snapshots, so large scopes
    /// can run it OFF the main thread — one search over 67k photos measured
    /// 380-430ms, which froze the UI when run inside a body evaluation.
    /// Lookups (lowercased names/cameras/tags) are prepared once by the caller:
    /// lowercasing the camera string per photo was most of that cost.
    nonisolated private static func filterAndSearch(
        _ base: [Photo], filter f: FilterState, query: String,
        names: [URL: String], cams: [String: String], tags: [String: [String]],
        metaByPath: [String: PhotoMeta], exif: [String: ExifInfo]
    ) -> [Photo] {
        let filterActive = f.isActive
        guard filterActive || !query.isEmpty else { return base }
        return base.filter { photo in
            let path = photo.url.path   // computed once — URL.path allocates
            if filterActive {
                if let type = f.fileType, photo.fileExtension != type { return false }
                let m = metaByPath[path] ?? PhotoMeta()
                if f.minRating > 0, m.rating < f.minRating { return false }
                if let label = f.label, m.label != label { return false }
                if f.favoritesOnly, !m.favorite { return false }
                if f.hideRejected, m.rejected { return false }
                if f.gpsOnly, !(exif[path]?.hasGPS ?? false) { return false }
                if let camera = f.camera, exif[path]?.cameraDisplay != camera { return false }
            }
            if !query.isEmpty {
                let matches = (names[photo.url]?.contains(query) ?? false)
                    || (tags[path]?.contains { $0.contains(query) } ?? false)
                    || (cams[path]?.contains(query) ?? false)
                if !matches { return false }
            }
            return true
        }
    }

    // Pre-lowercased camera names for search, rebuilt only when the EXIF index
    // changes — never per keystroke, never per photo.
    @ObservationIgnored private var lowerCameraCache: [String: String] = [:]
    @ObservationIgnored private var lowerCameraKey = -1
    @ObservationIgnored private var lowerCameras: [String: String] {
        if indexVersion == lowerCameraKey { return lowerCameraCache }
        lowerCameraCache = exif.compactMapValues { $0.cameraDisplay?.lowercased() }
        lowerCameraKey = indexVersion
        return lowerCameraCache
    }

    /// The active sort as a Sendable closure, so large scopes — including
    /// albums with a manual order — can sort off the main thread.
    /// Album scope keeps its manual order unless explicitly sorted.
    private func currentSorter() -> @Sendable ([Photo]) -> [Photo] {
        if case .album(let id) = committedSidebar, sortOrder == .dateNewest,
           let album = albums.first(where: { $0.id == id }) {
            let order = Dictionary(uniqueKeysWithValues: album.photoPaths.enumerated().map { ($1, $0) })
            return { photos in photos.sorted { (order[$0.url.path] ?? 0) < (order[$1.url.path] ?? 0) } }
        }
        let order = sortOrder
        return { order.sorted($0) }
    }

    /// Bumped whenever a freshly sorted result lands in the cache — derived
    /// caches (e.g. `monthGroups`) key on this to pick up async sort results.
    @ObservationIgnored private var visibleResultRevision = 0

    private func cacheVisible(_ key: Int, _ result: [Photo]) {
        // Re-caching an existing key (an async sort landing twice) must not
        // append a duplicate to the LRU order — evicting the first occurrence
        // would delete the live map entry while the key stays queued.
        if visibleCacheMap[key] == nil { visibleCacheOrder.append(key) }
        visibleCacheMap[key] = result
        visibleResultRevision &+= 1
        if visibleCacheOrder.count > visibleCacheCapacity {
            visibleCacheMap.removeValue(forKey: visibleCacheOrder.removeFirst())
        }
    }

    /// Final ordered list shown in the detail area. Small scopes filter + sort
    /// inline; large ones run BOTH off the main thread (filtering 67k photos
    /// for a search measured 380-430ms — as costly as the sort it preceded).
    var visiblePhotos: [Photo] {
        let key = visibleSignature
        if let hit = visibleCacheMap[key] { lastVisible = hit; cancelSupersededSort(currentKey: key); return hit }

        let source = sourcePhotos
        let scope = committedSidebar
        // Expensive membership scopes (Favorites/Label/Tag/…) on a large
        // library: don't pay the O(photos) scope pass on the main thread —
        // route scope + filter + sort off-main together. (Entering Favorites
        // ran the pass synchronously and measured 94ms at 66.8k photos.)
        let offloadScope = Self.scopeIsExpensive(scope) && source.count > asyncSortThreshold
        let base = offloadScope ? source : scoped(source)
        let sorter = currentSorter()
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let f = filter
        let needsPass = f.isActive || !query.isEmpty
        // Value snapshots for the (possibly off-main) pass — all COW, no copying.
        let names = query.isEmpty ? [:] : lowerNames
        let tags = lowercasedTags(query: query)
        let metaByPath = (needsPass || (offloadScope && Self.scopeNeedsMeta(scope))) ? store.items : [:]
        let exifSnapshot = needsPass ? exif : [:]

        if !offloadScope, base.count <= asyncSortThreshold {
            // Small scope: camera-name lookups built per-base (O(base), ~ms) —
            // NOT from the full 67k EXIF index, which costs ~200ms.
            var cams: [String: String] = [:]
            if !query.isEmpty {
                if lowerCameraKey == indexVersion {
                    cams = lowerCameraCache
                } else {
                    for p in base {
                        let path = p.url.path
                        if let c = exif[path]?.cameraDisplay { cams[path] = c.lowercased() }
                    }
                }
            }
            let gathered = needsPass
                ? Self.filterAndSearch(base, filter: f, query: query, names: names,
                                       cams: cams, tags: tags, metaByPath: metaByPath, exif: exifSnapshot)
                : base
            let sorted = sorter(gathered)
            cacheVisible(key, sorted)
            lastVisible = sorted
            cancelSupersededSort(currentKey: key)
            return sorted
        }

        // Large: filter + sort off-main; show the previous list + spinner until
        // ready. The lowercased-camera lookup is built inside the detached task
        // too (lowercasing 67k EXIF entries measured ~200ms on the main thread),
        // then installed back into the cache for subsequent keystrokes.
        if sortInFlightKey != key {
            sortInFlightKey = key
            sortTask?.cancel()
            let camsCached = (!query.isEmpty && lowerCameraKey == indexVersion) ? lowerCameraCache : nil
            let indexVersionSnapshot = indexVersion
            let wantsCams = !query.isEmpty
            // Scope-pass snapshots for the offloaded membership scan.
            let dupSnapshot = offloadScope ? duplicatePaths : []
            var albumSnapshot: [String]?
            if case .album(let id) = scope {
                albumSnapshot = albums.first(where: { $0.id == id })?.photoPaths
            }
            sortTask = Task { [weak self] in
                await MainActor.run { self?.isSortingVisible = true }
                let (sorted, builtCams) = await Task.detached(priority: .userInitiated) {
                    () -> ([Photo], [String: String]?) in
                    var cams: [String: String] = [:]
                    var built: [String: String]?
                    if wantsCams {
                        if let camsCached { cams = camsCached }
                        else {
                            cams = exifSnapshot.compactMapValues { $0.cameraDisplay?.lowercased() }
                            built = cams
                        }
                    }
                    let scopedBase = offloadScope
                        ? AppModel.scopePass(base, scope: scope, metaByPath: metaByPath,
                                             duplicatePaths: dupSnapshot, albumPaths: albumSnapshot,
                                             byFolder: [:])
                        : base
                    let gathered = needsPass
                        ? AppModel.filterAndSearch(scopedBase, filter: f, query: query, names: names,
                                                   cams: cams, tags: tags, metaByPath: metaByPath, exif: exifSnapshot)
                        : scopedBase
                    return (sorter(gathered), built)
                }.value
                // This Task inherits @MainActor, so execution resumes here on the
                // main actor after the detached work — the writes below are
                // main-actor-confined (no data race) without an explicit hop.
                guard let self else { return }
                // Superseded (a navigation to a cache-hit/small scope cancelled us):
                // bail before touching state. The detached CPU work already ran, but
                // we skip the now-pointless cache/spinner writes — and the late
                // guards below would no-op anyway.
                if Task.isCancelled { return }
                if let builtCams, self.indexVersion == indexVersionSnapshot {
                    self.lowerCameraCache = builtCams
                    self.lowerCameraKey = indexVersionSnapshot
                }
                if self.visibleSignature == key {
                    self.cacheVisible(key, sorted)
                    self.lastVisible = sorted
                }
                // Only the task that still OWNS the in-flight slot may clear it
                // — a superseded sort finishing late would otherwise hide the
                // spinner of (and force a duplicate of) the newer sort.
                if self.sortInFlightKey == key {
                    self.sortInFlightKey = -1
                    self.isSortingVisible = false
                }
            }
        }
        return lastVisible
    }

    /// A large-scope sort started for a PREVIOUS scope is now superseded: we're
    /// serving a cache hit or a synchronously-computed small scope for `currentKey`.
    /// Cancel it and drop its spinner so it doesn't linger over already-settled
    /// content (the task's late-landing guards already stop it applying stale data).
    /// Writing the observed `isSortingVisible` here happens at most once per orphan
    /// episode (the guard makes it idempotent), so it can't loop view updates.
    private func cancelSupersededSort(currentKey: Int) {
        guard sortInFlightKey != -1, sortInFlightKey != currentKey else { return }
        sortTask?.cancel()
        sortInFlightKey = -1
        isSortingVisible = false
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
        statsCache = Self.computeStats(allPhotos)
        statsCacheKey = libraryVersion
        return statsCache
    }

    /// Pure stats pass — Calendar.dateComponents per photo costs ~100ms at 67k,
    /// so the library-load and reconcile paths run this off-main and install
    /// the result, keeping the first post-load sidebar body cheap.
    nonisolated private static func computeStats(_ photos: [Photo]) -> LibraryStats {
        var s = LibraryStats()
        let cal = Calendar.current
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let today = cal.dateComponents([.month, .day], from: Date())
        for photo in photos {
            s.folderCounts[photo.folderURL, default: 0] += 1
            if let date = photo.creationDate {
                if date >= cutoff { s.recentlyAdded += 1 }
                let c = cal.dateComponents([.month, .day], from: date)
                if c.month == today.month && c.day == today.day { s.onThisDay += 1 }
            }
        }
        return s
    }

    /// Adopt stats that were computed off-main for the CURRENT library content.
    private func installStats(_ s: LibraryStats) {
        statsCache = s
        statsCacheKey = libraryVersion
    }

    /// The date-derived half of LibraryStats (the Calendar.dateComponents loop,
    /// ~110ms at 67k) — split out so the launch path can run it CONCURRENTLY
    /// with the index build; folderCounts comes free from the folder index.
    nonisolated private static func computeDateStats(_ photos: [Photo]) -> (recentlyAdded: Int, onThisDay: Int) {
        let cal = Calendar.current
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let today = cal.dateComponents([.month, .day], from: Date())
        var recent = 0, otd = 0
        for photo in photos {
            guard let date = photo.creationDate else { continue }
            if date >= cutoff { recent += 1 }
            let c = cal.dateComponents([.month, .day], from: date)
            if c.month == today.month && c.day == today.day { otd += 1 }
        }
        return (recent, otd)
    }

    /// folderCounts derived from the (already grouped) folder index — one URL
    /// per folder via a member photo's folderURL, so keys normalize exactly
    /// like every other folderURL use. (Never URL(fileURLWithPath:) — it stats
    /// the path, ~7ms each on a NAS.)
    nonisolated private static func folderCounts(from byFolder: [String: [Photo]]) -> [URL: Int] {
        Dictionary(uniqueKeysWithValues: byFolder.compactMap { _, photos in
            photos.first.map { ($0.folderURL, photos.count) }
        })
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

        // Build a parent → children map once (O(folders) — a linear
        // contains(where:) here made this O(folders²), ~100ms at 600 folders).
        let nodePaths = Set(nodeURLs.map(\.path))
        var childrenMap: [String: [URL]] = [:]
        for url in nodeURLs {
            let parent = url.deletingLastPathComponent().path
            if nodePaths.contains(parent) {
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

    @ObservationIgnored private var monthGroupsCache:
        (key: Int, revision: Int, groups: [(title: String, photos: [Photo])])?

    /// Photos grouped by month for the timeline layout. Cached per visible
    /// result so body re-evaluations don't re-group the whole list — the
    /// revision picks up async sort results that land under the same signature.
    var monthGroups: [(title: String, photos: [Photo])] {
        let photos = visiblePhotos   // computed first: may refresh the revision
        let key = visibleSignature
        if let cached = monthGroupsCache, cached.key == key,
           cached.revision == visibleResultRevision {
            return cached.groups
        }
        let cal = Calendar.current
        // Group by an integer year*100+month key: ONE Calendar.dateComponents per
        // photo (the title's date is reconstructed once per group), halving the
        // per-photo ICU cost vs the previous dateComponents + date(from:) pair.
        // The Int key sorts chronologically, matching the old Date sort.
        let grouped = Dictionary(grouping: photos) { photo -> Int in
            let c = cal.dateComponents([.year, .month], from: photo.creationDate ?? .distantPast)
            return (c.year ?? 0) * 100 + (c.month ?? 0)
        }
        let groups = grouped.keys.sorted(by: >).map { ym -> (title: String, photos: [Photo]) in
            let date = cal.date(from: DateComponents(year: ym / 100, month: ym % 100)) ?? .distantPast
            return (title: Self.monthFormatter.string(from: date), photos: grouped[ym] ?? [])
        }
        monthGroupsCache = (key, visibleResultRevision, groups)
        return groups
    }

    @ObservationIgnored private var geotaggedCache: [(photo: Photo, latitude: Double, longitude: Double)] = []
    @ObservationIgnored private var geotaggedCacheKey: (Int, Int, Int)?
    /// Photos that have GPS coordinates, for the map. Cached on
    /// (visibleSignature, indexVersion, visibleResultRevision): the map body reads
    /// this (and its .count/.isEmpty) several times per evaluation, and uncached it
    /// was an O(visible) string-alloc + EXIF lookup over the whole 60k scope each
    /// time. `let snapshot = exif` is read unconditionally so SwiftUI re-evaluates
    /// when the EXIF index changes (which also bumps indexVersion → cache miss).
    var geotaggedPhotos: [(photo: Photo, latitude: Double, longitude: Double)] {
        let photos = visiblePhotos
        let snapshot = exif
        let key = (visibleSignature, indexVersion, visibleResultRevision)
        if let cached = geotaggedCacheKey, cached == key { return geotaggedCache }
        let result = photos.compactMap { photo -> (photo: Photo, latitude: Double, longitude: Double)? in
            guard let info = snapshot[photo.url.path], let lat = info.latitude, let lon = info.longitude else { return nil }
            return (photo, lat, lon)
        }
        geotaggedCache = result
        geotaggedCacheKey = key
        return result
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

    /// Re-fires the map's location scan when the scope changes OR an off-main sort
    /// settles (a result lands without changing `visibleSignature`, only the
    /// revision). Observable — `PhotoMapView` keys its `.task` on this so the map
    /// isn't left scanning a stale list.
    var assetMapScanToken: Int {
        var hasher = Hasher()
        hasher.combine(visibleSignature)
        hasher.combine(isSortingVisible)
        return hasher.finalize()
    }

    /// Scan the current Photos scope's geotagged assets on a background thread and
    /// stream pins to the map in batches, so the map shows immediately and fills
    /// in progressively (reading 70k `PHAsset.location`s on the main thread froze
    /// the app). Capped at `assetMapPinLimit`.
    func ensureAssetMapPins() {
        guard committedSidebar.isPhotosLibrarySource else { return }
        let photos = visiblePhotos
        // If reading visiblePhotos found (or just kicked) an off-main sort for this
        // scope, `photos` is the stale previous list — skip; PhotoMapView re-fires
        // this when the sort settles (assetMapScanToken changes).
        guard sortInFlightKey != visibleSignature else { return }
        // Fold visibleResultRevision into the key so a sort landing under the same
        // signature re-scans against the FINAL list (mirrors monthGroups).
        var hasher = Hasher()
        hasher.combine(visibleSignature)
        hasher.combine(visibleResultRevision)
        let key = hasher.finalize()
        guard assetMapKey != key else { return }
        assetMapKey = key
        isLoadingAssetMap = true
        assetMapPins = []
        assetMapTruncated = false
        let limit = Self.assetMapPinLimit
        // Rebind weak→strong once: referencing a captured weak VAR from the
        // inner MainActor closures is a Swift 6 sendability error. AppModel
        // lives for the app's lifetime, so holding it during the scan is fine.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var batch: [(photo: Photo, latitude: Double, longitude: Double)] = []
            var total = 0
            for photo in photos {
                guard let c = PhotosImageLoader.shared.location(for: photo.url) else { continue }
                batch.append((photo: photo, latitude: c.latitude, longitude: c.longitude))
                total += 1
                if batch.count >= 40 || total >= limit {
                    let chunk = batch; batch = []
                    await MainActor.run { self.appendAssetMapPins(chunk, forKey: key) }
                }
                if total >= limit {
                    await MainActor.run { self.finishAssetMap(forKey: key, truncated: true) }
                    return
                }
            }
            let chunk = batch
            await MainActor.run {
                self.appendAssetMapPins(chunk, forKey: key)
                self.finishAssetMap(forKey: key, truncated: false)
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

    /// O(selection) via the id index — scanning all 60k+ photos per access made
    /// every selection change cost ~20ms × several body evals (measured 40-67ms
    /// per InspectorView body). Sorted by path so batch actions (rename, export)
    /// keep a stable, file-system-like order. Paths are extracted once before
    /// sorting: URL.path allocates per call, and localizedStandardCompare inside
    /// the sort measured 33ms for a 500-photo selection.
    /// Cached per (selection, library) — InspectorView reads this twice per body
    /// eval, and a select-all of 67k measured 170ms per uncached access.
    @ObservationIgnored private var selectedPhotosCache: [Photo] = []
    // Optional sentinel: nil can never collide with a real key (a fixed tuple
    // sentinel could, in principle, match a real signature).
    @ObservationIgnored private var selectedPhotosCacheKey: (Int, Int, Int, Int, Int)?
    var selectedPhotos: [Photo] {
        // visibleSignature is part of the key because huge selections take
        // their ORDER from visiblePhotos — a sort/filter change after ⌘A must
        // not serve a stale ordering to order-sensitive batch actions (rename).
        // visibleResultRevision too: an off-main sort lands without changing the
        // signature, so without it the cache would keep serving the pre-sort order
        // (same reason monthGroups keys on it).
        let key = (selectionRevision, libraryVersion, assetsVersion, visibleSignature, visibleResultRevision)
        if let cached = selectedPhotosCacheKey, cached == key { return selectedPhotosCache }
        let result = computeSelectedPhotos()
        selectedPhotosCache = result
        selectedPhotosCacheKey = key
        return result
    }

    private func computeSelectedPhotos() -> [Photo] {
        // Big selection (e.g. ⌘A on a 67k scope): one pass over the visible
        // list keeps display order and skips the per-item sort.
        if selection.count > 5000 {
            let result = visiblePhotos.filter { selection.contains($0.id) }
            if result.count == selection.count { return result }
            // Selected ids outside the current scope — fall through.
        }
        let index = photoByID
        return selection.compactMap { id -> (String, Photo)? in
            guard let p = index[id] else { return nil }
            return (p.url.path, p)
        }
        .sorted { $0.0 < $1.0 }
        .map { $0.1 }
    }

    // O(1) photo lookup by id, rebuilt only when the library or Photos assets
    // change. Includes Apple Photos assets (library + the open album) so the
    // inspector and viewer resolve a selected asset, not just file photos.
    @ObservationIgnored private var idIndexCache: [URL: Photo] = [:]
    @ObservationIgnored private var idIndexKey = (-1, -1)
    @ObservationIgnored private var photoByID: [URL: Photo] {
        let key = (libraryVersion, assetsVersion)
        if key == idIndexKey { return idIndexCache }
        var dict = Dictionary(allPhotos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        for p in assetPhotos where dict[p.url] == nil { dict[p.url] = p }
        for p in assetAlbumPhotos where dict[p.url] == nil { dict[p.url] = p }
        idIndexCache = dict
        idIndexKey = key
        return idIndexCache
    }

    func photo(for id: Photo.ID) -> Photo? { photoByID[id] }

    /// Per-library derived indexes, precomputed off-main on load/reconcile so
    /// their first on-main access doesn't stall: id lookup (~25ms), folder
    /// index (~150ms on first folder click), lowercased names for search
    /// (~100ms on first keystroke) — all measured at 67k photos.
    private struct DerivedIndexes: Sendable {
        var byID: [URL: Photo] = [:]
        var byFolder: [String: [Photo]] = [:]
        var lowerNames: [URL: String] = [:]
    }

    /// The folder-index key for one photo. Parent path by string slicing —
    /// equivalent to folderURL.path for the absolute file URLs we store, and
    /// ~4x faster than going through URL.deletingLastPathComponent (179ms →
    /// ~40ms at 67k, measured; this build gates the launch spinner).
    /// Single definition on purpose: the full rebuild and the incremental
    /// append (`appendScanned`) must produce byte-identical keys, or a folder
    /// click after an import would miss half its photos.
    nonisolated static func folderKey(for photo: Photo) -> String {
        let path = photo.url.path
        if let slash = path.lastIndex(of: "/"), slash != path.startIndex {
            return String(path[..<slash])
        }
        return photo.folderURL.path
    }

    nonisolated private static func computeDerivedIndexes(_ photos: [Photo]) -> DerivedIndexes {
        var d = DerivedIndexes()
        d.byID = Dictionary(photos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        d.byFolder = Dictionary(grouping: photos, by: Self.folderKey(for:))
        d.lowerNames = Dictionary(photos.map { ($0.url, $0.filename.lowercased()) },
                                  uniquingKeysWith: { a, _ in a })
        return d
    }

    private func installDerivedIndexes(_ d: DerivedIndexes) {
        // photoByID also merges Photos-library assets — only install the
        // file-photo base when no assets are loaded; otherwise let the getter
        // rebuild lazily (assets keep their own version key).
        if assetPhotos.isEmpty, assetAlbumPhotos.isEmpty {
            idIndexCache = d.byID
            idIndexKey = (libraryVersion, assetsVersion)
        }
        folderIndexCache = d.byFolder
        folderIndexKey = libraryVersion
        lowerNameCache = d.lowerNames
        lowerNameKey = libraryVersion
    }

    @ObservationIgnored private var derivedRefreshTask: Task<Void, Never>?
    /// After a direct edit mutates `allPhotos` (bumping libraryVersion), recompute
    /// the heavy derived caches (stats + DerivedIndexes) OFF the main actor and
    /// install them — so the next sidebar render / folder click / search keystroke
    /// is a cache hit instead of a ~100-150ms main-thread rebuild. reconcile() and
    /// installLoadedLibrary() already do this on their paths; the direct-edit
    /// handlers (scan/add, remove/rename root, delete, undo-delete, reveal) did not,
    /// so every edit was followed by a stall on the next interaction. Coalesces
    /// rapid edits (culling): a newer edit cancels the in-flight refresh so only the
    /// latest result installs.
    private func refreshDerivedCachesOffMain() {
        derivedRefreshTask?.cancel()
        let snapshot = allPhotos
        let version = libraryVersion
        derivedRefreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                (stats: Self.computeStats(snapshot), indexes: Self.computeDerivedIndexes(snapshot))
            }.value
            guard !Task.isCancelled, let self, self.libraryVersion == version else { return }
            self.installStats(result.stats)
            self.installDerivedIndexes(result.indexes)
        }
    }

    // Photos grouped by their immediate folder, so folder scope is O(result)
    // instead of an O(library) prefix scan on every folder click.
    @ObservationIgnored private var folderIndexCache: [String: [Photo]] = [:]
    @ObservationIgnored private var folderIndexKey = -1
    @ObservationIgnored private var directPhotosByFolder: [String: [Photo]] {
        if libraryVersion == folderIndexKey { return folderIndexCache }
        folderIndexCache = Dictionary(grouping: allPhotos, by: Self.folderKey(for:))
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
        Task { await scan(adding: urls) }
    }

    /// Stop the running import. Photos found so far are kept — the user paid the
    /// NAS to enumerate them.
    func cancelScan() { scanProgress.cancel() }

    // Two imports can overlap (a drop while an open-panel import is still
    // wrapping up), so the observed flag is driven by a count, not a bool.
    @ObservationIgnored private var runningScans = 0

    private func beginScan() -> ScanCancelToken {
        runningScans += 1
        isScanning = true
        return scanProgress.begin()
    }

    private func endScan(_ token: ScanCancelToken) {
        runningScans = max(0, runningScans - 1)
        scanProgress.finish(token)   // no-op once a newer scan owns the display
        guard runningScans == 0 else { return }
        isScanning = false
        if rescanDeferred { rescanDeferred = false; rescanRoots() }
    }

    /// A folder-watcher event arrived while an import or another reconcile was
    /// walking the disk, and was held back — see `rescanRoots`.
    @ObservationIgnored private var rescanDeferred = false
    @ObservationIgnored private var isReconciling = false

    /// Import walks stream their results back: enumerating a 30k-photo folder on
    /// an SMB share takes minutes, and the old path published *nothing* until it
    /// had finished — no count, no photos, just a spinner in the toolbar corner.
    /// Now the scanner hands over batches at folder boundaries, each one
    /// appended with `appendScanned` (O(batch), not an O(library) rebuild), so
    /// the grid fills in as the walk progresses.
    private func scan(adding urls: [URL]) async {
        let token = beginScan()
        // `end()` is idempotent and runs at the first of: the walk finishing
        // (below, so the long EXIF tail doesn't sit under a stale "Adding…")
        // or any early return.
        var ended = false
        func end() { if !ended { ended = true; endScan(token) } }
        defer { end() }

        // Both of these stat the filesystem, which blocks for seconds on a
        // wedged SMB mount — never on the main actor.
        let newRoots = await Task.detached(priority: .userInitiated) {
            urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }.value

        // Register the roots before the walk, so the sidebar shows the folder
        // the user just picked instead of staying empty for minutes.
        var registeredRoot = false
        for root in newRoots where !rootFolders.contains(root) {
            rootFolders.append(root); registeredRoot = true
        }
        if registeredRoot { persistRecentFolders() }

        // Each hand-off bumps `libraryVersion` and re-sorts the visible list, so
        // the batch size scales with the library: a fixed size would give a 67k
        // library hundreds of resorts, and a fresh one a grid that never moves.
        let batchSize = max(1_000, allPhotos.count / 12)
        // Re-importing a known folder reuses the cached metadata instead of
        // re-stat'ing every file (the incremental scanner's NAS win, which the
        // old import path — a plain full walk — never got).
        let cachedByFolder = directPhotosByFolder

        enum ScanEvent: Sendable {
            case batch([Photo])
            case progress(found: Int, folder: String?)
        }
        let (events, continuation) = AsyncStream<ScanEvent>.makeStream()
        let stream = IncrementalScanner.Stream(
            batchSize: batchSize,
            onBatch: { continuation.yield(.batch($0)) },
            onProgress: { continuation.yield(.progress(found: $0, folder: $1)) },
            isCancelled: { token.isCancelled }
        )
        let scanTask = Task.detached(priority: .userInitiated) { () -> IncrementalScanner.Result in
            defer { continuation.finish() }
            let known = LibraryCache.loadFolderMtimes()
            return IncrementalScanner.scan(roots: urls, knownMtimes: known,
                                           cachedByFolder: cachedByFolder, stream: stream)
        }

        // One ordered channel, consumed on the main actor — batches can never
        // land out of order or race the completion below.
        var added: [Photo] = []
        for await event in events {
            switch event {
            case .batch(let batch):
                let fresh = appendScanned(batch)
                if !fresh.isEmpty {
                    added.append(contentsOf: fresh)
                    scanProgress.addedPhotos(token, fresh.count)
                }
            case .progress(let found, let folder):
                scanProgress.update(token, found: found, folder: folder)
            }
        }
        let result = await scanTask.value

        // Remember the folder mtimes this walk observed, so the next reconcile
        // (and the next launch) reuses them instead of re-stat'ing the tree.
        // Never after a cancel — see `IncrementalScanner.Result.completed`.
        // Awaited BEFORE `end()` releases the deferred reconcile below: that
        // reconcile reads the mtimes off disk, and if it beat this write it
        // would re-walk the whole tree we just finished walking.
        if result.completed {
            let mtimes = result.folderMtimes
            await Task.detached(priority: .utility) { LibraryCache.mergeFolderMtimes(mtimes) }.value
        }
        end()

        let roots = rootFolders
        let available = await Task.detached(priority: .utility) {
            roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        }.value
        watcher?.watch(available)

        guard !added.isEmpty else {
            // Say so rather than leaving the user staring at an unchanged grid
            // wondering whether the import ran at all.
            if result.completed {
                showToast(result.photos.isEmpty
                          ? "No photos found in that folder"
                          : "Those photos are already in your library")
            }
            if registeredRoot { refreshDerivedCachesOffMain() }
            return
        }
        recomputeMetaCounts()
        // Backstop: `appendScanned` maintained the derived caches incrementally,
        // this re-derives them from the final library off-main so a streaming
        // import can never leave them drifted.
        refreshDerivedCachesOffMain()
        persistLibraryCache()
        showToast(result.completed
                  ? "Added \(added.count.formatted()) photos"
                  : "Stopped — added \(added.count.formatted()) photos")

        if !exif.isEmpty { await indexExif(for: added) }  // full index is deferred until needed
        scheduleThumbnailWarming()
    }

    /// Append a freshly scanned batch and EXTEND the derived caches in place,
    /// rather than letting the library-version bump invalidate them.
    /// A streaming import commits many batches; recomputing stats + indexes for
    /// the whole library on each one is O(library × batches) and measured ~250ms
    /// of main-thread work per commit at 67k photos. This is O(batch).
    /// Returns the photos that were genuinely new (deduped against the library).
    @discardableResult
    private func appendScanned(_ batch: [Photo]) -> [Photo] {
        guard !batch.isEmpty else { return [] }
        // Read through the getters BEFORE the append: a cold cache is built once
        // here instead of lazily during the next sidebar/grid render.
        var byID = photoByID
        var byFolder = directPhotosByFolder
        var lower = lowerNames
        var s = stats

        let cal = Calendar.current
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let today = cal.dateComponents([.month, .day], from: Date())

        var fresh: [Photo] = []
        fresh.reserveCapacity(batch.count)
        for photo in batch where byID[photo.url] == nil {
            byID[photo.url] = photo
            fresh.append(photo)
            byFolder[Self.folderKey(for: photo), default: []].append(photo)
            lower[photo.url] = photo.filename.lowercased()
            s.folderCounts[photo.folderURL, default: 0] += 1
            if let date = photo.creationDate {
                if date >= cutoff { s.recentlyAdded += 1 }
                let c = cal.dateComponents([.month, .day], from: date)
                if c.month == today.month && c.day == today.day { s.onThisDay += 1 }
            }
        }
        guard !fresh.isEmpty else { return [] }

        allPhotos.append(contentsOf: fresh)   // bumps libraryVersion
        statsCache = s
        statsCacheKey = libraryVersion
        // `byID` came from `photoByID`, so it already merges Photos assets —
        // keying on (libraryVersion, assetsVersion) keeps that valid.
        idIndexCache = byID
        idIndexKey = (libraryVersion, assetsVersion)
        folderIndexCache = byFolder
        folderIndexKey = libraryVersion
        lowerNameCache = lower
        lowerNameKey = libraryVersion
        return fresh
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

    // MARK: - Disconnected-drive guard

    /// Roots whose volume (NAS/USB) is currently unmounted. The sidebar grays
    /// these out and blocks selection; a mount notification clears them and
    /// triggers a rescan so the content reappears on its own.
    var offlineRoots: Set<URL> = []

    /// Which of `roots` are disconnected: the directory is missing AND the path
    /// shape says "removable/network volume" (a missing home-folder root was
    /// deleted, not unplugged — the vanished-local path handles that).
    /// `exists` is injectable for tests; production stats the filesystem.
    nonisolated static func computeOfflineRoots(
        _ roots: [URL],
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Set<URL> {
        // Pure path-shape classification (no filesystem probe): once `exists`
        // already said the directory is missing, a resourceValues stat would
        // throw anyway — and mixing a real probe behind an injected `exists`
        // makes the result depend on the test machine's mounts.
        Set(roots.filter { !exists($0) && $0.path.hasPrefix("/Volumes/") })
    }

    /// True when `url` is one of `roots` or lives under one (path-component
    /// boundary — /Volumes/nas2 is NOT under /Volumes/nas).
    nonisolated static func url(_ url: URL, isUnderAny roots: Set<URL>) -> Bool {
        guard !roots.isEmpty else { return false }
        let path = url.path
        return roots.contains { root in
            let rootPath = root.path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    /// Row-level check used by the sidebar (folder rows under an offline root
    /// gray out and refuse selection).
    func isUnderOfflineRoot(_ url: URL) -> Bool { Self.url(url, isUnderAny: offlineRoots) }

    /// Recompute `offlineRoots` off the main thread (statting a wedged SMB
    /// mount can block for seconds) and install the result on the main actor.
    /// If the selection points into a root that just went offline, fall back
    /// to All Photos so the browser never shows a dead scope.
    func refreshOfflineRoots() {
        let roots = rootFolders
        Task.detached(priority: .utility) { [weak self] in
            let offline = AppModel.computeOfflineRoots(roots)
            await MainActor.run { [weak self] in
                guard let self, self.offlineRoots != offline else { return }
                self.offlineRoots = offline
                if case .folder(let url) = self.selectedSidebar, Self.url(url, isUnderAny: offline) {
                    self.selectedSidebar = .allPhotos
                }
            }
        }
    }

    /// A volume mounted or unmounted. Refresh the offline set, then rescan:
    /// reconcile preserves photos under offline roots and re-attaches the
    /// folder watcher to every reachable root (a remounted volume needs both).
    private func volumesDidChange() {
        // The mount table just changed, so any cached volume→identity mapping
        // is stale — and cache keys are derived from it.
        VolumeIdentity.invalidate()
        refreshOfflineRoots()
        rescanRoots()
    }

    /// NSWorkspace mount/unmount observation — registered once from init.
    /// Process-lifetime observers by design (same reasoning as BUG-061/073).
    private func observeVolumeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.volumesDidChange() }
            }
        }
    }

    /// Everything reconcile needs to apply, computed off the main thread —
    /// diffing 67k photos (URL sets, path-prefix scans) measured 2.4-3s when it
    /// ran on the main actor, freezing the app ~40s after launch.
    private struct ReconcileDiff: Sendable {
        var scanned: [Photo] = []
        var added: [Photo] = []
        var removedPaths: [String] = []   // removed + prunedLocal, for exif/duplicates cleanup
        var offline: [Photo] = []
        var hasChanges = false
        var stats = LibraryStats()        // for the post-apply library, precomputed off-main
        var indexes = DerivedIndexes()    // ditto
    }

    nonisolated private static func computeReconcileDiff(
        current: [Photo], scanned: [Photo], roots: [URL], rootFolders: [URL]
    ) -> ReconcileDiff {
        let prefixes = roots.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }

        let knownURLs = Set(current.map { $0.url })
        let added = scanned.filter { !knownURLs.contains($0.url) }
        let scannedURLs = Set(scanned.map { $0.url })

        // Photos not under any *currently scanned* root split into two groups:
        //   • genuinely offline — their root is an unreachable network/NAS volume
        //     (e.g. unmounted). Keep these so the library still shows them.
        //   • orphaned — their root is a *local* folder that no longer exists,
        //     i.e. it was renamed/moved/deleted in Finder. The old paths are
        //     phantoms; keeping them leaves stale, fractured sidebar folders.
        //     Prune them (the new paths come back in as `added`).
        let missingRoots = rootFolders.filter { !roots.contains($0) }
        let preservableRoots = missingRoots.filter(Self.isOfflineNetworkRoot)

        var diff = ReconcileDiff(scanned: scanned, added: added)
        var offline: [Photo] = []
        var removedPaths: [String] = []
        for photo in current {
            let path = photo.url.path   // computed once per photo
            if prefixes.contains(where: { path.hasPrefix($0) }) {
                if !scannedURLs.contains(photo.url) { removedPaths.append(path) }
            } else if preservableRoots.contains(where: { path.hasPrefix($0.path + "/") }) {
                offline.append(photo)
            } else {
                removedPaths.append(path)   // orphaned local root — prune
            }
        }
        diff.offline = offline
        diff.removedPaths = removedPaths
        diff.hasChanges = !added.isEmpty || !removedPaths.isEmpty
        if diff.hasChanges {
            let next = offline + scanned
            diff.stats = computeStats(next)
            diff.indexes = computeDerivedIndexes(next)
        }
        return diff
    }

    private func reconcile(roots: [URL]) async {
        guard !roots.isEmpty else { return }

        // Incremental: reuse cached photos for folders whose mtime is unchanged.
        // The folder index is the same grouping, precomputed off-main at load —
        // grouping 67k photos here measured ~145ms on the main thread.
        //
        // ONE version span covers scan + diff: the scan can take seconds on a
        // NAS, so a delete/undo landing mid-scan (not just mid-diff) leaves
        // `scanned` stale and the diff would revert the user's action —
        // restored photos pruned as removed, deleted ones resurrected as
        // added. Re-scans on retry are cheap: only the folders the edit
        // touched have changed mtimes; everything else is a cache hit.
        var diff = ReconcileDiff()
        var diffIsCurrent = false
        for _ in 0..<3 {
            let snapshotVersion = libraryVersion
            let cachedByFolder = directPhotosByFolder
            let result = await Task.detached(priority: .utility) {
                let knownMtimes = LibraryCache.loadFolderMtimes()
                let r = IncrementalScanner.scan(roots: roots, knownMtimes: knownMtimes, cachedByFolder: cachedByFolder)
                LibraryCache.saveFolderMtimes(r.folderMtimes)
                return r
            }.value
            let scanned = result.photos
            let current = allPhotos
            let currentRoots = rootFolders
            diff = await Task.detached(priority: .userInitiated) {
                Self.computeReconcileDiff(current: current, scanned: scanned,
                                          roots: roots, rootFolders: currentRoots)
            }.value
            if libraryVersion == snapshotVersion { diffIsCurrent = true; break }
        }
        // Never apply a diff computed against an outdated library — it would
        // silently revert whatever the user just deleted/imported/renamed.
        // (Giving up is safe: the edit's own FSEvents trigger the next pass.)
        guard diffIsCurrent else { return }

        let missingRoots = rootFolders.filter { !roots.contains($0) }

        // Only mutate the library when something actually changed — otherwise a
        // no-op launch reconcile would bump the version and force the grid to
        // reload (throwing away in-flight thumbnail decodes).
        if diff.hasChanges {
            // One assignment, not per-item removeValue — each mutation of the
            // observed dictionary runs the observation machinery.
            var prunedExif = exif
            for path in diff.removedPaths { prunedExif.removeValue(forKey: path) }
            exif = prunedExif
            duplicatePaths.subtract(diff.removedPaths)
            allPhotos = diff.offline + diff.scanned
            installStats(diff.stats)
            installDerivedIndexes(diff.indexes)
            recomputeMetaCounts()
            persistLibraryCache()
        }
        let added = diff.added

        // Forget vanished *local* roots so they stop being re-watched/persisted
        // and disappear from the sidebar. Network roots stay — they may remount.
        let vanishedLocalRoots = missingRoots.filter { !Self.isOfflineNetworkRoot($0) }
        if !vanishedLocalRoots.isEmpty {
            rootFolders.removeAll { vanishedLocalRoots.contains($0) }
            persistRecentFolders()
        }
        watcher?.watch(roots)

        if !exif.isEmpty, !added.isEmpty { await indexExif(for: added) }
        scheduleThumbnailWarming()
    }

    /// What an index pass can skip because the same FILE is already covered
    /// under a different path — the case a remounted share creates.
    struct ExifAdoption: Sendable {
        /// path → info, to merge into the index without reading anything.
        var adopted: [String: ExifInfo] = [:]
        /// Photos genuinely never read.
        var stillMissing: [Photo] = []
        /// Old-path entries made redundant by an adoption — safe to drop,
        /// because the very same file is now present under a live path.
        var redundant: [String] = []
    }

    /// Match photos with no entry at their current path against entries filed
    /// under a previous mount point.
    ///
    /// Deliberately additive: nothing is re-keyed and nothing is dropped unless
    /// an adoption proves it redundant. Re-keying the whole index on load would
    /// be tidier but far more dangerous — a share that happens to be unmounted
    /// at launch would have its entries discarded, turning a cosmetic problem
    /// into a 64k-photo re-read of the NAS.
    ///
    /// `key` is injectable so the behaviour can be tested without mounting
    /// anything; production passes `VolumeIdentity.key(for:)`.
    nonisolated static func adoptExif(
        missing: [Photo], exif: [String: ExifInfo],
        key: (String) -> String = { VolumeIdentity.key(for: $0) }
    ) -> ExifAdoption {
        var result = ExifAdoption()
        guard !missing.isEmpty, !exif.isEmpty else {
            result.stillMissing = missing
            return result
        }
        // Only entries whose path is NOT a live one can be a previous mount of
        // something; building the map from those alone keeps it small.
        var byKey: [String: (path: String, info: ExifInfo)] = [:]
        byKey.reserveCapacity(exif.count)
        for (path, info) in exif where byKey[key(path)] == nil {
            byKey[key(path)] = (path, info)
        }
        for photo in missing {
            let path = photo.url.path
            if let hit = byKey[key(path)], hit.path != path {
                result.adopted[path] = hit.info
                result.redundant.append(hit.path)
            } else {
                result.stillMissing.append(photo)
            }
        }
        return result
    }

    private(set) var isIndexingExif = false
    /// Progress for the on-demand EXIF pass, so the UI can show "Indexing…"
    /// instead of an empty result while a large (NAS) library is read.
    private(set) var exifIndexTotal = 0
    private(set) var exifIndexDone = 0
    /// Which storage the index is currently reading ("Local disk" / "NAS") and
    /// the recent throughput in photos/sec — shown in the status bar.
    private(set) var exifIndexSource = ""
    private(set) var exifIndexRate = 0
    /// The file the index is on right now — "exactly where it is reading",
    /// shown in the background-job popover.
    private(set) var exifIndexCurrentPath: String?
    /// Photos this pass did NOT have to read because the index already covered
    /// them. Context, not progress — shown in the popover so "8,445 of 8,445"
    /// doesn't look like the library shrank.
    private(set) var exifIndexCached = 0
    /// Set briefly when an indexing pass finishes, so the status bar can confirm
    /// "Indexed N photos" before clearing. `exifReadyCount` is the photos covered.
    private(set) var exifIndexJustFinished = false
    @ObservationIgnored private var exifJustFinishedClearTask: Task<Void, Never>?
    private(set) var exifReadyCount = 0

    /// Index EXIF for any photos that don't have it yet — called on demand when
    /// the Map or an EXIF-based filter is first used, so a plain browse session
    /// never reads 50k files. Indexed in chunks so search/map results stream in
    /// progressively rather than appearing all at once after a long stall.
    func ensureExifIndex() {
        guard !isIndexingExif else { return }
        isIndexingExif = true   // claimed before the off-main prep so re-entry no-ops
        let photos = allPhotos
        let snapshot = exif
        Task {
            // Finding un-indexed photos scans the whole library (a path string +
            // dictionary lookup per photo — ~90ms at 67k), so it runs off-main.
            // Fast local disk before the (slow) NAS, so results appear quickly
            // and the user never waits on the network for nearby photos. The
            // boundary also drives the "Local disk / NAS" status label.
            let prep = await Task.detached(priority: .utility) { () -> (urls: [URL], localCount: Int, adoption: ExifAdoption) in
                let missing = photos.filter { snapshot[$0.url.path] == nil }
                guard !missing.isEmpty else { return ([], 0, ExifAdoption()) }
                // Before reading anything: a photo with no entry at its current
                // path may already be indexed under a previous mount point. On
                // the reference NAS this is the difference between adopting
                // tens of thousands of entries and re-reading them over SMB.
                let adoption = AppModel.adoptExif(missing: missing, exif: snapshot)
                let stillMissing = adoption.stillMissing
                guard !stillMissing.isEmpty else { return ([], 0, adoption) }
                let networkPrefixes = AppModel.networkVolumePrefixes()
                let isNetwork = { (url: URL) in networkPrefixes.contains { url.path.hasPrefix($0) } }
                let localURLs = stillMissing.map { $0.url }.filter { !isNetwork($0) }
                let networkURLs = stillMissing.map { $0.url }.filter { isNetwork($0) }
                return (localURLs + networkURLs, localURLs.count, adoption)
            }.value

            applyExifAdoption(prep.adoption)
            guard !prep.urls.isEmpty else { isIndexingExif = false; return }
            startExifIndexing(urls: prep.urls, localCount: prep.localCount)
        }
    }

    /// Install entries carried over from a previous mount point, and drop the
    /// old-path records they replaced (safe: the same file is now filed under a
    /// live path, so nothing becomes unreachable).
    private func applyExifAdoption(_ adoption: ExifAdoption) {
        guard !adoption.adopted.isEmpty else { return }
        var merged = exif
        for (path, info) in adoption.adopted { merged[path] = info }
        for path in adoption.redundant { merged.removeValue(forKey: path) }
        exif = merged
        persistExifCache()
        showToast("Reused metadata for \(adoption.adopted.count.formatted()) photos "
                  + "after the volume moved")
    }

    private func startExifIndexing(urls: [URL], localCount: Int) {
        // Report THIS PASS's work, not the whole library.
        //
        // It used to count from `libraryTotal - remaining` so the number would
        // "resume" rather than restart at zero. In practice that made a pass
        // with 8,445 photos left to read display as "55,809 of 64,254" — which
        // reads as "it is re-doing all 64k, every time", and is the reason the
        // cache looked broken when it was in fact being reused in full. The
        // already-cached count is still available, as context, in the popover.
        exifIndexCached = allPhotos.count - urls.count
        exifIndexTotal = urls.count
        exifIndexDone = 0
        let baseDone = 0
        exifIndexRate = 0
        exifIndexSource = localCount > 0 ? "Local disk" : "NAS"

        // .utility (not .background): a serial NAS read is already low-CPU since
        // it mostly waits on I/O, but .background throttles so hard the pass never
        // makes progress. .utility stays imperceptible yet actually completes.
        // Inherits @MainActor: the loop body resumes on the main actor after each
        // `await ...detached.value`, so the progress/exif writes below are
        // main-confined (the inner detached task does the off-main CPU work).
        Task(priority: .utility) {
            let chunkSize = 200
            let saveEvery = 2_000   // checkpoint so a long NAS pass survives a quit
            // Accumulate only the NEW entries and merge them into the CURRENT
            // exif at publish time. The old `var merged = exif` snapshot taken
            // at pass start resurrected every entry deleted during a long NAS
            // pass — and each publish CoW-copied the whole 67k dictionary.
            var pending: [String: ExifInfo] = [:]
            var start = 0
            var sinceSave = 0
            var tickTime = Date()
            var tickDone = 0
            var lastPublish = Date()
            while start < urls.count {
                let end = min(start + chunkSize, urls.count)
                let chunk = Array(urls[start..<end])
                // Read in the lumen-meta-bg helper process. A malformed file
                // that aborts ImageIO then costs one photo — recorded by name —
                // instead of taking the app down mid-pass. The client falls
                // back to in-process reading when the helper isn't present.
                let result = await Task.detached(priority: .utility) { () -> ExifIndexer.Result in
                    var out = ExifIndexer.Result()
                    let now = Date()
                    MetadataHelperClient.index(chunk) { path, info, failure in
                        out.info[path] = info
                        if let failure {
                            out.failures.append(JobFailure(kind: .metadata, path: path,
                                                           reason: failure, date: now))
                        }
                    }
                    return out
                }.value
                pending.merge(result.info) { _, new in new }
                if !result.failures.isEmpty {
                    JobFailureLog.shared.record(result.failures)
                    refreshJobFailures()
                }
                // Cheap status updates every chunk (status bar only).
                exifIndexDone = baseDone + end
                exifIndexCurrentPath = chunk.last?.path
                exifIndexSource = start < localCount ? "Local disk" : "NAS"
                // Publishing `exif` invalidates the visible cache and re-filters
                // the whole library — expensive while a search is active. Throttle
                // it to ~1.5s so streaming results don't make the grid stutter.
                if -lastPublish.timeIntervalSinceNow >= 1.5 {
                    exif = exif.merging(pending) { _, new in new }
                    pending.removeAll(keepingCapacity: true)
                    lastPublish = Date()
                }
                // Rolling throughput (photos/sec) over the last ~second.
                let elapsed = -tickTime.timeIntervalSinceNow
                if elapsed >= 1 {
                    exifIndexRate = Int(Double(end - tickDone) / elapsed)
                    tickTime = Date()
                    tickDone = end
                }
                start = end
                sinceSave += chunk.count
                if sinceSave >= saveEvery {   // persist partial progress periodically
                    persistExifCache()
                    sinceSave = 0
                }
            }
            exif = exif.merging(pending) { _, new in new }   // final publish so the cache + search are complete
            persistExifCache()
            isIndexingExif = false
            exifIndexTotal = 0
            exifIndexDone = 0
            exifIndexRate = 0
            exifIndexSource = ""
            exifIndexCurrentPath = nil
            exifIndexCached = 0
            refreshJobFailures()
            // Briefly confirm the index is ready, then clear the status indicator.
            exifReadyCount = exif.count
            exifIndexJustFinished = true
            // Cancel any prior clear task so overlapping passes don't clear the
            // confirmation out of order (an earlier timer firing during a later
            // pass would hide it prematurely).
            exifJustFinishedClearTask?.cancel()
            exifJustFinishedClearTask = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { exifIndexJustFinished = false }
            }
        }
    }

    /// Mount-point paths of currently-mounted *network* volumes (NAS/SMB/AFP).
    /// Used to classify photo URLs as local vs network by path prefix — far
    /// cheaper than stat-ing every one of tens of thousands of files.
    nonisolated static func networkVolumePrefixes() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []) ?? []
        return volumes
            .filter { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false }
            .map { $0.path }
    }

    /// Index EXIF for just the given (new) photos and merge into the cache.
    private func indexExif(for photos: [Photo]) async {
        guard !photos.isEmpty else { persistExifCache(); return }
        let urls = photos.map { $0.url }
        let result = await Task.detached(priority: .utility) { ExifIndexer.index(urls) }.value
        var merged = exif
        for (key, value) in result.info { merged[key] = value }
        exif = merged
        if !result.failures.isEmpty {
            JobFailureLog.shared.record(result.failures)
            refreshJobFailures()
        }
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
        // An import is already walking the filesystem. A reconcile now would
        // fight it for NAS bandwidth AND be discarded anyway — its diff is
        // computed against a library the import keeps growing, which trips the
        // "never apply a stale diff" guard. Hold the event and replay it once
        // the import (and its folder-mtime write) has settled.
        guard !isScanning else { rescanDeferred = true; return }
        // Single-flight. A reconcile walks the WHOLE library — 107k files across
        // three SMB shares on the reference machine — and FSEvents fires far
        // faster than that completes, so overlapping passes piled up: measured
        // 13 concurrent walker threads, 37% CPU, 3GB resident, and zero
        // thumbnails produced because each pass restarted the warm queue before
        // the last could finish anything. Coalesce instead: one runs, one is
        // remembered, everything else is already covered by the one that will.
        guard !isReconciling else { rescanDeferred = true; return }
        isReconciling = true

        // Stat the roots off the main actor: an FS change on a stalled-but-mounted
        // SMB share would otherwise block the main thread on fileExists until the
        // OS timeout (seconds) every time the watcher fires.
        let roots = rootFolders
        Task { [weak self] in
            let available = await Task.detached(priority: .utility) {
                roots.filter { FileManager.default.fileExists(atPath: $0.path) }
            }.value
            await self?.reconcile(roots: available)
            guard let self else { return }
            self.isReconciling = false
            // Replay exactly one held event, so a change that landed mid-scan
            // isn't lost — without turning that into an endless chain.
            if self.rescanDeferred {
                self.rescanDeferred = false
                self.rescanRoots()
            }
        }
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
        // Single-photo copies also carry image data so image fields accept the
        // paste — loaded OFF the main thread: NSImage(contentsOf:) on a NAS
        // original is a network read + full decode (seconds of beachball).
        // changeCount guards against clobbering a newer copy when it lands.
        guard photos.count == 1, !photos[0].isAsset else { return }
        let url = photos[0].url
        let change = pasteboard.changeCount
        Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: url) else { return }
            await MainActor.run {
                guard NSPasteboard.general.changeCount == change else { return }
                NSPasteboard.general.writeObjects([image])
            }
        }
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

    // Exports run detached — copyOriginals reads every file over the network
    // and exportResized adds a full decode+encode per photo; a 200-photo NAS
    // export beachballed the app for the whole copy. The count comes back to
    // the main actor as a toast (the result used to be silently discarded).
    /// Progress for a running export. Its own observable, so a per-photo tick
    /// doesn't re-render the grid.
    @ObservationIgnored let exportProgress = ExportMonitor()
    /// Observed mirror, so views can react to an export starting or ending.
    private(set) var isExporting = false

    func cancelExport() { exportProgress.cancel() }

    // MARK: Export entry points

    func exportOriginals(_ photos: [Photo]) { beginExport(photos, style: .originals) }
    func exportResized(_ photos: [Photo], maxPixel: Int) {
        beginExport(photos, style: .resized(maxPixel: maxPixel))
    }
    func exportZip(_ photos: [Photo]) { beginExport(photos, style: .zip) }

    /// Export everything in the Apple Photos library. The assets are fetched
    /// first — only the open scope is normally loaded, and "export the library"
    /// must not mean "export the part you happened to look at".
    func exportPhotosLibrary(style: ExportStyle) {
        Task {
            let assets = assetPhotos.isEmpty ? await PhotosLibraryService.fetchAllImages() : assetPhotos
            beginExport(assets, style: style)
        }
    }

    /// Export one Apple Photos album, fetching its assets on demand.
    func exportPhotosAlbum(_ id: String, style: ExportStyle) {
        Task {
            let assets = await PhotosLibraryService.fetchAssets(inAlbumId: id)
            beginExport(assets, style: style)
        }
    }

    /// Export a Lumen album by resolving its stored paths back to photos.
    func exportAlbum(_ id: UUID, style: ExportStyle) {
        guard let album = albums.first(where: { $0.id == id }) else { return }
        let index = photoByID
        let photos = album.photoPaths.compactMap {
            index[URL(filePath: $0, directoryHint: .notDirectory)]
        }
        beginExport(photos, style: style)
    }

    // MARK: The one export path

    private func beginExport(_ photos: [Photo], style: ExportStyle) {
        guard !photos.isEmpty else { showToast("Nothing to export"); return }
        guard !isExporting else { showToast("An export is already running"); return }

        switch style {
        case .originals, .resized:
            chooseDirectory(prompt: "Export Here") { dir in
                self.runExport(photos, style: style, destination: dir)
            }
        case .zip:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Lumen Export.zip"
            panel.allowedContentTypes = [.zip]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            runExport(photos, style: style, destination: url)
        }
    }

    /// Photos-library assets have no file to copy — their bytes come out of
    /// PhotoKit — so each item is routed to whichever mechanism can read it.
    /// One item at a time: that is what makes progress reportable and the whole
    /// thing stoppable, which for a 71k-photo library is the difference between
    /// a feature and a hang.
    private func runExport(_ photos: [Photo], style: ExportStyle, destination: URL) {
        let token = exportProgress.begin(total: photos.count, style: style.label)
        isExporting = true

        Task {
            // Zip collects into a staging directory and archives at the end;
            // the other styles write straight to the destination.
            let workDir: URL
            let staging: URL?
            if case .zip = style {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumenZip-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                workDir = tmp
                staging = tmp
            } else {
                workDir = destination
                staging = nil
            }

            var ok = 0
            for photo in photos {
                if token.isCancelled { break }
                let succeeded: Bool
                if photo.isAsset {
                    succeeded = await PhotosExporter.export(photo, style: style, to: workDir)
                } else {
                    succeeded = await Task.detached(priority: .userInitiated) { () -> Bool in
                        switch style {
                        case .originals, .zip: return Exporter.copyOriginal(photo, to: workDir)
                        case .resized(let px): return Exporter.exportResized(photo, maxPixel: px, to: workDir)
                        }
                    }.value
                }
                if succeeded { ok += 1 }
                exportProgress.advance(token, name: photo.filename, succeeded: succeeded)
            }

            var archived = true
            if let staging {
                let archive = destination
                archived = await Task.detached(priority: .userInitiated) {
                    let result = Exporter.archive(directory: staging, to: archive)
                    try? FileManager.default.removeItem(at: staging)
                    return result
                }.value
            }

            exportProgress.finish(token)
            isExporting = false
            if !archived {
                showToast(String(localized: "Couldn’t create the zip archive.", bundle: .lumen))
            } else if token.isCancelled {
                showToast("Export stopped — \(ok.formatted()) of \(photos.count.formatted()) exported")
            } else {
                didExport(count: ok, of: photos.count, to: destination)
            }
        }
    }

    private func didExport(count: Int, of total: Int, to destination: URL) {
        if count < total {
            showToast(String(localized: "Exported \(count) of \(total) photos · \(destination.lastPathComponent)", bundle: .lumen))
        } else {
            showToast(String(localized: "Exported \(count) photos · \(destination.lastPathComponent)", bundle: .lumen))
        }
    }

    // MARK: - Folder actions

    var showFolderRenameSheet = false
    var folderRenameDraft = ""
    @ObservationIgnored private var folderRenameURL: URL?

    /// All photos in a folder and its descendants. Walks the cached folder
    /// index (hundreds of keys) instead of prefix-scanning all 67k photos —
    /// this runs on every folder context-menu action.
    func photosInFolder(_ url: URL) -> [Photo] {
        let base = url.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var result: [Photo] = []
        for (folder, photos) in directPhotosByFolder
        where folder == base || folder.hasPrefix(prefix) {
            result.append(contentsOf: photos)
        }
        return result
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
        // The same path-component boundary test the offline guard uses, so
        // removing /Volumes/nas can never take /Volumes/nas2 with it. (Hoisted:
        // the set is built once, not per photo.)
        let scope: Set<URL> = [url]
        let removed = allPhotos.filter { Self.url($0.url, isUnderAny: scope) }
        allPhotos.removeAll { Self.url($0.url, isUnderAny: scope) }
        // One assignment each — per-item removeValue on the observed dicts fires
        // the observation machinery per element (a large root = thousands).
        var prunedExif = exif
        var prunedDups = duplicatePaths
        for photo in removed {
            prunedExif.removeValue(forKey: photo.url.path)
            prunedDups.remove(photo.url.path)
        }
        exif = prunedExif
        duplicatePaths = prunedDups
        if case .folder(let sel) = selectedSidebar, Self.url(sel, isUnderAny: scope) {
            selectedSidebar = .allPhotos
        }
        // A removed root must also leave the offline set, or a folder later
        // added back at the same path would render grayed-out and unselectable.
        offlineRoots.remove(url)
        recomputeMetaCounts()
        refreshDerivedCachesOffMain()
        persistRecentFolders()
        persistLibraryCache()
        persistExifCache()
        // Off the main actor: this is the path you take when a NAS volume died,
        // and statting whatever roots remain can block for seconds on a wedged
        // SMB mount — freezing the app on the very click meant to escape it.
        let remaining = rootFolders
        Task { [weak self] in
            let available = await Task.detached(priority: .utility) {
                remaining.filter { FileManager.default.fileExists(atPath: $0.path) }
            }.value
            self?.watcher?.watch(available)
        }
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

        // Photos. URL(filePath:directoryHint:) — fileURLWithPath stats each
        // path (~7ms on NAS; 60k photos would hang the main thread for minutes).
        allPhotos = allPhotos.map { photo in
            guard photo.url.path.hasPrefix(oldPrefix) else { return photo }
            return photo.relocated(to: URL(filePath: remap(photo.url.path), directoryHint: .notDirectory))
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
                selectedSidebar = .folder(URL(filePath: remap(sel.path), directoryHint: .isDirectory))
            }
        }

        recomputeMetaCounts()
        refreshDerivedCachesOffMain()
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
        // Target names are pure computation; the per-photo SMB moves run
        // detached (renaming hundreds of NAS files froze the main thread),
        // then ONE batched store remap + rescan lands back on the main actor.
        var jobs: [(from: URL, to: URL)] = []
        var index = startIndex
        for photo in sortOrder.sorted(photos) where !photo.isAsset {
            let ext = photo.url.pathExtension
            let newName = RenamePattern.filename(pattern: pattern, index: index, ext: ext)
            let newURL = photo.folderURL.appendingPathComponent(newName)
            index += 1
            guard newURL != photo.url else { continue }
            jobs.append((from: photo.url, to: newURL))
        }
        guard !jobs.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            var pairs: [(from: String, to: String)] = []
            var failed = 0
            for job in jobs {
                guard !FileManager.default.fileExists(atPath: job.to.path) else { failed += 1; continue }
                do {
                    try FileManager.default.moveItem(at: job.from, to: job.to)
                    pairs.append((from: job.from.path, to: job.to.path))
                } catch {
                    failed += 1
                    NSLog("Lumen rename failed: \(error.localizedDescription)")
                }
            }
            let pairsResult = pairs
            let failedResult = failed
            await MainActor.run { self.finishRename(pairs: pairsResult, failed: failedResult) }
        }
    }

    private func finishRename(pairs: [(from: String, to: String)], failed: Int) {
        if failed > 0 {
            showToast(String(localized: "Couldn’t rename \(failed) items (name in use or permission issue).", bundle: .lumen))
        }
        guard !pairs.isEmpty else { return }
        store.rename(pairs: pairs)
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

    /// True when a pending photo sits on a volume with no system Trash
    /// (NAS/SMB shares) — those files are staged into a hidden
    /// `.LumenTrash` folder at the library root instead, kept 30 days.
    /// Checked once per distinct volume, not per photo.
    var deletionUsesLumenTrash: Bool {
        var seenVolumes = Set<String>()
        for photo in photosPendingDeletion {
            let comps = photo.url.pathComponents
            let volume = comps.count > 2 && comps[1] == "Volumes" ? comps[2] : "/"
            guard seenVolumes.insert(volume).inserted else { continue }
            if (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                             appropriateFor: photo.url, create: false)) == nil {
                return true
            }
        }
        return false
    }

    var deletionMessage: String {
        let count = photosPendingDeletion.count
        let subject = count == 1
            ? "“\(photosPendingDeletion.first?.filename ?? "")”"
            : "\(count) photos"
        if deletionUsesLumenTrash {
            return "\(subject) will move to a hidden “.LumenTrash” folder on the same volume "
                + "(this volume has no Trash). Kept for \(LumenTrash.retentionDays) days, "
                + "then removed automatically. You can undo right after deleting."
        }
        return "\(subject) will be moved to the Trash. You can undo right after deleting."
    }

    /// Everything needed to reverse one delete action: where each file went,
    /// plus the library entries, metadata, EXIF, and album memberships that
    /// were detached from it.
    struct DeletionUndoBatch {
        var moves: [(staged: URL, original: URL)] = []
        var photos: [Photo] = []
        var metas: [String: PhotoMeta] = [:]
        var exifInfos: [String: ExifInfo] = [:]
        var albumMemberships: [UUID: [String]] = [:]
    }

    func confirmDeletion() {
        let photos = photosPendingDeletion
        photosPendingDeletion = []
        guard !photos.isEmpty else { return }

        // Remember where the selection should land via an id-keyed index map —
        // firstIndex(of:) compares whole Photo structs, so a 10k-photo delete
        // from a 67k scope was O(deleted × visible) on the main thread.
        let ordered = visiblePhotos
        let indexByID = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
        let firstIndex = photos.compactMap { indexByID[$0.id] }.min()

        // The file moves are one (NAS: often two) network round-trips per
        // photo — run the whole loop detached; the library mutation happens
        // back on the main actor in finishDeletion.
        let roots = rootFolders
        let stamp = LumenTrash.stamp()
        Task.detached(priority: .userInitiated) {
            var moves: [(staged: URL, original: URL)] = []
            var trashed = Set<URL>()
            var failed = 0
            for photo in photos {
                do {
                    var staged: NSURL?
                    try FileManager.default.trashItem(at: photo.url, resultingItemURL: &staged)
                    trashed.insert(photo.url)
                    if let staged = staged as URL? {
                        moves.append((staged: staged, original: photo.url))
                    }
                } catch {
                    // No Trash on this volume (NAS/SMB). Stage into
                    // `<root>/.LumenTrash/<stamp>/` on the same volume instead
                    // of deleting in place — a rename is instant even over
                    // SMB, the delete becomes undoable, and startup purges
                    // batches after 30 days.
                    if let root = LumenTrash.root(for: photo.url, roots: roots) {
                        do {
                            let staged = try LumenTrash.stage(photo.url, under: root, stamp: stamp)
                            trashed.insert(photo.url)
                            moves.append((staged: staged, original: photo.url))
                        } catch {
                            failed += 1
                            NSLog("Lumen: failed to stage \(photo.url.path): \(error.localizedDescription)")
                        }
                    } else {
                        // Outside every open root (shouldn't happen) — last
                        // resort: delete in place, like Finder does there. No undo.
                        do {
                            try FileManager.default.removeItem(at: photo.url)
                            trashed.insert(photo.url)
                        } catch {
                            failed += 1
                            NSLog("Lumen: failed to delete \(photo.url.path): \(error.localizedDescription)")
                        }
                    }
                }
            }
            let movedResult = moves
            let trashedResult = trashed
            let failedResult = failed
            await MainActor.run {
                self.finishDeletion(photos: photos, moves: movedResult, trashed: trashedResult,
                                    failed: failedResult, firstIndex: firstIndex)
            }
        }
    }

    /// Applies a completed deletion to the library: detach entries, snapshot
    /// the undo batch, fix viewer/selection, and offer Undo.
    private func finishDeletion(photos: [Photo], moves: [(staged: URL, original: URL)],
                                trashed: Set<URL>, failed: Int, firstIndex: Int?) {
        var batch = DeletionUndoBatch()
        batch.moves = moves
        if failed > 0 {
            showToast(String(localized: "Couldn’t delete \(failed) items (check permissions/connection).", bundle: .lumen))
        }
        guard !trashed.isEmpty else { return }

        // Snapshot everything the undo needs BEFORE detaching it from the library.
        let trashedPaths = trashed.map { $0.path }
        batch.photos = photos.filter { trashed.contains($0.url) }
        for path in trashedPaths {
            let meta = store.meta(for: path)
            if !meta.isEmpty { batch.metas[path] = meta }
            if let info = exif[path] { batch.exifInfos[path] = info }
        }
        batch.albumMemberships = store.albumMemberships(forPaths: trashedPaths)

        store.forget(paths: trashedPaths)
        albums = store.albums
        allPhotos.removeAll { trashed.contains($0.url) }
        // Prune the observed dictionaries with ONE assignment each — per-item
        // removeValue fires the observation machinery per element (20k deletes
        // = 20k registrar calls on the main thread).
        var prunedExif = exif
        var prunedDups = duplicatePaths
        for url in trashed {
            prunedExif.removeValue(forKey: url.path)
            prunedDups.remove(url.path)
        }
        exif = prunedExif
        duplicatePaths = prunedDups
        recomputeMetaCounts()
        refreshDerivedCachesOffMain()
        bumpMeta()
        persistLibraryCache()   // save the post-delete library so a relaunch can't reload the trashed files

        if viewerIndex != nil {
            viewerPhotos.removeAll { trashed.contains($0.url) }
            if viewerPhotos.isEmpty { viewerIndex = nil }
            else if let index = viewerIndex { viewerIndex = min(index, viewerPhotos.count - 1) }
        }

        // Pick the survivor from the list currently ON SCREEN minus the trashed
        // entries — NOT from a fresh visiblePhotos read. For a >4000 scope the
        // library-version bump above makes visiblePhotos kick an off-main sort and
        // return the stale pre-delete list (still containing the deleted photos),
        // so selecting from it would land on a just-deleted id.
        if let survivor = Self.nearestSurvivor(in: lastVisible, excluding: trashed, at: firstIndex) {
            selectOnly(survivor)
        } else {
            clearSelection()
        }

        if !batch.moves.isEmpty {
            let undo = batch
            showToast(String(localized: "\(batch.moves.count) photos deleted", bundle: .lumen),
                      actionLabel: String(localized: "Undo", bundle: .lumen),
                      duration: 10) { [weak self] in
                self?.undoDeletion(undo)
            }
        }
    }

    /// The photo to select after deleting `removed` from the on-screen list
    /// `onScreen`: the survivor nearest the deleted position, in display order.
    /// Returns nil (→ clear selection) when no anchor index is given or nothing
    /// survives. Pure (no I/O) so it's the unit-test seam, and it derives survivors
    /// SYNCHRONOUSLY — never from `visiblePhotos`, which is stale during the
    /// off-main re-sort that a delete triggers on a large scope.
    nonisolated static func nearestSurvivor(in onScreen: [Photo], excluding removed: Set<URL>, at index: Int?) -> Photo? {
        let remaining = onScreen.filter { !removed.contains($0.url) }
        guard let index, !remaining.isEmpty else { return nil }
        return remaining[min(max(index, 0), remaining.count - 1)]
    }

    /// Reverse a just-confirmed deletion: move staged files back to their
    /// original paths, then re-attach library entries, metadata, EXIF, and
    /// album memberships. The per-photo moves (2-3 SMB round-trips each) run
    /// detached; the library mutation happens back on the main actor.
    func undoDeletion(_ batch: DeletionUndoBatch) {
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var restoredPaths = Set<String>()
            var failed = 0
            for move in batch.moves {
                guard fm.fileExists(atPath: move.staged.path),
                      !fm.fileExists(atPath: move.original.path) else { failed += 1; continue }
                do {
                    try fm.moveItem(at: move.staged, to: move.original)
                    restoredPaths.insert(move.original.path)
                } catch {
                    failed += 1
                    NSLog("Lumen: failed to restore \(move.original.path): \(error.localizedDescription)")
                }
            }
            let restoredResult = restoredPaths
            let failedResult = failed
            await MainActor.run {
                self.finishUndoDeletion(batch: batch, restoredPaths: restoredResult, failed: failedResult)
            }
        }
    }

    private func finishUndoDeletion(batch: DeletionUndoBatch, restoredPaths: Set<String>, failed: Int) {
        guard !restoredPaths.isEmpty else {
            if failed > 0 {
                showToast(String(localized: "Couldn’t undo (files moved or permission issue).", bundle: .lumen))
            }
            return
        }

        let existing = Set(allPhotos.map { $0.url.path })
        allPhotos.append(contentsOf: batch.photos.filter {
            restoredPaths.contains($0.url.path) && !existing.contains($0.url.path)
        })
        for (path, meta) in batch.metas where restoredPaths.contains(path) {
            store.update(path) { $0 = meta }
        }
        for (id, paths) in batch.albumMemberships {
            store.addToAlbum(id, paths: paths.filter { restoredPaths.contains($0) })
        }
        albums = store.albums
        var mergedExif = exif
        for (path, info) in batch.exifInfos where restoredPaths.contains(path) {
            mergedExif[path] = info
        }
        exif = mergedExif
        recomputeMetaCounts()
        refreshDerivedCachesOffMain()
        bumpMeta()
        persistLibraryCache()
        showToast(failed > 0
            ? String(localized: "\(restoredPaths.count) photos restored · \(failed) failed", bundle: .lumen)
            : String(localized: "\(restoredPaths.count) photos restored", bundle: .lumen))
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
        let urls = paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
        rootFolders = urls
        isLoadingLibrary = true

        // Window appears immediately; load the cached library off the main
        // thread. Everything below is ordered so the grid shows as soon as the
        // photo list itself is ready (~0.25s of work at 67k) — the launch
        // spinner used to wait on photos + EXIF + stats SEQUENTIALLY (~1.4s
        // measured): the EXIF cache (680ms decode) isn't needed to draw the
        // grid, so it loads after; stats and indexes compute concurrently.
        // The ENTIRE load pipeline (decode → date stats ∥ indexes) runs detached
        // from the first instruction: a plain `Task {}` here inherits the main
        // actor, so even SPAWNING the work sat ~500ms behind the busy launch
        // main thread (measured). The single hop back to main to install the
        // result pays that wait exactly once — and overlaps window construction.
        // Presentation snapshot for the pipeline: it pre-sorts the default
        // scope and warms the first screenful of thumbnails, so the grid
        // appears already filled instead of empty-grid → sort → images pop.
        let launchSort = sortOrder
        let launchVersion = libraryVersion
        let launchTier = viewMode == .grid
            ? ThumbnailCache.tier(forPointSize: thumbnailSize)
            : ThumbnailCache.tier(forPointSize: 40)   // list rows

        Task.detached(priority: .userInitiated) { [weak self] in
            var loaded: LaunchLoad?
            if let cached = LibraryCache.loadPhotos(), !cached.isEmpty {
                async let dates = Task.detached(priority: .userInitiated) { Self.computeDateStats(cached) }.value
                async let sortedTask = Task.detached(priority: .userInitiated) { launchSort.sorted(cached) }.value
                let indexes = Self.computeDerivedIndexes(cached)
                let sorted = await sortedTask
                // One-time upgrade: a cache that wasn't saved in launch order
                // (pre-upgrade format, or persisted mid-edit) gets re-saved
                // sorted, so the NEXT launch's sort is ~free (adaptive sort
                // over already-ordered input).
                if !Self.isDateNewestSorted(cached) {
                    Task.detached(priority: .background) { LibraryCache.savePhotos(sorted) }
                }
                // First screenful straight into the memory cache (the disk
                // cache has them from past sessions) — decodes overlap the
                // window construction we're waiting on anyway.
                ThumbnailCache.shared.prefetch(
                    sorted.prefix(80).map { (url: $0.url, mtime: $0.cacheMtime) },
                    maxPixel: launchTier, limit: 80)
                loaded = LaunchLoad(photos: cached, dates: await dates,
                                    indexes: indexes, sort: launchSort, sorted: sorted)
            }
            guard let self else { return }
            await self.installLoadedLibrary(loaded, launchVersion: launchVersion)
            // EXIF (a 680ms decode of its own) loads only after the grid is up —
            // decoding both caches concurrently slowed the grid-gating decode
            // ~2x (CPU/allocator contention, measured), and the grid doesn't
            // need it. Still off-main; installed in the same finish hop.
            let cachedExif = loaded != nil ? LibraryCache.loadExif() : nil
            await self.finishLibraryStartup(cachedExif: cachedExif, urls: urls)
        }
    }

    /// True when `photos` is already in `.dateNewest` order (the launch sort) —
    /// a cheap O(n) scan that decides whether the cache needs re-saving sorted.
    nonisolated private static func isDateNewestSorted(_ photos: [Photo]) -> Bool {
        var previous = Date.distantFuture
        for photo in photos {
            let date = photo.creationDate ?? .distantPast
            if date > previous { return false }
            previous = date
        }
        return true
    }

    /// Everything the launch pipeline computes off-main before the single
    /// main-actor install hop.
    private struct LaunchLoad: Sendable {
        var photos: [Photo]
        var dates: (recentlyAdded: Int, onThisDay: Int)
        var indexes: DerivedIndexes
        var sort: SortOrder
        var sorted: [Photo]   // photos in `sort` order — the default scope's content
    }

    /// Main-actor landing for the off-main load pipeline: publish the library
    /// with its precomputed stats/indexes so the sidebar's first body, first
    /// folder click, and first search never recompute them on the main thread.
    private func installLoadedLibrary(_ loaded: LaunchLoad?, launchVersion: Int) {
        if let loaded {
            if libraryVersion != launchVersion {
                // Something (an early drag-import) already mutated the library
                // while the cache was decoding — merge instead of clobbering
                // it, and let stats/indexes recompute lazily (rare path).
                let known = Set(loaded.photos.map { $0.url.path })
                let extras = allPhotos.filter { !known.contains($0.url.path) }
                allPhotos = loaded.photos + extras
                recomputeMetaCounts()
            } else {
                allPhotos = loaded.photos
                installStats(LibraryStats(recentlyAdded: loaded.dates.recentlyAdded,
                                          onThisDay: loaded.dates.onThisDay,
                                          folderCounts: Self.folderCounts(from: loaded.indexes.byFolder)))
                installDerivedIndexes(loaded.indexes)
                recomputeMetaCounts()
                // Seed the visible cache with the pre-sorted default scope: without
                // it the first visiblePhotos access kicks the async 67k sort and
                // the grid sits empty behind a spinner for another ~300ms.
                if committedSidebar == .allPhotos, sortOrder == loaded.sort,
                   searchText.isEmpty, !filter.isActive {
                    cacheVisible(visibleSignature, loaded.sorted)
                    lastVisible = loaded.sorted
                }
            }
        }
        isLoadingLibrary = false   // grid is on screen from here
        PerfProbe.shared?.markLibraryReady(self)
    }

    private func finishLibraryStartup(cachedExif: [String: ExifInfo]?, urls: [URL]) async {
        if let cachedExif { exif = cachedExif }

        // Build the photo-metadata (EXIF) index up front so search, the map,
        // and camera filters are ready without the user having to trigger it.
        // Kick off on the cached list immediately — don't wait for the (slow,
        // NAS) reconcile. Runs at utility priority behind thumbnail warming;
        // cached so later launches only index newly-added photos.
        // (Must run AFTER the cached exif install or it would re-index everything.)
        ensureExifIndex()

        // Per-root existence check off the main actor: fileExists on a stalled but
        // mounted SMB share blocks until the OS timeout (seconds), which on the
        // launch path would beachball the first frames.
        let available = await Task.detached(priority: .utility) {
            urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        }.value
        if !available.isEmpty { await reconcile(roots: available) }

        ensureExifIndex()   // catch any photos reconcile newly added

        // Purge .LumenTrash batches older than 30 days — one directory
        // listing per root when nothing is staged, so it's effectively free.
        let roots = available
        Task.detached(priority: .background) {
            LumenTrash.cleanup(roots: roots)
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
        // Must load before reopenRecentFolders — the launch pipeline snapshots
        // sortOrder to decide whether the persisted pre-sorted cache applies.
        if let raw = defaults.string(forKey: "lumen.sortOrder"), let order = SortOrder(rawValue: raw) {
            sortOrder = order
        }
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(viewMode.rawValue, forKey: "lumen.viewMode")
        defaults.set(confirmBeforeDelete, forKey: "lumen.confirmDelete")
        defaults.set(slideshowInterval, forKey: "lumen.slideshowInterval")
        defaults.set(folderTreeView, forKey: "lumen.folderTreeView")
        defaults.set(sortOrder.rawValue, forKey: "lumen.sortOrder")
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
}
