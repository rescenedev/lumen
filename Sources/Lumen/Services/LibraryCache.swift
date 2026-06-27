import Foundation

/// Persists the scanned photo list and the EXIF index so the library appears
/// instantly on the next launch (then reconciles with disk in the background).
/// This matters most for large libraries on slow/network volumes (NAS).
enum LibraryCache {
    // Created once on first access — not a computed property, so cache reads and
    // writes don't issue a createDirectory syscall every time.
    private static let dir: URL = AppDirectories.lumenSupport()
    /// Test seam: redirect the cache directory so disk tests never touch the real
    /// user cache. nil = the real Application Support location.
    static var directoryOverride: URL?
    private static var baseDir: URL { directoryOverride ?? dir }
    private static var photosURL: URL { baseDir.appendingPathComponent("library-cache.plist") }
    private static var photosBinURL: URL { baseDir.appendingPathComponent("library-cache.bin") }
    private static var exifURL: URL { baseDir.appendingPathComponent("exif-cache.plist") }
    private static var exifBinURL: URL { baseDir.appendingPathComponent("exif-cache.bin") }
    private static var mtimesURL: URL { baseDir.appendingPathComponent("folder-mtimes.plist") }

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
        // (savePhotos is itself async on the serial save queue.)
        savePhotos(photos)
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

    /// All photo-cache writes funnel through one serial queue so a slow save
    /// scheduled earlier (e.g. the one-time plist→binary migration) can never
    /// land after — and silently revert — a newer library state.
    private static let saveQueue = DispatchQueue(label: "lumen.librarycache.save", qos: .utility)

    /// Test seam: block until all queued cache writes/deletes have run.
    static func flushForTesting() { saveQueue.sync {} }
    /// Test seam: submit a block onto the save queue (used to hold the queue busy
    /// so an ordering race can be reproduced deterministically).
    static func runOnSaveQueueForTesting(_ block: @escaping () -> Void) { saveQueue.async(execute: block) }

    static func savePhotos(_ photos: [Photo]) {
        // Persist in the launch sort order (date, newest first): launch always
        // starts in .dateNewest, and Swift's adaptive sort makes re-sorting an
        // already-sorted 67k list ~free — so the cached library is grid-ready
        // the moment it decodes. Saving runs in the background; the extra sort
        // here costs nothing user-visible.
        saveQueue.async {
            let wrote = savePhotosBinary(SortOrder.dateNewest.sorted(photos))
            // The legacy plist would go stale next to the binary — a downgrade
            // reading it would silently show an old library. Remove it so older
            // builds rescan from disk instead. ONLY once the binary verifiably
            // landed: deleting both after a failed write (disk full) would cost
            // the user their whole cached library.
            if wrote { try? FileManager.default.removeItem(at: photosURL) }
        }
    }

    // MARK: Binary photo cache ("LMC1")
    //
    // Header: magic u32, count u64. Per record: urlLen u32 + URL absoluteString
    // utf8, byteSize i64, creation/modification f64 (timeIntervalSinceReference-
    // Date; NaN = nil). Native endianness — the cache never leaves this machine.
    // URLs round-trip through absoluteString + URL(string:) — 37ms for 67k.
    // (NEVER URL(fileURLWithPath:) here: it stats each path, ~7ms each on NAS.)

    private static let photosBinMagic: UInt32 = 0x4C4D_4331   // "LMC1"

