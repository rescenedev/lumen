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
    @State private var hostWindow: NSWindow?

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
        // Folder-tree input is handled by an NSEvent monitor, NOT SwiftUI
        // modifiers — the sidebar List is AppKit-backed, so onKeyPress never
        // sees its key events and row-level gestures lose most clicks
        // (measured: 1 in 4 delivered). Behavior, Finder-style:
        //   • click on a folder row: the List selects it natively; the monitor
        //     then toggles its children — so clicking an expanded folder while
        //     browsing elsewhere folds it, and re-clicking re-opens it
        //   • the disclosure chevron keeps its native toggle (excluded here)
        //   • ↑/↓ only move the selection (no auto-expand); → reveals the
        //     selected folder's children, ← folds them
        .onAppear {
            guard keyMonitor == nil else { return }
            // leftMouseDOWN, not Up: NSTableView runs a mouse-tracking loop on
            // mouse-down that pulls the matching mouse-up straight off the event
            // queue — it never passes through sendEvent, so local monitors (and
            // SwiftUI row gestures) miss it. The down event always arrives.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
                if event.type == .leftMouseDown { return handleSidebarMouseDown(event) }
                return handleSidebarKeyDown(event)
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        // The monitor is app-global; capture the hosting window so events from
        // other windows (Settings — whose Form is also NSTableView-backed) are
        // never treated as sidebar input.
        .background(WindowReader { hostWindow = $0 })
        .sheet(item: $renamingAlbum) { album in
            AlbumNameSheet(title: "Rename Album", confirmLabel: "Rename", text: $renameText) {
                model.renameAlbum(album.id, to: renameText)
            }
        }
    }

    // MARK: Folder-tree input (NSEvent monitor)

    /// ←/→ act on the sidebar tree only while the user is "in" the sidebar.
    /// AppKit focus can't express that (clicking a List row doesn't reliably
    /// move first responder — it was found parked on the thumbnail slider), so
    /// gate on intent instead: a folder is selected, no photos are selected,
    /// and focus isn't in a photo view / text field / the viewer — there the
    /// arrows keep their navigation meaning.
    private func handleSidebarKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 123 || event.keyCode == 124,   // ← / →
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              model.folderTreeView,
              let hostWindow, event.window === hostWindow, hostWindow.isKeyWindow,
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

    /// A click on a sidebar outline row toggles the clicked folder's children.
    /// The List's native selection runs first (the event is never consumed,
    /// and the deferred block runs after the table's tracking loop completes);
    /// once it lands, the selected folder IS the clicked row, so toggling the
    /// selection is toggling the click target. Chevron clicks are left to the
    /// outline's own toggle — detected by the expansion state having already
    /// changed when the deferred block runs.
    private func handleSidebarMouseDown(_ event: NSEvent) -> NSEvent? {
        guard model.folderTreeView,
              event.clickCount == 1,   // double-clicks would expand-then-collapse
              let window = event.window, window === hostWindow,
              let root = window.contentView,
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        else { return event }
        // The sidebar list is the only non-photo NSTableView in the window
        // (SwiftUI backs it with a plain table even with DisclosureGroups).
        var view: NSView? = hit
        var table: NSTableView?
        while let v = view {
            if v is LumenCollectionView { return event }
            if let t = v as? NSTableView {
                if t is LumenTableView { return event }
                table = t
                break
            }
            view = v.superview
        }
        guard let table else { return event }

        let point = table.convert(event.locationInWindow, from: nil)
        guard table.row(at: point) >= 0 else { return event }

        let before = expandedFolders
        // Small delay, not a bare async hop: the List pushes the click's
        // selection through its own deferred binding update, and racing it
        // made the first cross-selection click's toggle land before the
        // selection (observed). 50ms is imperceptible and safely after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard case .folder(let url) = model.selectedSidebar,
                  expandedFolders == before   // chevron clicks toggle natively — don't double-toggle
            else { return }
            withAnimation {
                if expandedFolders.contains(url) {
                    expandedFolders.remove(url)
                } else {
                    expandedFolders.insert(url)
                }
            }
        }
        return event
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
                // No row-level gesture: SwiftUI gestures on rows of an
                // AppKit-backed List are unreliable (measured: 1 in 4 clicks
                // delivered). Click-to-toggle is handled by the sidebar's
                // NSEvent monitor instead — see SidebarView.body.
                label
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

/// Hands the hosting NSWindow to SwiftUI — used to scope the sidebar's
/// app-global NSEvent monitor to its own window.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class Coordinator {
        weak var lastWindow: NSWindow?
        var reported = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        report(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        report(view, context.coordinator)
    }

    /// Only fire `onWindow` when the hosting window actually changes — otherwise
    /// every SwiftUI update re-posts the same window and churns the parent's body.
    private func report(_ view: NSView, _ coordinator: Coordinator) {
        DispatchQueue.main.async { [weak view] in
            let window = view?.window
            guard !coordinator.reported || window !== coordinator.lastWindow else { return }
            coordinator.reported = true
            coordinator.lastWindow = window
            onWindow(window)
        }
    }
}
