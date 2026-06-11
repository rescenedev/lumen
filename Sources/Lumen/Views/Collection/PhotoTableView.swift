import SwiftUI
import AppKit

/// AppKit NSTableView wrapped for SwiftUI — the list presentation.
/// This replaced a SwiftUI `List`: at 67k photos its ForEach rebuild measured
/// ~210ms of main-thread stall on every entry, selection changes triggered a
/// "reentrant NSTableView delegate" warning from List's own internals, and
/// large selections cost ~100ms per change. A plain NSTableView with cell
/// reuse handles the same content instantly.
struct PhotoTableView: NSViewRepresentable {
    let model: AppModel
    let token: Int                 // visibleSignature — changes when the list changes
    let navToken: Int              // changes on user navigation — resets scroll to top
    let isSorting: Bool            // true while a big scope sorts off-main
    let metaVersion: Int           // favorites/ratings/labels changed → refresh badges
    let selection: Set<Photo.ID>
    let viewerActive: Bool         // true while the full-screen viewer is open

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LumenTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.headerView = nil
        table.focusRingType = .none

        func column(_ id: String, width: CGFloat? = nil, minWidth: CGFloat = 40) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            if let width { c.width = width; c.resizingMask = [] } else { c.resizingMask = .autoresizingMask }
            c.minWidth = minWidth
            return c
        }
        table.addTableColumn(column("name", minWidth: 160))
        table.addTableColumn(column("type", width: 48))
        table.addTableColumn(column("size", width: 76))
        table.addTableColumn(column("date", width: 150))
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let coord = context.coordinator
        table.dataSource = coord
        table.delegate = coord
        table.target = coord
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onKey = { [weak coord] key in coord?.handleKey(key) ?? false }
        table.menuProvider = { [weak coord, weak table] event in
            guard let coord, let table else { return nil }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            return coord.menu(forRow: row, in: table)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        coord.table = table
        coord.appliedToken = token
        coord.appliedNavToken = navToken
        coord.reload(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? LumenTableView else { return }
        let coord = context.coordinator

        if token != coord.appliedToken {
            coord.appliedToken = token
            coord.reload(table)
        } else if coord.appliedSorting && !isSorting {
            coord.reload(table)            // async sort just landed — refresh content
        } else if metaVersion != coord.appliedMetaVersion {
            coord.refreshVisibleRows(table)
        }
        coord.appliedSorting = isSorting
        coord.appliedMetaVersion = metaVersion

        if navToken != coord.appliedNavToken {
            coord.appliedNavToken = navToken
            if coord.photos.count > 0 { table.scrollRowToVisible(0) }
        }

        if selection != coord.appliedSelection {
            coord.applySelection(table, selection)
        }

        // Reclaim keyboard focus when the viewer closes (same dance as the grid).
        if coord.appliedViewerActive && !viewerActive {
            DispatchQueue.main.async { [weak table] in
                guard let table, let window = table.window else { return }
                if window.firstResponder !== table { window.makeFirstResponder(table) }
            }
        }
        coord.appliedViewerActive = viewerActive
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        var photos: [Photo] = []
        weak var table: NSTableView?
        var appliedToken = -1
        var appliedNavToken = -1
        var appliedSorting = false
        var appliedMetaVersion = -1
        var appliedSelection: Set<Photo.ID> = []
        var appliedViewerActive = false
        private var syncingSelection = false

        init(model: AppModel) { self.model = model }

        func reload(_ table: NSTableView) {
            photos = model.visiblePhotos
            table.reloadData()
            applySelection(table, model.selection)
        }

        func refreshVisibleRows(_ table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }

        func applySelection(_ table: NSTableView, _ selection: Set<Photo.ID>) {
            appliedSelection = selection
            syncingSelection = true
            if selection.isEmpty {
                table.deselectAll(nil)
            } else {
                var rows = IndexSet()
                for (i, photo) in photos.enumerated() where selection.contains(photo.id) {
                    rows.insert(i)
                }
                table.selectRowIndexes(rows, byExtendingSelection: false)
            }
            syncingSelection = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { photos.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard photos.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
            let photo = photos[row]
            switch id {
            case "name":
                let cell = tableView.makeView(withIdentifier: PhotoNameCell.identifier, owner: nil) as? PhotoNameCell
                    ?? PhotoNameCell()
                cell.configure(photo: photo, favorite: model.isFavorite(photo))
                return cell
            case "type":
                return textCell(tableView, "t", photo.fileExtension.uppercased(), secondary: true)
            case "size":
                return textCell(tableView, "s", Format.size(photo.byteSize), secondary: true, mono: true)
            case "date":
                return textCell(tableView, "d", Format.dateString(photo.creationDate), secondary: true)
            default:
                return nil
            }
        }

        private func textCell(_ table: NSTableView, _ reuseID: String, _ value: String,
                              secondary: Bool = false, mono: Bool = false) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier("text-\(reuseID)")
            let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                c.addSubview(label)
                c.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                    label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = value
            cell.textField?.font = mono
                ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
            return cell
        }

        // MARK: Selection sync (table → model)

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncingSelection, let table = notification.object as? NSTableView else { return }
            let sel = Set(table.selectedRowIndexes.compactMap { photos.indices.contains($0) ? photos[$0].id : nil })
            appliedSelection = sel
            model.selection = sel
            if let last = table.selectedRowIndexes.last, photos.indices.contains(last) {
                model.selectionAnchor = photos[last].id
            }
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, photos.indices.contains(table.clickedRow) else { return }
            model.openViewer(photos[table.clickedRow])
        }

        func menu(forRow row: Int, in table: NSTableView) -> NSMenu? {
            guard photos.indices.contains(row) else { return nil }
            let photo = photos[row]
            if !model.selection.contains(photo.id) {
                model.selectOnly(photo)
                applySelection(table, model.selection)
            }
            return PhotoMenuBuilder.build(for: photo, model: model)
        }

        func handleKey(_ key: LumenKey) -> Bool {
            switch key {
            case .space:
                guard let photo = model.primarySelectedPhoto ?? photos.first,
                      let index = photos.firstIndex(of: photo) else { return false }
                QuickLookPreview.shared.toggle(urls: photos.map { $0.url }, startAt: index)
                return true
            case .enter:
                guard let photo = model.primarySelectedPhoto ?? photos.first else { return false }
                model.openViewer(photo)
                return true
            case .delete:
                let targets = model.deletionTargets
                guard !targets.isEmpty else { return false }
                model.requestDeletion(targets)
                return true
            case .escape:
                guard !model.selection.isEmpty else { return false }
                model.clearSelection()
                return true
            }
        }
    }
}

