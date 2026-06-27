import Foundation
@testable import LumenKit

/// Regression tests for the main-thread O(n) recompute findings of the audit.
/// (geotaggedPhotos caching and PhotoMapView's dead [Pin] allocation are
/// AppModel/SwiftUI-internal and covered by build + the existing cache-key style
/// tests; recentOperations is the one with a real isolated seam.)
func perfAuditFixTests() {

    // recentOperations must read the affected count from its own column (no payload
    // decode), and that count must survive a store reload.
    test("recentOperationsAffectedCountPersistsAcrossReload") {
        let queue = try AppDatabase.inMemoryQueue()
        let store = MetadataStore(queue: queue)
        store.update(paths: ["/a.jpg", "/b.jpg", "/c.jpg", "/d.jpg"],
                     logAs: (.rating, "Rated ★3")) { $0.rating = 3 }

        checkEqual(store.recentOperations().first?.affectedCount, 4,
                   "affected count comes straight from the column")

        // Reopen against the same DB: the count is persisted, not recomputed from
        // a payload (which the history view no longer decodes).
        let reloaded = MetadataStore(queue: queue)
        checkEqual(reloaded.recentOperations().first?.affectedCount, 4,
                   "affected count survives a reload (read from the column)")
    }

    // Format.dateString now uses the cached DateFormatter (per-row on table scroll)
    // and must render identically to the previous Date.formatted() call.
    test("dateStringUsesCachedFormatterWithUnchangedOutput") {
        let d = Fixtures.date("2026-05-09T15:13:00Z")
        checkEqual(Format.dateString(d), Format.date.string(from: d),
                   "dateString must use the cached medium/short DateFormatter")
        checkEqual(Format.dateString(d), d.formatted(date: .abbreviated, time: .shortened),
                   "output must be unchanged from the previous .formatted() rendering")
        checkEqual(Format.dateString(nil), "—", "nil renders as an em dash")
    }
}
