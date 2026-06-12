import SwiftUI
import Photos

/// Home: pick what to organize (전체 / 즐겨찾기 / 최근 / 스크린샷 / each album),
/// then swipe just that bundle. Slate dark theme to match the organize screen.
struct LibraryView: View {
    let library: PhotoLibrary
    var scrollTopKey: Int = 0   // tab re-tap: pop the open album, else scroll to top
    @State private var scope: OrganizeScope?
    @State private var showSort = false
    @State private var showSettings = false
    @State private var pull: CGFloat = 0      // current over-pull past the list top
    @State private var pullArmed = true       // one settings open per pull
    @Environment(\.horizontalSizeClass) private var hSize

    // 2 columns on iPhone, ~4-5 on iPad.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: hSize == .regular ? 250 : 165), spacing: 12)]
    }

    var body: some View {
        ScrollViewReader { proxy in
        ZStack {
            ZStack {
                Color.lumenBG.ignoresSafeArea()
                if !library.loaded {
                    TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                        let n = Int(ctx.date.timeIntervalSince1970 / 0.4) % 4
                        HStack(spacing: 0) {
                            Text("사진을 불러오고 있어요")
                            Text(String(repeating: ".", count: n)).frame(width: 16, alignment: .leading)
                        }
                        .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                    }
                } else if !library.authorized {
                    OnboardingView { Task { await library.load() } }
                } else if library.scopes.isEmpty {
                    emptyState
                } else {
                    scopeList
                }
            }
            // Pinned tab title (shared style) — sits above the list, which
            // scrolls underneath its scrim. Hidden during onboarding.
            .overlay(alignment: .top) {
                if library.authorized { TabTitleBar(title: String(localized: "앨범")) }
            }
            // Parallax: the home slides left a touch while the gallery comes in, so
            // both move together (like a nav push) instead of the gallery sliding
            // over a static background.
            .offset(x: scope != nil ? -UIScreen.main.bounds.width * 0.22 : 0)
            .overlay(Color.black.opacity(scope != nil ? 0.25 : 0).ignoresSafeArea())

            // Gallery as a fast right-slide overlay (quicker than a nav push) — back
            // slides out the same way.
            if let s = scope {
                AlbumGalleryView(scope: s, library: library,
                                 onClose: { withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { scope = nil } })
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.lumenAccent)
        .sheet(isPresented: $showSort) {
            SortSheet(current: library.albumSort) { library.albumSort = $0 }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .onChange(of: library.loaded) { _, loaded in
            guard loaded, scope == nil else { return }
            if ProcessInfo.processInfo.arguments.contains("-autoOrganize"), let s = library.scopes.first {
                library.prewarmScope(s)
                scope = s
            }
        }
        // Tab re-tap: an open album pops back to the list; the list scrolls to top.
        .onChange(of: scrollTopKey) {
            if scope != nil {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { scope = nil }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("home-top", anchor: .top) }
            }
        }
        }
    }

    /// Branded empty state — distinguishes "no photos yet" from "all organized".
    private var emptyState: some View {
        VStack(spacing: 16) {
            LumenGlyph(size: 72)
            Text(!library.hasAnyPhotos ? String(localized: "사진이 없어요") : String(localized: "모두 정리했어요"))
                .font(.title2.bold()).foregroundStyle(.white)
            Text(!library.hasAnyPhotos
                 ? String(localized: "기기에 사진이 추가되면 여기에서 정리할 수 있어요.")
                 : String(localized: "정리할 사진을 모두 둘러봤어요. 보관한 사진은 ‘Lumen’ 앨범에 모여 있어요."))
                .font(.subheadline).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center).padding(.horizontal, 44)
        }
        .padding(.bottom, 40)
    }

    /// How far past the top you pull before settings open — deliberately long
    /// (~2x a refresh pull) so casual bounces never trigger it.
    private static let settingsPullThreshold: CGFloat = 160

    private var scopeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("정리할 앨범").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button { showSort = true } label: {
                        HStack(spacing: 5) {
                            Text(library.albumSort.label)
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
                .id("home-top")
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(library.scopes) { s in
                        ScopeCard(scope: s, library: library)
                            .onTapGesture {
                                // Tap does ZERO PhotoKit work: the slide starts now, the
                                // grid resolves its fetch lazily on first cell draw, and
                                // prewarm warms the cache off-main.
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { scope = s }
                                library.prewarmScope(s)
                            }
                    }
                }
                Text("앨범을 골라 좌우로 넘기며 둘러보세요. 위로 올리면 삭제 후보, 보관함 버튼은 ‘Lumen’ 앨범으로, ★는 즐겨찾기입니다.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 4).padding(.top, 6)
            }
            .padding(.horizontal, 16).padding(.top, 4)
        }
        // Content starts below the pinned title but still scrolls under it.
        .contentMargins(.top, 52, for: .scrollContent)
        // Short album lists fit the screen and would never rubber-band — force
        // bouncing so the pull-down gesture works regardless of content height.
        .scrollBounceBehavior(.always, axes: .vertical)
        // NOTE: the classic GeometryReader+preference offset trick does NOT update
        // during interactive scrolling on the iOS 18+/26 scroll engine — overscroll
        // must be read via onScrollGeometryChange.
        .modifier(PullToReveal(pull: $pull) { handlePull($0) })
        // Hidden settings: pull the list down past the threshold and the sheet
        // opens (with a haptic). A gear rides in with the pull so the gesture
        // is discoverable without spending a visible button on it.
        .overlay(alignment: .top) {
            let p = min(pull / Self.settingsPullThreshold, 1)
            if p > 0.02 {
                Image(systemName: "gearshape.fill")
                    .font(.title3).foregroundStyle(.white.opacity(0.85))
                    .rotationEffect(.degrees(Double(pull) * 1.5))
                    .opacity(Double(p)).scaleEffect(0.5 + 0.5 * p)
                    .offset(y: 38 + pull * 0.45)   // rides in below the pinned title
            }
        }
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: showSettings) { _, new in new }
    }

    private func handlePull(_ y: CGFloat) {
        if y > Self.settingsPullThreshold, pullArmed, !showSettings {
            pullArmed = false
            showSettings = true
        } else if y < 5 {
            pullArmed = true     // re-arm once the bounce settles
        }
    }
}

