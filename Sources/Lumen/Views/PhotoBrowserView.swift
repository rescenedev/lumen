import SwiftUI

/// Hosts either the grid or list presentation, plus the shared Finder-style
/// bottom status bar (item / selection count + thumbnail-size slider).
struct PhotoBrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var searchInput = ""
    @State private var searchDebounce: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .onAppear { prefetch() }
        .onChange(of: model.visibleToken) { _, _ in prefetch() }
    }

    /// Warm thumbnails for the current list so cells appear instantly on scroll.
    private func prefetch() {
        guard model.viewMode != .map else { return }
        ThumbnailCache.shared.prefetch(model.visiblePhotos.map { $0.url })
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
        let work = DispatchWorkItem { model.searchText = value }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @ViewBuilder
    private var content: some View {
        if model.viewMode == .map {
            PhotoMapView()
        } else if model.visiblePhotos.isEmpty {
            emptyFilterState
        } else if model.viewMode == .grid {
            PhotoGridView()
        } else {
            PhotoListView()
        }
    }

    private var emptyFilterState: some View {
        ContentUnavailableView {
            Label("No Photos", systemImage: "photo.on.rectangle")
        } description: {
            Text(emptyDescription)
        }
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
            .onKeyPress(.delete) {
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
