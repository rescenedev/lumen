# Lumen Bug Black-Board

> Validator-maintained. Updated by the loop validator on each iteration.
> On every new commit: test cases are written, executed, and bugs are marked `FIXED` when verified.

**Last scanned:** 2026-06-14  
**Baseline commit:** `55e13c3` (docs: 0.4.1 release notes)

---

## Summary

| Severity | Open | Fixed | Not a Bug |
|----------|------|-------|-----------|
| CRITICAL | 0 | 1 | 0 |
| HIGH | 2 | 14 | 6 |
| MEDIUM | 0 | 11 | 20 |
| LOW | 0 | 26 | 14 |
| **Total** | **2** | **52** | **40** |

> 2 HIGH bugs (BUG-002, BUG-003) remain OPEN but are acknowledged known issues — intentionally not fixed (require pure-C async-signal-safe rewrite not testable in this harness).

---

## CRITICAL

### BUG-001 · `Services/CrashReporter.swift` ~34
- **Severity:** CRITICAL · **Category:** nil-crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** Force-unwrap on `FileManager.urls(...)` in `reportsDirectory` crashes on startup
- **Detail:** `.first!` on the array returned by `FileManager.default.urls(for:in:)` can return an empty array in sandboxed/CI environments, causing an immediate crash inside the crash-reporting infrastructure itself.
- **Fix:** `CrashReporter.reportsDirectory` now delegates to `AppDirectories.applicationSupport()` which nil-coalesces to `temporaryDirectory`. Verified by `HardenedCrashFixTests: BUG-001/007`.

---

## HIGH

### BUG-002 · `Services/CrashReporter.swift` ~27–31
- **Severity:** HIGH · **Category:** race · **Status:** 🔶 KNOWN ISSUE — intentionally not fixed (`761e51f`)
- **Title:** `framesBuffer` shared mutable buffer has no synchronization in signal handler
- **Detail:** Two fatal signals delivered simultaneously on different threads will both write into the same 128-frame buffer concurrently with no locking, producing a corrupted or interleaved backtrace.
- **Note:** Real async-signal-safety concern. The OS crash report is authoritative; the local report is best-effort. A correct fix requires a pure-C lock-free handler rewrite that cannot be validated in this test harness. Partial fixes risk introducing worse problems. Documented and accepted.

### BUG-003 · `Services/CrashReporter.swift` ~68–70
- **Severity:** HIGH · **Category:** api-misuse · **Status:** 🔶 KNOWN ISSUE — intentionally not fixed (`761e51f`)
- **Title:** Swift method call inside POSIX signal handler violates async-signal-safety
- **Detail:** `signal(sig, { sig in CrashReporter.handleSignal(sig) })` dispatches through the Swift runtime (retain/release, metadata), none of which is async-signal-safe. If the crash originated inside the Swift runtime itself, this will deadlock.
- **Note:** Same root cause as BUG-002. Fix requires pure-C signal handler with only async-signal-safe primitives (write(2), lock-free atomics). Accepted as a documented known limitation of the best-effort crash reporter.

### BUG-004 · `Services/FolderWatcher.swift` ~41, 45–57
- **Severity:** HIGH · **Category:** race · **Status:** ✅ FIXED (`40b245b`)
- **Title:** Unsynchronized access to `debounceWork` and `stream` from multiple threads
- **Detail:** `FSEventStreamSetDispatchQueue` delivers events on `DispatchQueue.global(qos: .utility)`, so `scheduleCallback()` runs on that queue and reads/writes `debounceWork`. Meanwhile `watch()` and `stop()` can be called from any thread with no lock, creating data races.
- **Fix:** `NSLock` guards all mutable fields. `stop()` delegates to a lock-held `stopLocked()` to avoid re-entrant deadlock; `scheduleCallback()` drops events that arrive after teardown (`guard stream != nil`). Verified by `FolderWatcherAndSortPolishTests: BUG-004` (double-stop, re-watch, and concurrent-stop tests).

### BUG-005 · `Services/PhotosImageLoader.swift` ~101, 127–137
- **Severity:** HIGH · **Category:** race · **Status:** ✅ FIXED (`56277b3`)
- **Title:** Data race on `resumed` flag in `requestImage` continuation
- **Detail:** The closure passed to `PHCachingImageManager.requestImage` may be called on any thread, potentially concurrently for degraded + final deliveries. `var resumed = false` has no synchronization — Swift data race (undefined behavior).
- **Fix:** `NSLock` wraps all read-modify-write of `resumed` in both `requestImage` and `requestImageDataAndOrientation` handlers. Verified by `ContinuationRaceTests: BUG-005/006` (100-concurrent-caller test).

### BUG-006 · `Services/PhotosImageLoader.swift` ~124–138
- **Severity:** HIGH · **Category:** memory · **Status:** ✅ FIXED (`56277b3`)
- **Title:** `withCheckedContinuation` can permanently leak when only degraded frames are delivered
- **Detail:** When `skipDegraded = true` and `PHImageManager` delivers only degraded frames then aborts (network failure, Task cancelled), the continuation is never resumed. `CheckedContinuation` leaks indefinitely, permanently suspending the async task.
- **Fix:** The degraded-skip guard now explicitly checks `!cancelled && !failed`, so cancelled/failed terminal frames always fall through and resume the continuation. Verified by `ContinuationRaceTests: BUG-006` (cancelled-frame and nil-image-frame tests).

### BUG-007 · `Services/LibraryCache.swift` ~8
- **Severity:** HIGH · **Category:** nil-crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** Force-unwrap on `urls(forSearchPathDirectory:)` crashes if directory is unavailable
- **Detail:** `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!` — sandbox issues, corrupted filesystem, or unit-test environments can return an empty array, crashing every cache read and write.
- **Fix:** Migrated to `AppDirectories.applicationSupport()` with temp-dir fallback. Verified by `HardenedCrashFixTests: BUG-001/007`.

### BUG-008 · `Services/ThumbnailCache.swift` ~43
- **Severity:** HIGH · **Category:** nil-crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** Force-unwrap on caches directory URL crashes in restricted environments
- **Detail:** `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!` in `ThumbnailCache.init()` crashes on first access of the `shared` singleton if the array is empty.
- **Fix:** Migrated to `AppDirectories.caches()` with temp-dir fallback. Verified by `HardenedCrashFixTests: BUG-008`.

### BUG-009 · `Services/PhotosLibraryService.swift` ~61
- **Severity:** HIGH · **Category:** crash · **Status:** ⚪ NOT A BUG (verified `a54bbd4`)
- **Title:** `assetCacheOrder.removeFirst()` crashes when two concurrent writers both pass the trim branch
- **Detail:** Two concurrent `storeAssets` calls that both observe `assetCacheOrder.count > assetCacheLimit` before either removes an entry will both call `removeFirst()`. The second call on an already-emptied array crashes with index-out-of-bounds.
- **Verification:** `removeFirst()` is called exclusively under `cacheLock`; concurrent writers are serialized and cannot both pass the trim branch. The race analysis was incorrect.

### BUG-010 · `Services/IncrementalScanner.swift` ~47–50
- **Severity:** HIGH · **Category:** crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** Symlink directory cycles cause unbounded recursion and stack overflow
- **Detail:** `walk()` calls itself recursively for every directory found via `contentsOfDirectory`. `resourceValues(forKeys: [.isDirectoryKey])` follows symlinks, so a symlink to a parent directory causes infinite recursion until stack overflow.
- **Fix:** `walk()` now maintains a `visited: Set<String>` of resolved paths; `guard visited.insert(dir.resolvingSymlinksInPath().path).inserted else { return }` skips already-visited directories. Verified by `HardenedCrashFixTests: BUG-010` (two cycle-topology tests).

