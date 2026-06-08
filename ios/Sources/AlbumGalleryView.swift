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

    var body: some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            if !ready {
                ProgressView().tint(.white)
            } else if assets.isEmpty {
                Text("사진이 없어요").font(.subheadline).foregroundStyle(.white.opacity(0.5))
            } else {
                PhotoGridView(assets: assets,
                              onTap: { open = StartAt(index: $0) },
                              onBack: { dismiss() })
                    .ignoresSafeArea(edges: .bottom)
            }
            header
        }
        .preferredColorScheme(.dark)
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
