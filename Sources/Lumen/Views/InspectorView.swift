import SwiftUI

/// Right-hand inspector showing file info and EXIF metadata for the
/// currently selected (or currently viewed) photo.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var metadata: ImageMetadata?

    private var photo: Photo? {
        if let viewed = model.currentViewerPhoto { return viewed }
        return model.primarySelectedPhoto
    }

    /// Number of selected photos when the viewer isn't open.
    private var selectionCount: Int {
        model.currentViewerPhoto == nil ? model.selection.count : 1
    }

    /// Photos that metadata edits apply to.
    private var editorTargets: [Photo] {
        if let viewed = model.currentViewerPhoto { return [viewed] }
        if model.selection.count > 1 { return model.selectedPhotos }
        if let primary = model.primarySelectedPhoto { return [primary] }
        return []
    }

    var body: some View {
        Group {
            if let photo {
                content(for: photo)
            } else {
                ContentUnavailableView("No Selection",
                                       systemImage: "info.circle",
                                       description: Text("Select a photo to see its details."))
            }
        }
        .task(id: photo?.url) { await loadMetadata() }
    }

    private func content(for photo: Photo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if selectionCount > 1 {
                    multiSelectionBanner
                }
                preview(for: photo)
                header(for: photo)
                Divider()
                MetadataEditor(targets: editorTargets)
                Divider()
                fileSection(for: photo)
                if let meta = metadata, meta.hasCameraInfo {
                    Divider()
                    cameraSection(meta)
                }
                if let coord = metadata?.gpsCoordinate {
                    Divider()
                    locationSection(coord)
                }
            }
            .padding(16)
        }
    }

    private var multiSelectionBanner: some View {
        let photos = model.selectedPhotos
        let totalBytes = photos.reduce(Int64(0)) { $0 + $1.byteSize }
        return VStack(alignment: .leading, spacing: 8) {
            Label("\(photos.count) photos selected", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            Text("Combined size: \(Format.size(totalBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    model.toggleFavorites(photos)
                } label: {
                    Label("Favorite", systemImage: "heart")
                }
                Button {
                    model.revealInFinder(photos)
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
            Text("Showing details for the most recent selection:")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Divider()
        }
    }

    private func preview(for photo: Photo) -> some View {
        AsyncThumbnail(url: photo.url, mtime: photo.cacheMtime)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func header(for photo: Photo) -> some View {
        HStack(alignment: .top) {
            Text(photo.filename)
                .font(.headline)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer()
            Button {
                model.toggleFavorite(photo)
            } label: {
                Image(systemName: model.isFavorite(photo) ? "heart.fill" : "heart")
                    .foregroundStyle(model.isFavorite(photo) ? .pink : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Toggle favorite")
        }
    }

    private func fileSection(for photo: Photo) -> some View {
        // Assets pull Kind/Size/Where from PhotoKit; file photos use the on-disk
        // values. Size is only shown once known (avoids a misleading "Zero KB").
        let kind = photo.isAsset ? (metadata?.kind ?? "—") : photo.fileExtension.uppercased()
        let byteSize = photo.isAsset ? metadata?.byteSize : photo.byteSize
        let whereText = photo.isAsset ? (metadata?.sourceLabel ?? "Apple Photos") : photo.folderURL.path
        return MetadataSection(title: "File") {
            InfoRow("Kind", kind)
            if let byteSize { InfoRow("Size", Format.size(byteSize)) }
            InfoRow("Dimensions", Format.dimensions(metadata?.pixelWidth, metadata?.pixelHeight))
            if let mp = Format.megapixels(metadata?.pixelWidth, metadata?.pixelHeight) {
                InfoRow("Resolution", mp)
            }
            InfoRow("Created", Format.dateString(photo.creationDate))
            InfoRow("Modified", Format.dateString(photo.modificationDate))
            InfoRow("Where", whereText, mono: !photo.isAsset)
        }
    }

    private func cameraSection(_ meta: ImageMetadata) -> some View {
        MetadataSection(title: "Camera") {
            if let make = meta.cameraMake, let model = meta.cameraModel {
                InfoRow("Camera", "\(make) \(model)")
            } else if let model = meta.cameraModel {
                InfoRow("Camera", model)
            }
            if let lens = meta.lens { InfoRow("Lens", lens) }
            if let focal = meta.focalLength { InfoRow("Focal Length", focal) }
            if let aperture = meta.aperture { InfoRow("Aperture", aperture) }
            if let shutter = meta.shutterSpeed { InfoRow("Shutter", shutter) }
            if let iso = meta.iso { InfoRow("ISO", iso) }
            if let date = meta.dateTaken { InfoRow("Taken", date) }
        }
    }

    private func locationSection(_ coord: (lat: Double, lon: Double)) -> some View {
        MetadataSection(title: "Location") {
            InfoRow("Latitude", String(format: "%.5f", coord.lat))
            InfoRow("Longitude", String(format: "%.5f", coord.lon))
            Button("Show in Maps") {
                let url = URL(string: "https://maps.apple.com/?ll=\(coord.lat),\(coord.lon)&q=Photo")!
                NSWorkspace.shared.open(url)
            }
            .font(.caption)
            .padding(.top, 2)
        }
    }

    private func loadMetadata() async {
        metadata = nil
        guard let photo else { return }
        // Assets have no file on disk — read their metadata from PhotoKit/iCloud.
        if photo.isAsset {
            let m = await PhotosImageLoader.shared.metadata(for: photo.url)
            guard !Task.isCancelled else { return }   // photo changed mid-load
            metadata = m
        } else {
            let url = photo.url
            let m = await Task.detached(priority: .userInitiated) {
                MetadataReader.read(url: url)
            }.value
            guard !Task.isCancelled else { return }   // photo changed mid-load
            metadata = m
        }
    }
}

/// A titled group of info rows.
private struct MetadataSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// A label/value pair row. Click the value to copy it to the clipboard.
private struct InfoRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    @State private var copied = false
    @State private var hovering = false
    @State private var resetTask: Task<Void, Never>?

    init(_ label: String, _ value: String, mono: Bool = false) {
        self.label = label
        self.value = value
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? .green : .secondary)
                .opacity(copied || hovering ? 1 : 0)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { copy() }
        .help("Click to copy")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        copied = true
        // Cancel any prior reset so a rapid second copy (or row reuse) doesn't
        // leave the checkmark stuck or clear it early.
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { copied = false }
        }
    }
}
