import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import LumenKit

private struct LegacyLibraryPayload: Codable {
    var items: [String: PhotoMeta]
    var albums: [Album]
}

/// Regression tests for the data-safety findings of the 2026-06-27 full audit.
/// Each test reproduces a way the app could silently lose, corrupt, or fabricate
/// user data, and pins the fix.
func dataSafetyAuditFixTests() {
    let fm = FileManager.default

    // MARK: - IncrementalScanner: a transient listing failure must not prune a folder

    test("scannerKeepsCachedPhotosWhenChangedBranchListingFails") {
        // The 'unchanged' branch already falls back to the cache on a listing
        // failure; the 'changed' branch did not — and it is the MORE likely branch
        // on a NAS blip (a failed dir-mtime read makes `unchanged` false). Dropping
        // the folder there prunes the user's photos + EXIF until the next scan.
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-scan-perm-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        let a = dir.appendingPathComponent("a.jpg")
        fm.createFile(atPath: a.path, contents: Data([0xFF, 0xD8, 0xFF, 0xE0]))

        let first = IncrementalScanner.scan(roots: [dir], knownMtimes: [:], cachedByFolder: [:])
        check(first.photos.count == 1, "setup: first scan should see 1 photo, got \(first.photos.count)")
        let cached = Dictionary(grouping: first.photos) { $0.folderURL.path }
        // Re-scan from the canonical folder URL the scanner emitted (contentsOfDirectory
        // resolves /var → /private/var), so the folder cache key matches by construction
        // — exactly how AppModel feeds roots+cache back from a prior scan.
        let canonicalRoot = first.photos.first?.folderURL ?? dir

        // Make the directory unlistable (opendir → EACCES, the transient-failure
        // stand-in) and force the CHANGED branch with non-matching mtimes. The
        // folder still exists, so its cached photos must survive.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        let second = IncrementalScanner.scan(roots: [canonicalRoot], knownMtimes: [:], cachedByFolder: cached)
        check(second.photos.count == 1,
              "changed-branch listing failure must keep cached photos, got \(second.photos.count)")
    }

    // MARK: - LibraryCache: clear() must not be resurrected by an in-flight save

    test("clearIsNotResurrectedByAPendingSave") {
        let tmp = fm.temporaryDirectory.appendingPathComponent("lumen-libcache-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        LibraryCache.directoryOverride = tmp
        defer { LibraryCache.directoryOverride = nil; try? fm.removeItem(at: tmp) }

        // Hold the serial save queue busy so the save is provably still pending
        // when clear() runs — that's the window where a clear could be undone.
        let gate = DispatchSemaphore(value: 0)
        LibraryCache.runOnSaveQueueForTesting { gate.wait() }

        let photo = Photo(url: URL(fileURLWithPath: "/x/a.jpg"), byteSize: 1, creationDate: nil, modificationDate: nil)
        LibraryCache.savePhotos([photo])   // enqueues a binary write behind the gate
        LibraryCache.clear()               // must serialize AFTER that queued save
        gate.signal()                      // release the queue
        LibraryCache.flushForTesting()     // wait for save + clear to finish

        let binURL = tmp.appendingPathComponent("library-cache.bin")
        check(!fm.fileExists(atPath: binURL.path),
              "clear() must not be undone by a save that was already queued")
    }

    // MARK: - DuplicateFinder: a mid-file read error must NOT be mistaken for EOF

    test("hashReadErrorYieldsNilNotPartialHash") {
        // On a NAS the connection can drop mid-file. Treating that as EOF would
        // hash partial bytes — two unrelated files that both fail to read collide
        // as a "duplicate", which can lead the user to delete a unique photo.
        struct ReadDropped: Error {}
        var calls = 0
        let h = DuplicateFinder.hash {
            calls += 1
            if calls == 1 { return Data("first megabyte".utf8) }
            throw ReadDropped()
        }
        checkNil(h, "a read error must not produce a hash")
    }

    test("hashEmptyChunkIsRealEOFAndMatchesSingleShot") {
        // An empty (or nil) read is genuine EOF: finalize the hash. Chunked and
        // single-shot reads of the same bytes must produce the identical hash.
        var chunked = 0
        let multi = DuplicateFinder.hash {
            chunked += 1
            switch chunked {
            case 1: return Data("abc".utf8)
            case 2: return Data("def".utf8)
            default: return Data()        // EOF
            }
        }
        var done = false
        let single = DuplicateFinder.hash {
            if done { return nil }        // nil is EOF too
            done = true
            return Data("abcdef".utf8)
        }
        checkNotNil(multi, "a clean EOF must finalize a hash")
        checkEqual(multi, single, "chunked and single-shot hashes of the same bytes must match")
    }

    // MARK: - MetadataStore: a failed migration must keep library.json (no data loss)

    test("legacyMigrationSucceedsRenamesBackupAndImports") {
        let dir = try Fixtures.tempDir("MetaMigrateOK")
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("library.json")
        var meta = PhotoMeta(); meta.favorite = true; meta.rating = 4
        let payload = LegacyLibraryPayload(items: ["/photos/a.jpg": meta],
                                           albums: [Album(id: UUID(), name: "Trip", photoPaths: ["/photos/a.jpg"])])
        try JSONEncoder().encode(payload).write(to: legacy)

        let store = MetadataStore(queue: try AppDatabase.inMemoryQueue())
        let ok = store.migrateLegacy(from: legacy)
        check(ok, "migration should succeed on a writable DB")
        check(!fm.fileExists(atPath: legacy.path), "library.json should be renamed away after success")
        check(fm.fileExists(atPath: legacy.appendingPathExtension("bak").path), ".bak backup should exist after success")
        checkEqual(store.meta(for: "/photos/a.jpg").rating, 4, "migrated metadata should be in the store")
        check(store.albums.contains { $0.name == "Trip" }, "migrated album should be present")
    }

    test("legacyMigrationKeepsJSONWhenDBWriteFails") {
        // The bug: library.json was renamed to .bak even when persistAll() failed,
        // so a full disk / read-only DB silently lost the user's favorites, ratings,
        // labels and albums. A failed write must KEEP library.json for a retry.
        let dir = try Fixtures.tempDir("MetaMigrateFail")
        defer { try? FileManager.default.removeItem(at: dir) }

        // A real on-disk DB with the schema, reopened read-only so every write throws.
        let dbPath = dir.appendingPathComponent("lumen.sqlite").path
        do { try AppDatabase.migrate(try DatabaseQueue(path: dbPath)) }
        var config = Configuration()
        config.readonly = true
        let readOnly = try DatabaseQueue(path: dbPath, configuration: config)

        let legacy = dir.appendingPathComponent("library.json")
        var meta = PhotoMeta(); meta.favorite = true; meta.rating = 4
        let payload = LegacyLibraryPayload(items: ["/photos/a.jpg": meta], albums: [])
        try JSONEncoder().encode(payload).write(to: legacy)

        let store = MetadataStore(queue: readOnly)
        let ok = store.migrateLegacy(from: legacy)
        check(!ok, "migration must report failure when the DB write fails")
        check(fm.fileExists(atPath: legacy.path), "library.json must be KEPT on a failed migration (retry next launch)")
        check(!fm.fileExists(atPath: legacy.appendingPathExtension("bak").path),
              "must NOT rename to .bak when the write failed")
    }

    // MARK: - ImageEditor: edits must carry EXIF/GPS forward (capture date, location)

    test("processPreservesGPSAndCaptureDate") {
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-editmeta-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A source JPEG carrying capture date + GPS.
        let srcURL = dir.appendingPathComponent("src.jpg")
        let cg = solidImage(width: 120, height: 90)
        guard let dst = CGImageDestinationCreateWithURL(srcURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            check(false, "could not create source image destination"); return
        }
        let srcProps: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 127.0, kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ]
        CGImageDestinationAddImage(dst, cg, srcProps as CFDictionary)
        check(CGImageDestinationFinalize(dst), "could not write source JPEG")

        // Resize-edit it to a new file.
        let destURL = dir.appendingPathComponent("out.jpg")
        let edit = ImageEditor.Edit(cropNorm: nil, targetWidth: 50, targetHeight: nil)
        check(ImageEditor.process(source: srcURL, edit: edit, to: destURL), "process failed")

        // The edited copy must still carry capture date + GPS.
        guard let outSrc = CGImageSourceCreateWithURL(destURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(outSrc, 0, nil) as? [CFString: Any] else {
            check(false, "could not read edited image"); return
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        checkEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2020:01:02 03:04:05",
                   "capture date dropped on edit")
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        checkNotNil(gps, "GPS dropped on edit")
        checkEqual(gps?[kCGImagePropertyGPSLatitude] as? Double, 37.5, "GPS latitude dropped on edit")
    }
}

/// A solid-color opaque RGBA image for building test fixtures.
private func solidImage(width: Int, height: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}
