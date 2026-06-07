import Foundation

/// Persists the scanned photo list and the EXIF index so the library appears
/// instantly on the next launch (then reconciles with disk in the background).
/// This matters most for large libraries on slow/network volumes (NAS).
enum LibraryCache {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var photosURL: URL { dir.appendingPathComponent("library-cache.plist") }
    private static var exifURL: URL { dir.appendingPathComponent("exif-cache.plist") }
    private static var mtimesURL: URL { dir.appendingPathComponent("folder-mtimes.plist") }

    // MARK: Photos

    static func loadPhotos() -> [Photo]? {
        guard let data = try? Data(contentsOf: photosURL) else { return nil }
        return try? PropertyListDecoder().decode([Photo].self, from: data)
    }

    static func savePhotos(_ photos: [Photo]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(photos) else { return }
        try? data.write(to: photosURL, options: .atomic)
    }

    // MARK: EXIF index

    static func loadExif() -> [String: ExifInfo]? {
        guard let data = try? Data(contentsOf: exifURL) else { return nil }
        return try? PropertyListDecoder().decode([String: ExifInfo].self, from: data)
    }

    static func saveExif(_ index: [String: ExifInfo]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: exifURL, options: .atomic)
    }

    // MARK: Folder modification times

    static func loadFolderMtimes() -> [String: Date] {
        guard let data = try? Data(contentsOf: mtimesURL),
              let decoded = try? PropertyListDecoder().decode([String: Date].self, from: data) else { return [:] }
        return decoded
    }

    static func saveFolderMtimes(_ mtimes: [String: Date]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(mtimes) else { return }
        try? data.write(to: mtimesURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: photosURL)
        try? FileManager.default.removeItem(at: exifURL)
        try? FileManager.default.removeItem(at: mtimesURL)
    }
}