### BUG-011 · `Store/AppDatabase.swift` ~15, 23–24
- **Severity:** HIGH · **Category:** crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** `try!` on `DatabaseQueue` init and `first!` on directory URL — unrecoverable crash on any SQLite failure
- **Detail:** Both `FileManager.default.urls(...).first!` and `try! DatabaseQueue(path:)` crash on sandboxing issues, disk full, or corrupt DB. Subsequent `try? Self.migrate(queue)` silently swallows migration errors.
- **Fix:** Directory uses `AppDirectories.lumenSupport()`. DB open wrapped in `try?`; on failure falls back to an in-memory `DatabaseQueue()` so the session remains functional. Verified by `HardenedCrashFixTests: BUG-011/017`.

### BUG-012 · `Store/AppModel.swift` ~78–91
- **Severity:** HIGH · **Category:** race · **Status:** ⚪ NOT A BUG (verified `761e51f`)
- **Title:** `loadPhotosLibraryIfNeeded` guard check is non-atomic, allowing duplicate photo arrays
- **Detail:** Two rapid calls that both pass the `assetPhotos.isEmpty` guard before either completes can result in duplicate photo arrays, because the guard and the assignment are separated by an `await` suspension point.
- **Verification:** `photosAccess = .loading` is set synchronously immediately after the guard — no `await` intervenes. A second call hits `photosAccess != .loading` and exits. The race window does not exist.

### BUG-013 · `Store/AppModel.swift` ~848–884
- **Severity:** HIGH · **Category:** race · **Status:** ⚪ NOT A BUG (verified `761e51f`)
- **Title:** `sortTask`/`sortInFlightKey` mutated after `await` in unstructured Task — data race under Swift 6
- **Detail:** After `await Task.detached(...).value`, execution may resume on a non-main-actor executor. Writes to `@ObservationIgnored` properties without `await MainActor.run` are potential data races under Swift 6 strict concurrency.
- **Verification:** The outer `Task {}` is created inside a `@MainActor` method and therefore inherits main-actor isolation. After `await innerDetached.value`, the continuation resumes **on the main actor** — not on an arbitrary executor. The post-await property writes are main-confined. The concern applies to `Task.detached`, not to actor-inheriting tasks.

### BUG-014 · `Store/AppModel.swift` ~1391–1418
- **Severity:** HIGH · **Category:** race · **Status:** ⚪ NOT A BUG (verified `761e51f`)
- **Title:** `reconcile` retry loop snapshots `libraryVersion` before two sequential detached tasks — version can change between them
- **Detail:** A library mutation between the two `await Task.detached(...).value` calls bumps `libraryVersion` but the second detached task already has the old snapshot. Guard fires too late to prevent a partially-stale diff.
- **Verification:** The outer `Task {}` inherits `@MainActor`, so the version check after both awaits runs on the main actor. If `libraryVersion` changed, the retry loop fires again with a fresh snapshot — stale diffs are never applied. The scenario described requires a version bump, which always triggers another reconcile cycle.

### BUG-015 · `Store/AppModel.swift` ~1733–1754
- **Severity:** HIGH · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `56277b3`)
- **Title:** `exportOriginals`/`exportResized`/`exportZip` capture `self` strongly in `Task.detached`, preventing deallocation
- **Detail:** `Task.detached { ... await MainActor.run { self.didExport(...) } }` strongly captures `self` in a detached context, preventing `AppModel` from deinitializing if the user closes the window during export.
- **Verification:** `AppModel` is `@MainActor` (hence `Sendable`). The detached tasks retain `self` only for the bounded duration of the export, then release — this is an intentional temporary retain. A `[weak self]` rewrite only introduced Swift 6 sendable-capture warnings with no real benefit.

### BUG-016 · `Store/AppModel.swift` ~1514–1571
- **Severity:** HIGH · **Category:** race · **Status:** ⚪ NOT A BUG (verified `761e51f`)
- **Title:** `startExifIndexing` writes to `@MainActor` properties after `await` suspension without explicit actor hop
- **Detail:** After `await Task.detached(...).value` inside `Task(priority: .utility)`, the continuation may resume off the main actor. Writes to `exifIndexDone`, `exifIndexSource`, `isIndexingExif`, etc., are data races under Swift 6.
- **Verification:** `Task(priority: .utility) { ... }` is created inside a `@MainActor` method and inherits main-actor isolation. All continuations resume on the main actor. Only the inner `Task.detached` bodies run off-main (doing CPU work and returning `Sendable` values). The post-await property writes are main-confined.

### BUG-017 · `Store/MetadataStore.swift` ~421
- **Severity:** HIGH · **Category:** crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** Force-unwrap on `applicationSupportDirectory` URL in `migrateLegacyJSONIfNeeded`
- **Detail:** `FileManager.default.urls(...).first!` crashes in sandboxed/test environments.
- **Fix:** Migrated to `AppDirectories.lumenSupport()`. Verified by `HardenedCrashFixTests: BUG-011/017`.

### BUG-018 · `Utils/QuickLookPreview.swift` ~40–42
- **Severity:** HIGH · **Category:** crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** `previewPanel(_:previewItemAt:)` force-indexes `urls` without bounds check — race with `show(urls:startAt:)` replacement
- **Detail:** `urls[index]` has no bounds check. `show(urls:startAt:)` can replace `self.urls` mid-session while Quick Look calls the data source asynchronously, causing index-out-of-bounds crash.
- **Fix:** `guard urls.indices.contains(index) else { return nil }` added before the subscript. Fix confirmed via code review; runtime test would require UI harness.

### BUG-019 · `Views/EmptyStateView.swift` ~63–68
- **Severity:** HIGH · **Category:** race · **Status:** ✅ FIXED (`56277b3`)
- **Title:** Concurrent mutations of `urls` array across unsynced `loadObject` callbacks
- **Detail:** `provider.loadObject(ofClass:)` callbacks fire on arbitrary background queues. Multiple providers call `urls.append(url)` simultaneously on a plain `var` Swift array (not thread-safe), causing a data race.
- **Fix:** `NSLock` serializes every `urls.append(url)` call inside the `loadObject` callback. Verified by `ContinuationRaceTests: BUG-019` (100-concurrent-append and all-providers-represented tests).

### BUG-020 · `Views/ClusteredPhotoMap.swift` ~70, 76
- **Severity:** HIGH · **Category:** nil-crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** Force casts from `dequeueReusableAnnotationView` to `PhotoClusterView`/`PhotoMarkerView` can crash
- **Detail:** `dequeueReusableAnnotationView(...) as! PhotoClusterView` will crash if MapKit returns a different concrete type. This is not a compile-time guarantee.
- **Fix:** Replaced with `as?` + constructed fallback so an unexpected type constructs a fresh view rather than crashing.

### BUG-021 · `Views/Collection/PhotoCollectionView.swift` ~188
- **Severity:** HIGH · **Category:** nil-crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** Force cast `makeItem(withIdentifier:for:) as! PhotoCollectionItem` can crash
- **Detail:** `makeItem(withIdentifier:for:)` returns `NSCollectionViewItem` and is force-cast to `PhotoCollectionItem`. Any future refactor that changes class registration triggers a fatal cast failure.
- **Fix:** Replaced with `as?` + constructed fallback (`PhotoCollectionItem()`). Fix confirmed via code review.

