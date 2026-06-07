import SwiftUI

/// Interactive rating / color-label / tag editor in the inspector. Edits apply
/// to all `targets` (the current photo or the whole selection).
struct MetadataEditor: View {
    @EnvironmentObject var model: AppModel
    let targets: [Photo]

    @State private var newTag = ""

    private var primary: Photo? { targets.first }

    var body: some View {
        if let primary {
            VStack(alignment: .leading, spacing: 12) {
                ratingRow(primary)
                labelRow(primary)
                tagsRow(primary)
                addToAlbumRow
            }
        }
    }

    private func ratingRow(_ photo: Photo) -> some View {
        let rating = model.rating(photo)
        return HStack(spacing: 8) {
            Text("Rating").foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= rating ? "star.fill" : "star")
                        .foregroundStyle(i <= rating ? .yellow : .secondary)
                        .onTapGesture {
                            model.setRating(i == rating ? 0 : i, for: targets)
                        }
                }
            }
        }
        .font(.callout)
    }

    private func labelRow(_ photo: Photo) -> some View {
        let current = model.label(photo)
        return HStack(spacing: 8) {
            Text("Label").foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(ColorLabel.allCases) { label in
                    swatch(label, selected: label == current)
                }
            }
        }
        .font(.callout)
    }

    private func swatch(_ label: ColorLabel, selected: Bool) -> some View {
        Group {
            if let color = label.color {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(.secondary, lineWidth: 1)
                    .overlay(Image(systemName: "slash.circle").font(.system(size: 8)).foregroundStyle(.secondary))
            }
        }
        .frame(width: 16, height: 16)
        .overlay(Circle().strokeBorder(.primary, lineWidth: selected ? 2 : 0))
        .onTapGesture { model.setLabel(label, for: targets) }
        .help(label.title)
    }

    private func tagsRow(_ photo: Photo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").foregroundStyle(.secondary).font(.callout)
            FlowTags(tags: model.tags(photo)) { tag in
                model.removeTag(tag, from: targets)
            }
            HStack {
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                Button("Add", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private var addToAlbumRow: some View {
        Menu {
            Button("New Album…") { model.startNewAlbum(with: targets) }
            if !model.albums.isEmpty { Divider() }
            ForEach(model.albums) { album in
                Button(album.name) { model.addToAlbum(album.id, photos: targets) }
            }
        } label: {
            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
        }
        .controlSize(.small)
    }

    private func addTag() {
        model.addTag(newTag, to: targets)
        newTag = ""
    }
}

/// A simple wrapping tag layout with removable chips.
private struct FlowTags: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        if tags.isEmpty {
            Text("No tags").font(.caption).foregroundStyle(.tertiary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag).font(.caption)
                        Button { onRemove(tag) } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
                }
            }
        }
    }
}

/// Minimal flow layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
