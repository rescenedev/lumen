import SwiftUI
import Photos

private enum Decision { case keep, trash }

/// What the brief centered confirmation shows after an action.
private enum Flash {
    case keep, trash, favorite, unfavorite
    var text: String {
        switch self { case .keep: "보관"; case .trash: "삭제"; case .favorite: "즐겨찾기"; case .unfavorite: "즐겨찾기 해제" }
    }
    var icon: String {
        switch self { case .keep: "rectangle.stack.fill"; case .trash: "trash.fill"; case .favorite: "star.fill"; case .unfavorite: "star.slash.fill" }
    }
}

/// Viewer + organize. You enter as a viewer: swipe LEFT/RIGHT to browse (straight
/// line), swipe UP to favorite. Tapping "정리 시작" begins organizing from the photo
/// you're on (no need to restart from the first) — ✕/♥ appear: ♥ files into "Lumen"
/// (live), ✕ marks for deletion, applied/confirmed on the summary.
struct OrganizeView: View {
    let scope: OrganizeScope
    let library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var source: GridSource                  // photos for this scope (ready at init)
    @State private var organizing = false                 // viewer first, then organize
    @State private var index: Int

    init(scope: OrganizeScope, library: PhotoLibrary, startIndex: Int = 0) {
        self.scope = scope
        self.library = library
        let s = library.gridSource(for: scope)
        _source = State(initialValue: s)
        _index = State(initialValue: min(max(startIndex, 0), max(s.count - 1, 0)))
    }
    @State private var offset: CGSize = .zero
    @State private var decisions: [Int: Decision] = [:]   // index → keep/trash
    @State private var finished = false
    @State private var flash: Flash?                      // brief action confirmation
    @State private var currentIsFav = false               // live favorite state of the shown photo
    @State private var favOverrides: [String: Bool] = [:] // session favorite toggles (avoids per-swipe refetch)
    @State private var tick = 0
    @State private var doneMsg = ""

    // Pinch zoom (current photo only): drag pans while zoomed, double-tap toggles.
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var isPinching = false

    // In-flight page transition (so rapid taps complete it early instead of being dropped).
    @State private var advanceTask: Task<Void, Never>?
    @State private var pendingTarget: Int?

    private let threshold: CGFloat = 80
    private var isZoomed: Bool { zoom > 1.01 }

    private var count: Int { source.count }
    private var keepCount: Int { decisions.values.filter { $0 == .keep }.count }
    private var trashAssets: [PHAsset] { decisions.compactMap { $0.value == .trash ? source.asset($0.key) : nil } }

    var body: some View {
        ZStack {
            Color.lumenBG.ignoresSafeArea()
            if finished {
                summary
            } else {
                photoLayer(source)
                flashOverlay
                topBar
                if organizing { bottomControls } else { startBar }
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: tick)
    }

    // MARK: - Photo (full-screen, swipe = navigate)

    /// Page width: one screen plus a small gap between photos.
    private var pageW: CGFloat { UIScreen.main.bounds.width + 24 }
    private var visibleIndices: [Int] { [index - 1, index, index + 1].filter { $0 >= 0 && $0 < count } }

    private func photoLayer(_ source: GridSource) -> some View {
        ZStack {
            // The current photo AND both neighbors, paged side by side like the
            // Photos app — a horizontal drag pulls the next photo in WITH your
            // finger instead of flying the current out and popping the next in.
            // ForEach identity is the photo index, so when `index` advances the
            // neighbor that's already centered becomes the current view with no
            // re-creation — the handoff is seamless (no flash, no pop).
            ForEach(visibleIndices, id: \.self) { i in
                OrganizeCard(asset: source.asset(i), library: library)
                    .overlay(alignment: .top) { if i == index { trashHint } }
                    .scaleEffect(cardScale(i))
                    .offset(x: CGFloat(i - index) * pageW + offset.width + (i == index ? pan.width : 0),
                            y: i == index ? offset.height + pan.height : 0)
                    .zIndex(i == index ? 1 : 0)
            }
            // Tap the left/right edge to step photos (no swipe needed); center
            // double-tap toggles zoom. Edge steps only apply unzoomed — while
            // zoomed, drags pan and double-tap (anywhere) zooms back out.
            // Edge zones are single-tap ONLY — pairing them with a double-tap
            // recognizer makes every tap wait ~0.3s for the double to fail, which
            // reads as lag. Zoom toggling lives on the (wide) center zone instead.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .frame(width: 64)
                    .onTapGesture { if !isZoomed { swipeTo(next: false) } }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { toggleZoom() }
                Color.clear.contentShape(Rectangle())
                    .frame(width: 64)
                    .onTapGesture { if !isZoomed { swipeTo(next: true) } }
            }
            .ignoresSafeArea()
            .zIndex(2)
        }
            .task(id: index) {
                guard index < source.count else { return }
                zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero   // new photo starts unzoomed
                // Favorite state: session toggles are tracked locally — no per-swipe
                // PhotoKit fetch on the main thread.
                let a = source.asset(index)
                currentIsFav = favOverrides[a.localIdentifier] ?? a.isFavorite
                // Warm the photos around this one at full-screen size, so the next
                // swipe shows an already-decoded/downloaded image instead of a spinner.
                let neighbors = [index + 1, index + 2, index - 1]
                    .filter { $0 >= 0 && $0 < source.count }
                    .map { source.asset($0) }
                library.prewarmViewer(neighbors)
            }
            .gesture(dragGesture)
            .simultaneousGesture(pinchGesture)
            .ignoresSafeArea()
    }

