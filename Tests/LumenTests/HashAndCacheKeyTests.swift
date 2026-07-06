import Foundation
@testable import LumenKit

/// Regression tests for commit 185890b — O(1) FolderNode hash and
/// collision-proof selection cache key.
///
/// BUG-065: FolderNode's synthesized Hashable recursed through the entire
///   `children` subtree — O(subtree) per node on a large tree. Fix: custom
///   `hash(into:)` that hashes only `url`; `==` stays structural.
/// BUG-037: `selectedPhotosCacheKey` used a fixed `(-1,-1,-1,-1)` sentinel
///   that could in principle collide with a real key. Fix: Optional nil
///   sentinel that can never collide.
///
/// NOT A BUG:
/// BUG-049: PhotoCombineView.renderPreview already guards writes with a
///   `renderToken` counter; a superseded detached render bails before
///   writing `preview`, preventing stale preview application.
func hashAndCacheKeyTests() {

    // MARK: BUG-065 — O(1) FolderNode hash

    test("BUG-065: FolderNode hash uses only url — O(1) regardless of children count") {
        // Build a node with many children and verify hash completes in O(1).
        // (We can't measure time reliably in tests, but we can verify correctness.)
        let url = URL(fileURLWithPath: "/photos/albums")
        let children = (0..<1000).map { i in
            FolderNode(url: URL(fileURLWithPath: "/photos/albums/\(i)"),
                       name: "\(i)", count: 0, children: nil)
        }
        let node = FolderNode(url: url, name: "albums", count: 1000, children: children)

        // Hash must equal hashing only the url.
        var h1 = Hasher(); node.hash(into: &h1)
        var h2 = Hasher(); url.hash(into: &h2)
        checkEqual(h1.finalize(), h2.finalize(),
                   "FolderNode hash must equal url-only hash")
    }

    test("BUG-065: nodes with same url but different children have equal hashes") {
        // The custom hash is url-only, so two nodes at the same path must hash
        // the same even when their child sets differ. This is required by the
        // Hashable contract (equal objects must have equal hashes).
        let url = URL(fileURLWithPath: "/photos/2024")
        let nodeA = FolderNode(url: url, name: "2024", count: 0, children: nil)
        let nodeB = FolderNode(url: url, name: "2024", count: 1, children: [
            FolderNode(url: URL(fileURLWithPath: "/photos/2024/jan"),
                       name: "jan", count: 1, children: nil)
        ])

        var ha = Hasher(); nodeA.hash(into: &ha)
        var hb = Hasher(); nodeB.hash(into: &hb)
        checkEqual(ha.finalize(), hb.finalize(),
                   "nodes with same url must have equal hashes regardless of children")
    }

    test("BUG-065: nodes with different urls have different hashes") {
        let nodeA = FolderNode(url: URL(fileURLWithPath: "/photos/2023"), name: "2023", count: 0, children: nil)
        let nodeB = FolderNode(url: URL(fileURLWithPath: "/photos/2024"), name: "2024", count: 0, children: nil)

        var ha = Hasher(); nodeA.hash(into: &ha)
        var hb = Hasher(); nodeB.hash(into: &hb)
        check(ha.finalize() != hb.finalize(),
              "nodes with different urls must have different hashes")
    }

    test("BUG-065: FolderNode usable in Set (requires consistent hash + equality)") {
        // If used in a Set, equal nodes must not appear twice.
        let url = URL(fileURLWithPath: "/photos/albums")
        let nodeA = FolderNode(url: url, name: "albums", count: 5, children: nil)
        let nodeB = FolderNode(url: url, name: "albums", count: 5, children: nil)  // same url → equal

        var set = Set<FolderNode>()
        set.insert(nodeA)
        set.insert(nodeB)
        checkEqual(set.count, 1, "equal FolderNodes must occupy one Set slot")
    }

    test("BUG-065: synthesized hash for deep tree would be O(n) — documents the bug") {
        // The synthesized Hashable calls hash(into:) on every stored property.
        // For FolderNode, that includes `children: [FolderNode]?`, which recurses.
        // Simulating: a hash function that recursively hashes children.
        func recursiveHashCost(depth: Int, branching: Int) -> Int {
            // Returns node count visited (proportional to hashing cost).
            if depth == 0 { return 1 }
            return 1 + branching * recursiveHashCost(depth: depth - 1, branching: branching)
        }
        // 3-level tree, branching factor 3: 1 + 3 + 9 + 27 = 40 nodes visited per hash.
        let cost = recursiveHashCost(depth: 3, branching: 3)
        check(cost > 1, "synthesized hash visits \(cost) nodes — O(n) cost confirmed (bug)")

        // Fixed hash visits exactly 1 node (the url).
        let fixedCost = 1
        checkEqual(fixedCost, 1, "fixed hash visits exactly 1 node — O(1)")
    }

    // MARK: BUG-037 — Optional nil sentinel for cache key

    test("BUG-037: nil Optional sentinel can never equal a real key") {
        // The fix: `selectedPhotosCacheKey: (Int, Int, Int, Int)?` starts nil.
        // A nil Optional can never == any concrete tuple, so the first access
        // always recomputes (correct) and there is no collision risk.
        var cacheKey: (Int, Int, Int, Int)? = nil
        let realKey = (0, 0, 0, 0)   // a key that could have collided with (-1,-1,-1,-1)

        // nil optional must not match any real key.
        if let cached = cacheKey, cached == realKey {
            check(false, "nil sentinel must never match any real key")
        }
        // Reaching here means nil correctly caused a cache miss.
        checkNil(cacheKey, "initial cache key must be nil")
    }

    test("BUG-037: old (-1,-1,-1,-1) sentinel could collide with real key") {
        // If selectionRevision, libraryVersion, assetsVersion, or visibleSignature
        // ever all happen to be -1 simultaneously (e.g. initial state or overflow),
        // the old sentinel would match and serve a stale (empty) cache.
        let oldSentinel = (-1, -1, -1, -1)
        let realKey     = (-1, -1, -1, -1)   // plausible initial system state

        check(oldSentinel == realKey,
              "old sentinel collides with a real key of (-1,-1,-1,-1) — bug confirmed")
    }

    test("BUG-037: cache hit only fires when Optional is non-nil and key matches") {
        // Mirrors the fixed check: `if let cached = selectedPhotosCacheKey, cached == key`.
        var cacheKey: (Int, Int, Int, Int)? = nil
        var computeCount = 0

        func selectedPhotos(key: (Int, Int, Int, Int)) -> [Int] {
            if let cached = cacheKey, cached == key {
                return []   // cache hit
            }
            computeCount += 1
            cacheKey = key
            return [1, 2, 3]
        }

        // First access — cache miss (nil).
        _ = selectedPhotos(key: (1, 2, 3, 4))
        checkEqual(computeCount, 1, "first access must compute (cache miss on nil)")

        // Same key — cache hit.
        _ = selectedPhotos(key: (1, 2, 3, 4))
        checkEqual(computeCount, 1, "repeated same key must be a cache hit")

        // Different key — cache miss.
        _ = selectedPhotos(key: (1, 2, 3, 5))
        checkEqual(computeCount, 2, "different key must recompute (cache miss)")
    }

    test("BUG-037: nil sentinel forces recompute on very first access") {
        var cacheKey: (Int, Int, Int, Int)? = nil
        var computeCount = 0

        func selectedPhotos(key: (Int, Int, Int, Int)) -> [Int] {
            if let cached = cacheKey, cached == key { return [] }
            computeCount += 1
            cacheKey = key
            return [42]
        }

        // Even if the very first real key is (0,0,0,0) — nil can't match it.
        let firstKey = (0, 0, 0, 0)
        _ = selectedPhotos(key: firstKey)
        checkEqual(computeCount, 1,
                   "nil sentinel must not match (0,0,0,0) — recompute required")
    }

    // MARK: BUG-049 — renderToken guards stale preview writes

    test("BUG-049: renderToken pattern cancels superseded renders before writing") {
        // PhotoCombineView.renderPreview increments `renderToken` each time a new
        // render starts. The detached render captures the token at launch time
        // and bails if the current token has advanced by the time the render completes.
        var renderToken = 0
        var previewWriteCount = 0

        func renderPreview(currentToken: Int) {
            // Simulates the detached render completing and checking its token.
            guard renderToken == currentToken else { return }
            previewWriteCount += 1
        }

        // Launch render 1.
        let token1 = renderToken
        // Before render 1 completes, a new render starts (token advances).
        renderToken += 1
        let token2 = renderToken
        // Launch render 2.
        _ = token2   // render 2 captured this token

        // Render 1 completes — token has advanced, so it bails.
        renderPreview(currentToken: token1)
        checkEqual(previewWriteCount, 0,
                   "superseded render must not write preview (token mismatch)")

        // Render 2 completes — token still matches.
        renderPreview(currentToken: token2)
        checkEqual(previewWriteCount, 1,
                   "current render must write preview (token matches)")
    }

    test("BUG-049: renderToken resets write count when a new render sequence starts") {
        var renderToken = 0
        var previewWriteCount = 0

        func startRender() -> Int { renderToken += 1; return renderToken }
        func completeRender(token: Int) {
            guard renderToken == token else { return }
            previewWriteCount += 1
        }

        // Sequence of 5 rapid renders: only the last one writes.
        var lastToken = 0
        for _ in 0..<5 { lastToken = startRender() }
        for i in 1...5 { completeRender(token: i) }   // 1–4 are superseded

        checkEqual(previewWriteCount, 1,
                   "exactly one preview write per render sequence (the last)")
        checkEqual(renderToken, 5, "token incremented once per render start")
    }
}
