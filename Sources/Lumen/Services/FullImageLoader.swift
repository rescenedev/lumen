import AppKit
import ImageIO

/// Loads full-resolution images for the single-photo viewer, off the main thread.
/// A byte-bounded cache keeps the current and neighbouring photos warm for fast
/// paging without letting a few huge images blow up memory.
final class FullImageLoader {
    static let shared = FullImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "lumen.fullimage", qos: .userInitiated)

    private init() {
        // ~200 MB — holds several 4096px images, evicting the oldest by cost.
        cache.totalCostLimit = 200 * 1024 * 1024
    }

    private func cost(of image: NSImage) -> Int {
        Int(image.size.width * image.size.height) * 4
    }

    func image(for url: URL) async -> NSImage? {
        let cacheKey = url.path as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                let image = Self.decode(url: url)
                if let self, let image { self.cache.setObject(image, forKey: cacheKey, cost: self.cost(of: image)) }
                continuation.resume(returning: image)
            }
        }
    }

    /// Warm neighbouring images so paging next/prev is instant.
    func prefetch(_ urls: [URL]) {
        for url in urls {
            let key = url.path as NSString
            if cache.object(forKey: key) != nil { continue }
            queue.async { [weak self] in
                guard let self, self.cache.object(forKey: key) == nil else { return }
                if let image = Self.decode(url: url) {
                    self.cache.setObject(image, forKey: key, cost: self.cost(of: image))
                }
            }
        }
    }

    /// Decode honouring EXIF orientation.
    private static func decode(url: URL) -> NSImage? {
        // Pull down the original if it only exists in iCloud.
        iCloudDownloader.ensureLocal(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // Cap very large originals so a 100MP RAW doesn't blow memory.
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        // Fallback: let NSImage handle formats ImageIO thumbnailing missed.
        return NSImage(contentsOf: url)
    }
}
