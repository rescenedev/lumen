import SwiftUI

/// Left sidebar: library shortcuts, smart collections, albums, tags, color
/// labels, and folders.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renamingAlbum: Album?
    @State private var renameText = ""
    @State private var photoAlbumsExpanded = false
    @State private var expandedFolders: Set<URL> = []

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
                    let folders = folderCounts.keys.sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                    ForEach(folders, id: \.self) { url in
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
                // Our handler adds the toggle: expand on click, collapse on
                // re-click — Finder source-list feel.
                label
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        model.selectedSidebar = .folder(node.url)
                        withAnimation { isExpanded.wrappedValue.toggle() }
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
