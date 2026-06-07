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
            image = await FullImageLoader.shared.image(for: url)
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
