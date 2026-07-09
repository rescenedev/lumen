import Foundation
import CryptoKit
@testable import LumenKit

/// Stale disk-cache GC: cache filenames are opaque SHA256(path|tier|mtime)
/// hashes, so when a library moves volumes (or files are re-copied with new
/// mtimes) the old entries become permanently unreachable garbage — gigabytes
/// after a 60k-photo move. The sweep computes the set of names the CURRENT
/// library can still reference and deletes old entries outside it.
func thumbnailSweepTests() {

    let fm = FileManager.default

    func makeCacheDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-sweep-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a cache file under its shard subdir with the given age in days.
    func plant(_ name: String, in dir: URL, ageDays: Double, ext: String = "jpg") throws -> URL {
        let shard = dir.appendingPathComponent(String(name.prefix(2)), isDirectory: true)
        try fm.createDirectory(at: shard, withIntermediateDirectories: true)
        let file = shard.appendingPathComponent(name).appendingPathExtension(ext)
        try Data("x".utf8).write(to: file)
        let mtime = Date(timeIntervalSinceNow: -ageDays * 86_400)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        return file
    }

    // MARK: diskName (the pure key — must match what the cache writes)

    test("diskName: 64-char sha256 hex of path|tier|integer-mtime") {
        let name = ThumbnailCache.diskName(path: "/Volumes/nas/a.jpg", maxPixel: 512, mtime: 1700000000.9)
        checkEqual(name.count, 64)
        let expected = SHA256.hash(data: Data("/Volumes/nas/a.jpg|512|1700000000".utf8))
            .map { String(format: "%02x", $0) }.joined()
        checkEqual(name, expected, "must truncate mtime to Int exactly like the cache key")
    }

    test("diskName: path, tier, and mtime each change the name") {
        let base = ThumbnailCache.diskName(path: "/a.jpg", maxPixel: 512, mtime: 100)
        checkNotEqual(base, ThumbnailCache.diskName(path: "/b.jpg", maxPixel: 512, mtime: 100))
        checkNotEqual(base, ThumbnailCache.diskName(path: "/a.jpg", maxPixel: 256, mtime: 100))
        checkNotEqual(base, ThumbnailCache.diskName(path: "/a.jpg", maxPixel: 512, mtime: 101))
    }

    // MARK: sweepStale

    test("sweepStale: deletes old entries outside the valid set, keeps valid ones") {
        let dir = try makeCacheDir()
        defer { try? fm.removeItem(at: dir) }
        let valid = ThumbnailCache.diskName(path: "/Volumes/orico/a.jpg", maxPixel: 512, mtime: 1)
        let stale = ThumbnailCache.diskName(path: "/Volumes/oldnas/a.jpg", maxPixel: 512, mtime: 1)
        let validFile = try plant(valid, in: dir, ageDays: 30)
        let staleFile = try plant(stale, in: dir, ageDays: 30)

        let deleted = ThumbnailCache.sweepStale(in: dir, valid: [valid], olderThan: 86_400)
        checkEqual(deleted, 1)
        check(fm.fileExists(atPath: validFile.path), "current-library entry must survive")
        check(!fm.fileExists(atPath: staleFile.path), "orphaned entry must be deleted")
    }

    test("sweepStale: young stale entries survive (in-flight write safety margin)") {
        let dir = try makeCacheDir()
        defer { try? fm.removeItem(at: dir) }
        let stale = ThumbnailCache.diskName(path: "/gone.jpg", maxPixel: 512, mtime: 1)
        let file = try plant(stale, in: dir, ageDays: 0)   // written just now

        let deleted = ThumbnailCache.sweepStale(in: dir, valid: [], olderThan: 86_400)
        checkEqual(deleted, 0)
        check(fm.fileExists(atPath: file.path),
              "a photo imported after the valid-set snapshot writes keys the snapshot doesn't know — age guard must keep them")
    }

    test("sweepStale: only touches .jpg files") {
        let dir = try makeCacheDir()
        defer { try? fm.removeItem(at: dir) }
        let name = ThumbnailCache.diskName(path: "/gone.jpg", maxPixel: 512, mtime: 1)
        let other = try plant(name, in: dir, ageDays: 30, ext: "tmp")

        let deleted = ThumbnailCache.sweepStale(in: dir, valid: [], olderThan: 86_400)
        checkEqual(deleted, 0)
        check(fm.fileExists(atPath: other.path))
    }

    test("sweepStale: sweeps across shard subdirectories and reports the total") {
        let dir = try makeCacheDir()
        defer { try? fm.removeItem(at: dir) }
        var planted: [URL] = []
        for i in 0..<6 {
            let name = ThumbnailCache.diskName(path: "/gone/\(i).jpg", maxPixel: 512, mtime: 1)
            planted.append(try plant(name, in: dir, ageDays: 10))
        }
        let deleted = ThumbnailCache.sweepStale(in: dir, valid: [], olderThan: 86_400)
        checkEqual(deleted, 6)
        for url in planted { check(!fm.fileExists(atPath: url.path)) }
    }

    test("sweepStale: missing directory is a no-op") {
        let missing = fm.temporaryDirectory.appendingPathComponent("lumen-sweep-missing-\(UUID().uuidString)")
        checkEqual(ThumbnailCache.sweepStale(in: missing, valid: [], olderThan: 0), 0)
    }
}
