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
    @State private var scale: CGFloat = 1             // continuous zoom during a pinch
    @State private var startCols: Int?                // columns when the pinch began

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
                    .scaleEffect(scale, anchor: .top)        // smooth, continuous during pinch
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            if startCols == nil { startCols = cols }
                            scale = min(max(v.magnification, 0.45), 2.4)
                        }
                        .onEnded { _ in
                            let start = startCols ?? cols
                            // pinch out → fewer/bigger columns, pinch in → more/smaller
                            let newCols = min(8, max(2, Int((CGFloat(start) / scale).rounded())))
                            startCols = nil
                            // Animate the column reflow and the scale-reset together so the
                            // thumbnails slide to their new spots instead of popping.
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                                cols = newCols
                                scale = 1
                            }
                        }
                )
            }
            header
        }
        .preferredColorScheme(.dark)
        .simultaneousGesture(
            // Swipe in from the left edge → back to the album list.
            DragGesture(minimumDistance: 20)
                .onEnded { v in
                    if v.startLocation.x < 36, v.translation.width > 90, abs(v.translation.height) < 70 {
                        dismiss()
                    }
                }
        )
        .task {
            assets = await library.assets(for: scope)
            ready = true
        }
        .fullScreenCover(item: $open, onDismiss: {
            // Refresh after the viewer — e.g. un-favorited photos leave the 즐겨찾기 grid.
            Task { assets = await library.assets(for: scope) }
        }) { start in
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
