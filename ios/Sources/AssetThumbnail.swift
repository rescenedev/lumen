import SwiftUI
import Photos

/// Async grid thumbnail for a PhotoKit asset, with the multi-select treatment
/// (accent ring + checkmark, dim the rest) — mirrors the macOS grid cell.
struct AssetThumbnail: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let selected: Bool
    let selecting: Bool

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.04)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                if selecting && !selected { Color.black.opacity(0.45) }
                if selected {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(brandGradient, lineWidth: 3)
                    VStack { HStack { Spacer()
                        Image(systemName: "checkmark.circle.fill").font(.title3)
                            .foregroundStyle(.white, Color(red: 0.36, green: 0.53, blue: 1))
                            .padding(5)
                    }; Spacer() }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: asset.localIdentifier) {
            image = await library.thumbnail(asset, points: 130)
        }
    }
}
