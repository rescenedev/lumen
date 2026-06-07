import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Read-only export helpers: copy originals, export resized copies, zip, and
/// set the desktop wallpaper. None of these modify the source files.
enum Exporter {
    /// Copy originals into a destination directory.
    static func copyOriginals(_ photos: [Photo], to directory: URL) -> Int {
        var copied = 0
        for photo in photos {
            let dest = uniqueDestination(directory, filename: photo.filename)
            if (try? FileManager.default.copyItem(at: photo.url, to: dest)) != nil { copied += 1 }
        }
        return copied
    }

    /// Export downsized JPEG copies (longest edge = maxPixel) into a directory.
    static func exportResized(_ photos: [Photo], maxPixel: Int, to directory: URL) -> Int {
        var exported = 0
        for photo in photos {
            guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, nil) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let baseName = (photo.filename as NSString).deletingPathExtension
            let dest = uniqueDestination(directory, filename: "\(baseName).jpg")
            guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(out, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(out) { exported += 1 }
        }
        return exported
    }

    /// Create a zip archive of the originals using the system `zip` tool.
    static func zip(_ photos: [Photo], to archiveURL: URL) -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenZip-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for photo in photos {
            let dest = uniqueDestination(tmp, filename: photo.filename)
            try? FileManager.default.copyItem(at: photo.url, to: dest)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tmp
        process.arguments = ["-r", "-q", archiveURL.path, "."]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func setWallpaper(_ photo: Photo) {
        guard let screen = NSScreen.main else { return }
        try? NSWorkspace.shared.setDesktopImageURL(photo.url, for: screen, options: [:])
    }

    /// Present the system share sheet anchored to a view.
    @MainActor
    static func share(_ photos: [Photo], from view: NSView) {
        let picker = NSSharingServicePicker(items: photos.map { $0.url })
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private static func uniqueDestination(_ directory: URL, filename: String) -> URL {
        var candidate = directory.appendingPathComponent(filename)
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }
}
