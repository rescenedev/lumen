import SwiftUI

/// Left sidebar: library shortcuts, smart collections, albums, tags, color
/// labels, and folders.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renamingAlbum: Album?
    @State private var renameText = ""

    var body: some View {
        List(selection: Binding(
            get: { model.selectedSidebar },
            set: { if let value = $0 { model.selectedSidebar = value } }
        )) {
            librarySection
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
                    OutlineGroup(model.folderTree, children: \.children) { node in
                        row(.folder(node.url), node.name, .secondary, count: node.count)
                            .contextMenu { FolderContextMenu(url: node.url) }
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
