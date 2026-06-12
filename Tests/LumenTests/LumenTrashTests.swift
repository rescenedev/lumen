import Foundation
@testable import LumenKit

/// LumenTrash staging/cleanup against real temp directories, plus the
/// forget() scale fix (Set membership + chunked deletes) it relies on.
func lumenTrashTests() {
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenTrashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func makeFile(_ name: String, in dir: URL, contents: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    test("stageMovesFileIntoTrashBatch") {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("IMG_001.jpg", in: root, contents: "photo-bytes")

        let staged = try LumenTrash.stage(file, under: root, stamp: "2026-06-12 10.00.00")

        check(!FileManager.default.fileExists(atPath: file.path), "original should be gone")
        check(FileManager.default.fileExists(atPath: staged.path), "staged copy should exist")
        check(staged.path.contains("/.LumenTrash/2026-06-12 10.00.00/"),
              "staged path should sit in the batch dir: \(staged.path)")
        checkEqual(try String(contentsOf: staged, encoding: .utf8), "photo-bytes")
    }

    test("stageSuffixesOnNameCollision") {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = try makeFile("IMG_001.jpg", in: root, contents: "a")
        let b = try makeFile("IMG_001.jpg", in: sub, contents: "b")

        let stagedA = try LumenTrash.stage(a, under: root, stamp: "s")
        let stagedB = try LumenTrash.stage(b, under: root, stamp: "s")

        checkEqual(stagedA.lastPathComponent, "IMG_001.jpg")
        checkEqual(stagedB.lastPathComponent, "IMG_001 2.jpg")
        checkEqual(try String(contentsOf: stagedB, encoding: .utf8), "b")
    }

    test("rootPicksDeepestContainingRoot") {
        let outer = URL(filePath: "/Volumes/nas/photos", directoryHint: .isDirectory)
        let inner = URL(filePath: "/Volumes/nas/photos/2024", directoryHint: .isDirectory)
        let file = URL(filePath: "/Volumes/nas/photos/2024/trip/IMG.jpg", directoryHint: .notDirectory)

        checkEqual(LumenTrash.root(for: file, roots: [outer, inner])?.path, inner.path)
        checkEqual(LumenTrash.root(for: file, roots: [outer])?.path, outer.path)
        check(LumenTrash.root(for: URL(filePath: "/elsewhere/IMG.jpg"), roots: [outer, inner]) == nil,
              "file outside every root should resolve to nil")
    }

    test("cleanupPurgesOldBatchesKeepsFreshOnes") {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try makeFile("old.jpg", in: root)
        let fresh = try makeFile("fresh.jpg", in: root)
        let stagedOld = try LumenTrash.stage(old, under: root, stamp: "old-batch")
        let stagedFresh = try LumenTrash.stage(fresh, under: root, stamp: "fresh-batch")

        // Backdate the old batch dir 31 days; the fresh one stays current.
        let oldDate = Date(timeIntervalSinceNow: -31 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate],
                                              ofItemAtPath: stagedOld.deletingLastPathComponent().path)

        LumenTrash.cleanup(roots: [root])

        check(!FileManager.default.fileExists(atPath: stagedOld.path), "old batch should be purged")
        check(FileManager.default.fileExists(atPath: stagedFresh.path), "fresh batch should survive")
    }

    test("cleanupRemovesEmptyTrashFolder") {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("only.jpg", in: root)
        let staged = try LumenTrash.stage(file, under: root, stamp: "batch")
        let oldDate = Date(timeIntervalSinceNow: -31 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate],
                                              ofItemAtPath: staged.deletingLastPathComponent().path)

        LumenTrash.cleanup(roots: [root])

        let trashDir = root.appendingPathComponent(LumenTrash.folderName)
        check(!FileManager.default.fileExists(atPath: trashDir.path),
              ".LumenTrash itself should vanish once empty")
        // And a root with no .LumenTrash at all is a silent no-op.
        LumenTrash.cleanup(roots: [root])
    }

    test("forgetAtScaleIsFastAndCapturesMemberships") {
        let store = MetadataStore(queue: try AppDatabase.inMemoryQueue())
        let album = store.addAlbum(named: "Big")
        let all = (0..<20_000).map { "/photos/IMG_\($0).jpg" }
        store.addToAlbum(album.id, paths: all)
        store.update(all[0]) { $0.favorite = true }

        let doomed = Array(all[5_000..<15_000])
        let memberships = store.albumMemberships(forPaths: doomed)
        checkEqual(memberships[album.id]?.count, 10_000)

        let t0 = Date()
        store.forget(paths: doomed)
        let ms = -t0.timeIntervalSinceNow * 1000

        let got = store.albums.first(where: { $0.id == album.id })!.photoPaths
        checkEqual(got.count, 10_000)
        checkEqual(got.first, "/photos/IMG_0.jpg")
        checkEqual(got.last, "/photos/IMG_19999.jpg")
        check(store.meta(for: all[0]).favorite, "untouched meta should survive forget")
        print("      · forget 10k of 20k: \(Int(ms))ms")
        check(ms < 2_000, "forget at 10k scale took \(Int(ms))ms")

        // Restore path used by undo: addToAlbum re-attaches the captured membership.
        store.addToAlbum(album.id, paths: memberships[album.id] ?? [])
        checkEqual(store.albums.first(where: { $0.id == album.id })!.photoPaths.count, 20_000)
    }
}
