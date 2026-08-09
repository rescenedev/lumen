import SwiftUI

/// Pure decision for what a sidebar folder-row click does to the tree's
/// expansion set. Extracted so it's unit-testable without AppKit.
///
/// A click is **expand-only**: it reveals a collapsed folder but never collapses
/// one. Collapsing is the disclosure chevron's and the ← key's job. This is what
/// makes the click robust — a duplicate mouse-down or a late native disclosure
/// toggle can re-run this with the folder already open, and it stays open
/// instead of flipping shut (the old toggle behaviour caused open-then-collapse).
enum FolderTreeExpansion {
    /// - Parameters:
    ///   - current: the live expansion set when the deferred decision runs.
    ///   - before: the set captured the instant the click landed.
    ///   - clicked: the folder the selection resolved to.
    /// - Returns: a new set (never mutates the input). Unchanged when the set
    ///   shifted since the click (a chevron toggle — leave the native control
    ///   alone) or the folder is already expanded.
    static func expandedAfterFolderClick(current: Set<URL>, before: Set<URL>,
                                         clicked: URL) -> Set<URL> {
        guard current == before, !current.contains(clicked) else { return current }
        return current.union([clicked])
    }
}

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
        //     then *expands* its children (expand-only — never folds, so a stray
        //     second event can't collapse what the click just opened)
        //   • the disclosure chevron keeps its native toggle — that, and ←, are
        //     how a folder collapses
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

    /// A click on a sidebar outline row expands the clicked folder's children.
    /// The List's native selection runs first (the event is never consumed,
    /// and the deferred block runs after the table's tracking loop completes);
    /// once it lands, the selected folder IS the clicked row, so expanding the
    /// selection is expanding the click target. Chevron clicks are left to the
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
        // made the first cross-selection click land before the selection
        // (observed). 50ms is imperceptible and safely after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard case .folder(let url) = model.selectedSidebar else { return }
            // Expand-only — see FolderTreeExpansion. A click reveals a folder
            // but never folds it (chevron / ← do that), so a stray second event
            // can't collapse what the click just opened.
            let next = FolderTreeExpansion.expandedAfterFolderClick(
                current: expandedFolders, before: before, clicked: url)
            if next != expandedFolders {
                withAnimation { expandedFolders = next }
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
                        let offline = model.isUnderOfflineRoot(url)
                        let isRoot = model.isRootFolder(url)
                        FolderRowLabel(name: url.lastPathComponent,
                                       count: folderCounts[url] ?? 0, offline: offline,
                                       storage: isRoot ? VolumeIdentity.kind(for: url.path) : nil,
                                       storageDetail: isRoot ? VolumeIdentity.describe(url.path) : nil)
                            .tag(SidebarItem.folder(url))
                            .selectionDisabled(offline)
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
        let offline = model.isUnderOfflineRoot(node.url)
        let isRoot = model.isRootFolder(node.url)
        return FolderRowLabel(name: node.name, count: node.count, offline: offline,
                              storage: isRoot ? VolumeIdentity.kind(for: node.url.path) : nil,
                              storageDetail: isRoot ? VolumeIdentity.describe(node.url.path) : nil)
            .tag(SidebarItem.folder(node.url))
            .selectionDisabled(offline)
            .contextMenu { FolderContextMenu(url: node.url) }
    }
}

/// Folder row shared by the tree and flat presentations. When the folder's
/// volume is disconnected the row grays out, swaps its count for a
/// disconnected-drive badge, and (via `selectionDisabled` at the call sites)
/// refuses selection until the volume mounts again.
private struct FolderRowLabel: View {
    let name: String
    let count: Int
    let offline: Bool
    /// Where this folder lives — set only on the roots the user added, so the
    /// badge marks the boundary between storage rather than repeating on every
    /// descendant. nil draws the plain folder icon.
    var storage: VolumeIdentity.Kind?
    var storageDetail: String?

    var body: some View {
        Label {
            HStack {
                Text(name).lineLimit(1)
                    .foregroundStyle(offline ? Color.secondary.opacity(0.55) : Color.primary)
                Spacer()
                if offline {
                    Image(systemName: "externaldrive.badge.xmark")
                        .imageScale(.small)
                        .foregroundStyle(Color.secondary.opacity(0.55))
                } else {
                    Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: storage?.symbol ?? "folder")
                .foregroundStyle(offline ? Color.secondary.opacity(0.4) : Color.secondary)
        }
        // The row is grayed and unselectable, so the tooltip has to say both
        // things: it comes back on its own, and there's a way out if it won't.
        .help(offline
              ? "Drive not connected — the folder comes back when the volume mounts. "
                + "Right-click to remove it from the library."
              : (storageDetail ?? ""))
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