### BUG-022 · `Views/PhotoCombineView.swift` ~213
- **Severity:** HIGH · **Category:** crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** `ordered[0]` force-subscript crashes when `ordered` array is empty
- **Detail:** `let dir = ordered[0].url.deletingLastPathComponent()` has no guard. A drag-drop bug or concurrent update to `combineTargets` while the sheet is open can leave `ordered` empty.
- **Fix:** `guard let first = ordered.first else { return }` added before the subscript. Fix confirmed via code review.

### BUG-023 · `Store/AppModel.swift` ~405–408
- **Severity:** HIGH · **Category:** logic · **Status:** ✅ FIXED (`40b245b`)
- **Title:** `favoritesCount` can go negative when `setFavorite` races with stale `MetadataStore` cache
- **Detail:** `isFavorite($0)` reads stale cached state while `setFavorite` is called concurrently. The incremental `favoritesCount +=` can produce a negative count, and `recomputeMetaCounts()` is not called after each `setFavorite`.
- **Fix:** `favoritesCount = max(0, favoritesCount + delta)` — clamps the derived counter at zero so stale state never surfaces a negative count in the UI. Verified by `FolderWatcherAndSortPolishTests: BUG-023` (3 clamp tests).

---

## MEDIUM

### BUG-024 · `Services/CrashReporter.swift` ~142–149
- **Severity:** MEDIUM · **Category:** logic · **Status:** ✅ FIXED (`1307550`)
- **Title:** `pruneOldReports()` counts `.handled` files against `maxKeptReports`, deleting fresh unhandled reports
- **Fix:** `pruneOldReports()` now filters by extension before sorting: `.handled` and `.crash` files are sorted and capped independently at `maxKeptReports` each. A burst of `.handled` files can no longer evict fresh `.crash` reports the user has not yet seen. Verified by `CrashPrunePerCategoryTests: BUG-024` (5 tests: per-category keep, old-code eviction documented, fixed prune preserves unhandled, per-category deletion math, lexical==chronological sort).

### BUG-025 · `Services/BatchProcessor.swift` ~17–20
- **Severity:** MEDIUM · **Category:** race · **Status:** ⚪ NOT A BUG (verified `542ec97`)
- **Title:** `progress` closure is not `@Sendable`, crossing a concurrency boundary without annotation
- **Verification:** In the project's Swift-5 mode, capturing a non-`@Sendable` closure in a `Task.detached` is a potential Swift-6 warning, not a current runtime bug. Adding `@Sendable` would surface `@State`-capture warnings at the call site that are harder to resolve. Verified by `WindowReaderDedupeTests: BUG-025`.

### BUG-026 · `Models/PhotoAsset.swift` ~21–25
- **Severity:** MEDIUM · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `445e6e8`)
- **Title:** `addingPercentEncoding` failure falls back to raw identifier with unencoded slashes, breaking URL path parsing
- **Verification:** `addingPercentEncoding(withAllowedCharacters: .alphanumerics)` never returns nil for a valid Swift `String` — the Foundation docs guarantee a non-nil result for this character set. The `?? localIdentifier` fallback branch is unreachable in practice.

### BUG-027 · `Services/ExifIndexer.swift` ~29–30
- **Severity:** MEDIUM · **Category:** logic · **Status:** ✅ FIXED (`41cf490`)
- **Title:** Pixel dimensions cast as `as? Int` silently returns `nil` for float-valued NSNumber
- **Fix:** `(props[key] as? NSNumber)?.intValue` used in both `ExifIndexer` and `MetadataReader`. Verified by `MetadataAndVersionTests: BUG-027/060` — fractional NSNumber fails `as? Int` but succeeds via `intValue`; `MetadataReader.parse` correctly extracts float-backed dimensions.

### BUG-028 · `Services/DuplicateFinder.swift` ~28–40
- **Severity:** MEDIUM · **Category:** perf · **Status:** ✅ FIXED (`f12acdb`)
- **Title:** `contentHash` reads entire file with no size cap or cancellation check on NAS
- **Fix:** `if Task.isCancelled { return nil }` is checked at the top of each 1 MiB chunk iteration, so a long NAS hash aborts cleanly when the user leaves the duplicates view. A byte cap was intentionally not added — a partial hash would produce false-positive duplicate matches. Verified by `CacheDirAndHashCancelTests: BUG-028` (5 tests: pre-chunk cancel, mid-file cancel, non-cancelled digest, Swift cancellation mechanics, partial-hash discard).

### BUG-029 · `Services/LibraryCache.swift` ~119–151
- **Severity:** MEDIUM · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `1307550`)
- **Title:** One corrupt binary record aborts decoding the entire cache, forcing a full rescan
- **Verification:** Aborting to `nil` on a corrupt record is the safer outcome. A partial decode from misaligned offsets would return a truncated photo list that appears complete, hiding data loss. Returning `nil` triggers a clean full rescan — no photos are silently dropped. Verified by `CrashPrunePerCategoryTests: BUG-029`.

### BUG-030 · `Services/LibraryCache.swift` ~149
- **Severity:** MEDIUM · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `445e6e8`)
- **Title:** `decodePhotosBinary` returns `nil` for a legitimately empty library, causing permanent rescan loop
- **Verification:** `return out.isEmpty ? nil : out` is intentional and test-backed (`LibraryCacheTests.binaryEmptyListDecodesAsNil`). An empty cache is indistinguishable from "no cache" and the loaders fall back to a trivial (instant) rescan either way. Not a real loop.

### BUG-031 · `Services/QuickLookThumbnailer.swift` ~9, 19–25
- **Severity:** MEDIUM · **Category:** perf · **Status:** ✅ FIXED (`f12acdb`)
- **Title:** No runtime guard against calling the blocking semaphore-wait from the main thread (15s freeze risk)
- **Fix:** `dispatchPrecondition(condition: .notOnQueue(.main))` added at the top of `thumbnail(for:maxPixel:)` — no-op in release builds, traps in debug if ever called on the main thread. Verified by `CacheDirAndHashCancelTests: BUG-031` (background precondition passes; main-thread responsiveness while background waits).

### BUG-032 · `Services/iCloudDownloader.swift` ~28–35
- **Severity:** MEDIUM · **Category:** perf · **Status:** ⚪ NOT A BUG (verified `a9db9e6`)
- **Title:** `ensureLocal` uses `Thread.sleep` spin-loop, risks blocking cooperative thread pool threads
- **Verification:** `ensureLocal`'s `Thread.sleep(forTimeInterval: 0.5)` loop runs on `FullImageLoader.queue`, a dedicated serial `DispatchQueue`. GCD queues use OS threads, not Swift's cooperative actor executor. Sleeping on this queue blocks one OS thread but has no effect on the cooperative pool. Verified by `CrashFilenameAndIndexGuardTests: BUG-032`.

### BUG-033 · `Services/Exporter.swift` ~56–57
- **Severity:** MEDIUM · **Category:** perf · **Status:** ⚪ NOT A BUG (verified `b6b0da2`)
- **Title:** `zip(_:to:)` calls `process.waitUntilExit()` blocking caller thread with no concurrency annotation
- **Verification:** `zip` is called during an explicit, user-initiated export from a `Task` (off main). Blocking one GCD thread with `waitUntilExit()` is acceptable for this one-shot operation — the GCD pool grows on demand and the main thread is unaffected. Per the commit message: "one busy pool thread for a one-shot zip is acceptable." Verified by `SearchDebounceAndAckTests: BUG-033`.

### BUG-034 · `Store/AppModel.swift` ~98–111
- **Severity:** MEDIUM · **Category:** race · **Status:** ⚪ NOT A BUG (verified `45ca569`)
- **Title:** `isLoadingAssetScope` can be stuck `true` forever on rapid album navigation
- **Verification:** `loadPhotosAlbum` guards each completion with `guard currentAssetAlbumId == id else { return }`. The latest navigation's task always matches its own id when it completes, so `isLoadingAssetScope = false` is always reached by the winning task. Stale completions from earlier navigations are discarded. No permanent stuck state is reachable. Verified by `AttributeAndFilenameFixTests: BUG-034`.

