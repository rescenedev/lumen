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
    private static var photosBinURL: URL { dir.appendingPathComponent("library-cache.bin") }
    private static var exifURL: URL { dir.appendingPathComponent("exif-cache.plist") }
    private static var mtimesURL: URL { dir.appendingPathComponent("folder-mtimes.plist") }

    // MARK: Photos

    /// This load gates the first window content, so it favors raw speed:
    /// the compact binary format decodes a 67k-photo library in ~100ms where
    /// PropertyListDecoder took ~410ms (measured). The legacy plist is read as
    /// a fallback for the first launch after updating, then replaced.
    static func loadPhotos() -> [Photo]? {
        if let photos = loadPhotosBinary() { return photos }
        guard let photos = loadPhotosLegacyPlist() else { return nil }
        // One-time migration: write the fast format now — waiting for the next
        // library change could leave every launch on the slow plist path.
        DispatchQueue.global(qos: .utility).async { savePhotos(photos) }
        return photos
    }

    private static func loadPhotosLegacyPlist() -> [Photo]? {
        guard let data = try? Data(contentsOf: photosURL) else { return nil }
        // Legacy plist: manual field extraction beats PropertyListDecoder's
        // Codable machinery by ~40% (410ms → 240ms at 67k, measured).
        if let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [[String: Any]] {
            var out: [Photo] = []
            out.reserveCapacity(raw.count)
            for entry in raw {
                guard let urlDict = entry["url"] as? [String: Any],
                      let relative = urlDict["relative"] as? String else { continue }
                // Codable-encoded URLs may carry a base; ours are absolute
                // file URLs, but resolve defensively.
                let base = (urlDict["base"] as? String).flatMap { URL(string: $0) }
                guard let url = URL(string: relative, relativeTo: base)?.absoluteURL else { continue }
                out.append(Photo(url: url,
                                 byteSize: entry["byteSize"] as? Int64 ?? 0,
                                 creationDate: entry["creationDate"] as? Date,
                                 modificationDate: entry["modificationDate"] as? Date))
            }
            if !out.isEmpty { return out }
        }
        return try? PropertyListDecoder().decode([Photo].self, from: data)
    }

    static func savePhotos(_ photos: [Photo]) {
        // Persist in the launch sort order (date, newest first): launch always
        // starts in .dateNewest, and Swift's adaptive sort makes re-sorting an
        // already-sorted 67k list ~free — so the cached library is grid-ready
        // the moment it decodes. Saving runs in the background; the extra sort
        // here costs nothing user-visible.
        savePhotosBinary(SortOrder.dateNewest.sorted(photos))
        // The legacy plist would go stale next to the binary — a downgade
        // reading it would silently show an old library. Remove it so older
        // builds rescan from disk instead.
        try? FileManager.default.removeItem(at: photosURL)
    }

    // MARK: Binary photo cache ("LMC1")
    //
    // Header: magic u32, count u64. Per record: urlLen u32 + URL absoluteString
    // utf8, byteSize i64, creation/modification f64 (timeIntervalSinceReference-
    // Date; NaN = nil). Native endianness — the cache never leaves this machine.
    // URLs round-trip through absoluteString + URL(string:) — 37ms for 67k.
    // (NEVER URL(fileURLWithPath:) here: it stats each path, ~7ms each on NAS.)

    private static let photosBinMagic: UInt32 = 0x4C4D_4331   // "LMC1"

    private static func savePhotosBinary(_ photos: [Photo]) {
        try? encodePhotosBinary(photos).write(to: photosBinURL, options: .atomic)
    }

    private static func loadPhotosBinary() -> [Photo]? {
        guard let data = try? Data(contentsOf: photosBinURL) else { return nil }
        return decodePhotosBinary(data)
    }

    /// Pure encoder/decoder pair (no disk) — also the unit-test seam.
    static func encodePhotosBinary(_ photos: [Photo]) -> Data {
        var out = Data()
        out.reserveCapacity(photos.count * 120 + 16)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { out.append(contentsOf: $0) } }
        append(photosBinMagic)
        append(UInt64(photos.count))
        for photo in photos {
            let utf8 = Array(photo.url.absoluteString.utf8)
            append(UInt32(utf8.count))
            out.append(contentsOf: utf8)
            append(photo.byteSize)
            append(photo.creationDate?.timeIntervalSinceReferenceDate ?? Double.nan)
            append(photo.modificationDate?.timeIntervalSinceReferenceDate ?? Double.nan)
        }
        return out
    }

    static func decodePhotosBinary(_ data: Data) -> [Photo]? {
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [Photo]? in
            var offset = 0
            func read<T>(_ type: T.Type) -> T? {
                guard offset + MemoryLayout<T>.size <= buf.count else { return nil }
                defer { offset += MemoryLayout<T>.size }
                return buf.loadUnaligned(fromByteOffset: offset, as: type)
            }
            guard read(UInt32.self) == photosBinMagic, let count = read(UInt64.self) else { return nil }
            var out: [Photo] = []
            out.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let urlLen = read(UInt32.self).map(Int.init),
                      offset + urlLen <= buf.count else { return nil }
                let urlString = String(decoding: buf[offset..<(offset + urlLen)], as: UTF8.self)
                offset += urlLen
                guard let byteSize = read(Int64.self),
                      let created = read(Double.self),
                      let modified = read(Double.self),
                      let url = URL(string: urlString) else { return nil }
                out.append(Photo(url: url, byteSize: byteSize,
                                 creationDate: created.isNaN ? nil : Date(timeIntervalSinceReferenceDate: created),
                                 modificationDate: modified.isNaN ? nil : Date(timeIntervalSinceReferenceDate: modified)))
            }
            return out.isEmpty ? nil : out
        }
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
        try? FileManager.default.removeItem(at: photosBinURL)
        try? FileManager.default.removeItem(at: exifURL)
        try? FileManager.default.removeItem(at: mtimesURL)
    }
}
