import Foundation
@testable import LumenKit

/// Covers the streaming import path added so a 30k-photo NAS folder shows
/// progress (and photos) while it is still being enumerated, instead of
/// publishing nothing at all until the whole walk finished.
func importStreamingTests() {
    let fm = FileManager.default

    func tempDir() -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-stream-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func touch(_ url: URL) { fm.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xE0])) }

    /// A tree of `folders` subfolders holding `perFolder` photos each.
    @discardableResult
    func buildTree(_ root: URL, folders: Int, perFolder: Int) -> Int {
        for f in 0..<folders {
            let sub = root.appendingPathComponent("f\(f)", isDirectory: true)
            try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
            for i in 0..<perFolder { touch(sub.appendingPathComponent("p\(i).jpg")) }
        }
        return folders * perFolder
    }

    /// Collector for the scanner's callbacks. The hooks are `@Sendable` and fire
    /// on the scanning thread, so the storage is lock-guarded even though the
    /// walk itself is single-threaded.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var batches: [[Photo]] = []
        private(set) var progress: [(found: Int, folder: String?)] = []
        func batch(_ photos: [Photo]) { lock.lock(); batches.append(photos); lock.unlock() }
        func tick(_ found: Int, _ folder: String?) {
            lock.lock(); progress.append((found, folder)); lock.unlock()
        }
        var streamed: [Photo] { lock.lock(); defer { lock.unlock() }; return batches.flatMap { $0 } }
    }

    // MARK: Streaming

    test("streamDeliversEveryPhotoExactlyOnceAcrossBatches") {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let total = buildTree(dir, folders: 8, perFolder: 25)   // 200 photos

        let sink = Sink()
        let stream = IncrementalScanner.Stream(
            batchSize: 30,
            onBatch: { sink.batch($0) },
            onProgress: { sink.tick($0, $1) }
        )
        let result = IncrementalScanner.scan(roots: [dir], knownMtimes: [:],
                                             cachedByFolder: [:], stream: stream)

        checkEqual(result.photos.count, total, "full result")
        check(result.completed, "an uninterrupted walk completes")
        let streamed = sink.streamed
        checkEqual(streamed.count, total, "streamed \(streamed.count) of \(total)")
        checkEqual(Set(streamed.map { $0.url }), Set(result.photos.map { $0.url }),
                   "streamed set must equal the full result — no drops, no duplicates")
        check(sink.batches.count > 1, "200 photos at batchSize 30 should take several batches, got \(sink.batches.count)")
    }

    test("streamReportsProgressBeforeTheWalkFinishes") {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        buildTree(dir, folders: 6, perFolder: 10)

        let sink = Sink()
        _ = IncrementalScanner.scan(
            roots: [dir], knownMtimes: [:], cachedByFolder: [:],
            stream: IncrementalScanner.Stream(batchSize: 5,
                                              progressInterval: 0,   // every folder boundary
                                              onBatch: { sink.batch($0) },
                                              onProgress: { sink.tick($0, $1) }))

        check(sink.progress.count > 1, "expected repeated progress ticks, got \(sink.progress.count)")
        check(sink.progress.contains { $0.found > 0 && $0.found < 60 },
              "at least one tick must land mid-walk (a partial count)")
        check(sink.progress.last?.found == 60, "final tick reports the total, got \(sink.progress.last?.found ?? -1)")
        check(sink.progress.dropLast().contains { $0.folder != nil },
              "ticks name the folder being read")
    }

    test("streamIsOptional_noHooksBehavesLikeBefore") {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let total = buildTree(dir, folders: 3, perFolder: 4)
        let result = IncrementalScanner.scan(roots: [dir], knownMtimes: [:], cachedByFolder: [:])
        checkEqual(result.photos.count, total)
        check(result.completed)
    }

    // MARK: Cancellation

    test("cancelStopsTheWalkAndKeepsWhatWasFound") {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        buildTree(dir, folders: 20, perFolder: 20)   // 400 photos

        let sink = Sink()
        // Cancel as soon as the first batch has been handed over.
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var on = false
            var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
            func set() { lock.lock(); on = true; lock.unlock() }
        }
        let flag = Flag()
        let result = IncrementalScanner.scan(
            roots: [dir], knownMtimes: [:], cachedByFolder: [:],
            stream: IncrementalScanner.Stream(batchSize: 20,
                                              onBatch: { sink.batch($0); flag.set() },
                                              isCancelled: { flag.value }))

        check(!result.completed, "a cancelled walk must report completed == false")
        check(!result.photos.isEmpty, "photos found before the cancel are kept")
        check(result.photos.count < 400, "expected an early stop, got the whole tree (\(result.photos.count))")
        checkEqual(Set(sink.streamed.map { $0.url }), Set(result.photos.map { $0.url }),
                   "the tail batch ships even after a cancel")
    }

    test("cancelledScanMtimesAreNotTrustedByTheCaller") {
        // The scanner records a folder's mtime BEFORE reading its entries, so a
        // walk abandoned mid-folder can hold an mtime for a folder it never
        // finished. `completed == false` is the caller's signal not to persist
        // them — a wrongly persisted entry would make the folder look scanned
        // forever and its photos would never appear.
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        buildTree(dir, folders: 5, perFolder: 5)
        let result = IncrementalScanner.scan(
            roots: [dir], knownMtimes: [:], cachedByFolder: [:],
            stream: IncrementalScanner.Stream(batchSize: 1,
                                              onBatch: { _ in },
                                              isCancelled: { true }))
        check(!result.completed)
        check(result.photos.isEmpty, "cancelled before the first folder, got \(result.photos.count)")
    }

    // MARK: Folder-mtime merge

    test("mergeFolderMtimesKeepsEntriesFromOtherRoots") {
        let tmp = tempDir()
        LibraryCache.directoryOverride = tmp
        defer {
            LibraryCache.flushForTesting()
            LibraryCache.directoryOverride = nil
            try? fm.removeItem(at: tmp)
        }
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        LibraryCache.saveFolderMtimes(["/Volumes/nas/a": old, "/Users/x/b": old])
        LibraryCache.mergeFolderMtimes(["/Volumes/nas/a": new, "/Volumes/nas/c": new])

        let loaded = LibraryCache.loadFolderMtimes()
        checkEqual(loaded.count, 3, "merge must not drop the untouched root")
        checkEqual(loaded["/Users/x/b"], old, "untouched entry survives")
        checkEqual(loaded["/Volumes/nas/a"], new, "rescanned entry is updated")
        checkEqual(loaded["/Volumes/nas/c"], new, "newly imported entry is added")
    }

    test("mergeFolderMtimesOnEmptyInputIsANoOp") {
        let tmp = tempDir()
        LibraryCache.directoryOverride = tmp
        defer {
            LibraryCache.flushForTesting()
            LibraryCache.directoryOverride = nil
            try? fm.removeItem(at: tmp)
        }
        let stamp = Date(timeIntervalSince1970: 42)
        LibraryCache.saveFolderMtimes(["/a": stamp])
        LibraryCache.mergeFolderMtimes([:])
        LibraryCache.flushForTesting()
        checkEqual(LibraryCache.loadFolderMtimes(), ["/a": stamp])
    }

    // MARK: Folder-index key

    test("folderKeyMatchesFolderURLPathSoIncrementalAppendAgrees") {
        // `appendScanned` extends the folder index one batch at a time while the
        // full rebuild regroups everything; if the two keys ever diverge, a
        // folder click after an import silently misses photos.
        let cases = [
            "/Volumes/data0/photos/2011.Turkey/IMGP4142.jpg",
            "/Users/x/Desktop/한글 폴더/사진 (1).HEIC",
            "/a/b.jpg",
            "/top.jpg",
        ]
        for path in cases {
            let photo = Photo(url: URL(fileURLWithPath: path), byteSize: 1,
                              creationDate: nil, modificationDate: nil)
            checkEqual(AppModel.folderKey(for: photo), photo.folderURL.path,
                       "key mismatch for \(path)")
        }
    }

    // MARK: Progress monitor

    // The harness runs on the process's main thread, so the main actor's
    // isolation is genuinely satisfied here.
    func onMain(_ body: @MainActor () -> Void) { MainActor.assumeIsolated(body) }

    test("scanMonitorTracksOneImport") {
        onMain {
            let monitor = ScanMonitor()
            check(!monitor.isScanning, "idle before begin")
            let token = monitor.begin()
            check(monitor.isScanning)
            monitor.update(token, found: 120, folder: "Trip")
            monitor.addedPhotos(token, 100)
            monitor.addedPhotos(token, 20)
            checkEqual(monitor.found, 120)
            checkEqual(monitor.added, 120, "added accumulates across batches")
            checkEqual(monitor.folder, "Trip")

            monitor.cancel()
            check(monitor.isStopping)
            check(token.isCancelled, "cancel must reach the token the scanner polls")

            monitor.finish(token)
            check(!monitor.isScanning)
            check(!monitor.isStopping)
            checkNil(monitor.folder)
        }
    }

    test("scanMonitorIgnoresAFinishedImportOnceANewerOneOwnsTheDisplay") {
        // An import keeps working after its walk ends (EXIF, cache writes). If a
        // second import starts in that window, the first one's late finish/update
        // must not blank or rewrite the second one's progress.
        onMain {
            let monitor = ScanMonitor()
            let first = monitor.begin()
            monitor.update(first, found: 10, folder: "old")

            let second = monitor.begin()
            checkEqual(monitor.found, 0, "begin resets the counters for the new import")
            monitor.update(second, found: 500, folder: "new")

            monitor.update(first, found: 11, folder: "old")
            monitor.addedPhotos(first, 999)
            checkEqual(monitor.found, 500, "a stale import can't rewrite the count")
            checkEqual(monitor.folder, "new")
            checkEqual(monitor.added, 0, "a stale import can't inflate the added count")

            monitor.finish(first)
            check(monitor.isScanning, "a stale finish must not end the running import")

            monitor.finish(second)
            check(!monitor.isScanning)
        }
    }

    test("scanMonitorFinishIsIdempotent") {
        onMain {
            let monitor = ScanMonitor()
            let token = monitor.begin()
            monitor.finish(token)
            monitor.finish(token)   // the explicit call + the defer backstop
            check(!monitor.isScanning)
        }
    }

    test("scanCancelTokenIsThreadSafeAndOneWay") {
        let token = ScanCancelToken()
        check(!token.isCancelled)
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async { token.cancel(); group.leave() }
        }
        group.wait()
        check(token.isCancelled, "cancel never un-sets")
    }

    // MARK: Status text

    test("scanStatusTextShowsBothNumbersOnlyWhenTheyDiffer") {
        // Counts go through Int.formatted(), so the expectations are built the
        // same way — the assertion is about the wording, not the machine locale.
        checkEqual(ScanStatusText.statusBar(found: 12_480, added: 12_000,
                                            folder: "2011.Turkey", stopping: false),
                   "Reading folder · \(12_480.formatted()) found · \(12_000.formatted()) new · 2011.Turkey",
                   "some photos were already in the library — say so")
        checkEqual(ScanStatusText.statusBar(found: 12_480, added: 12_480,
                                            folder: nil, stopping: false),
                   "Reading folder · \(12_480.formatted()) photos",
                   "a fresh import shows one number, not the same one twice")
        checkEqual(ScanStatusText.statusBar(found: 5, added: 5, folder: "", stopping: false),
                   "Reading folder · 5 photos", "an empty folder name is dropped, not appended")
        checkEqual(ScanStatusText.statusBar(found: 5, added: 5, folder: "x", stopping: true),
                   "Stopping…")
    }

    test("warmingTextAlwaysCarriesADenominator") {
        // The old status line was a bare countdown ("Caching 29,412") — a number
        // with nothing to measure it against.
        checkEqual(BackgroundWorkText.warming(done: 12_340, total: 30_124, folder: "2011.Turkey"),
                   "Thumbnails \(12_340.formatted()) / \(30_124.formatted()) · 41% · 2011.Turkey")
        checkEqual(BackgroundWorkText.warming(done: 0, total: 8, folder: nil),
                   "Thumbnails 0 / 8 · 0%")
        checkEqual(BackgroundWorkText.warming(done: 8, total: 8, folder: nil),
                   "Thumbnails 8 / 8 · 100%")
        checkEqual(BackgroundWorkText.warming(done: 0, total: 0, folder: nil),
                   "Thumbnails 0 / 0", "no total yet ⇒ no misleading 0%/NaN")
    }

    test("warmingMonitorDerivesDoneAndFraction") {
        onMain {
            let monitor = WarmingMonitor()
            checkEqual(monitor.done, 0)
            checkEqual(monitor.fraction, 0, "no division by zero before a total lands")

            monitor.update(remaining: 30_124, total: 30_124, folder: "a")
            checkEqual(monitor.done, 0)
            checkEqual(monitor.fraction, 0)

            monitor.update(remaining: 17_784, total: 30_124, folder: "b")
            checkEqual(monitor.done, 12_340)
            check(abs(monitor.fraction - 12_340.0 / 30_124.0) < 0.0001)

            // A late tick from a superseded pass (bigger remaining than its own
            // total) must not drive the bar past full or negative.
            monitor.update(remaining: 500, total: 100, folder: nil)
            checkEqual(monitor.total, 500)
            checkEqual(monitor.done, 0)
            check(monitor.fraction >= 0 && monitor.fraction <= 1)
        }
    }
}