/// Streams how far a scroll view is over-pulled past its top (0 when not).
/// iOS 18+ only — on 17 the gesture is simply unavailable.
private struct PullToReveal: ViewModifier {
    @Binding var pull: CGFloat
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                max(0, -(geo.contentOffset.y + geo.contentInsets.top))
            } action: { _, overpull in
                pull = overpull
                onChange(overpull)
            }
        } else {
            content
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
                for await img in library.imageStream(a, points: PhotoLibrary.coverPoints, mode: .aspectFill) { cover = img }
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
                feature("hand.draw.fill", "넘기며 둘러보기", "좌우로 넘기고, 위로 올리면 삭제 후보")
                feature("tray.full.fill", "보관은 Lumen 앨범에", "보관함에 담은 사진을 한 곳에 모아 나중에 분류")
                feature("checkmark.shield.fill", "안전하게", "삭제는 항상 확인 후 진행")
            }
            .padding(.top, 36).padding(.horizontal, 30)

            Spacer()
            Button {
                requesting = true
                Task { onAuthorized(); requesting = false }
            } label: {
                Text("사진 접근 허용").font(.headline)
                    .opacity(requesting ? 0 : 1)
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

    // LocalizedStringKey params so the literal call-site strings localize.
    private func feature(_ icon: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
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

struct OrganizePickerView: View {
    let library: PhotoLibrary
    var scrollTopKey: Int = 0   // tab re-tap: pop the open album, else scroll to top
    @State private var scope: OrganizeScope?
    @State private var resume: ResumeTarget?
    @AppStorage("lumen.lastOrganizedScopeId") private var lastScopeId = "all"

    /// The album + position the user last organized, if it's still meaningful.
    private var resumeTarget: ResumeTarget? {
        guard let s = library.scopes.first(where: { $0.id == lastScopeId }) else { return nil }
        let i = UserDefaults.standard.integer(forKey: "lumen.resume.\(s.id)")
        guard i > 0, i < s.count - 1 else { return nil }
        return ResumeTarget(scope: s, index: i)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ZStack {
            ZStack {
                Color.lumenBG.ignoresSafeArea()
                if !library.loaded {
                    ProgressView().tint(.white.opacity(0.4))
                } else if library.scopes.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(.white.opacity(0.22))
                        Text("정리할 사진이 없어요")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                    }
                } else {
                    pickerList
                }
            }
            // Pinned tab title — same style as every other tab.
            .overlay(alignment: .top) { TabTitleBar(title: String(localized: "정리")) }
            .offset(x: scope != nil ? -UIScreen.main.bounds.width * 0.22 : 0)
            .overlay(Color.black.opacity(scope != nil ? 0.25 : 0).ignoresSafeArea())

            // Album opens as a browsing grid first — tap a photo to view it, then
            // "정리 시작" begins organizing from that photo (not from the start).
            if let s = scope {
                AlbumGalleryView(scope: s, library: library,
                                 onClose: { withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { scope = nil } })
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.lumenAccent)
        .fullScreenCover(item: $resume) { r in
            // Straight into the viewer at the saved spot — 정리 시작 is one tap away.
            OrganizeView(scope: r.scope, library: library, startIndex: r.index)
        }
        // Tab re-tap: an open album pops back to the picker; the picker scrolls to top.
        .onChange(of: scrollTopKey) {
            if scope != nil {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { scope = nil }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("organize-top", anchor: .top) }
            }
        }
        }
    }

    private var pickerList: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 안내 한 줄 — 타이틀은 핀(TabTitleBar)으로 올라갔다.
                Text("앨범을 골라보세요 · 위로 올리면 삭제 · 정리가 끝나면 한번에 삭제")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                    .id("organize-top")

                // 이어서 정리 — 마지막으로 보던 앨범·위치로 바로 점프.
                if let r = resumeTarget {
                    Button { resume = r } label: { ResumeCard(target: r, library: library) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }

                // 리스트
                VStack(spacing: 0) {
                    ForEach(Array(library.scopes.enumerated()), id: \.element.id) { i, s in
                        ScopeRow(scope: s, library: library)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { scope = s }
                                library.prewarmScope(s)
                            }
                        if i < library.scopes.count - 1 {
                            Divider().overlay(.white.opacity(0.07))
                        }
                    }
                }
                .background(Color.lumenCard)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06)))
                .padding(.horizontal, 16)
            }
        }
        .contentMargins(.top, 52, for: .scrollContent)   // start below the pinned title
    }
}

