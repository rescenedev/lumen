import Foundation
@testable import LumenKit

/// Album operations at library scale — correctness plus generous time bounds
/// so a quadratic regression (the bug these caught) fails the suite loudly.
func albumScaleTests() {
    func makeStore() throws -> MetadataStore {
        MetadataStore(queue: try AppDatabase.inMemoryQueue())
    }
    func paths(_ range: Range<Int>) -> [String] { range.map { "/photos/IMG_\($0).jpg" } }

    test("addToAlbumAtScaleIsFastAndCorrect") {
        let store = try makeStore()
        let album = store.addAlbum(named: "Big")

        // Seed 20k, then add 10k more (5k overlap → only 5k actually new).
        let t0 = Date()
        store.addToAlbum(album.id, paths: paths(0..<20_000))
        store.addToAlbum(album.id, paths: paths(15_000..<25_000))
        let ms = -t0.timeIntervalSinceNow * 1000

        let got = store.albums.first(where: { $0.id == album.id })!.photoPaths
        checkEqual(got.count, 25_000)
        checkEqual(got.first, "/photos/IMG_0.jpg")
        checkEqual(got.last, "/photos/IMG_24999.jpg")
        // Order: originals keep their position, new ones append.
        checkEqual(got[19_999], "/photos/IMG_19999.jpg")
        checkEqual(got[20_000], "/photos/IMG_20000.jpg")
        print("      · addToAlbum 20k+10k: \(Int(ms))ms")
        check(ms < 2_000, "addToAlbum at 25k scale took \(Int(ms))ms")
    }

    test("batchedMetaUpdateAtScaleIsFastAndCorrect") {
        let queue = try AppDatabase.inMemoryQueue()
        let store = MetadataStore(queue: queue)
        let all = paths(0..<20_000)

        let t0 = Date()
        store.update(paths: all) { $0.favorite = true }
        let ms = -t0.timeIntervalSinceNow * 1000

        checkEqual(store.items.count, 20_000)
        check(store.meta(for: all[0]).favorite)
        check(store.meta(for: all[19_999]).favorite)
        print("      · batched favorite 20k: \(Int(ms))ms")
        check(ms < 2_000, "batched favorite at 20k took \(Int(ms))ms")

        // No-op transform writes nothing; clearing back to empty deletes rows.
        store.update(paths: all) { $0.favorite = true }   // unchanged → skipped
        store.update(paths: all) { $0.favorite = false }  // now empty → deleted
        checkEqual(store.items.count, 0)

        // Persistence round-trip through the same DB.
        store.update(paths: Array(all[0..<10])) { $0.rating = 4 }
        let reloaded = MetadataStore(queue: queue)
        checkEqual(reloaded.meta(for: all[5]).rating, 4)
        checkEqual(reloaded.items.count, 10)
    }

    test("operationLogRecordsAndRevertsMetaChanges") {
        let queue = try AppDatabase.inMemoryQueue()
        let store = MetadataStore(queue: queue)
        let p = paths(0..<3)

        // Two logged actions: rate 4, then favorite.
        store.update(paths: p, logAs: (.rating, "Rated ★4")) { $0.rating = 4 }
        store.update(paths: p, logAs: (.favorite, "Favorited")) { $0.favorite = true }

        var log = store.recentOperations()
        checkEqual(log.count, 2)
        checkEqual(log[0].summary, "Favorited")        // newest first
        checkEqual(log[0].kind, .favorite)
        checkEqual(log[0].affectedCount, 3)
        checkEqual(log[1].summary, "Rated ★4")
        check(store.meta(for: p[0]).favorite)
        checkEqual(store.meta(for: p[0]).rating, 4)

        // Revert the favorite → rating 4 stays, favorite gone.
        let affected = store.undoOperation(log[0].id)
        checkEqual(Set(affected), Set(p))
        check(!store.meta(for: p[0]).favorite, "favorite should be reverted")
        checkEqual(store.meta(for: p[0]).rating, 4, "rating must survive the favorite revert")

        // Entry is marked undone and can't be reverted twice.
        log = store.recentOperations()
        check(log[0].undone)
        check(!store.canUndo(log[0].id))
        checkEqual(store.undoOperation(log[0].id).count, 0)

        // Revert the rating too → back to empty meta (row deleted).
        store.undoOperation(log[1].id)
        check(store.meta(for: p[0]).isEmpty, "all meta reverted")
        checkEqual(store.items.count, 0)
    }

    test("operationLogPersistsAndBoundsHugePayloads") {
        let queue = try AppDatabase.inMemoryQueue()
        let store = MetadataStore(queue: queue)

        // Below the cap: undoable + survives reload.
        store.update(paths: paths(0..<10), logAs: (.tag, "Tagged “trip”")) { $0.tags = ["trip"] }
        let reloaded = MetadataStore(queue: queue)
        let log = reloaded.recentOperations()
        checkEqual(log.count, 1)
        check(reloaded.canUndo(log[0].id), "small action should remain undoable after reload")

        // Above the cap: recorded but NOT undoable (no giant payload kept).
        let store2 = MetadataStore(queue: try AppDatabase.inMemoryQueue())
        let big = (0..<(MetadataStore.maxLoggedPaths + 1)).map { "/p/\($0).jpg" }
        store2.update(paths: big, logAs: (.favorite, "Favorited")) { $0.favorite = true }
        let big1 = store2.recentOperations()
        checkEqual(big1.count, 1)
        check(!store2.canUndo(big1[0].id), "oversized action must not be undoable")
        checkEqual(big1[0].affectedCount, 0, "oversized payload isn't stored")
    }

    test("removeFromAlbumAtScaleIsFastAndCorrect") {
        let store = try makeStore()
        let album = store.addAlbum(named: "Big")
        store.addToAlbum(album.id, paths: paths(0..<20_000))

        let t0 = Date()
        store.removeFromAlbum(album.id, paths: paths(5_000..<15_000))
        let ms = -t0.timeIntervalSinceNow * 1000

        let got = store.albums.first(where: { $0.id == album.id })!.photoPaths
        checkEqual(got.count, 10_000)
        check(!got.contains("/photos/IMG_5000.jpg"))
        check(got.contains("/photos/IMG_4999.jpg"))
        check(got.contains("/photos/IMG_15000.jpg"))
        print("      · removeFromAlbum 10k of 20k: \(Int(ms))ms")
        check(ms < 2_000, "removeFromAlbum at 20k scale took \(Int(ms))ms")
    }

    test("albumMembershipSurvivesReload") {
        let queue = try AppDatabase.inMemoryQueue()
        let store = MetadataStore(queue: queue)
        let album = store.addAlbum(named: "Persist")
        store.addToAlbum(album.id, paths: paths(0..<50))
        store.removeFromAlbum(album.id, paths: paths(0..<10))

        let reloaded = MetadataStore(queue: queue)
        let got = reloaded.albums.first(where: { $0.id == album.id })!.photoPaths
        checkEqual(got.count, 40)
        checkEqual(got.first, "/photos/IMG_10.jpg")   // order preserved after removal
        checkEqual(got.last, "/photos/IMG_49.jpg")
    }
}
