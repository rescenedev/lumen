import SwiftUI
import Photos

/// Photos-app-style thumbnail grid for an album. Tap a photo to open the
/// full-screen viewer (and organize from there).
struct AlbumGalleryView: View {
    let scope: OrganizeScope
    let library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [PHAsset] = []
    @State private var ready = false
    @State private var open: StartAt?
    @State private var cols = 4                       // pinch to change

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 3), count: cols) }

    var body: some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            if !ready {
                ProgressView().tint(.white)
            } else if assets.isEmpty {
                Text("사진이 없어요").font(.subheadline).foregroundStyle(.white.opacity(0.5))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { i, asset in
                            GalleryThumb(asset: asset, library: library)
                                .onTapGesture { open = StartAt(index: i) }
                        }
                    }
                    .padding(.horizontal, 3).padding(.top, 54).padding(.bottom, 24)
                }
                .gesture(
                    MagnifyGesture().onEnded { v in
                        withAnimation(.spring(response: 0.3)) {
                            if v.magnification > 1.15 { cols = max(2, cols - 1) }       // zoom in → bigger thumbs
                            else if v.magnification < 0.85 { cols = min(8, cols + 1) }  // pinch → smaller thumbs
                        }
                    }
                )
            }
            header
        }
        .preferredColorScheme(.dark)
        .task {
            assets = await library.assets(for: scope)
            ready = true
        }
        .fullScreenCover(item: $open) { start in
            OrganizeView(scope: scope, library: library, startIndex: start.index)
        }
    }

    private var header: some View {
        ZStack {
            Text(scope.title).font(.headline).foregroundStyle(.white)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline.bold()).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A starting index, wrapped so it can drive `.fullScreenCover(item:)`.
struct StartAt: Identifiable { let id = UUID(); let index: Int }

/// One square thumbnail; shows a small heart if the photo is an Apple favorite.
struct GalleryThumb: View {
    let asset: PHAsset
    let library: PhotoLibrary
    @State private var image: UIImage?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                for await img in library.imageStream(asset, points: 200, mode: .aspectFill) { image = img }
            }
    }
}
