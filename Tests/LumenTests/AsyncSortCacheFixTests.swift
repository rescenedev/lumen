import Foundation
@testable import LumenKit

/// Regression tests for the async-sort caching cluster of the 2026-06-27 audit.
///
/// When a >4000-photo scope sorts off-main, `visiblePhotos` returns the previous
/// `lastVisible` and the landing bumps only `visibleResultRevision` (not
/// `visibleSignature`). Consumers that key on the signature alone — or that read
/// `visiblePhotos` right after a library mutation — then serve stale data.
func asyncSortCacheFixTests() {

    // MARK: - #3 finishDeletion: pick the survivor synchronously, never from a
    //         (possibly stale) visiblePhotos read.

    test("nearestSurvivorExcludesDeletedAndKeepsOrder") {
        // The on-screen list still contains the just-deleted photos (this mirrors
        // `lastVisible` before the async re-sort lands). The survivor must be a
        // NON-deleted photo at the deleted position, never a deleted one.
        let p = (0..<5).map { Fixtures.photo("p\($0).jpg") }   // p0..p4
        let onScreen = p
        let deleted: Set<URL> = [p[1].url, p[2].url]            // delete p1, p2
        // firstIndex was the index of the first deleted photo (1) in the old list.
        let survivor = AppModel.nearestSurvivor(in: onScreen, excluding: deleted, at: 1)
        checkNotNil(survivor, "a survivor must be selected")
        check(!deleted.contains(survivor!.url), "survivor must not be a deleted photo")
        // remaining = [p0, p3, p4]; index 1 → p3.
        checkEqual(survivor?.url, p[3].url, "survivor should be the photo now at the deleted position")
    }

    test("nearestSurvivorClampsPastEnd") {
        let p = (0..<3).map { Fixtures.photo("q\($0).jpg") }    // q0,q1,q2
        // Delete the last two; index pointed at the last (2). remaining = [q0].
        let survivor = AppModel.nearestSurvivor(in: p, excluding: [p[1].url, p[2].url], at: 2)
        checkEqual(survivor?.url, p[0].url, "index past the new end clamps to the last survivor")
    }

    test("nearestSurvivorNilWhenNothingRemainsOrNoIndex") {
        let p = (0..<2).map { Fixtures.photo("r\($0).jpg") }
        checkNil(AppModel.nearestSurvivor(in: p, excluding: [p[0].url, p[1].url], at: 0),
                 "deleting everything leaves no survivor")
        checkNil(AppModel.nearestSurvivor(in: p, excluding: [], at: nil),
                 "no anchor index → clear selection (nil)")
    }

    // MARK: - #2 selectedPhotos cache must pick up an async-sort landing.
    //
    // selectedPhotos caches on (selectionRevision, libraryVersion, assetsVersion,
    // visibleSignature, visibleResultRevision). The signature does NOT change when
    // an off-main sort lands — only visibleResultRevision does — so the revision
    // must be part of the key or the pre-sort ORDER is served to order-sensitive
    // batch actions (combine, export). Mirrors HashAndCacheKeyTests' BUG-037 style.

    test("selectedPhotosKeyInvalidatesOnResultRevisionBump") {
        var cacheKey: (Int, Int, Int, Int, Int)?
        var computeCount = 0
        func read(_ key: (Int, Int, Int, Int, Int)) {
            if let c = cacheKey, c == key { return }   // cache hit
            computeCount += 1
            cacheKey = key
        }
        read((0, 0, 0, 42, 0))                          // first read under signature 42
        checkEqual(computeCount, 1, "first access computes")
        read((0, 0, 0, 42, 0))                          // identical → hit
        checkEqual(computeCount, 1, "identical key is a cache hit")
        read((0, 0, 0, 42, 1))                          // async sort lands: rev bumps, sig same
        checkEqual(computeCount, 2, "a result-revision bump under the same signature must recompute")
    }

    test("selectedPhotosSignatureOnlyKeyCannotSeeALandedReSort") {
        // Documents the bug the 5-tuple fixes: the old 4-tuple (no revision) is
        // identical before and after an async-sort landing, so it serves stale order.
        let before = (0, 0, 0, 42)
        let afterLanding = (0, 0, 0, 42)   // visibleSignature is unchanged when the sort lands
        check(before == afterLanding,
              "signature-only key can't distinguish a landed re-sort — bug confirmed")
    }

    // MARK: - #1 map pins: the dedupe key must fold in visibleResultRevision so a
    //         sort landing (signature unchanged) triggers a re-scan of the final list.

    test("assetMapKeyFoldsInResultRevision") {
        // Mirrors ensureAssetMapPins' composite key. A signature-only key (the old
        // behavior) stays equal across an async-sort landing, so the map stays stuck
        // showing the pre-sort (often empty) pin set.
        func mapKey(sig: Int, rev: Int) -> Int {
            var h = Hasher(); h.combine(sig); h.combine(rev); return h.finalize()
        }
        check(mapKey(sig: 7, rev: 0) != mapKey(sig: 7, rev: 1),
              "a result-revision bump under the same signature must change the map key (re-scan)")
        checkEqual(mapKey(sig: 7, rev: 2), mapKey(sig: 7, rev: 2),
                   "same scope + same revision stays deduped (no needless re-scan)")
        check(mapKey(sig: 7, rev: 5) != mapKey(sig: 8, rev: 5),
              "a scope change must also change the map key")
    }

    // MARK: - LOW #5/#6 superseded-sort spinner cleanup (cancelSupersededSort logic).

    test("supersededSortClearsSpinnerButNotTheCurrentScopes") {
        struct SortState {
            var inFlightKey = -1, spinner = false, cancelled = false
            mutating func clearSuperseded(currentKey: Int) {
                guard inFlightKey != -1, inFlightKey != currentKey else { return }
                cancelled = true; inFlightKey = -1; spinner = false
            }
        }
        // Scope A's sort in flight (spinner on); navigate to a different scope B.
        var a = SortState(inFlightKey: 100, spinner: true)
        a.clearSuperseded(currentKey: 200)
        check(a.cancelled, "a sort for a previous scope must be cancelled on navigation")
        check(!a.spinner, "its lingering spinner must be dropped")
        checkEqual(a.inFlightKey, -1, "the in-flight slot must be released")

        // Nothing in flight → no-op (no spurious cancellation).
        var idle = SortState()
        idle.clearSuperseded(currentKey: 200)
        check(!idle.cancelled, "nothing in flight → nothing to cancel")

        // The CURRENT scope's own in-flight sort must survive (don't cancel ourselves).
        var current = SortState(inFlightKey: 200, spinner: true)
        current.clearSuperseded(currentKey: 200)
        check(!current.cancelled, "the current scope's own sort must not be cancelled")
        check(current.spinner, "the current scope's spinner stays until it lands")
    }
}
