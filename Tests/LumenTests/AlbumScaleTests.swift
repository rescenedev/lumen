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
