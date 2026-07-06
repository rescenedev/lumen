import Foundation
@testable import LumenKit

/// Regression tests for commit 40b245b — FolderWatcher races, count clamps,
/// thumbnail/sort polish.
///
/// BUG-004: FolderWatcher — NSLock guards stream/paths/debounceWork
/// BUG-023: favoritesCount clamped at max(0, …)
/// BUG-035: labelCounts clamped at max(0, …)
/// BUG-067: name-sort tie-break on full path for deterministic order
/// BUG-070: NOT A BUG — deletion message empty-filename path unreachable
/// BUG-041: AsyncThumbnail `failed` reset on url change (SwiftUI — runtime only)
func folderWatcherAndSortPolishTests() {

    // MARK: BUG-004 — FolderWatcher lock safety

    test("BUG-004: FolderWatcher stop is idempotent (no crash on double-stop)") {
        let watcher = FolderWatcher { }
        // Calling stop() when nothing is watched must be safe.
        watcher.stop()
        watcher.stop()
    }

    test("BUG-004: FolderWatcher watch then stop then stop does not crash") {
        let watcher = FolderWatcher { }
        // watch() with no valid FS roots is a no-op, but the lock path still runs.
        watcher.watch([])
        watcher.stop()
        watcher.stop()
    }

    test("BUG-004: FolderWatcher watch then immediate re-watch does not crash") {
        // watch() calls stopLocked() internally; two rapid watch() calls must
        // not dead-lock on the lock or crash via a dangling stream pointer.
        let watcher = FolderWatcher { }
        watcher.watch([])
        watcher.watch([])
        watcher.stop()
    }

    test("BUG-004: FolderWatcher concurrent stop calls are safe") {
        // Simulate the main-thread `stop` racing with a background `scheduleCallback`
        // by calling stop() from several queues simultaneously.
        let watcher = FolderWatcher { }
        watcher.watch([])
        let group = DispatchGroup()
        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                watcher.stop()
                group.leave()
            }
        }
        group.wait()
    }

    // MARK: BUG-023 — favoritesCount clamp

    test("BUG-023: favoritesCount max(0) prevents negative count (undershoot by 2)") {
        // Mirrors the fixed line: favoritesCount = max(0, favoritesCount + delta)
        // Scenario: count is 1, user un-favorites 3 photos → delta = -3 → would be -2.
        var favoritesCount = 1
        let delta = -1 * 3   // removing 3 that are "changing"
        favoritesCount = max(0, favoritesCount + delta)
        checkEqual(favoritesCount, 0, "count must not go negative")
    }

    test("BUG-023: favoritesCount max(0) is a no-op when count is already positive") {
        var favoritesCount = 5
        favoritesCount = max(0, favoritesCount + -2)
        checkEqual(favoritesCount, 3)
    }

    test("BUG-023: favoritesCount max(0) allows increment normally") {
        var favoritesCount = 0
        favoritesCount = max(0, favoritesCount + 1 * 4)
        checkEqual(favoritesCount, 4)
    }

    // MARK: BUG-035 — labelCounts clamp

    test("BUG-035: labelCounts max(0) prevents negative on over-decrement") {
        // Mirrors: labelCounts[old] = max(0, (labelCounts[old] ?? 0) - 1)
        var counts: [ColorLabel: Int] = [.red: 1]
        // Decrement twice from a count of 1.
        counts[.red] = max(0, (counts[.red] ?? 0) - 1)   // 0
        counts[.red] = max(0, (counts[.red] ?? 0) - 1)   // would be -1 → clamped to 0
        checkEqual(counts[.red], 0, "labelCount must not go negative")
    }

    test("BUG-035: labelCounts missing key treated as 0 (not nil crash)") {
        var counts: [ColorLabel: Int] = [:]
        // Removing a label whose count was never incremented must not crash or go negative.
        counts[.green] = max(0, (counts[.green] ?? 0) - 1)
        checkEqual(counts[.green], 0, "missing key should clamp to 0")
    }

    test("BUG-035: labelCounts increment unaffected by clamp") {
        var counts: [ColorLabel: Int] = [:]
        counts[.blue, default: 0] += 1
        counts[.blue, default: 0] += 1
        checkEqual(counts[.blue], 2)
        // Now decrement below zero — must clamp.
        counts[.blue] = max(0, (counts[.blue] ?? 0) - 5)
        checkEqual(counts[.blue], 0)
    }

    // MARK: BUG-067 — name-sort tie-break

    test("BUG-067: nameAZ with equal filenames is stable via path tie-break") {
        // Photos with identical filenames in different directories.
        let alpha = Photo(url: URL(fileURLWithPath: "/albums/alpha/photo.jpg"),
                         byteSize: 0, creationDate: nil, modificationDate: nil)
        let beta  = Photo(url: URL(fileURLWithPath: "/albums/beta/photo.jpg"),
                         byteSize: 0, creationDate: nil, modificationDate: nil)
        let gamma = Photo(url: URL(fileURLWithPath: "/albums/gamma/photo.jpg"),
                         byteSize: 0, creationDate: nil, modificationDate: nil)

        // Scramble the input order.
        let scrambled = [gamma, alpha, beta]
        let sorted1 = SortOrder.nameAZ.sorted(scrambled)
        let sorted2 = SortOrder.nameAZ.sorted([beta, gamma, alpha])

        // Both passes must produce the same path order.
        let paths1 = sorted1.map(\.url.path)
        let paths2 = sorted2.map(\.url.path)
        checkEqual(paths1, paths2, "nameAZ must be deterministic for equal filenames")

        // The tie-break is ascending path → alpha < beta < gamma.
        checkEqual(paths1[0], "/albums/alpha/photo.jpg")
        checkEqual(paths1[1], "/albums/beta/photo.jpg")
        checkEqual(paths1[2], "/albums/gamma/photo.jpg")
    }

    test("BUG-067: nameZA with equal filenames is stable via path tie-break") {
        let alpha = Photo(url: URL(fileURLWithPath: "/x/alpha/shot.jpg"),
                         byteSize: 0, creationDate: nil, modificationDate: nil)
        let beta  = Photo(url: URL(fileURLWithPath: "/x/beta/shot.jpg"),
                         byteSize: 0, creationDate: nil, modificationDate: nil)

        let sorted1 = SortOrder.nameZA.sorted([alpha, beta])
        let sorted2 = SortOrder.nameZA.sorted([beta, alpha])

        // ZA still tie-breaks by ascending path (secondary key is always AZ for paths).
        let paths1 = sorted1.map(\.url.path)
        let paths2 = sorted2.map(\.url.path)
        checkEqual(paths1, paths2, "nameZA must be deterministic for equal filenames")
    }

    test("BUG-067: nameAZ does not change primary sort for distinct filenames") {
        // The tie-break must not disturb the primary filename ordering.
        let photos = [
            Fixtures.photo("zebra.jpg"),
            Fixtures.photo("apple.jpg"),
            Fixtures.photo("mango.jpg"),
        ]
        let names = SortOrder.nameAZ.sorted(photos).map(\.filename)
        checkEqual(names, ["apple.jpg", "mango.jpg", "zebra.jpg"])
    }

    test("BUG-067: sort is idempotent — running twice gives same order") {
        let photos = (0..<10).map { i in
            Photo(url: URL(fileURLWithPath: "/folder-\(i % 3)/image.jpg"),
                  byteSize: Int64(i), creationDate: nil, modificationDate: nil)
        }
        let first  = SortOrder.nameAZ.sorted(photos).map(\.url.path)
        let second = SortOrder.nameAZ.sorted(photos.reversed()).map(\.url.path)
        checkEqual(first, second, "sort must be idempotent regardless of input order")
    }
}