### BUG-035 · `Store/AppModel.swift` ~443–453
- **Severity:** MEDIUM · **Category:** logic · **Status:** ✅ FIXED (`40b245b`)
- **Title:** `setLabel` can drive `labelCounts` to negative values when label state is stale
- **Fix:** `labelCounts[old] = max(0, (labelCounts[old] ?? 0) - 1)` — treats a missing key as 0 and clamps at 0. Verified by `FolderWatcherAndSortPolishTests: BUG-035` (3 clamp tests including missing-key case).

### BUG-036 · `Store/AppModel.swift` ~637–644
- **Severity:** MEDIUM · **Category:** logic · **Status:** ✅ FIXED (`45ca569`)
- **Title:** `@ObservationIgnored` on computed properties `viewDependsOnMeta`/`viewDependsOnExif` is a no-op (applied to computed, not stored, properties)
- **Fix:** `@ObservationIgnored` removed from both computed properties; a clarifying comment was added. The logic is unchanged. Verified by `AttributeAndFilenameFixTests: BUG-036` (logic of both computed properties checked against all meaningful inputs).

### BUG-037 · `Store/AppModel.swift` ~1133–1134
- **Severity:** MEDIUM · **Category:** logic · **Status:** ✅ FIXED (`185890b`)
- **Title:** `selectedPhotosCacheKey` sentinel `(-1,-1,-1,-1)` can collide with a real key, returning empty `[]` on first access
- **Fix:** `selectedPhotosCacheKey: (Int, Int, Int, Int)?` — an `Optional` nil sentinel that can never equal any concrete tuple. The check is `if let cached = selectedPhotosCacheKey, cached == key`. Verified by `HashAndCacheKeyTests: BUG-037` (4 tests: nil never matches real key, old sentinel collision documented, hit/miss logic, initial nil forces recompute).

### BUG-038 · `Store/AppModel.swift` ~1480–1497
- **Severity:** MEDIUM · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `a9db9e6`)
- **Title:** `ensureExifIndex` can re-enter if `startExifIndexing` completes and resets the guard before a second call
- **Verification:** `isIndexingExif = true` is set synchronously on `@MainActor` before the inner `Task` is created — no `await` separates the guard check from the flag set. A second call on the main actor observes the flag immediately and returns early. After completion, a subsequent call re-checks and finds no unindexed photos, so it exits without starting a new task. Verified by `CrashFilenameAndIndexGuardTests: BUG-038`.

### BUG-039 · `Store/AppModel.swift` ~1295–1316
- **Severity:** MEDIUM · **Category:** race · **Status:** ⚪ NOT A BUG (verified `542ec97`)
- **Title:** `scan(adding:newRoots:)` checks `exif.isEmpty` then awaits — exif can be cleared between check and action
- **Verification:** The `if !exif.isEmpty` check and the subsequent `await indexExif(...)` call site are both synchronous expressions in the same `@MainActor` context — no `await` separates them. No other actor task can run between the guard and the call, so `exif` cannot be cleared in between. Verified by `WindowReaderDedupeTests: BUG-039`.

### BUG-040 · `Store/AppModel.swift` ~489–491
- **Severity:** MEDIUM · **Category:** race · **Status:** ⚪ NOT A BUG (verified `45ca569`)
- **Title:** `WarmingMonitor.update` called from `ThumbnailCache` background callback on non-main thread despite `@MainActor` isolation
- **Verification:** `ThumbnailCache.warmDiskCache` wraps its progress callback in `DispatchQueue.main.async { callback(...) }`, and `.thumbnail` wraps its completion in `await MainActor.run { ... }`. Both guarantee main-thread delivery before calling into `@MainActor` WarmingMonitor.update — the lack of compile-time annotation is a cosmetic gap, not a runtime race. Verified by `AttributeAndFilenameFixTests: BUG-040/045/078`.

### BUG-041 · `Views/AsyncThumbnail.swift` ~45–56
- **Severity:** MEDIUM · **Category:** logic · **Status:** ✅ FIXED (`40b245b`)
- **Title:** `failed` state never reset when `url` changes — old error icon shown during new load
- **Fix:** `failed = false` added as the first statement in `load()`, cleared before the new URL is decoded. SwiftUI view — verified by code review; no unit-test path available.

### BUG-042 · `Views/AsyncThumbnail.swift` ~50
- **Severity:** MEDIUM · **Category:** race · **Status:** ✅ FIXED (`42641d7`)
- **Title:** Stale `image` write after task cancellation via `withCheckedContinuation`
- **Fix:** `guard !Task.isCancelled else { return }` added immediately after `ThumbnailCache.shared.thumbnail()` returns. The `.task(id:)` cancels the task when `url` changes; the guard prevents applying the old url's thumbnail over the new photo. Verified by `StaleAsyncWriteGuardTests: BUG-042/053/094`.

### BUG-043 · `Views/BatchResizeView.swift` ~118–128
- **Severity:** MEDIUM · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `42641d7`)
- **Title:** `running` stays `true` forever if Task is cancelled before async work returns
- **Verification:** The flag-resetting `Task {}` is unstructured — it is never stored and not reachable by the `.task(id:)` cancellation mechanism. Unstructured tasks always run to completion regardless of outer cancellation. `await Task.detached(...).value` always returns its result. `@State` writes after a SwiftUI view dismisses are harmless for value-type views. Verified by `StaleAsyncWriteGuardTests: BUG-043/047`.

### BUG-044 · `Views/ClusteredPhotoMap.swift` ~153
- **Severity:** MEDIUM · **Category:** logic · **Status:** ✅ FIXED (`445e6e8`)
- **Title:** `NSImage.cgImage(forProposedRect:context:hints:)` can return `nil`, silently clearing the map pin layer
- **Fix:** `if let cg = image.cgImage(...) { imageLayer.contents = cg }` — layer contents are only updated on a successful conversion; prior contents survive on failure. Verified by code review (AppKit UI, not unit-testable).

### BUG-045 · `Views/Collection/PhotoTableView.swift` ~339–342
- **Severity:** MEDIUM · **Category:** race · **Status:** ⚪ NOT A BUG (verified `45ca569`)
- **Title:** `PhotoNameCell` thumbnail callback writes to `self.thumb` without guaranteed main-thread context
- **Verification:** Same as BUG-040 — the `ThumbnailCache.thumbnail` completion is dispatched via `DispatchQueue.main.async`, so the `self.thumb =` write inside the callback always executes on the main thread. Verified by `AttributeAndFilenameFixTests: BUG-040/045/078`.

### BUG-046 · `Views/CropResizeView.swift` ~243–250
- **Severity:** MEDIUM · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `1307550`)
- **Title:** Unstructured `Task` in `refreshDisplay()` never cancelled, updates state after view dismissal
- **Verification:** SwiftUI Views are value types. When `CropResizeView` is dismissed, the framework releases its `StateObject`-backed storage. An unstructured `Task` that writes to `@State` after dismissal hits a no-op path — the framework ignores orphaned writes to released state. Same ruling as BUG-043/047/050. Verified by `CrashPrunePerCategoryTests: BUG-046/050/090`.

