import SwiftUI

/// Right-click menu for a folder row in the sidebar.
///
/// A folder on a disconnected volume gets a deliberately short menu instead of
/// no menu at all. Nothing that touches the files can work while the volume is
/// away — but "stop tracking this folder" is exactly what you want when a drive
/// is gone for good, and suppressing the whole menu left that row with no way
/// out of the library.
struct FolderContextMenu: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        if model.isUnderOfflineRoot(url) {
            offlineMenu
        } else {
            connectedMenu
        }
    }

    @ViewBuilder
    private var offlineMenu: some View {
        // Names why the menu is short, so it doesn't read as broken.
        Section("Volume not connected") {
            Button("Copy Path") { model.copyPath(url) }
        }
        if model.isRootFolder(url) {
            Divider()
            // Same wording as the connected case on purpose: this only forgets
            // the folder, it never touches files — and adding the folder back
            // undoes it, so it asks for no confirmation.
            Button("Remove from Library", role: .destructive) { model.removeRootFolder(url) }
        }
    }

    @ViewBuilder
    private var connectedMenu: some View {
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
