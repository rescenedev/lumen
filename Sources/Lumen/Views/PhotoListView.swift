import SwiftUI

/// List presentation backed by SwiftUI's native multi-selectable `List`,
/// which provides ⌘/⇧-click selection and arrow-key navigation for free.
struct PhotoListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return List(selection: $model.selection) {
            ForEach(model.visiblePhotos) { photo in
                PhotoRow(photo: photo)
                    .tag(photo.id)
                    .contextMenu { PhotoContextMenu(photo: photo) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        model.openViewer(photo)
                    })
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onChange(of: model.selection) { _, sel in
            // Keep the inspector anchor pointing at a still-selected photo.
            if let anchor = model.selectionAnchor, sel.contains(anchor) { return }
            model.selectionAnchor = sel.first
        }
        .browserKeyHandlers()
    }
}

/// A single row: small thumbnail, filename, and file facts.
private struct PhotoRow: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    var body: some View {
        HStack(spacing: 12) {
            AsyncThumbnail(url: photo.url)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.black.opacity(0.1), lineWidth: 1)
                )

            Text(photo.filename)
                .lineLimit(1)
                .truncationMode(.middle)

            if model.isFavorite(photo) {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
            }

            Spacer()

            Text(photo.fileExtension.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Text(Format.size(photo.byteSize))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            Text(Format.dateString(photo.creationDate))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
