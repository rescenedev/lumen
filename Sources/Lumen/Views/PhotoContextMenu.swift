import SwiftUI

/// Shared right-click menu for a photo. When the clicked photo is part of a
/// multi-selection, actions apply to the whole selection.
struct PhotoContextMenu: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    private var targets: [Photo] { model.actionTargets(for: photo) }
    private var isBatch: Bool { targets.count > 1 }
    private var suffix: String { isBatch ? " (\(targets.count))" : "" }

    var body: some View {
        if !isBatch {
            Button("Open") { model.openViewer(photo) }
            Button("Quick Look") { QuickLookPreview.shared.show(urls: [photo.url], startAt: 0) }
            if !photo.isAsset {
                Button("Crop & Resize…") { model.startEdit(photo) }
            }
        }
        if targets.count == 2 {
            Button("Compare") { model.openCompare(targets) }
        }

        Divider()

        Button(favoriteLabel + suffix) { model.toggleFavorites(targets) }

        Menu("Rating") {
            Button("None") { model.setRating(0, for: targets) }
            ForEach(1...5, id: \.self) { n in
                Button(String(repeating: "★", count: n)) { model.setRating(n, for: targets) }
            }
        }

        Menu("Label") {
            ForEach(ColorLabel.allCases) { label in
                Button(label.title) { model.setLabel(label, for: targets) }
            }
        }

        Menu("Add to Album") {
            Button("New Album…") { model.startNewAlbum(with: targets) }
            if !model.albums.isEmpty { Divider() }
            ForEach(model.albums) { album in
                Button(album.name) { model.addToAlbum(album.id, photos: targets) }
            }
        }

        if case .album(let id) = model.committedSidebar {
            Button("Remove from Album" + suffix) { model.removeFromAlbum(id, photos: targets) }
        }

        Divider()

        Button("Share…") { model.share(targets) }
        Menu("Export") {
            Button("Originals…") { model.exportOriginals(targets) }
            Button("Resized 1024px…") { model.exportResized(targets, maxPixel: 1024) }
            Button("Resized 2048px…") { model.exportResized(targets, maxPixel: 2048) }
            Button("As Zip…") { model.exportZip(targets) }
        }
        if !isBatch {
            Button("Set as Wallpaper") { model.setWallpaper(photo) }
        }
        Button("Rename…" + suffix) { model.startRename(targets) }

        Divider()

        if !isBatch { Button("Open in Default App") { model.openWithDefaultApp(photo) } }
        Button("Reveal in Finder" + suffix) { model.revealInFinder(targets) }
        Button("Copy" + suffix) { model.copyToPasteboard(targets) }

        Divider()

        Button("Move to Trash" + suffix, role: .destructive) { model.requestDeletion(targets) }
    }

    private var favoriteLabel: String {
        if isBatch { return "Toggle Favorite" }
        return model.isFavorite(photo) ? "Remove from Favorites" : "Add to Favorites"
    }
}