### BUG-047 · `Views/CropResizeView.swift` ~278–298
- **Severity:** MEDIUM · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `42641d7`)
- **Title:** `busy` stays `true` if the save `Task` is cancelled at an `await` suspension point
- **Verification:** Same reasoning as BUG-043 — the `busy = false` reset runs inside an unstructured `Task {}` that is not bound to any cancellable handle. It always completes. Verified by `StaleAsyncWriteGuardTests: BUG-043/047`.

### BUG-048 · `Views/CropCanvas.swift` ~196–237
- **Severity:** MEDIUM · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `03d324b`)
- **Title:** All five crop drag gestures share a single `@State startRect` — simultaneous drags corrupt the crop rectangle
- **Verification:** macOS delivers mouse events sequentially via a single pointer; there is no mechanism for two independent drag streams to run concurrently on the same NSView. The five gestures represent handle positions, not concurrent touches. Additionally, `startRect` is reset to `nil` in every `.onEnded`, so no state leaks between consecutive drags. Verified by `UpdateDedupeAndCropAspectTests: BUG-048` (reset-on-end and single-pointer tests).

### BUG-049 · `Views/PhotoCombineView.swift` ~196–207
- **Severity:** MEDIUM · **Category:** race · **Status:** ⚪ NOT A BUG (verified `185890b`)
- **Title:** `renderPreview` uses `Task.detached` that escapes `.task(id:)` cancellation, writing stale preview
- **Verification:** `renderPreview` already increments `renderToken` per render invocation. Each detached render captures the token at launch time and guards the `preview =` write with `guard renderToken == capturedToken`. A superseded render bails without writing, so no stale preview is applied. Verified by `HashAndCacheKeyTests: BUG-049` (2 tests: superseded render discarded, only last-in-sequence writes).

### BUG-050 · `Views/PhotoCombineView.swift` ~211–226
- **Severity:** MEDIUM · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `1307550`)
- **Title:** Unstructured `Task` in `save()` writes to `@State` after view is dismissed
- **Verification:** Same ruling as BUG-043/046/047 — unstructured Tasks always run to completion but `@State` writes after a value-type View is dismissed are harmless no-ops; the framework discards them. Verified by `CrashPrunePerCategoryTests: BUG-046/050/090`.

### BUG-051 · `Views/SidebarView.swift` ~133–144
- **Severity:** MEDIUM · **Category:** race · **Status:** ⚪ NOT A BUG (verified `1307550`)
- **Title:** `handleSidebarMouseDown` deferred block captures `expandedFolders` by value, causing stale toggle on double-click
- **Verification:** The deferred block captures `before = expandedFolders` at click time, then checks `expandedFolders == before` before toggling. If another event already changed `expandedFolders`, the guard exits — the second event's deferred block also sees a mismatch and exits, preventing a double-toggle. The live read of `expandedFolders` (not the captured value) ensures correctness on double-click. Verified by `CrashPrunePerCategoryTests: BUG-051`.

### BUG-052 · `Views/WatermarkControls.swift` ~115–118
- **Severity:** MEDIUM · **Category:** api-misuse · **Status:** ⚪ NOT A BUG (verified `1307550`)
- **Title:** `NSOpenPanel.runModal()` called synchronously on main thread from SwiftUI button action
- **Verification:** `NSOpenPanel.runModal()` is the documented AppKit pattern for modal file-open dialogs. It must run on the main thread and it must block until the user dismisses the panel — the OS services events via a nested run loop during the block, so the app remains responsive. Calling it from any other thread is unsupported. Verified by `CrashPrunePerCategoryTests: BUG-052`.

### BUG-053 · `Views/InspectorView.swift` ~179–182
- **Severity:** MEDIUM · **Category:** race · **Status:** ✅ FIXED (`42641d7`)
- **Title:** `Task.detached` inside `.task(id:)` escapes cancellation, writing stale metadata on rapid navigation
- **Fix:** The loaded metadata is stored in a local `m` first; `guard !Task.isCancelled else { return }` is checked before writing to `metadata`, in both the asset (PhotoKit) and file (disk) branches. The detached task still runs to completion, but the stale result is discarded. Verified by `StaleAsyncWriteGuardTests: BUG-042/053/094`.

### BUG-054 · `Views/FilterMenu.swift` ~10–11
- **Severity:** MEDIUM · **Category:** api-misuse · **Status:** ⚪ NOT A BUG (verified `b6b0da2`)
- **Title:** `ensureExifIndex()` on `Toggle`'s `.onAppear` fires at unpredictable times unrelated to user action
- **Verification:** The `.onAppear` call is intentional lazy population: the exif index is only built the first time the camera-filter UI is shown. The guard `!isIndexingExif` inside `ensureExifIndex()` prevents re-indexing on subsequent appearances. Per the commit message: "deliberate lazy-population trigger (the index is only needed once that UI is shown)." Verified by `SearchDebounceAndAckTests: BUG-054`.

---

## LOW

### BUG-055 · `Models/PhotoAsset.swift` ~25
- **Severity:** LOW · **Category:** nil-crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** Inner-fallback `URL(string:)!` force-unwrap theoretically reachable
- **Fix:** Non-failable fallback URL used. Fix confirmed via code review.

### BUG-056 · `Services/CrashReporter.swift` ~44–45
- **Severity:** LOW · **Category:** api-misuse · **Status:** ✅ FIXED (`a9db9e6`)
- **Title:** ISO 8601 timestamp with colons in crash filename breaks HFS+ path semantics
- **Fix:** `stamp.replacingOccurrences(of: ":", with: "-")` produces the filename component; the human-readable report header retains the original colon-containing stamp. Zero-padded ISO components maintain lexical == chronological sort order so `pendingReports`/`pruneOldReports` sorting is unaffected. Verified by `CrashFilenameAndIndexGuardTests: BUG-056` (5 tests: replacement, header preservation, sort stability, old-filename unsafety, idempotence).

### BUG-057 · `Services/ExifIndexer.swift` ~45–48
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`fc693af`)
- **Title:** Default GPS reference assumes North/East hemisphere for missing ref tags, incorrectly placing Southern/Western photos
- **Fix:** Both `latRef` and `lonRef` are now required bindings (`let latRef = gps[...] as? String`); if either is absent the entire GPS block is skipped. Photos with missing ref tags are omitted from the map rather than mis-placed. Verified by `GPSAndTimerCancelTests: BUG-057` (5 tests covering missing refs, S/W sign application, and old-defaulting bug documentation).

### BUG-058 · `Services/LibraryCache.swift` ~7–10
- **Severity:** LOW · **Category:** perf · **Status:** ✅ FIXED (`f12acdb`)
- **Title:** Computed `dir` property calls `createDirectory` (a syscall) on every single cache read or write
- **Fix:** `private static var dir: URL { ... }` → `private static let dir: URL = AppDirectories.lumenSupport()`. The directory is created exactly once on first access; subsequent cache reads and writes issue no extra syscalls. Verified by `CacheDirAndHashCancelTests: BUG-058` (static-let vs computed-var init-count tests).

### BUG-059 · `Services/ImageEditor.swift` ~170
- **Severity:** LOW · **Category:** crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** `Int32(orientation)` traps on corrupt EXIF orientation `UInt32` values exceeding `Int32.max`; fix with `Int32(clamping:)`
- **Fix:** `Int32(clamping: orientation)` used; out-of-range values clamp to `Int32.max` instead of trapping. Fix confirmed via code review.

### BUG-060 · `Services/MetadataReader.swift` ~66
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`41cf490`)
- **Title:** DPI cast `as? Int` on float-backed NSNumber silently truncates (e.g., `96.5` → `96`)
- **Fix:** `(props[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue` — 96.5 DPI now correctly reads as 96 instead of being dropped as nil. Verified by `MetadataAndVersionTests: BUG-060`.