    @discardableResult
    private static func savePhotosBinary(_ photos: [Photo]) -> Bool {
        (try? encodePhotosBinary(photos).write(to: photosBinURL, options: .atomic)) != nil
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
            guard read(UInt32.self) == photosBinMagic, let count = read(UInt64.self),
                  // A corrupted count field must not trap Int() or attempt a
                  // multi-GB reserve INSIDE the launch decode (that would crash
                  // every launch until the cache is hand-deleted). 24 bytes is
                  // the minimum record size, so any real count fits this bound.
                  count <= UInt64(max(0, buf.count - 12) / 24)
            else { return nil }
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
            // Empty decodes to nil by design: an empty cache is indistinguishable
            // from "no cache" and loaders fall back to a (trivial) rescan either
            // way. See LibraryCacheTests.binaryEmptyListDecodesAsNil.
            return out.isEmpty ? nil : out
        }
    }

    // MARK: EXIF index

    // Binary EXIF index ("LXE1"). PropertyListDecoder/Codable measured ~680ms at
    // 67k and churns the allocator in the first seconds after launch; this
    // hand-rolled format mirrors the photo cache (LMC1). Layout: magic u32, count
    // u64. Per entry: pathLen u32 + utf8, flags u8 (bit per present optional), then
    // present values in field order — Int as i64, String as u32 len + utf8, Date &
    // Double as f64 (timeIntervalSinceReferenceDate for Date).
    private static let exifBinMagic: UInt32 = 0x4C58_4531   // "LXE1"

    static func loadExif() -> [String: ExifInfo]? {
        if let data = try? Data(contentsOf: exifBinURL), let decoded = decodeExifBinary(data) { return decoded }
        // Legacy plist fallback (first launch after update) — migrate to binary.
        guard let data = try? Data(contentsOf: exifURL),
              let decoded = try? PropertyListDecoder().decode([String: ExifInfo].self, from: data) else { return nil }
        saveExif(decoded)
        return decoded
    }

    static func saveExif(_ index: [String: ExifInfo]) {
        guard (try? encodeExifBinary(index).write(to: exifBinURL, options: .atomic)) != nil else { return }
        // Remove the stale legacy plist so an older build can't read an outdated
        // index — only after the binary verifiably landed.
        try? FileManager.default.removeItem(at: exifURL)
    }

    /// Pure encoder/decoder pair (no disk) — also the unit-test seam.
    static func encodeExifBinary(_ index: [String: ExifInfo]) -> Data {
        var out = Data()
        out.reserveCapacity(index.count * 64 + 12)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { out.append(contentsOf: $0) } }
        func appendString(_ s: String) { let u = Array(s.utf8); append(UInt32(u.count)); out.append(contentsOf: u) }
        append(exifBinMagic)
        append(UInt64(index.count))
        for (path, info) in index {
            appendString(path)
            var flags: UInt8 = 0
            if info.pixelWidth != nil  { flags |= 1 << 0 }
            if info.pixelHeight != nil { flags |= 1 << 1 }
            if info.cameraMake != nil  { flags |= 1 << 2 }
            if info.cameraModel != nil { flags |= 1 << 3 }
            if info.dateTaken != nil   { flags |= 1 << 4 }
            if info.latitude != nil    { flags |= 1 << 5 }
            if info.longitude != nil   { flags |= 1 << 6 }
            append(flags)
            if let v = info.pixelWidth  { append(Int64(v)) }
            if let v = info.pixelHeight { append(Int64(v)) }
            if let v = info.cameraMake  { appendString(v) }
            if let v = info.cameraModel { appendString(v) }
            if let v = info.dateTaken   { append(v.timeIntervalSinceReferenceDate) }
            if let v = info.latitude    { append(v) }
            if let v = info.longitude   { append(v) }
        }
        return out
    }

    static func decodeExifBinary(_ data: Data) -> [String: ExifInfo]? {
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [String: ExifInfo]? in
            var offset = 0
            func read<T>(_ type: T.Type) -> T? {
                guard offset + MemoryLayout<T>.size <= buf.count else { return nil }
                defer { offset += MemoryLayout<T>.size }
                return buf.loadUnaligned(fromByteOffset: offset, as: type)
            }
            func readString() -> String? {
                guard let len = read(UInt32.self).map(Int.init), offset + len <= buf.count else { return nil }
                let s = String(decoding: buf[offset..<(offset + len)], as: UTF8.self)
                offset += len
                return s
            }
            guard read(UInt32.self) == exifBinMagic, let count = read(UInt64.self),
                  // Min entry is 5 bytes (4-byte pathLen + 1-byte flags), so a
                  // corrupt count can't trap Int() or over-reserve.
                  count <= UInt64(max(0, buf.count - 12) / 5)
            else { return nil }
            var out: [String: ExifInfo] = [:]
            out.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let path = readString(), let flags = read(UInt8.self) else { return nil }
                var info = ExifInfo()
                if flags & (1 << 0) != 0 { guard let v = read(Int64.self) else { return nil }; info.pixelWidth = Int(v) }
                if flags & (1 << 1) != 0 { guard let v = read(Int64.self) else { return nil }; info.pixelHeight = Int(v) }
                if flags & (1 << 2) != 0 { guard let v = readString() else { return nil }; info.cameraMake = v }
                if flags & (1 << 3) != 0 { guard let v = readString() else { return nil }; info.cameraModel = v }
                if flags & (1 << 4) != 0 { guard let v = read(Double.self) else { return nil }; info.dateTaken = Date(timeIntervalSinceReferenceDate: v) }
                if flags & (1 << 5) != 0 { guard let v = read(Double.self) else { return nil }; info.latitude = v }
                if flags & (1 << 6) != 0 { guard let v = read(Double.self) else { return nil }; info.longitude = v }
                out[path] = info
            }
            return out
        }
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
        // Delete on the SAME serial queue the saves use, so a save scheduled
        // earlier can't land after the clear and resurrect the cache the user
        // just wiped (it would reappear on next launch). Snapshot the URLs now;
        // the deletion runs after any in-flight/queued save.
        let urls = [photosURL, photosBinURL, exifURL, exifBinURL, mtimesURL]
        saveQueue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }
}
