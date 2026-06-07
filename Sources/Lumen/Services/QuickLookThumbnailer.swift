import AppKit
import QuickLookThumbnailing

/// Generates thumbnails via QuickLook. Unlike ImageIO, this works on iCloud
/// "dataless" files (it uses the cloud-provided preview) and on formats ImageIO
/// can't open, so it's our fallback when a direct decode fails.
enum QuickLookThumbnailer {
    /// Synchronous thumbnail generation. Call only on a background queue.
    static func thumbnail(for url: URL, maxPixel: Int) -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: .all
        )

        let semaphore = DispatchSemaphore(value: 0)
        var result: NSImage?
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            if let rep { result = NSImage(cgImage: rep.cgImage, size: rep.contentRect.size) }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }
}
