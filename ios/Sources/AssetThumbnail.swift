import SwiftUI
import Photos

/// Async square grid thumbnail for a PhotoKit asset, with the native multi-select
/// treatment (Photos-style accent checkmark + dim).
struct AssetThumbnail: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let selected: Bool
    let selecting: Bool

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .overlay {
                if selecting && !selected { Color.black.opacity(0.35) }
            }
            .overlay(alignment: .bottomTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.9)),
                                         selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
                        .padding(5).shadow(radius: 1)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                if image == nil { image = await library.thumbnail(asset, points: 110) }
            }
    }
}
