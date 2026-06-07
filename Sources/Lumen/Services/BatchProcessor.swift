import Foundation
import CoreGraphics

/// Applies one `ImageEditor.Edit` (resize / exact-canvas + padding) to many
/// photos, writing non-destructive copies into an output folder. Source files
/// are never touched. Runs off the main thread; reports progress as it goes.
enum BatchProcessor {
    enum Format: String, CaseIterable, Identifiable {
        case jpg, png
        var id: String { rawValue }
        var ext: String { rawValue }
        var label: String { self == .jpg ? "JPG" : "PNG" }
    }

    /// Process `photos` into `outputDir`. Returns the number written. `progress`
    /// is called on a background thread after each file with (done, total).
    static func run(_ photos: [URL], edit: ImageEditor.Edit, format: Format,
                    quality: CGFloat, background: CGColor, into outputDir: URL,
                    progress: (Int, Int) -> Void) -> Int {
        let total = photos.count
        var done = 0, written = 0
        for url in photos {
            let base = url.deletingPathExtension().lastPathComponent
            let dest = ImageEditor.uniqueFileURL(in: outputDir, base: base, ext: format.ext)
            if ImageEditor.process(source: url, edit: edit, to: dest, quality: quality, background: background) {
                written += 1
            }
            done += 1
            progress(done, total)
        }
        return written
    }
}
