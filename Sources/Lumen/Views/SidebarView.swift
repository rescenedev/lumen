import SwiftUI

/// Left sidebar: library shortcuts, smart collections, albums, tags, color
/// labels, and folders.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renamingAlbum: Album?
    @State private var renameText = ""
    @State private var photoAlbumsExpanded = false
    @State private var expandedFolders: Set<URL> = []
    @State private var keyMonitor: Any?

    var body: some View {
        List(selection: Binding(
            get: { model.selectedSidebar },
            set: { if let value = $0 { model.selectedSidebar = value } }
        )) {
            librarySection
            photosLibrarySection
            albumsSection
            tagsSection
            labelsSection
            foldersSection
        }
        .listStyle(.sidebar)
        // Keyboard outline navigation, Finder-style: ↑/↓ only move the
        // selection (no auto-expand — arrowing through a long folder list used
        // to unfold every folder it passed); → reveals the selected folder's
        // children, ← folds them. An NSEvent monitor, not onKeyPress: the
        // sidebar List is NSTableView-backed and its key events never reach
        // SwiftUI's key-press chain (→ used to shift focus to the detail pane
        // instead). Click-driven expansion lives on the row gesture below.
        .onAppear {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // ←/→ act on the sidebar tree only while the user is "in" the
                // sidebar. AppKit focus can't express that (clicking a List row
                // doesn't reliably move first responder — it was found parked
                // on the thumbnail slider), so gate on intent instead: a folder
                // is selected, no photos are selected, and focus isn't in a
                // photo view / text field / the viewer — there the arrows keep
                // their navigation meaning.
                guard event.keyCode == 123 || event.keyCode == 124,   // ← / →
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      case .folder(let url) = model.selectedSidebar,
                      model.viewerIndex == nil,
                      model.selection.isEmpty
                else { return event }
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is LumenCollectionView || responder is LumenTableView || responder is NSText {
                    return event
                }
                if event.keyCode == 124 {
                    if !expandedFolders.contains(url) {
                        withAnimation { _ = expandedFolders.insert(url) }
                    }
                } else {
                    if expandedFolders.contains(url) {
                        withAnimation { _ = expandedFolders.remove(url) }
                    }
                }
                return nil   // consumed — the focus must stay on the sidebar
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .sheet(item: $renamingAlbum) { album in
            AlbumNameSheet(title: "Rename Album", confirmLabel: "Rename", text: $renameText) {
                model.renameAlbum(album.id, to: renameText)
            }
        }
    }

    // MARK: Sections

    private var librarySection: some View {
        let stats = model.stats
        return Section("Library") {
            row(.allPhotos, "All Photos", .accentColor, count: model.totalCount)
            row(.favorites, "Favorites", .pink, count: model.favoritesCount)
            row(.recentlyAdded, "Recently Added", .accentColor, count: stats.recentlyAdded)
            row(.onThisDay, "On This Day", .accentColor, count: stats.onThisDay)
            if !model.duplicatePaths.isEmpty {
                row(.duplicates, "Duplicates", .orange, count: model.duplicatePaths.count)
            }
        }
    }

    @ViewBuilder
    private var photosLibrarySection: some View {
        Section("Photos") {
            Label {
                HStack {
                    Text("Photos Library").lineLimit(1)
                    Spacer()
                    switch model.photosAccess {
                    case .loading:
                        ProgressView().controlSize(.small)
                    case .denied:
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("Photos access denied — enable in System Settings › Privacy › Photos.")
                    default:
                        if !model.assetPhotos.isEmpty {
                            Text("\(model.assetPhotos.count)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } icon: {
                Image(systemName: SidebarItem.photosLibrary.systemImage).foregroundStyle(Color.accentColor)
            }
            .tag(SidebarItem.photosLibrary)

            // Favorites stays pinned; the (often long) user-album list collapses.
            if let faves = model.photosAlbums.first(where: { $0.isFavorites }) {
                photosAlbumRow(faves)
            }
            let userAlbums = model.photosAlbums.filter { !$0.isFavorites }
            if !userAlbums.isEmpty {
                DisclosureGroup(isExpanded: $photoAlbumsExpanded) {
                    ForEach(userAlbums) { album in photosAlbumRow(album) }
                } label: {
                    Label("Albums (\(userAlbums.count))", systemImage: "rectangle.stack")
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            withAnimation { photoAlbumsExpanded.toggle() }
                        }
                }
            }
        }
    }

    private func photosAlbumRow(_ album: PhotosAlbumRef) -> some View {
        Label {
            HStack {
                Text(album.title).lineLimit(1)
                Spacer()
                Text("\(album.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: album.isFavorites ? "heart.fill" : "rectangle.stack")
                .foregroundStyle(album.isFavorites ? Color.pink : Color.accentColor)
        }
        .tag(SidebarItem.photosAlbum(album.id))
    }

    private var albumsSection: some View {
        Section {
            ForEach(model.albums) { album in
                row(.album(album.id), album.name, .accentColor, count: album.photoPaths.count)
                    .contextMenu {
                        Button("Rename…") { renameText = album.name; renamingAlbum = album }
                        Button("Delete Album", role: .destructive) { model.deleteAlbum(album.id) }
                    }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Albums")
                Button { model.startNewAlbum(with: []) } label: {
                    Image(systemName: "plus.circle")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New album")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        let tags = model.allTags()
        if !tags.isEmpty {
            Section("Tags") {
                ForEach(tags, id: \.tag) { entry in
                    row(.tag(entry.tag), entry.tag, .teal, count: entry.count)
                }
            }
        }
    }

    @ViewBuilder
    private var labelsSection: some View {
        let labelCounts = model.labelCounts
        let used = ColorLabel.allCases.filter { $0 != .none && (labelCounts[$0] ?? 0) > 0 }
        if !used.isEmpty {
            Section("Labels") {
                ForEach(used) { label in
                    row(.label(label), label.title, label.color ?? .gray, count: labelCounts[label] ?? 0,
                        iconOverride: "circle.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        let folderCounts = model.stats.folderCounts
        if !folderCounts.isEmpty {
            Section {
                if model.folderTreeView {
                    ForEach(model.folderTree) { node in
                        FolderTreeNode(node: node, expanded: $expandedFolders)
                    }
                } else {
                    // Pre-sorted + cached in the model — re-sorting here ran on
                    // every sidebar body evaluation.
                    ForEach(model.photoFolders, id: \.self) { url in
                        row(.folder(url), url.lastPathComponent, .secondary, count: folderCounts[url] ?? 0)
                            .contextMenu { FolderContextMenu(url: url) }
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Folders")
                    Button {
                        model.folderTreeView.toggle()
                    } label: {
                        Image(systemName: model.folderTreeView ? "list.bullet.indent" : "list.bullet")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(model.folderTreeView ? "Show as flat list" : "Show as folder tree")
                    Spacer()
                }
            }
        }
    }

    // MARK: Row builder

    private func row(_ item: SidebarItem, _ title: String, _ tint: Color, count: Int,
                     iconOverride: String? = nil) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: iconOverride ?? item.systemImage).foregroundStyle(tint)
        }
        .tag(item)
    }

}

/// One node of the folder tree. A click on a folder with children selects it
/// and toggles its children; the disclosure chevron still works as usual.
private struct FolderTreeNode: View {
    @Environment(AppModel.self) private var model
    let node: FolderNode
    @Binding var expanded: Set<URL>

    private var hasChildren: Bool { !(node.children?.isEmpty ?? true) }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.url) },
            set: { expanded = $0 ? expanded.union([node.url]) : expanded.subtracting([node.url]) }
        )
    }

    var body: some View {
        if hasChildren {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children ?? []) { child in
                    FolderTreeNode(node: child, expanded: $expanded)
                }
            } label: {
                // simultaneousGesture, NOT onTapGesture: the List must also see
                // the click so it does its native selection (which focuses the
                // list — an exclusive gesture left the highlight gray/inactive).
                // DragGesture(minimumDistance: 0), NOT TapGesture: a tiny drag
                // during the click defeats TapGesture (while the List still
                // selects), which made re-click-to-collapse feel unreliable —
                // a zero-distance drag always delivers its end event.
                // Clicking selects + reveals children; re-clicking the already-
                // selected folder toggles them.
                label
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard abs(value.translation.width) < 4,
                              abs(value.translation.height) < 4 else { return }
                        let item = SidebarItem.folder(node.url)
                        if model.selectedSidebar == item {
                            withAnimation { isExpanded.wrappedValue.toggle() }
                        } else {
                            model.selectedSidebar = item
                            if !isExpanded.wrappedValue {
                                withAnimation { isExpanded.wrappedValue = true }
                            }
                        }
                    })
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label {
            HStack {
                Text(node.name).lineLimit(1)
                Spacer()
                Text("\(node.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: "folder").foregroundStyle(.secondary)
        }
        .tag(SidebarItem.folder(node.url))
        .contextMenu { FolderContextMenu(url: node.url) }
    }
}
