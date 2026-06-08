import SwiftUI
import Photos

/// The home screen: the device photo library as a grid, with a prominent entry
/// into the Tinder-style organize mode.
struct LibraryView: View {
    @State private var lib = PhotoLibrary()
    @State private var organizing = false

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ZStack {
            LumenBackground()
            if lib.loaded && !lib.authorized {
                permissionView
            } else {
                VStack(spacing: 0) {
                    header
                    grid
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { if !lib.loaded { await lib.load() } }
        .fullScreenCover(isPresented: $organizing) {
            OrganizeView(assets: lib.assets, library: lib)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lumen").font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(brandGradient)
                Spacer()
                if !lib.assets.isEmpty {
                    Text("\(lib.assets.count)장").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }
            }
            Button { organizing = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("정리 시작").font(.headline)
                        Text("좌우로 넘기며 보관 / 삭제 결정").font(.caption2).opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "arrow.right").font(.headline)
                }
                .padding(16).foregroundStyle(.white)
                .background(brandGradient, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color(red: 0.6, green: 0.36, blue: 1).opacity(0.35), radius: 16, y: 6)
            }
            .disabled(lib.assets.isEmpty)
            .opacity(lib.assets.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 14)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 3) {
                ForEach(lib.assets, id: \.localIdentifier) { asset in
                    AssetThumbnail(asset: asset, library: lib, selected: false, selecting: false)
                }
            }
            .padding(.horizontal, 3)
        }
        .overlay {
            if lib.loaded && lib.assets.isEmpty && lib.authorized {
                Text("사진이 없습니다").foregroundStyle(.white.opacity(0.4))
            } else if !lib.loaded {
                ProgressView().tint(.white)
            }
        }
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(brandGradient)
            Text("사진 접근 권한이 필요해요").font(.headline).foregroundStyle(.white)
            Text("설정 ▸ Lumen ▸ 사진에서 ‘모든 사진’을 허용하세요")
                .font(.subheadline).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .padding(.horizontal, 22).padding(.vertical, 11)
            .background(brandGradient, in: Capsule()).foregroundStyle(.white)
        }
        .padding(40)
    }
}