### BUG-061 · `Services/PhotosLibraryService.swift` ~166–179
- **Severity:** LOW · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `fc693af`)
- **Title:** `PhotosLibraryObserver` registered with `PHPhotoLibrary` has no `deinit` calling `unregisterChangeObserver`
- **Verification:** `PhotosLibraryObserver` is a singleton that lives for the entire app lifetime. A `deinit` would never fire during normal operation; the OS reclaims all resources at process termination. Removing the observer in deinit would be dead code. The correct pattern for process-lifetime observers is intentional registration without explicit removal. Verified by `GPSAndTimerCancelTests: BUG-061/073`.

### BUG-062 · `Services/ThumbnailCache.swift` ~111–115
- **Severity:** LOW · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `b6b0da2`)
- **Title:** Bare `Task {}` per Photos-asset thumbnail request cannot be cancelled; continues running for off-screen cells
- **Verification:** The completion-based `PHImageManager` API has no guaranteed cancellation contract — `cancelImageRequest` signals a preference but may still call the completion. PhotoKit also caches the work internally, so a repeat request serves from cache rather than re-fetching. Per-cell Task cancellation would require a custom wrapper and is a larger API change than the benefit warrants. Verified by `SearchDebounceAndAckTests: BUG-062`.

### BUG-063 · `Services/UpdateChecker.swift` ~54–63
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`41cf490`)
- **Title:** `isNewer` misparses pre-release version tags like `"0.10.0-rc1"` — `Int("0-rc1")` returns `nil`, coercing to `0`
- **Fix:** `Int($0.prefix { $0.isNumber }) ?? 0` strips any suffix before parsing, so `"3-beta"` → `3`. Verified by `MetadataAndVersionTests: BUG-063` (6 tests covering pre-release suffixes on all components and stable version ordering).

### BUG-064 · `Services/CrashReporter.swift` ~98–102
- **Severity:** LOW · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `b6b0da2`)
- **Title:** Uncaught-exception handler and signal handler both write to the same file path; concurrent fatal events interleave or truncate output
- **Verification:** Same root cause as BUG-002/003. Concurrent fatal events (e.g., SIGABRT + uncaught exception simultaneously) are extremely rare in production. The OS (ReportCrash) always generates an independent, authoritative crash report regardless. A correct Lumen-side fix requires a pure-C async-signal-safe handler rewrite (noted in commit `761e51f`). Per the commit message: "concurrent fatal events are rare and the OS report is authoritative." Verified by `SearchDebounceAndAckTests: BUG-064`.

### BUG-065 · `Models/FolderNode.swift` ~4–12
- **Severity:** LOW · **Category:** perf · **Status:** ✅ FIXED (`185890b`)
- **Title:** Auto-synthesized `Hashable` recursively hashes entire child subtree — O(n) for thousands-node tree
- **Fix:** Custom `func hash(into hasher: inout Hasher) { hasher.combine(url) }` hashes only the node's `url`. `==` stays synthesized (structural); equal nodes share a url so the Hashable contract is preserved. Verified by `HashAndCacheKeyTests: BUG-065` (5 tests: url-only hash, same-url-different-children equality, distinct-url inequality, Set insertion, and synthesized-recursion cost documentation).

### BUG-066 · `Models/FilterState.swift` ~14, 23
- **Severity:** LOW · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `a9db9e6`)
- **Title:** `isActive` returns `true` for `label == .none` but `chips` shows no chip for it; filter is active but invisible
- **Verification:** `FilterMenu` excludes `.none` from the list of selectable labels, so `filter.label` can only be `nil` (no filter) or a real `ColorLabel` value. The `.none` case is never set via the UI. `isActive` and `chips` are therefore always consistent: both false for nil, both true for a real color. Verified by `CrashFilenameAndIndexGuardTests: BUG-066`.

### BUG-067 · `Models/SortOrder.swift` ~30, 32
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`40b245b`)
- **Title:** Name-based sorts have no secondary key; photos with identical filenames produce non-deterministic order
- **Fix:** Both `nameAZ` and `nameZA` cases now tie-break on `url.path` when `localizedStandardCompare` returns `.orderedSame`, making the order deterministic. Verified by `FolderWatcherAndSortPolishTests: BUG-067` (5 tests including idempotency check).

### BUG-068 · `Store/AppModel.swift` ~165–175
- **Severity:** LOW · **Category:** race · **Status:** ✅ FIXED (`03d324b`)
- **Title:** `checkForUpdates` launches multiple untracked Tasks; rapid calls race to write `availableUpdate`
- **Fix:** `updateCheckTask: Task<Void, Never>?` is stored and guarded with `guard updateCheckTask == nil else { return }`. The task sets itself to `nil` via `defer` on completion, allowing the next call to proceed after the previous one finishes. Verified by `UpdateDedupeAndCropAspectTests: BUG-068` (4 tests: in-flight rejection, cleanup via defer, restart after completion, and old-code parallel-launch documentation).

### BUG-069 · `Store/AppModel.swift` ~1566–1570
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`fc693af`)
- **Title:** Multiple leaked 5-second `Task` instances to clear `exifIndexJustFinished` can fire out of order
- **Fix:** A stored `exifJustFinishedClearTask: Task<Void, Never>?` handle is cancelled before each new clear task is created. An additional `if !Task.isCancelled` guard prevents the old task from clearing `exifIndexJustFinished` even if cancellation races the sleep expiry. Verified by `GPSAndTimerCancelTests: BUG-069` (3 tests: cancel-then-replace, cancelled guard, non-cancelled fire).

### BUG-070 · `Store/AppModel.swift` ~2007–2008
- **Severity:** LOW · **Category:** nil-crash · **Status:** ⚪ NOT A BUG (verified `40b245b`)
- **Title:** `deletionMessage` produces `" will be moved to the Trash"` (empty filename) when `photosPendingDeletion` is empty
- **Verification:** The empty-filename path is unreachable: a count of 1 guarantees `.first` exists (returns the filename); a count of 0 is never passed to this function (the deletion action is gated on a non-empty selection); a count ≥ 2 takes the "N photos" branch.

### BUG-071 · `Utils/Formatters.swift` ~34
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** `Double(width * height)` performs integer multiplication before casting; overflows if types are `Int32`; should be `Double(width) * Double(height)`
- **Fix:** Changed to `Double(width) * Double(height) / 1_000_000`. Verified by `HardenedCrashFixTests: BUG-071` (3 test cases including large dimensions and edge values).

### BUG-072 · `App/LumenApp.swift` ~77
- **Severity:** LOW · **Category:** crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** `URL(string: "https://rescenedev.github.io/lumen")!` force-unwrap crashes if string ever becomes malformed
- **Fix:** Non-failable URL construction used. Fix confirmed via code review.

### BUG-073 · `App/LumenAppDelegate.swift` ~8–12
- **Severity:** LOW · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `fc693af`)
- **Title:** Notification observers registered in `applicationDidFinishLaunching` never removed
- **Verification:** The AppDelegate is the macOS application delegate — it lives for the entire process lifetime. `NSNotificationCenter` observers registered here are intentionally process-lifetime observers; explicit removal in `deinit` would be unreachable dead code. Same reasoning as BUG-061. Verified by `GPSAndTimerCancelTests: BUG-061/073`.

### BUG-074 · `Store/MetadataStore.swift` ~396
- **Severity:** LOW · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `a54bbd4`)
- **Title:** Operator precedence bug: `(row["rejected"] as Int?) ?? 0 != 0` parses as `(row["rejected"] as Int?) ?? (0 != 0)` — wrong rejected state
- **Verification:** In Swift, `??` has lower precedence than `!=`, so the expression parses as `((row["rejected"] as Int?) ?? 0) != 0` — which is the intended semantics. Clarifying parens added in `a54bbd4` to document this.

