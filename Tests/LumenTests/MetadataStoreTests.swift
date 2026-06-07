import Foundation
@testable import LumenKit

/// Tests run against an isolated in-memory SQLite database (never the user's real
/// `lumen.sqlite`). This is the highest-stakes surface: it owns favorites,
/// ratings, labels, tags and albums, and must survive a restart intact.
func metadataStoreTests() {
    func makeStore() throws -> MetadataStore {
        MetadataStore(queue: try AppDatabase.inMemoryQueue())
    }

    test("defaultMetaIsEmpty") {
        let store = try makeStore()
        check(store.meta(for: "/x.jpg").isEmpty)
        check(store.items.isEmpty)
    }

    test("updateStoresMeta") {
        let store = try makeStore()
        store.update("/x.jpg") { $0.favorite = true; $0.rating = 5; $0.label = .red }
        let meta = store.meta(for: "/x.jpg")
        check(meta.favorite)
        checkEqual(meta.rating, 5)
        checkEqual(meta.label, .red)
    }

    test("clearingAllFieldsRemovesRow") {
        let store = try makeStore()
        store.update("/x.jpg") { $0.favorite = true }
        checkEqual(store.items.count, 1)
        store.update("/x.jpg") { $0.favorite = false }   // back to empty → deleted
        check(store.items.isEmpty)
    }

    test("rejectedRoundTrips") {
        let queue = try AppDatabase.inMemoryQueue()
        let first = MetadataStore(queue: queue)
        first.update("/cull.jpg") { $0.rejected = true }
        check(first.meta(for: "/cull.jpg").rejected)
        // Survives a reopen (column persisted via the v2 migration).
        let reopened = MetadataStore(queue: queue)
        check(reopened.meta(for: "/cull.jpg").rejected)
        // Clearing it removes the now-empty row.
        reopened.update("/cull.jpg") { $0.rejected = false }
        check(reopened.meta(for: "/cull.jpg").isEmpty)
    }

    test("persistsAcrossStoreInstances") {
        let queue = try AppDatabase.inMemoryQueue()
        let first = MetadataStore(queue: queue)
        first.update("/keep.jpg") { $0.favorite = true; $0.tags = ["beach", "2024"] }
        let album = first.addAlbum(named: "Summer")
        first.addToAlbum(album.id, paths: ["/keep.jpg"])

        // A fresh store over the same DB must read everything back.
        let reopened = MetadataStore(queue: queue)
        check(reopened.meta(for: "/keep.jpg").favorite)
        checkEqual(reopened.meta(for: "/keep.jpg").tags, ["beach", "2024"])
        checkEqual(reopened.albums.count, 1)
        check(reopened.albums.first?.name == "Summer")
        check(reopened.albums.first?.photoPaths == ["/keep.jpg"])
    }

    test("allTagsCountsAndSorts") {
        let store = try makeStore()
        store.update("/a.jpg") { $0.tags = ["sky", "beach"] }
        store.update("/b.jpg") { $0.tags = ["beach"] }
        let tags = store.allTags()
        checkEqual(tags.map(\.tag), ["beach", "sky"])   // natural sort
        check(tags.first { $0.tag == "beach" }?.count == 2)
    }

    // MARK: - Albums

    test("addRenameDeleteAlbum") {
        let store = try makeStore()
        let album = store.addAlbum(named: "Trip")
        checkEqual(store.albums.count, 1)
        store.renameAlbum(album.id, to: "Roadtrip")
        check(store.albums.first?.name == "Roadtrip")
        store.deleteAlbum(album.id)
        check(store.albums.isEmpty)
    }

    test("addToAlbumDeduplicates") {
        let store = try makeStore()
        let album = store.addAlbum(named: "A")
        store.addToAlbum(album.id, paths: ["/1.jpg", "/2.jpg"])
        store.addToAlbum(album.id, paths: ["/2.jpg", "/3.jpg"])   // /2 already present
        check(store.albums.first?.photoPaths == ["/1.jpg", "/2.jpg", "/3.jpg"])
    }

    test("removeFromAlbum") {
        let store = try makeStore()
        let album = store.addAlbum(named: "A")
        store.addToAlbum(album.id, paths: ["/1.jpg", "/2.jpg"])
        store.removeFromAlbum(album.id, paths: ["/1.jpg"])
        check(store.albums.first?.photoPaths == ["/2.jpg"])
    }

    // MARK: - Path remapping (rename / move / delete)

    test("renameMovesMetaAndAlbumMembership") {
        let store = try makeStore()
        store.update("/old.jpg") { $0.favorite = true }
        let album = store.addAlbum(named: "A")
        store.addToAlbum(album.id, paths: ["/old.jpg"])

        store.rename(from: "/old.jpg", to: "/new.jpg")
        check(store.meta(for: "/new.jpg").favorite)
        check(store.meta(for: "/old.jpg").isEmpty)
        check(store.albums.first?.photoPaths == ["/new.jpg"])
    }

    test("renamePrefixRemapsFolder") {
        let store = try makeStore()
        store.update("/Photos/2023/a.jpg") { $0.rating = 4 }
        store.update("/Photos/2023/sub/b.jpg") { $0.rating = 5 }
        store.update("/Other/c.jpg") { $0.rating = 1 }   // outside the prefix

        store.renamePrefix(from: "/Photos/2023", to: "/Photos/Trip")
        checkEqual(store.meta(for: "/Photos/Trip/a.jpg").rating, 4)
        checkEqual(store.meta(for: "/Photos/Trip/sub/b.jpg").rating, 5)
        checkEqual(store.meta(for: "/Other/c.jpg").rating, 1)        // untouched
        check(store.meta(for: "/Photos/2023/a.jpg").isEmpty)         // old path gone
    }

    test("forgetDropsMetaAndAlbumMembership") {
        let store = try makeStore()
        store.update("/gone.jpg") { $0.favorite = true }
        let album = store.addAlbum(named: "A")
        store.addToAlbum(album.id, paths: ["/gone.jpg", "/stay.jpg"])

        store.forget(paths: ["/gone.jpg"])
        check(store.meta(for: "/gone.jpg").isEmpty)
        check(store.albums.first?.photoPaths == ["/stay.jpg"])
    }

    test("renamePrefixSurvivesReopen") {
        // The SQL substr() remap must match the in-memory mirror after reload.
        let queue = try AppDatabase.inMemoryQueue()
        let store = MetadataStore(queue: queue)
        store.update("/Photos/2023/a.jpg") { $0.rating = 4 }
        store.renamePrefix(from: "/Photos/2023", to: "/Photos/Trip")

        let reopened = MetadataStore(queue: queue)
        checkEqual(reopened.meta(for: "/Photos/Trip/a.jpg").rating, 4)
        check(reopened.meta(for: "/Photos/2023/a.jpg").isEmpty)
    }
}
