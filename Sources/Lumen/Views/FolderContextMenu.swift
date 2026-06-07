import SwiftUI

/// Right-click menu for a folder row in the sidebar.
struct FolderContextMenu: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        Button("Open in Finder") { model.openFolderInFinder(url) }
        Button("Reveal in Finder") { model.revealFolderInFinder(url) }

        Divider()

        Button("Rename Folder…") { model.startRenameFolder(url) }
        Button("New Album from Folder") { model.createAlbumFromFolder(url) }

        Menu("Export") {
            Button("Originals…") { model.exportOriginals(model.photosInFolder(url)) }
            Button("Resized 2048px…") { model.exportResized(model.photosInFolder(url), maxPixel: 2048) }
            Button("As Zip…") { model.exportZip(model.photosInFolder(url)) }
        }

        Button("Find Duplicates Here") { model.findDuplicates(in: url) }
            .disabled(model.isFindingDuplicates)

        Divider()

        Button("Copy Path") { model.copyPath(url) }

        if model.isRootFolder(url) {
            Divider()
            Button("Remove from Library", role: .destructive) { model.removeRootFolder(url) }
        }
    }
}