/// Where the user left off — drives the 정리 탭's "이어서 정리" card.
struct ResumeTarget: Identifiable {
    var id: String { scope.id }
    let scope: OrganizeScope
    let index: Int
}

/// The 정리 탭's hero card: jump back to where organizing left off.
private struct ResumeCard: View {
    let target: ResumeTarget
    let library: PhotoLibrary
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Color.white.opacity(0.06)
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("이어서 정리").font(.body.weight(.semibold)).foregroundStyle(.white)
                Text("\(target.scope.title) · \(target.index + 1)번째 사진부터")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Image(systemName: "arrow.forward.circle.fill")
                .font(.title3).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.lumenCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .contentShape(Rectangle())
        .task(id: target.scope.cover?.localIdentifier) {
            if let a = target.scope.cover {
                for await img in library.imageStream(a, points: 52, mode: .aspectFill) { cover = img }
            }
        }
    }
}

private struct ScopeRow: View {
    let scope: OrganizeScope
    let library: PhotoLibrary
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            // 썸네일
            ZStack {
                Color.white.opacity(0.06)
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: scope.symbol)
                        .font(.system(size: 16)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(scope.title)
                    .font(.body.weight(.semibold)).foregroundStyle(.white)
                Text("\(scope.count)장")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.25))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .task(id: scope.cover?.localIdentifier) {
            if let a = scope.cover {
                for await img in library.imageStream(a, points: 52, mode: .aspectFill) { cover = img }
            }
        }
    }
}
