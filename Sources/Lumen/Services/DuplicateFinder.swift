import Foundation
import CryptoKit

/// Finds duplicate photos. Groups by byte size first (cheap), then confirms
/// with a content hash so only true duplicates are reported.
enum DuplicateFinder {
    /// Returns the set of photo URLs that are part of any duplicate group.
    static func duplicatePaths(in photos: [Photo]) -> Set<String> {
        var bySize: [Int64: [Photo]] = [:]
        for photo in photos where photo.byteSize > 0 {
            bySize[photo.byteSize, default: []].append(photo)
        }

        var result = Set<String>()
        for (_, group) in bySize where group.count > 1 {
            var byHash: [String: [Photo]] = [:]
            for photo in group {
                guard let hash = contentHash(photo.url) else { continue }
                byHash[hash, default: []].append(photo)
            }
            for (_, dupes) in byHash where dupes.count > 1 {
                for photo in dupes { result.insert(photo.url.path) }
            }
        }
        return result
    }

    private static func contentHash(_ url: URL) -> String? {
        // Skip iCloud-evicted files so we don't download the whole library.
        if iCloudDownloader.isDataless(url) { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return hash { try handle.read(upToCount: 1 << 20) }
    }

    /// SHA-256 over a stream of chunks. `next` returns the next chunk, nil/empty at
    /// EOF, or THROWS on a read failure. A thrown error returns nil (skip the file)
    /// — it must never be mistaken for EOF, or a NAS connection drop would finalize
    /// a hash over partial bytes and two such files would collide as false
    /// "duplicates". Pure (no disk) so it's the unit-test seam.
    static func hash(reading next: () throws -> Data?) -> String? {
        var hasher = SHA256()
        while true {
            // Allow a long NAS hash to be cancelled (e.g. the user leaves the
            // duplicates view) instead of reading the whole file regardless.
            if Task.isCancelled { return nil }
            let chunk: Data?
            do {
                chunk = try next()
            } catch {
                return nil   // read error ≠ EOF: skip rather than hash partial data
            }
            guard let chunk, !chunk.isEmpty else { break }   // nil/empty = real EOF
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
