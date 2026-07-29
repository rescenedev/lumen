import SwiftUI

/// A view that asynchronously loads and displays a downsampled thumbnail.
/// Thumbnails are decoded once at a fixed resolution and cached, so resizing
/// the grid only rescales an existing bitmap rather than re-decoding.
struct AsyncThumbnail: View {
    let url: URL
    /// Scan-time mtime for the disk-cache key — pass `photo.cacheMtime` to
    /// avoid a per-thumbnail stat (a NAS roundtrip); nil stats the file.
    var mtime: TimeInterval?
    /// Decode tier. Use `ThumbnailCache.tier(forPointSize:)` for small cells so
    /// keys match prefetch; the default is crisp at the largest grid size.
    var maxPixel = ThumbnailCache.gridMaxPixel

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if failed {
                placeholder(systemImage: "exclamationmark.triangle.fill",
                            tint: AnyShapeStyle(.yellow.opacity(0.85)))
            } else {
                placeholder(systemImage: "photo",
                            tint: AnyShapeStyle(.secondary.opacity(0.45)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: image == nil)
        .task(id: url) { await load() }
    }

    /// A spinner per cell turns a cold grid into a field of flickering
    /// pinwheels — visual noise that says nothing (the real progress lives in
    /// the status bar, with a count and a bar). A still, dim glyph reads as
    /// "not loaded yet" and lets the photos that HAVE landed carry the view.
    /// Mirrors the AppKit grid cell's placeholder (see `PhotoGridCellView`), but
    /// with semantic colors: unlike that always-dark grid, this view also sits on
    /// the inspector and viewer chrome, which follow the system theme.
    private func placeholder(systemImage: String, tint: AnyShapeStyle) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.5))
                Image(systemName: systemImage)
                    .font(.system(size: min(side * 0.30, 56), weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func load() async {
        // url changed (task id) — clear any stale error from the previous photo
        // so its warning icon doesn't linger over the new one.
        failed = false
        if let hit = ThumbnailCache.shared.cached(for: url, maxPixel: maxPixel) {
            image = hit
            return
        }
        let loaded = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel, mtime: mtime)
        // Bail if the url changed while loading — don't apply a stale thumbnail.
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }
}