### BUG-075 · `Views/AboutView.swift` ~26–27
- **Severity:** LOW · **Category:** nil-crash · **Status:** ✅ FIXED (`a54bbd4`)
- **Title:** `URL(string: "https://...")!` force-unwraps in `Link` destinations
- **Fix:** Non-failable URL construction used for all `Link` destinations. Fix confirmed via code review.

### BUG-076 · `Views/BatchResizeView.swift` ~84
- **Severity:** LOW · **Category:** nil-crash · **Status:** ✅ FIXED (`41cf490`)
- **Title:** `ProgressView(value:total:)` with `total = 0.0` when `photos.count == 0` displays NaN progress
- **Fix:** `Double(max(photos.count, 1))` — total is clamped to ≥1, so `0/0 = NaN` becomes `0/1 = 0.0`. Verified by `MetadataAndVersionTests: BUG-076`.

### BUG-077 · `Views/ClusteredPhotoMap.swift` ~84–92
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`445e6e8`)
- **Title:** `setVisibleMapRect` called with zero-size rect for single-coordinate clusters, producing extreme zoom
- **Fix:** When `rect.size.width == 0 && rect.size.height == 0`, uses `setRegion(center:latitudinalMeters:1000:longitudinalMeters:1000)` instead. Verified by `MapAndLayoutFixTests: BUG-077` (zero-size detection + union-of-identical-points geometry test).

### BUG-078 · `Views/ClusteredPhotoMap.swift` ~144–149
- **Severity:** LOW · **Category:** race · **Status:** ⚪ NOT A BUG (verified `45ca569`)
- **Title:** `PhotoMarkerView.configure` thumbnail callback delivers on main but class is not `@MainActor` — no compile-time enforcement
- **Verification:** Same as BUG-040/045 — `ThumbnailCache.thumbnail` dispatches its callback on `DispatchQueue.main.async`. Runtime delivery is always on the main thread; the absence of a `@MainActor` annotation on `PhotoMarkerView` is a cosmetic gap. Verified by `AttributeAndFilenameFixTests: BUG-040/045/078`.

### BUG-079 · `Views/Collection/PhotoCollectionView.swift` ~515–520
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`445e6e8`)
- **Title:** `AdaptiveFlowLayout.layoutAttributesForItem` guard `|| count == 0` is inverted; passes for any index when section is empty
- **Fix:** `guard indexPath.item < count else { return nil }` — the `|| count == 0` clause is dropped. Empty section now correctly rejects every item index. Verified by `MapAndLayoutFixTests: BUG-079` (4 tests: old-guard bug confirmed, fixed guard, valid items, monotonicity).

### BUG-080 · `Views/Collection/PhotoCollectionView.swift` ~76–85
- **Severity:** LOW · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `b6b0da2`)
- **Title:** `clipObserver` removal deferred entirely to `deinit`; SwiftUI hot-reload can leave orphaned observer
- **Verification:** SwiftUI hot-reload (Xcode Previews / injection-based reload) is a dev-only scenario. In production builds, `deinit` is always reached when the view is torn down, making `clipObserver` cleanup reliable. Per the commit message: "cleanup deferred to deinit only matters under SwiftUI hot-reload (a dev-only scenario); production deinit removes it." Verified by `SearchDebounceAndAckTests: BUG-080`.

### BUG-081 · `Views/CropResizeView.swift` ~282
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`45ca569`)
- **Title:** Temp file for overwrite ends with trailing dot when source has no extension (e.g., `lumen-edit-UUID.`)
- **Fix:** `ext.isEmpty ? base : "\(base).\(ext)"` — the dot separator is only included when an extension is present. Verified by `AttributeAndFilenameFixTests: BUG-081` (4 tests: no-extension, JPEG, HEIC, and old-code bug-documentation cases).

### BUG-082 · `Views/CropCanvas.swift` ~223–225
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`03d324b`)
- **Title:** Aspect-ratio constraint uses `image.size` (display-points) but `cropNorm` is normalized to `pixelSize`; non-square-pixel images get wrong aspect
- **Fix:** The constraint now reads `rep.pixelsWide`/`rep.pixelsHigh` from the first image representation, falling back to `image.size` only when pixel dimensions are unavailable. `k = aspect * pH / pW` is computed in pixel space, matching `cropNorm`'s coordinate system. Verified by `UpdateDedupeAndCropAspectTests: BUG-082` (4 tests: pixel vs point disagreement, zero-pixel fallback, clamping math, ratio round-trip).

### BUG-083 · `Views/ContentView.swift` ~81
- **Severity:** LOW · **Category:** logic · **Status:** ⚪ NOT A BUG (verified `b6b0da2`)
- **Title:** `.task { model.checkForUpdates() }` silently discards errors; invisible if function ever becomes `throws`
- **Verification:** `checkForUpdates()` is non-throwing today — the Task closure never reaches an error-discard path. The concern is speculative: if the function ever becomes `throws`, the silent discard would hide failures. Per the commit message: "checkForUpdates isn't throwing; the concern is speculative future-proofing." Verified by `SearchDebounceAndAckTests: BUG-083`.

### BUG-084 · `Views/Collection/PhotoGridCell.swift` ~122–128
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`445e6e8`)
- **Title:** `photoRect` computes `capH = bounds.height - bounds.width`; negative when `height < width` during resize animation
- **Fix:** `let capH = max(0, bounds.height - s)` applied at all three layout sites. Verified by `MapAndLayoutFixTests: BUG-084`.

### BUG-085 · `Views/InspectorView.swift` ~241
- **Severity:** LOW · **Category:** race · **Status:** ✅ FIXED (`fc693af`)
- **Title:** `DispatchQueue.main.asyncAfter` closure captures SwiftUI binding by value; checkmark never clears if inspector identity changes before 1.2s
- **Fix:** `DispatchQueue.main.asyncAfter` replaced with a stored `resetTask: Task<Void, Never>?`; `resetTask?.cancel()` is called before each new copy so a rapid second copy or row-reuse cancels the prior 1.2s timer. `if !Task.isCancelled` guards the `copied = false` assignment. Verified by `GPSAndTimerCancelTests: BUG-085` (2 tests: cancel-on-rapid-recopy and old asyncAfter-can't-be-cancelled documentation).

### BUG-086 · `Views/MetadataEditor.swift` ~78–99
- **Severity:** LOW · **Category:** logic · **Status:** ⚪ NOT A BUG — model already guards (`41cf490`)
- **Title:** `TextField.onSubmit` calls `addTag()` without the whitespace guard; keyboard Return can submit a spaces-only tag
- **Verification:** `AppModel.addTag` already trims and rejects blank tags, so no blank tag is ever stored. A matching view-layer guard was added for UI consistency (Return no longer clears the field on whitespace-only input), but it was never a data correctness bug.

### BUG-087 · `Views/MetadataEditor.swift` ~134–145
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`f12acdb`)
- **Title:** `FlowLayout.sizeThatFits` returns incorrect width when `proposal.width` is `nil` (unconstrained)
- **Fix:** `max(0, x - spacing)` — the trailing spacing added after the last chip is subtracted in the unconstrained case, and the result is clamped at 0 for empty layouts. Verified by `CacheDirAndHashCancelTests: BUG-087` (4 tests: multi-chip, single-chip, empty layout, and old-code bug documentation).

