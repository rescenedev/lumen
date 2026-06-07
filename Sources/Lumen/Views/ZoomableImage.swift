import SwiftUI

/// Loads a full-resolution image and applies pinch-to-zoom, scroll-to-zoom,
/// double-click zoom, and drag-to-pan. Zoom/pan state is owned by the parent
/// so it can be reset on navigation.
struct ZoomableImage: View {
    let url: URL
    @Binding var scale: CGFloat
    @Binding var lastScale: CGFloat
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize
    @Binding var loadedSize: CGSize?

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnification)
                        .simultaneousGesture(panGesture)
                        .onTapGesture(count: 2) { toggleZoom() }
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: url) {
            image = nil
            // 1. Show the already-cached grid thumbnail instantly (local disk) so
            //    there's no blank wait while the full-res original loads from NAS.
            if let thumb = ThumbnailCache.shared.cached(for: url, maxPixel: ThumbnailCache.gridMaxPixel) {
                image = thumb
                loadedSize = thumb.size
            } else if let thumb = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: ThumbnailCache.gridMaxPixel) {
                if image == nil { image = thumb; loadedSize = thumb.size }
            }
            // 2. Swap in the full-resolution image when it arrives.
            if let full = await FullImageLoader.shared.image(for: url) {
                image = full
                loadedSize = full.size
            }
        }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = clamp(lastScale * value.magnification)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { resetPan() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1; lastScale = 1; resetPan()
            } else {
                scale = 2.5; lastScale = 2.5
            }
        }
    }

    private func resetPan() {
        offset = .zero
        lastOffset = .zero
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(8, max(1, value))
    }
}
