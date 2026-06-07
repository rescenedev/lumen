import AppKit

/// NSMenuItem that runs a closure (so we can build menus without @objc targets).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler() }
}

/// Builds the right-click menu for a photo in the collection grid, mirroring the
/// SwiftUI `PhotoContextMenu` (batch-aware).
@MainActor
enum PhotoMenuBuilder {
    static func build(for photo: Photo, model: AppModel) -> NSMenu {
        let targets = model.actionTargets(for: photo)
        let isBatch = targets.count > 1
        let suffix = isBatch ? " (\(targets.count))" : ""
        let menu = NSMenu()

        if !isBatch {
            menu.addItem(ClosureMenuItem("Open") { model.openViewer(photo) })
            menu.addItem(ClosureMenuItem("Quick Look") {
                QuickLookPreview.shared.show(urls: [photo.url], startAt: 0)
            })
            if !photo.isAsset {
                menu.addItem(ClosureMenuItem("Crop & Resize…") { model.startEdit(photo) })
            }
        }
        if targets.count == 2 {
            menu.addItem(ClosureMenuItem("Compare") { model.openCompare(targets) })
        }
        if isBatch && targets.contains(where: { !$0.isAsset }) {
            menu.addItem(ClosureMenuItem("Combine into One…") { model.startCombine(targets) })
        }
        menu.addItem(.separator())

        let favTitle = isBatch ? "Toggle Favorite" : (model.isFavorite(photo) ? "Remove from Favorites" : "Add to Favorites")
        menu.addItem(ClosureMenuItem(favTitle + suffix) { model.toggleFavorites(targets) })

        // Rating
        let ratingMenu = NSMenu()
        ratingMenu.addItem(ClosureMenuItem("None") { model.setRating(0, for: targets) })
        for n in 1...5 {
            ratingMenu.addItem(ClosureMenuItem(String(repeating: "★", count: n)) { model.setRating(n, for: targets) })
        }
        let ratingItem = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        ratingItem.submenu = ratingMenu
        menu.addItem(ratingItem)

        // Label
        let labelMenu = NSMenu()
        for label in ColorLabel.allCases {
            labelMenu.addItem(ClosureMenuItem(label.title) { model.setLabel(label, for: targets) })
        }
        let labelItem = NSMenuItem(title: "Label", action: nil, keyEquivalent: "")
        labelItem.submenu = labelMenu
        menu.addItem(labelItem)

        // Add to Album
        let albumMenu = NSMenu()
        albumMenu.addItem(ClosureMenuItem("New Album…") { model.startNewAlbum(with: targets) })
        if !model.albums.isEmpty { albumMenu.addItem(.separator()) }
        for album in model.albums {
            albumMenu.addItem(ClosureMenuItem(album.name) { model.addToAlbum(album.id, photos: targets) })
        }
        let albumItem = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
        albumItem.submenu = albumMenu
        menu.addItem(albumItem)

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Share…") { model.share(targets) })
        let exportMenu = NSMenu()
        exportMenu.addItem(ClosureMenuItem("Originals…") { model.exportOriginals(targets) })
        exportMenu.addItem(ClosureMenuItem("Resized 2048px…") { model.exportResized(targets, maxPixel: 2048) })
        exportMenu.addItem(ClosureMenuItem("As Zip…") { model.exportZip(targets) })
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)
        if !isBatch {
            menu.addItem(ClosureMenuItem("Set as Wallpaper") { model.setWallpaper(photo) })
        }
        menu.addItem(ClosureMenuItem("Rename…" + suffix) { model.startRename(targets) })

        menu.addItem(.separator())

        if !isBatch {
            menu.addItem(ClosureMenuItem("Open in Default App") { model.openWithDefaultApp(photo) })
        }
        menu.addItem(ClosureMenuItem("Reveal in Finder" + suffix) { model.revealInFinder(targets) })
        menu.addItem(ClosureMenuItem("Copy" + suffix) { model.copyToPasteboard(targets) })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Move to Trash" + suffix) { model.requestDeletion(targets) })

        return menu
    }
}
