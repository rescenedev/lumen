import SwiftUI

/// Hosts either the grid or list presentation, plus the shared Finder-style
/// bottom status bar (item / selection count + thumbnail-size slider).
struct PhotoBrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var searchInput = ""
    @State private var searchDebounce: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            if let update = model.availableUpdate, !model.updateBannerDismissed {
                updateBanner(update)
                Divider()
            }
            searchBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if model.isSortingVisible {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 10)
                    }
                }
            Divider()
            statusBar
        }
        .onAppear { prefetch() }
        .onChange(of: model.visibleToken) { _, _ in prefetch() }
    }

    /// Warm thumbnails for a freshly opened list so the first screens appear
    /// instantly. The NSCollectionView grid prefetches per-viewport on its own,
    /// so it only needs the first screens here; the SwiftUI list/month views
    /// have no viewport callback and warm deeper.
    private func prefetch() {
        guard model.viewMode != .map else { return }
        ThumbnailCache.shared.yieldWarmingToBrowsing()
        let usesCollectionGrid = model.viewMode == .grid && !model.groupByMonth
        let tier = model.viewMode == .grid
            ? ThumbnailCache.tier(forPointSize: model.thumbnailSize)
            : ThumbnailCache.tier(forPointSize: 40)   // list rows
        let limit = usesCollectionGrid ? 200 : 600
        let entries: [ThumbnailCache.Entry] = model.visiblePhotos.prefix(limit)
            .map { (url: $0.url, mtime: $0.cacheMtime) }
        ThumbnailCache.shared.prefetch(entries, maxPixel: tier, limit: limit)
    }

    /// Non-intrusive "a new version exists" bar. Notify-only: Homebrew installs
    /// get the upgrade command, direct downloads get the release page.
    private func updateBanner(_ update: UpdateInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text("Lumen \(update.version) 사용 가능").font(.callout.weight(.medium))
            Spacer()
            if update.isBrewInstall {
                Button("Homebrew로 업데이트") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UpdateInfo.brewUpgradeCommand, forType: .string)
                    model.showToast(String(localized: "Upgrade command copied: \(UpdateInfo.brewUpgradeCommand)", bundle: .module))
                }
            } else {
                Button("다운로드") { NSWorkspace.shared.open(update.releaseURL) }
            }
            Button("릴리즈 노트") { NSWorkspace.shared.open(update.releaseURL) }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
            Button { model.updateBannerDismissed = true } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.tint.opacity(0.12))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search by name, tag, or camera", text: $searchInput)
                .textFieldStyle(.plain)
                .onChange(of: searchInput) { _, value in scheduleSearch(value) }
                .onChange(of: model.searchText) { _, value in
                    if value != searchInput { searchInput = value }  // external clears
                }
            if !searchInput.isEmpty {
                Button {
                    searchInput = ""
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Debounce search input so we don't re-filter the whole library on every keystroke.
    private func scheduleSearch(_ value: String) {
        searchDebounce?.cancel()
        // Camera search needs the EXIF index; populate it on demand the first time
        // the user actually searches (a plain browse session still skips it).
        if !value.trimmingCharacters(in: .whitespaces).isEmpty { model.ensureExifIndex() }
        let work = DispatchWorkItem { model.searchText = value }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @ViewBuilder
    private var content: some View {
        if model.viewMode == .map {
            PhotoMapView()
        } else if model.visiblePhotos.isEmpty && !model.isSortingVisible {
            emptyFilterState
        } else if model.viewMode == .grid {
            if model.groupByMonth {
                PhotoGridView()   // SwiftUI fallback keeps month sections
            } else {
                PhotoCollectionView(
                    model: model,
                    token: model.visibleToken,
                    navToken: model.navigationToken,
                    isSorting: model.isSortingVisible,
                    metaVersion: model.metaRevision,
                    thumbnailSize: model.thumbnailSize,
                    selection: model.selection,
                    anchor: model.selectionAnchor,
                    viewerActive: model.viewerIndex != nil
                )
            }
        } else {
            PhotoTableView(
                model: model,
                token: model.visibleToken,
                navToken: model.navigationToken,
                isSorting: model.isSortingVisible,
                metaVersion: model.metaRevision,
                selection: model.selection,
                viewerActive: model.viewerIndex != nil
            )
        }
    }

    @ViewBuilder
    private var emptyFilterState: some View {
        if model.isLoadingVisibleScope {
            VStack(spacing: 14) {
                ProgressView()
                Text("Loading…").font(.title3.weight(.medium))
                Text("Fetching photos from your library.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if model.isIndexingExif && !model.searchText.isEmpty {
            indexingState
        } else {
            ContentUnavailableView {
                Label("No Photos", systemImage: "photo.on.rectangle")
            } description: {
                Text(emptyDescription)
            }
        }
    }

    /// Shown while the EXIF index is still being built for a search — camera
    /// matches can't appear until their files have been read.
    private var indexingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Indexing photo metadata…").font(.title3.weight(.medium))
            Text(indexingDescription).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var indexingDescription: String {
        let total = model.exifIndexTotal
        guard total > 0 else { return "Reading EXIF (camera, date, GPS) to match “\(model.searchText)”." }
        return "Reading EXIF (camera, date, GPS)… \(model.exifIndexDone.formatted()) of \(total.formatted()) photos"
    }

    private var emptyDescription: String {
        if !model.searchText.isEmpty { return "No photos match “\(model.searchText)”." }
        if case .favorites = model.committedSidebar { return "Mark photos as favorites to see them here." }
        return "This folder has no photos."
    }

    // MARK: - Status bar

    private var statusBar: some View {
        @Bindable var model = model
        return ZStack {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 6) {
                WarmingStatusView(warming: model.warming)
                if model.isIndexingExif {
                    ProgressView().controlSize(.mini)
                    Text(indexingStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Reading camera & EXIF info so search and the map can find photos")
                } else if model.exifIndexJustFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.green)
                    Text("Metadata indexed · \(model.exifReadyCount.formatted()) photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Photo metadata (camera, date, GPS) is indexed — search and the map are ready")
                }
                Spacer()
                if model.viewMode == .grid {
                    Image(systemName: "square.grid.3x3")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.thumbnailSize, in: 90...320)
                        .controlSize(.mini)
                        .frame(width: 96)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    private var indexingStatusText: String {
        let total = model.exifIndexTotal
        guard total > 0 else { return "Indexing photo metadata…" }
        var parts = ["Indexing metadata"]
        if !model.exifIndexSource.isEmpty { parts.append(model.exifIndexSource) }
        parts.append("\(model.exifIndexDone.formatted()) / \(total.formatted())")
        if model.exifIndexRate > 0 { parts.append("\(model.exifIndexRate)/s") }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        let count = model.selection.count
        if count > 0 {
            return "\(count) of \(model.visibleCount) selected"
        }
        return "\(model.visibleCount) \(model.visibleCount == 1 ? "item" : "items")"
    }
}

/// Shared keyboard handling for both presentations: Space → Quick Look,
/// Return → open viewer, ⌘A → select all, Esc → clear selection.
struct BrowserKeyHandlers: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space) { quickLook() }
            .onKeyPress(.return) { openSelected() }
            .onKeyPress(keys: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAll(model.visiblePhotos)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !model.selection.isEmpty else { return .ignored }
                model.clearSelection()
                return .handled
            }
            // Backspace arrives as DEL (\u{7F}), not KeyEquivalent.delete —
            // match every delete variant or the key looks dead.
            .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { _ in
                let targets = model.deletionTargets
                guard !targets.isEmpty else { return .ignored }
                model.requestDeletion(targets)
                return .handled
            }
    }

    private func quickLook() -> KeyPress.Result {
        let photos = model.visiblePhotos
        guard let photo = model.primarySelectedPhoto ?? photos.first,
              let index = photos.firstIndex(of: photo) else { return .ignored }
        QuickLookPreview.shared.toggle(urls: photos.map { $0.url }, startAt: index)
        return .handled
    }

    private func openSelected() -> KeyPress.Result {
        guard let photo = model.primarySelectedPhoto ?? model.visiblePhotos.first else { return .ignored }
        model.openViewer(photo)
        return .handled
    }
}

extension View {
    func browserKeyHandlers() -> some View { modifier(BrowserKeyHandlers()) }
}