    /// Current card: pinch zoom × pull-down shrink. Neighbors: 1.
    private func cardScale(_ i: Int) -> CGFloat {
        guard i == index else { return 1 }
        let pull = offset.height > 0 ? max(0.86, 1 - offset.height / 1100) : 1
        return zoom * pull
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                isPinching = true
                zoom = min(max(zoomBase * v, 0.7), 5)   // rubber-band below 1, cap at 5 mid-pinch
            }
            .onEnded { _ in
                isPinching = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    zoom = min(max(zoom, 1), 4)
                    if zoom <= 1.01 { zoom = 1; pan = .zero }
                }
                zoomBase = zoom
                panBase = pan
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                guard !isPinching else { return }     // two-finger pinch also moves the centroid — ignore it
                if isZoomed {
                    // Zoomed: drag pans the photo instead of navigating.
                    pan = CGSize(width: panBase.width + v.translation.width,
                                 height: panBase.height + v.translation.height)
                    return
                }
                let dx = v.translation.width, dy = v.translation.height
                // Vertical (up = favorite, down = dismiss) vs horizontal (navigate).
                if abs(dy) > abs(dx) {
                    offset = CGSize(width: 0, height: dy)
                } else {
                    offset = CGSize(width: dx, height: 0)
                }
            }
            .onEnded { v in
                guard !isPinching else { return }
                if isZoomed {
                    // Keep the photo's visible area on screen (clamp, with a spring).
                    let b = UIScreen.main.bounds.size
                    let maxX = (zoom - 1) * b.width / 2, maxY = (zoom - 1) * b.height / 2
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        pan = CGSize(width: min(max(pan.width, -maxX), maxX),
                                     height: min(max(pan.height, -maxY), maxY))
                    }
                    panBase = pan
                    return
                }
                let dx = v.translation.width, dy = v.translation.height
                if abs(dy) > abs(dx) {
                    if dy < -threshold { trashFromSwipe() }
                    else if dy > 110 { dismiss() }                 // pull down → back, like Photos
                    else { withAnimation(.spring(response: 0.3)) { offset = .zero } }
                } else if dx < -threshold { swipeTo(next: true) }
                else if dx > threshold { swipeTo(next: false) }
                else { withAnimation(.spring(response: 0.3)) { offset = .zero } }
            }
    }

    /// Double-tap: zoom to 2.5x, or back to fit.
    private func toggleZoom() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            if isZoomed { zoom = 1; pan = .zero } else { zoom = 2.5 }
        }
        zoomBase = zoom
        panBase = pan
    }

    /// Trash icon that grows as you drag up — hint that releasing deletes the photo.
    @ViewBuilder private var trashHint: some View {
        let p = min(max(-offset.height / threshold, 0), 1)
        if p > 0.02 {
            Label("삭제", systemImage: "trash.fill")
                .font(.headline.bold()).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .padding(.top, 70)
                .opacity(Double(p)).scaleEffect(0.85 + 0.15 * p)
        }
    }

    /// Short centered confirmation after ♥ / ✕ / up-swipe.
    @ViewBuilder private var flashOverlay: some View {
        if let flash {
            Label(flash.text, systemImage: flash.icon)
                .font(.headline.bold()).foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    // MARK: - Top bar (count + current photo's decision state)

    private var topBar: some View {
        ZStack {
            VStack(spacing: 6) {
                Text("\(index + 1) / \(count)").font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                if let d = decisions[index] {
                    Text(d == .keep ? "보관됨" : "삭제 예정").font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            HStack {
                Button { trashAssets.isEmpty ? dismiss() : finish() } label: {
                    Image(systemName: "xmark").font(.headline.bold()).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Viewer "정리 시작" button (starts organizing from the current photo)

    private var startBar: some View {
        Button {
            withAnimation(.spring(response: 0.35)) { organizing = true }
        } label: {
            Text("정리 시작")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 28).padding(.vertical, 13)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Bottom controls (♥ Lumen left, ★ favorite right)

    private var bottomControls: some View {
        HStack {
            control("heart.fill") { decide(.keep) }
            Spacer()
            control("star.fill") { favorite() }
        }
        .padding(.horizontal, 52)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func control(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 28, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 72, height: 72)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(spacing: 0) {
            Spacer()
            LumenGlyph(size: 64)
            Text("정리 완료").font(.title2.bold()).foregroundStyle(.white).padding(.top, 14)
            Text(keepCount > 0 ? "보관한 \(keepCount)장은 Lumen 앨범에 모았어요" : "수고하셨어요!")
                .font(.subheadline).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center).padding(.top, 6)
            Spacer()
            if !trashAssets.isEmpty {
                Button(role: .destructive) { Task { await deleteTrash() } } label: {
                    Label("\(trashAssets.count)장 한번에 삭제", systemImage: "trash")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
            }
            Button("닫기") { dismiss() }
                .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                .padding(.top, 14).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation (swipe) & decisions (buttons)

    /// Move to the next/previous photo. At the last photo, a forward swipe just
    /// springs back — browsing never forces you into the summary.
    /// If a page transition is mid-flight, finish it NOW (jump-cut) so a rapid
    /// tap/swipe starts the next step immediately instead of being swallowed.
    private func commitPendingStep() {
        advanceTask?.cancel()
        if let t = pendingTarget { index = t; offset = .zero; pendingTarget = nil }
    }

    private func swipeTo(next: Bool) {
        commitPendingStep()
        let target = next ? index + 1 : index - 1
        guard target >= 0, target < count else {
            withAnimation(.spring(response: 0.3)) { offset = .zero }; return
        }
        // Animate exactly one page, then swap index + reset offset in the same
        // frame: the neighbor that just animated to center IS the new current
        // (same ForEach identity), so the handoff doesn't move a single pixel.
        pendingTarget = target
        withAnimation(.easeOut(duration: 0.22)) { offset = CGSize(width: next ? -pageW : pageW, height: 0) }
        advanceTask = Task {
            try? await Task.sleep(for: .milliseconds(215))
            guard !Task.isCancelled else { return }
            index = target; offset = .zero; pendingTarget = nil
        }
    }

    /// Record a decision for the current photo, then advance. Deciding the last
    /// photo wraps up into the summary.
    private func decide(_ d: Decision) {
        guard index < count else { return }
        let a = source.asset(index)
        decisions[index] = d
        if d == .keep { Task { await library.addToLumen(a) } }   // file into Lumen, live
        tick += 1
        showFlash(d == .keep ? .keep : .trash)
        flyAndAdvance(CGSize(width: -pageW, height: 0))   // exactly one page → seamless handoff
    }

    /// Up-swipe: mark the photo for deletion and fly it up.
    private func trashFromSwipe() {
        guard index < count else { return }
        decisions[index] = .trash
        tick += 1
        showFlash(.trash)
        flyAndAdvance(CGSize(width: 0, height: -1200))
    }

    /// Right button: toggle Apple Favorite.
    private func favorite() {
        guard index < count else { return }
        let a = source.asset(index)
        let newValue = !currentIsFav
        favOverrides[a.localIdentifier] = newValue
        library.bumpFavorite(a, added: newValue)   // instant home update
        Task { try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: a).isFavorite = newValue } }
        currentIsFav = newValue
        tick += 1
        showFlash(newValue ? .favorite : .unfavorite)
        flyAndAdvance(CGSize(width: 0, height: -1200))
    }

    /// Fly the current card out, then step to the next photo (or finish at the end).
    private func flyAndAdvance(_ fly: CGSize) {
        commitPendingStep()
        let target = index < count - 1 ? index + 1 : nil
        pendingTarget = target
        withAnimation(.easeOut(duration: 0.22)) { offset = fly }
        advanceTask = Task {
            try? await Task.sleep(for: .milliseconds(215))
            guard !Task.isCancelled else { return }
            pendingTarget = nil
            if let target { index = target; offset = .zero } else { offset = .zero; finish() }
        }
    }

    private func showFlash(_ f: Flash) {
        withAnimation(.spring(response: 0.3)) { flash = f }
        Task { try? await Task.sleep(for: .milliseconds(500)); if flash == f { withAnimation { flash = nil } } }
    }

    private func finish() {
        if trashAssets.isEmpty { dismiss(); return }
        withAnimation { finished = true }
    }

    private func deleteTrash() async {
        let targets = trashAssets
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(targets as NSArray) }
            dismiss()
        } catch { /* 사용자가 iOS 다이얼로그 취소 — 요약 화면에 머뭄 */ }
    }
}

/// Full-screen photo (fits the screen; black fills the rest).
struct OrganizeCard: View {
    let asset: PHAsset
    let library: PhotoLibrary
    @State private var image: UIImage?
    @State private var showSpinner = false

    var body: some View {
        ZStack {
            Color.lumenBG
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if showSpinner { ProgressView().tint(.white) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            // Spinner only if loading actually takes a moment — a cache hit lands
            // within a frame or two and shouldn't flash a spinner first.
            showSpinner = false
            let spin = Task { try? await Task.sleep(for: .milliseconds(180)); if image == nil { showSpinner = true } }
            defer { spin.cancel() }
            // Screen-size target (not an oversized square) — decodes only the pixels
            // we can show, and matches prewarmViewer so neighbors arrive from cache.
            for await img in library.imageStream(asset, target: PhotoLibrary.viewerTarget, mode: .aspectFit) { image = img }
        }
    }
}