/// NSTableView routing space/return/delete/escape to the coordinator and
/// serving row context menus (arrows, ⌘A, type-select stay native).
final class LumenTableView: NSTableView {
    var onKey: ((LumenKey) -> Bool)?
    var menuProvider: ((NSEvent) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        var handled = false
        switch event.keyCode {
        case 49: handled = onKey?(.space) ?? false       // space
        case 36, 76: handled = onKey?(.enter) ?? false   // return / enter
        case 51, 117: handled = onKey?(.delete) ?? false // delete / fwd-delete
        case 53: handled = onKey?(.escape) ?? false      // esc
        default: break
        }
        if !handled { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event) ?? super.menu(for: event)
    }
}

/// Name column cell: 40pt thumbnail + filename + favorite heart. Reuses the
/// shared thumbnail cache; cancels nothing on reuse (the cache callback is
/// guarded by URL identity instead, like the grid cells).
final class PhotoNameCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("photo-name")

    private let thumb = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let heart = NSImageView()
    private var currentURL: URL?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 5
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
        thumb.translatesAutoresizingMaskIntoConstraints = false

        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.translatesAutoresizingMaskIntoConstraints = false

        heart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Favorite")
        heart.contentTintColor = .systemPink
        heart.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        heart.translatesAutoresizingMaskIntoConstraints = false
        heart.isHidden = true

        addSubview(thumb); addSubview(name); addSubview(heart)
        textField = name
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 40),
            thumb.heightAnchor.constraint(equalToConstant: 40),
            name.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            heart.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            heart.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            heart.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(photo: Photo, favorite: Bool) {
        name.stringValue = photo.filename
        heart.isHidden = !favorite
        let url = photo.url
        currentURL = url
        let tier = ThumbnailCache.tier(forPointSize: 40)
        if let hit = ThumbnailCache.shared.cached(for: url, maxPixel: tier) {
            thumb.image = hit
            return
        }
        thumb.image = nil
        ThumbnailCache.shared.thumbnail(for: url, maxPixel: tier, mtime: photo.cacheMtime) { [weak self] image in
            guard let self, self.currentURL == url else { return }
            self.thumb.image = image
        }
    }
}
