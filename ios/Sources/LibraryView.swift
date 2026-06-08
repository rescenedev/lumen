import SwiftUI
import Photos

/// Home: a polished dashboard — branded onboarding before access, then a hero
/// "정리 시작" card over a Photos-style grid.
struct LibraryView: View {
    @State private var lib = PhotoLibrary()
    @State private var organizing = false

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        NavigationStack {
            Group {
                if !lib.loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !lib.authorized {
                    OnboardingView { Task { await lib.load() } }
                } else {
                    libraryContent
                }
            }
            .navigationTitle("Lumen")
            .navigationBarTitleDisplayMode(lib.authorized ? .large : .inline)
        }
        .task { if !lib.loaded { await lib.load() } }
        .fullScreenCover(isPresented: $organizing) {
            OrganizeView(assets: lib.assets, library: lib)
        }
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                heroCard
                if lib.assets.isEmpty {
                    ContentUnavailableView("사진 없음", systemImage: "photo")
                        .frame(height: 240)
                } else {
                    sectionHeader
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(lib.assets, id: \.localIdentifier) { asset in
                            AssetThumbnail(asset: asset, library: lib, selected: false, selecting: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)
        }
    }

    private var heroCard: some View {
        Button { organizing = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "sparkles").font(.title3)
                    Spacer()
                    Text("\(lib.assets.count)장").font(.subheadline.weight(.medium)).opacity(0.9)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("사진 정리 시작").font(.title2.bold())
                    Text("좌우로 넘기며 보관·삭제를 빠르게 결정하세요")
                        .font(.subheadline).opacity(0.92).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text("시작하기").font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right").font(.footnote.weight(.bold))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.white.opacity(0.22), in: Capsule())
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .foregroundStyle(.white)
            .shadow(color: .lumenAccent.opacity(0.35), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .disabled(lib.assets.isEmpty)
        .opacity(lib.assets.isEmpty ? 0.6 : 1)
    }

    private var sectionHeader: some View {
        HStack {
            Text("전체 사진").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 4)
    }
}

/// Branded pre-access onboarding — sets the app's identity and asks for Photos.
struct OnboardingView: View {
    let onAuthorized: () -> Void
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            LumenGlyph(size: 84)
            Text("Lumen").font(.system(size: 38, weight: .heavy, design: .rounded)).padding(.top, 18)
            Text("사진 정리가 쉬워집니다").font(.headline).foregroundStyle(.secondary).padding(.top, 4)

            VStack(spacing: 18) {
                feature("hand.draw.fill", "좌우 스와이프로 정리", "한 장씩 넘기며 보관·삭제를 결정")
                feature("heart.fill", "보관은 즐겨찾기로", "남길 사진은 한 번에 즐겨찾기")
                feature("checkmark.shield.fill", "안전하게", "삭제는 항상 확인 후 진행")
            }
            .padding(.top, 36).padding(.horizontal, 30)

            Spacer()
            Button {
                requesting = true
                Task { onAuthorized(); requesting = false }
            } label: {
                Text(requesting ? "" : "사진 접근 허용").font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .overlay { if requesting { ProgressView().tint(.white) } }
            }
            .background(heroGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.bottom, 18)

            Button("설정에서 변경") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 24)
        }
    }

    private func feature(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
