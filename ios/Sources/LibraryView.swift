import SwiftUI
import Photos

/// Home: the photo library as a native, Photos-style grid with a large title and
/// a prominent entry into organize mode.
struct LibraryView: View {
    @State private var lib = PhotoLibrary()
    @State private var organizing = false

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Lumen")
                .toolbar {
                    if !lib.assets.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text("\(lib.assets.count)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { startBar }
        }
        .task { if !lib.loaded { await lib.load() } }
        .fullScreenCover(isPresented: $organizing) {
            OrganizeView(assets: lib.assets, library: lib)
        }
    }

    @ViewBuilder private var content: some View {
        if !lib.loaded {
            ProgressView()
        } else if !lib.authorized {
            ContentUnavailableView {
                Label("사진 접근 권한 필요", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("설정에서 Lumen에 ‘모든 사진’ 접근을 허용하세요.")
            } actions: {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(.borderedProminent)
            }
        } else if lib.assets.isEmpty {
            ContentUnavailableView("사진 없음", systemImage: "photo", description: Text("이 기기에 사진이 없습니다."))
        } else {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(lib.assets, id: \.localIdentifier) { asset in
                        AssetThumbnail(asset: asset, library: lib, selected: false, selecting: false)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    @ViewBuilder private var startBar: some View {
        if lib.authorized && !lib.assets.isEmpty {
            Button {
                organizing = true
            } label: {
                Label("정리 시작", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}
