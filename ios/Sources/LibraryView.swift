import SwiftUI
import Photos

/// Home: pick what to organize (전체 / 즐겨찾기 / 최근 / 스크린샷 / each album),
/// then swipe just that bundle. Slate dark theme to match the organize screen.
struct LibraryView: View {
    @State private var lib = PhotoLibrary()
    @State private var scope: OrganizeScope?
    @Environment(\.horizontalSizeClass) private var hSize

    // 2 columns on iPhone, ~4-5 on iPad.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: hSize == .regular ? 250 : 165), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lumenBG.ignoresSafeArea()
                if !lib.loaded {
                    TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                        let n = Int(ctx.date.timeIntervalSince1970 / 0.4) % 4
                        HStack(spacing: 0) {
                            Text("사진을 불러오고 있어요")
                            Text(String(repeating: ".", count: n)).frame(width: 16, alignment: .leading)
                        }
                        .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                    }
                } else if !lib.authorized {
                    OnboardingView { Task { await lib.load() } }
                } else if lib.scopes.isEmpty {
                    emptyState
                } else {
                    scopeList
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Push the gallery so back is a natural horizontal slide (not a drop-down).
            .navigationDestination(item: $scope) { s in
                AlbumGalleryView(scope: s, library: lib)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.lumenAccent)
        .task {
            if !lib.loaded { await lib.load() }
            // Screenshot helper: `-autoOrganize` opens the first album straight away.
            if scope == nil, ProcessInfo.processInfo.arguments.contains("-autoOrganize") {
                scope = lib.scopes.first
            }
        }
    }

    /// Branded empty state — distinguishes "no photos yet" from "all organized".
    private var emptyState: some View {
        VStack(spacing: 16) {
            LumenGlyph(size: 72)
            Text(!lib.hasAnyPhotos ? "사진이 없어요" : "모두 정리했어요")
                .font(.title2.bold()).foregroundStyle(.white)
            Text(!lib.hasAnyPhotos
                 ? "기기에 사진이 추가되면 여기에서 정리할 수 있어요."
                 : "정리할 사진을 모두 둘러봤어요. 보관한 사진은 ‘Lumen’ 앨범에 모여 있어요.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center).padding(.horizontal, 44)
        }
        .padding(.bottom, 40)
    }

    private var scopeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Lumen").font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white).padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 4)
                HStack {
                    Text("정리할 앨범").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Menu {
                        ForEach(AlbumSort.allCases, id: \.self) { s in
                            Button { lib.albumSort = s } label: {
                                if lib.albumSort == s { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(lib.albumSort.label)
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, 4)
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(lib.scopes) { s in
                        ScopeCard(scope: s, library: lib)
                            .onTapGesture { scope = s }
                    }
                }
                Text("앨범을 골라 좌우로 넘기며 둘러보세요. 위로 올리면 즐겨찾기, ♥는 ‘Lumen’ 앨범에 보관, ✕는 삭제 후보입니다.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 4).padding(.top, 6)
            }
            .padding(.horizontal, 16).padding(.top, 4)
        }
    }
}

/// Poster-style album card — a big cover with title/count below. Used in the
/// grid on both iPhone (2 columns) and iPad (more columns).
struct ScopeCard: View {
    let scope: OrganizeScope
    let library: PhotoLibrary
    @State private var cover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed 16:10 cover → every cell is the same height, so rows always align.
            Color.clear
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    ZStack {
                        Color.white.opacity(0.06)
                        if let cover {
                            Image(uiImage: cover).resizable().scaledToFill()
                        } else {
                            Image(systemName: scope.symbol).font(.system(size: 30)).foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }
                .clipped()

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(scope.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(scope.count)장").font(.caption).foregroundStyle(.white.opacity(0.5)).layoutPriority(1)
            }
            .padding(.horizontal, 12).frame(height: 46)
            .frame(maxWidth: .infinity)
        }
        .background(Color.lumenCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)) }
        .contentShape(Rectangle())
        .task(id: scope.cover?.localIdentifier) {
            if let a = scope.cover {
                for await img in library.imageStream(a, points: 300, mode: .aspectFill) { cover = img }
            }
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
                feature("hand.draw.fill", "넘기며 둘러보기", "좌우로 넘기고, 위로 올리면 즐겨찾기")
                feature("rectangle.stack.fill", "보관은 Lumen 앨범에", "♥로 고른 사진을 한 곳에 모아 나중에 분류")
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
