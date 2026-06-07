import Foundation
@testable import LumenKit

/// Regression tests for the folder-cache desync bug: a deleted file lingered
/// forever because the persisted folder-mtime matched while the persisted photo
/// list was stale, so the scanner reused the stale list without re-reading.
/// The scanner now reconciles the cache against the live directory listing.
func incrementalScannerTests() {
    let fm = FileManager.default

    func tempDir() -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-scan-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func touch(_ url: URL) { fm.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xE0])) }
    /// The dir's current mtime — used as `knownMtimes` so `unchanged` is forced
    /// true regardless of filesystem timestamp precision (reproduces the desync).
    func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
    func setMtime(_ url: URL, _ date: Date) {
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    test("scannerDropsVanishedFileEvenWhenMtimeUnchanged") {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jpg")
        let b = dir.appendingPathComponent("b.jpg")
        touch(a); touch(b)

        let first = IncrementalScanner.scan(roots: [dir], knownMtimes: [:], cachedByFolder: [:])
        check(first.photos.count == 2, "first scan got \(first.photos.count)")
        let recorded = first.folderMtimes[dir.path]!

        // Delete b, then pin the folder mtime so the scanner believes nothing
        // changed — the exact desync that resurrected deleted photos.
        try? fm.removeItem(at: b)
        setMtime(dir, recorded)
        let cached = Dictionary(grouping: first.photos) { $0.folderURL.path }
        let second = IncrementalScanner.scan(roots: [dir],
                                             knownMtimes: [dir.path: mtime(dir)],
                                             cachedByFolder: cached)
        check(second.photos.count == 1, "expected 1 after delete, got \(second.photos.count)")
        check(second.photos.first?.url.lastPathComponent == "a.jpg",
              "got \(second.photos.first?.url.lastPathComponent ?? "nil")")
    }

    test("scannerPicksUpNewFileEvenWhenMtimeUnchanged") {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jpg")
        touch(a)
        let first = IncrementalScanner.scan(roots: [dir], knownMtimes: [:], cachedByFolder: [:])
        let recorded = first.folderMtimes[dir.path]!

        let c = dir.appendingPathComponent("c.jpg")
        touch(c)
        setMtime(dir, recorded)
        let cached = Dictionary(grouping: first.photos) { $0.folderURL.path }
        let second = IncrementalScanner.scan(roots: [dir],
                                             knownMtimes: [dir.path: mtime(dir)],
                                             cachedByFolder: cached)
        check(second.photos.count == 2, "expected 2 after add, got \(second.photos.count)")
    }

    test("scannerReusesCachedWhenListingUnavailable") {
        // A folder that doesn't exist at scan time must not wipe its cached photos
        // (protects against transient NAS read failures dropping the whole folder).
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.jpg")
        touch(a)
        let first = IncrementalScanner.scan(roots: [dir], knownMtimes: [:], cachedByFolder: [:])
        let recorded = first.folderMtimes[dir.path]!
        let cached = Dictionary(grouping: first.photos) { $0.folderURL.path }

        // Root removed entirely → scan skips it (fileExists guard), photos survive
        // via the caller's offline-preserve path, not by being wiped here.
        try? fm.removeItem(at: dir)
        let second = IncrementalScanner.scan(roots: [dir],
                                             knownMtimes: [dir.path: recorded],
                                             cachedByFolder: cached)
        check(second.photos.isEmpty, "missing root should be skipped, got \(second.photos.count)")
    }
}
