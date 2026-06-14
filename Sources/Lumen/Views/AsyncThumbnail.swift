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
            } else if failed {
                placeholder(systemImage: "exclamationmark.triangle")
            } else {
                placeholder(systemImage: nil)
            }
        }
        .task(id: url) { await load() }
    }

    private func placeholder(systemImage: String?) -> some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
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
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }
}
