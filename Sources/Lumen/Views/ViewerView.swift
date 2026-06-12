import SwiftUI

/// Full-window single-photo viewer presented as an overlay. Supports zoom,
/// pan, keyboard + on-screen navigation, favoriting, and a slideshow.
struct ViewerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    // Zoom & pan state
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // Slideshow
    @State private var isPlaying = false
    @State private var chromeVisible = true

    private let slideshowInterval: TimeInterval = 3.5
    private let timer = Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()

    @State private var containerSize: CGSize = .zero
    @State private var loadedImageSize: CGSize?   // actual pixel size of the shown image

    // One-time culling-shortcuts hint, shown on the very first viewer open.
    @State private var showCullingHint = false
    private static let cullingHintKey = "lumen.cullingHintShown"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { withAnimation { chromeVisible.toggle() } }
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in containerSize = size }
                })

            if let photo = model.currentViewerPhoto {
                if let secondary = model.compareSecondary {
                    compareArea(primary: photo, secondary: secondary)
                } else {
                    imageArea(for: photo)
                }

                if model.showExifOverlay {
                    exifOverlay(for: photo)
                }

                if chromeVisible {
                    navigationButtons
                    topBar(for: photo)
                    bottomBar(for: photo)
                }

                if showCullingHint {
                    cullingHint
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onAppear {
            guard !UserDefaults.standard.bool(forKey: Self.cullingHintKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.cullingHintKey)
            withAnimation(.easeOut(duration: 0.3)) { showCullingHint = true }
            Task {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeInOut(duration: 0.8)) { showCullingHint = false }
            }
        }
        .onChange(of: model.viewerIndex) { _, _ in
            resetZoom()
            loadedImageSize = nil
            prefetchNeighbors()
        }
        .onAppear { prefetchNeighbors() }
        .onReceive(timer) { _ in if isPlaying { advanceSlideshow() } }
        .onKeyPress(.escape) { model.closeViewer(); return .handled }
        .onKeyPress(.leftArrow) { model.viewerStep(-1); return .handled }
        .onKeyPress(.rightArrow) { model.viewerStep(1); return .handled }
        .onKeyPress(.space) { model.favoriteAndAdvanceViewer(); return .handled }
        .onKeyPress(KeyEquivalent("p")) { toggleSlideshow(); return .handled }
        .onKeyPress(KeyEquivalent("=")) { zoom(by: 1.4); return .handled }
        .onKeyPress(KeyEquivalent("-")) { zoom(by: 1 / 1.4); return .handled }
        .onKeyPress(KeyEquivalent("0")) { resetZoom(); return .handled }
        .onKeyPress(KeyEquivalent("f")) { favoriteCurrent(); return .handled }
        .onKeyPress(KeyEquivalent("x")) { rejectCurrent(); return .handled }
        .onKeyPress(KeyEquivalent("i")) { model.showExifOverlay.toggle(); return .handled }
        // Backspace arrives as DEL (\u{7F}), not KeyEquivalent.delete (\u{8}) —
        // match every delete variant or the key looks dead.
        .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { _ in
            deleteCurrent(); return .handled
        }
        .onKeyPress(keys: ["0", "1", "2", "3", "4", "5"]) { press in
            if let n = Int(String(press.key.character)), let photo = model.currentViewerPhoto {
                model.setRating(n, for: [photo])
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Image area

    private func imageArea(for photo: Photo) -> some View {
        ZoomableImage(url: photo.url,
                      scale: $scale,
                      lastScale: $lastScale,
                      offset: $offset,
                      lastOffset: $lastOffset,
                      loadedSize: $loadedImageSize)
            .id(photo.url)
            .contextMenu { PhotoContextMenu(photo: photo) }
    }

    private func compareArea(primary: Photo, secondary: Photo) -> some View {
        HStack(spacing: 2) {
            comparePane(primary)
            Divider().overlay(.white.opacity(0.4))
            comparePane(secondary)
        }
    }

    private func comparePane(_ photo: Photo) -> some View {
        ZStack(alignment: .bottom) {
            CompareImage(url: photo.url)
            Text(photo.filename)
                .font(.caption).foregroundStyle(.white).lineLimit(1)
                .padding(6).background(.black.opacity(0.5), in: Capsule()).padding(8)
        }
    }

    private func exifOverlay(for photo: Photo) -> some View {
        let info = model.exif[photo.url.path]
        return VStack(alignment: .leading, spacing: 4) {
            ratingStars(for: photo)
            if let info {
                if let w = info.pixelWidth, let h = info.pixelHeight {
                    overlayRow("Dimensions", "\(w) × \(h)")
                }
                if let cam = info.cameraModel { overlayRow("Camera", cam) }
                if let date = info.dateTaken { overlayRow("Taken", Format.dateString(date)) }
                if info.hasGPS { overlayRow("Location", "GPS tagged") }
            }
            overlayRow("Size", Format.size(photo.byteSize))
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private func ratingStars(for photo: Photo) -> some View {
        let rating = model.rating(photo)
        return HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .foregroundStyle(i <= rating ? .yellow : .white.opacity(0.5))
            }
        }
        .padding(.bottom, 2)
    }

    private func overlayRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: 80, alignment: .leading)
            Text(value)
        }
    }

    // MARK: - Culling hint

    /// One-time keyboard cheat sheet for culling, floating above the bottom
    /// bar. Purely informational — never intercepts clicks or keys.
    private var cullingHint: some View {
        HStack(spacing: 16) {
            hintItem("Space", "Favorite + next")
            hintItem("X", "Reject + next")
            hintItem("1–5", "Rate")
            hintItem("← →", "Navigate")
            hintItem("⌫", "Delete")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .padding(.bottom, 96)   // clears the bottom toolbar
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .allowsHitTesting(false)
    }

    private func hintItem(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func showExifOverlayToggle() { model.showExifOverlay.toggle() }

    // MARK: - Chrome

    private var prevPhoto: Photo? {
        guard let i = model.viewerIndex, i > 0 else { return nil }
        return model.viewerPhotos[i - 1]
    }

    private var nextPhoto: Photo? {
        guard let i = model.viewerIndex, i < model.viewerPhotos.count - 1 else { return nil }
        return model.viewerPhotos[i + 1]
    }

    /// Width of the black bar beside a fitted portrait image, so the edge
    /// previews can grow to fill it. Returns 0 when the image fills the width.
    private var sideMargin: CGFloat {
        // Use the actually-loaded image's size (EXIF index may be incomplete).
        guard containerSize.width > 0, containerSize.height > 0,
              let isz = loadedImageSize, isz.width > 0, isz.height > 0 else { return 0 }
        let imageAspect = isz.width / isz.height
        let containerAspect = containerSize.width / containerSize.height
        guard imageAspect < containerAspect else { return 0 }
        let displayedWidth = containerSize.height * imageAspect
        return max(0, (containerSize.width - displayedWidth) / 2)
    }

    /// Edge-preview thumbnail size: grows to fill a wide side margin (leaving
    /// breathing room on both sides), capped.
    private var edgeThumbSize: CGFloat {
        max(120, min(sideMargin - 48, 400))
    }

    private var navigationButtons: some View {
        HStack {
            edgeButton(photo: prevPhoto, chevron: "chevron.left", enabled: model.canStepBack) {
                model.viewerStep(-1)
            }
            Spacer()
            edgeButton(photo: nextPhoto, chevron: "chevron.right", enabled: model.canStepForward) {
                model.viewerStep(1)
            }
        }
        .padding(.horizontal, 28)
    }

    /// Only show the preview thumbnail when the side margin can hold it without
    /// overlapping the main photo; otherwise show just the chevron button.
    private var showEdgeThumb: Bool { sideMargin >= 150 }

    private func edgeButton(photo: Photo?, chevron: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        let size = edgeThumbSize
        return Button(action: action) {
            ZStack {
                if showEdgeThumb, let photo {
                    AsyncThumbnail(url: photo.url, mtime: photo.cacheMtime)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 6)
                }
                Image(systemName: chevron)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.2), value: size)
    }

    private func topBar(for photo: Photo) -> some View {
        HStack(spacing: 14) {
            Button { model.closeViewer() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")

            VStack(alignment: .leading, spacing: 1) {
                Text(photo.filename).font(.headline).foregroundStyle(.white).lineLimit(1)
                if let index = model.viewerIndex {
                    Text("\(index + 1) of \(model.viewerPhotos.count)")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            Button { favoriteCurrent() } label: {
                Image(systemName: model.isFavorite(photo) ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(model.isFavorite(photo) ? .pink : .white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Favorite (F)")
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func bottomBar(for photo: Photo) -> some View {
        HStack(spacing: 18) {
            toolButton("minus.magnifyingglass") { zoom(by: 1 / 1.4) }
            Text("\(Int(scale * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 52)
            toolButton("plus.magnifyingglass") { zoom(by: 1.4) }
            toolButton("arrow.up.left.and.arrow.down.right") { resetZoom() }

            Divider().frame(height: 22).overlay(.white.opacity(0.3))

            toolButton(isPlaying ? "pause.fill" : "play.fill") { toggleSlideshow() }
            toolButton("magnifyingglass") {
                QuickLookPreview.shared.show(urls: [photo.url], startAt: 0)
            }
            toolButton("info.circle") { showExifOverlayToggle() }
            if !photo.isAsset {
                toolButton("crop") { model.startEdit(photo) }
            }
            toolButton("folder") { model.revealInFinder([photo]) }
            toolButton("trash") { deleteCurrent() }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func toolButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func prefetchNeighbors() {
        FullImageLoader.shared.prefetch([prevPhoto?.url, nextPhoto?.url].compactMap { $0 })
    }

    private func favoriteCurrent() {
        if let photo = model.currentViewerPhoto { model.toggleFavorite(photo) }
    }

    /// Reject (X): flag to discard and advance, so you can cull without lifting
    /// your hand off the keyboard.
    private func rejectCurrent() {
        guard let photo = model.currentViewerPhoto else { return }
        model.toggleRejected([photo])
        if model.canStepForward { model.viewerStep(1) }
    }

    private func deleteCurrent() {
        if isPlaying { isPlaying = false }
        if let photo = model.currentViewerPhoto { model.requestDeletion([photo]) }
    }

    private func toggleSlideshow() {
        isPlaying.toggle()
        if isPlaying { resetZoom() }
    }

    private func advanceSlideshow() {
        if model.canStepForward {
            model.viewerStep(1)
        } else {
            model.viewerIndex = 0 // loop
        }
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.18)) {
            scale = min(8, max(1, scale * factor))
            lastScale = scale
            if scale <= 1 { offset = .zero; lastOffset = .zero }
        }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
    }
}
