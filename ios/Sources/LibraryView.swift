import SwiftUI
import Photos

/// Home: pick what to organize (전체 / 즐겨찾기 / 최근 / 스크린샷 / each album),
/// then swipe just that bundle. Slate dark theme to match the organize screen.
struct LibraryView: View {
    @State private var lib = PhotoLibrary()
    @State private var scope: OrganizeScope?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lumenBG.ignoresSafeArea()
                if !lib.loaded {
                    ProgressView().tint(.white)
                } else if !lib.authorized {
                    OnboardingView { Task { await lib.load() } }
                } else if lib.scopes.isEmpty {
                    ContentUnavailableView("사진 없음", systemImage: "photo",
                                           description: Text("정리할 사진이 없습니다."))
                } else {
                    scopeList
                }
            }
            .navigationTitle("Lumen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(.lumenAccent)
        .task { if !lib.loaded { await lib.load() } }
        .fullScreenCover(item: $scope, onDismiss: { lib.refresh() }) { s in
            OrganizeView(assets: lib.assets(for: s), library: lib)
        }
    }

    private var scopeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("정리할 묶음").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 4).padding(.top, 4)
                ForEach(lib.scopes) { s in
                    ScopeRow(scope: s, library: lib)
                        .contentShape(Rectangle())
                        .onTapGesture { scope = s }
                }
                Text("묶음을 골라 좌우로 넘기며 정리하세요. 오른쪽(보관)은 ‘Lumen’ 앨범에 모이고, 왼쪽은 삭제 후보입니다.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 4).padding(.top, 6)
            }
            .padding(.horizontal, 16).padding(.top, 4)
        }
    }
}

/// One slate card in the scope picker: cover thumbnail · title · count.
struct ScopeRow: View {
    let scope: OrganizeScope
    let library: PhotoLibrary
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06))
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: scope.symbol).font(.title3).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(scope.title).font(.headline).foregroundStyle(.white)
                Text("\(scope.count)장").font(.subheadline).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.3))
        }
        .padding(14)
        .background(Color.lumenCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .task(id: scope.id) {
            if cover == nil, let a = scope.cover { cover = await library.thumbnail(a, points: 60) }
        }
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
            Text("Lumen").font(.system(size: 38, weight: .heavy, design: .rounded)).foregroundStyle(.white).padding(.top, 18)
            Text("사진 정리가 쉬워집니다").font(.headline).foregroundStyle(.white.opacity(0.6)).padding(.top, 4)

            VStack(spacing: 18) {
                feature("hand.draw.fill", "좌우 스와이프로 정리", "오른쪽은 보관, 왼쪽은 삭제")
                feature("rectangle.stack.fill", "보관은 Lumen 앨범에", "남긴 사진을 한 곳에 모아 나중에 분류")
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
            .font(.footnote).foregroundStyle(.white.opacity(0.5)).padding(.bottom, 24)
        }
    }

    private func feature(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
    }
}
