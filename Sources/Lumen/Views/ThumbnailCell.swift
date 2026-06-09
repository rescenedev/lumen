import SwiftUI

/// One cell in the photo grid: a square thumbnail with a favorite badge,
/// selection ring, rating, and color label. Value-based + `Equatable` so that
/// a selection or favorite change only re-renders the cells that changed.
struct ThumbnailCell: View, Equatable {
    let photo: Photo
    let isSelected: Bool
    let isFavorite: Bool
    let rating: Int
    let label: ColorLabel
    let size: Double

    static func == (lhs: ThumbnailCell, rhs: ThumbnailCell) -> Bool {
        lhs.photo == rhs.photo
        && lhs.isSelected == rhs.isSelected
        && lhs.isFavorite == rhs.isFavorite
        && lhs.rating == rhs.rating
        && lhs.label == rhs.label
        && lhs.size == rhs.size
    }

    var body: some View {
        VStack(spacing: 5) {
            thumbnail
            HStack(spacing: 4) {
                if let color = label.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(photo.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            if rating > 0 {
                HStack(spacing: 1) {
                    ForEach(0..<rating, id: \.self) { _ in
                        Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(.yellow)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        AsyncThumbnail(url: photo.url, mtime: photo.cacheMtime,
                       maxPixel: ThumbnailCache.tier(forPointSize: size))
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.08),
                                  lineWidth: isSelected ? 3 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.pink, in: Circle())
                        .padding(6)
                        .shadow(radius: 2)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: isSelected ? 6 : 3, y: 2)
    }
}
