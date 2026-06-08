import SwiftUI
import Photos

/// Home: pick what to organize (전체 / 즐겨찾기 / 최근 / 스크린샷 / each album),
/// then swipe just that bundle. Scoping keeps large libraries manageable.
struct LibraryView: View {
    @State private var lib = PhotoLibrary()
    @State private var scope: OrganizeScope?

    var body: some View {
        NavigationStack {
            Group {
                if !lib.loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !lib.authorized {
                    OnboardingView { Task { await lib.load() } }
                } else {
                    list
                }
            }
            .navigationTitle("Lumen")
        }
        .task { if !lib.loaded { await lib.load() } }
        .fullScreenCover(item: $scope, onDismiss: { lib.refresh() }) { s in
            OrganizeView(assets: lib.assets(for: s), library: lib)
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(lib.scopes) { s in
                    Button { scope = s } label: { ScopeRow(scope: s, library: lib) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("정리할 묶음")
            } footer: {
                Text("묶음을 골라 좌우로 넘기며 정리하세요. 위로 넘기면 ‘Lumen’ 앨범으로 모읍니다.")
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// One row in the scope picker: cover thumbnail · title · count.
struct ScopeRow: View {
    let scope: OrganizeScope
    let library: PhotoLibrary
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.tertiary)
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: scope.symbol).font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(scope.title).font(.headline)
                Text("\(scope.count)장").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
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
            Text("Lumen").font(.system(size: 38, weight: .heavy, design: .rounded)).padding(.top, 18)
            Text("사진 정리가 쉬워집니다").font(.headline).foregroundStyle(.secondary).padding(.top, 4)

            VStack(spacing: 18) {
                feature("hand.draw.fill", "좌우 스와이프로 정리", "한 장씩 넘기며 보관·삭제를 결정")
                feature("rectangle.stack.badge.plus", "위로 넘기면 Lumen 앨범", "나중에 천천히 분류")
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
