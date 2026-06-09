import SwiftUI
import Photos

/// Home: pick what to organize (전체 / 즐겨찾기 / 최근 / 스크린샷 / each album),
/// then swipe just that bundle. Slate dark theme to match the organize screen.
struct LibraryView: View {
    @State private var lib = PhotoLibrary()
    @State private var scope: OrganizeScope?
    @State private var showSort = false
    @Environment(\.horizontalSizeClass) private var hSize

    // 2 columns on iPhone, ~4-5 on iPad.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: hSize == .regular ? 250 : 165), spacing: 12)]
    }

    var body: some View {
        ZStack {
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
            // Parallax: the home slides left a touch while the gallery comes in, so
            // both move together (like a nav push) instead of the gallery sliding
            // over a static background.
            .offset(x: scope != nil ? -UIScreen.main.bounds.width * 0.22 : 0)
            .overlay(Color.black.opacity(scope != nil ? 0.25 : 0).ignoresSafeArea())

            // Gallery as a fast right-slide overlay (quicker than a nav push) — back
            // slides out the same way.
            if let s = scope {
                AlbumGalleryView(scope: s, library: lib,
                                 onClose: { withAnimation(.easeOut(duration: 0.4)) { scope = nil } })
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.lumenAccent)
        .sheet(isPresented: $showSort) {
            SortSheet(current: lib.albumSort) { lib.albumSort = $0 }
        }
        .task {
            if !lib.loaded { await lib.load() }
            // Screenshot helper: `-autoOrganize` opens the first album straight away
            // (via the same prewarm path a real tap takes).
            if scope == nil, ProcessInfo.processInfo.arguments.contains("-autoOrganize"),
               let s = lib.scopes.first {
                lib.prewarmScope(s)
                scope = s
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
                    Button { showSort = true } label: {
                        HStack(spacing: 5) {
                            Text(lib.albumSort.label)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(lib.scopes) { s in
                        ScopeCard(scope: s, library: lib)
                            .onTapGesture {
                                // Tap does ZERO PhotoKit work: the slide starts now, the
                                // grid resolves its fetch lazily on first cell draw, and
                                // prewarm warms the cache off-main.
                                withAnimation(.easeOut(duration: 0.4)) { scope = s }
                                lib.prewarmScope(s)
                            }
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

/// Modern bottom sheet for picking the album sort (always on-screen, slate).
struct SortSheet: View {
    let current: AlbumSort
    let onSelect: (AlbumSort) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("정렬 기준").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)
            ForEach(Array(AlbumSort.allCases.enumerated()), id: \.element) { i, s in
                Button { onSelect(s); dismiss() } label: {
                    HStack {
                        Text(s.label).font(.body.weight(.medium)).foregroundStyle(.white)
                        Spacer()
                        if current == s {
                            Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(Color.lumenAccent)
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < AlbumSort.allCases.count - 1 {
                    Divider().overlay(.white.opacity(0.07)).padding(.leading, 22)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(CGFloat(AlbumSort.allCases.count) * 56 + 64)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.lumenCard)
        .preferredColorScheme(.dark)
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