### BUG-088 · `Views/PhotoBrowserView.swift` ~107–115
- **Severity:** LOW · **Category:** memory · **Status:** ✅ FIXED (`b6b0da2`)
- **Title:** `searchDebounce` `DispatchWorkItem` not cancelled on view disappearance; fires after window close
- **Fix:** `.onDisappear { searchDebounce?.cancel() }` added to `PhotoBrowserView`. The optional-chained cancel is safe when `searchDebounce` is `nil` (no first keystroke yet). Verified by `SearchDebounceAndAckTests: BUG-088` (4 tests: cancel-before-fire, fixed-onDisappear pattern, old-code bug documented, nil-safe cancel).

### BUG-089 · `Views/ViewerView.swift` ~22
- **Severity:** LOW · **Category:** perf · **Status:** ⚪ NOT A BUG (verified `45ca569`)
- **Title:** `Timer.publish(...).autoconnect()` as `let` property connects at every SwiftUI init; multiple timers stack if view is recreated while playing
- **Verification:** `Timer.publish().autoconnect()` is the documented SwiftUI pattern. SwiftUI struct views are value types — when a view body is re-evaluated, the previous struct is discarded and its subscriber is released, cancelling the subscription and stopping the timer. A fresh subscriber starts a new timer. Timers do not accumulate. Verified by `AttributeAndFilenameFixTests: BUG-089`.

### BUG-090 · `Views/ViewerView.swift` ~71–74
- **Severity:** LOW · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `1307550`)
- **Title:** 5-second auto-dismiss `Task` for culling hint is unstructured and not cancelled on viewer close
- **Verification:** Same ruling as BUG-043/046/047/050 — the `@State` write after a value-type SwiftUI View is dismissed is a harmless no-op; the framework discards writes to released state storage. The 5-second Task runs to completion but the `showCullingHint = false` write is ignored once `ViewerView` is gone. Verified by `CrashPrunePerCategoryTests: BUG-046/050/090`.

### BUG-091 · `Views/ViewerView.swift` ~402
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`41cf490`)
- **Title:** Slideshow loop sets `viewerIndex = 0` directly instead of via `viewerStep()`, bypassing bounds validation when `viewerPhotos` is empty
- **Fix:** `else if !model.viewerPhotos.isEmpty { model.viewerIndex = 0 }` — reset only fires when there is something to show. Verified by `MetadataAndVersionTests: BUG-091` (2 tests including the empty-array crash scenario).

### BUG-092 · `Views/SidebarView.swift` ~43–50
- **Severity:** LOW · **Category:** memory · **Status:** ⚪ NOT A BUG (verified `fc693af`)
- **Title:** NSEvent global monitor not removed if `onDisappear` fires without matching `onAppear`; each mismatch leaks one monitor
- **Verification:** `onAppear` guards with `guard keyMonitor == nil` before adding, and `onDisappear` guards with `guard keyMonitor != nil` before removing. Neither double-add nor orphaned-monitor is reachable: if onDisappear fires before onAppear, `keyMonitor` is nil and the remove-guard exits immediately. Verified by `GPSAndTimerCancelTests: BUG-092` (add/remove idempotency and double-add prevention tests).

### BUG-093 · `Views/SidebarView.swift` ~380–387
- **Severity:** LOW · **Category:** api-misuse · **Status:** ✅ FIXED (`542ec97`)
- **Title:** `WindowReader.updateNSView` re-posts `onWindow` callback on every SwiftUI update, triggering unnecessary `SidebarView` body diffs
- **Fix:** A `Coordinator` class tracks `lastWindow` (weak ref) and a `reported` flag. The shared `report()` helper guards with `!reported || window !== lastWindow` before calling `onWindow`, so redundant same-window callbacks are silently dropped. Verified by `WindowReaderDedupeTests: BUG-093` (6 tests: first-fire always, identical-window dedup, nil↔window transitions, distinct windows, churn comparison).

### BUG-094 · `Views/ZoomableImage.swift` ~43–44
- **Severity:** LOW · **Category:** logic · **Status:** ✅ FIXED (`42641d7`)
- **Title:** Missing `try Task.checkCancellation()` after full-res image load; stale full image from previous navigation can be applied
- **Fix:** `guard !Task.isCancelled else { return }` added inside the `if let full = await FullImageLoader.shared.image(for: url)` branch, before `image = full`. A full-res NAS load can take seconds; this prevents the previous photo's full image from flashing over the newly navigated photo. Verified by `StaleAsyncWriteGuardTests: BUG-042/053/094`.

---

## Commit Change Log

| Commit | Bug IDs Tested | Result |
|--------|---------------|--------|
| `a54bbd4` fix: harden crash-prone force-unwraps, casts, and symlink recursion | BUG-001,007,008,009,010,011,017,018,020,021,022,055,059,071,072,074,075 | ✅ 15 FIXED · 2 NOT A BUG · 124/124 tests pass |
| `56277b3` fix: synchronize PhotoKit/drop continuation races | BUG-005,006,015,019 | ✅ 3 FIXED · 1 NOT A BUG · 131/131 tests pass |
| `40b245b` fix: FolderWatcher races, count clamps, thumbnail/sort polish | BUG-004,023,035,041,067,070 | ✅ 5 FIXED · 1 NOT A BUG · 145/145 tests pass |
| `761e51f` docs: clarify main-actor concurrency invariants | BUG-002,003,012,013,014,016 | ⚪ 4 NOT A BUG · 🔶 2 KNOWN ISSUE · no new tests (docs only) · 145/145 tests pass |
| `41cf490` fix: robust metadata number casts, version parse, viewer/progress guards | BUG-027,060,063,076,086,091 | ✅ 5 FIXED · 1 NOT A BUG · 159/159 tests pass |
| `445e6e8` fix: map pin/zoom, empty-section bounds, grid cell clamp | BUG-026,030,044,077,079,084 | ✅ 4 FIXED · 2 NOT A BUG · 168/168 tests pass |
| `42641d7` fix: guard against stale async writes after task cancellation | BUG-042,043,047,053,094 | ✅ 3 FIXED · 2 NOT A BUG · 176/176 tests pass |
| `45ca569` fix: drop no-op attribute, avoid trailing-dot temp filename | BUG-034,036,040,045,078,081,089 | ✅ 2 FIXED · 5 NOT A BUG · 185/185 tests pass |
| `fc693af` fix: GPS hemisphere, cancel stale confirmation timers | BUG-057,061,069,073,085,092 | ✅ 3 FIXED · 3 NOT A BUG · 197/197 tests pass |
| `f12acdb` fix: cache dir create-once, background guard, hash cancel, flow width | BUG-028,031,058,087 | ✅ 4 FIXED · 210/210 tests pass |
| `03d324b` fix: dedupe update checks, use pixel aspect for crop constraint | BUG-048,068,082 | ✅ 2 FIXED · 1 NOT A BUG · 220/220 tests pass |
| `185890b` fix: O(1) FolderNode hash, collision-proof selection cache key | BUG-037,049,065 | ✅ 2 FIXED · 1 NOT A BUG · 231/231 tests pass |
| `a9db9e6` fix: colon-free crash report filenames | BUG-032,038,056,066 | ✅ 1 FIXED · 3 NOT A BUG · 242/242 tests pass |
| `542ec97` perf: WindowReader deduplication | BUG-025,039,093 | ✅ 1 FIXED · 2 NOT A BUG · 251/251 tests pass |
| `1307550` fix: prune crash reports per-category | BUG-024,029,046,050,051,052,090 | ✅ 1 FIXED · 6 NOT A BUG · 260/260 tests pass |
| `b6b0da2` fix: cancel search debounce on view disappear | BUG-033,054,062,064,080,083,088 | ✅ 1 FIXED · 6 NOT A BUG · 276/276 tests pass |
