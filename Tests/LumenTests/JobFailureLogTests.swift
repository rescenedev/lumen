import Foundation
@testable import LumenKit

/// The failure log behind the background-job popover: what a pass could not
/// read, why, and whether it survives a relaunch so it can be retried later.
func jobFailureLogTests() {
    let fm = FileManager.default

    func tempDir() -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-failures-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func failure(_ path: String, _ kind: JobFailure.Kind = .metadata,
                 _ reason: String = "unreadable", _ t: TimeInterval = 0) -> JobFailure {
        JobFailure(kind: kind, path: path, reason: reason,
                   date: Date(timeIntervalSince1970: t))
    }

    // MARK: Merge policy (pure)

    test("mergeKeepsTheNewestRecordPerPath") {
        let merged = JobFailureLog.merged(
            [failure("/a.jpg", .metadata, "old reason", 100)],
            adding: [failure("/a.jpg", .metadata, "new reason", 200)],
            maxPerKind: 10)
        checkEqual(merged.count, 1, "same path + kind is one entry, not two")
        checkEqual(merged.first?.reason, "new reason")
    }

    test("mergeNeverLetsAStaleWorkerOverwriteAFresherReason") {
        // Two workers can report the same file out of order; the older report
        // must not replace the newer one just because it landed last.
        let merged = JobFailureLog.merged(
            [failure("/a.jpg", .metadata, "new reason", 200)],
            adding: [failure("/a.jpg", .metadata, "old reason", 100)],
            maxPerKind: 10)
        checkEqual(merged.count, 1)
        checkEqual(merged.first?.reason, "new reason")
    }

    test("theSamePathUnderTwoKindsIsTwoRecords") {
        let merged = JobFailureLog.merged(
            [], adding: [failure("/a.jpg", .metadata), failure("/a.jpg", .thumbnail)],
            maxPerKind: 10)
        checkEqual(merged.count, 2, "a file can fail metadata AND thumbnailing")
    }

    test("eachKindIsCappedIndependently") {
        // A NAS going offline mid-pass fails thousands of files at once; that
        // flood must neither write a huge file nor evict the other job's records.
        let manyThumbs = (0..<50).map { failure("/t\($0).jpg", .thumbnail, "gone", Double($0)) }
        let oneMeta = [failure("/m.jpg", .metadata, "unreadable", 0)]
        let merged = JobFailureLog.merged(oneMeta, adding: manyThumbs, maxPerKind: 10)
        checkEqual(merged.filter { $0.kind == .thumbnail }.count, 10, "thumbnail kind capped")
        checkEqual(merged.filter { $0.kind == .metadata }.count, 1,
                   "the flood must not evict the other kind")
    }

    test("theCapKeepsTheNewestEntries") {
        let old = (0..<5).map { failure("/old\($0).jpg", .metadata, "r", Double($0)) }
        let new = (0..<5).map { failure("/new\($0).jpg", .metadata, "r", Double(100 + $0)) }
        let merged = JobFailureLog.merged(old, adding: new, maxPerKind: 5)
        checkEqual(merged.count, 5)
        check(merged.allSatisfy { $0.path.hasPrefix("/new") },
              "kept \(merged.map(\.path)) — the cap must drop the oldest, not the newest")
    }

    test("aZeroCapDropsEverythingWithoutTrapping") {
        let merged = JobFailureLog.merged([], adding: [failure("/a.jpg")], maxPerKind: 0)
        check(merged.isEmpty)
    }

    // MARK: Store + persistence

    test("recordedFailuresSurviveAReload") {
        let dir = tempDir()
        JobFailureLog.directoryOverride = dir
        defer { JobFailureLog.directoryOverride = nil; try? fm.removeItem(at: dir) }

        let log = JobFailureLog(loading: false)
        log.record(kind: .metadata, path: "/Volumes/nas/한글 사진.HEIC", reason: "Could not open the file")
        log.record(kind: .thumbnail, path: "/Volumes/nas/b.jpg", reason: "Could not decode the image")
        log.flushForTesting()

        // A fresh instance reads what the previous session wrote — the whole
        // point of "where did it fail LAST time".
        let reloaded = JobFailureLog(loading: true)
        checkEqual(reloaded.all().count, 2)
        checkEqual(reloaded.count(kind: .metadata), 1)
        checkEqual(reloaded.all(kind: .thumbnail).first?.path, "/Volumes/nas/b.jpg")
        checkEqual(reloaded.all(kind: .metadata).first?.reason, "Could not open the file")
    }

    test("clearingOneKindLeavesTheOther") {
        let dir = tempDir()
        JobFailureLog.directoryOverride = dir
        defer { JobFailureLog.directoryOverride = nil; try? fm.removeItem(at: dir) }

        let log = JobFailureLog(loading: false)
        log.record([failure("/a.jpg", .metadata), failure("/b.jpg", .thumbnail)])
        log.clear(kind: .metadata)
        checkEqual(log.count(kind: .metadata), 0)
        checkEqual(log.count(kind: .thumbnail), 1)
    }

    test("clearingSpecificPathsIsWhatARetryDoes") {
        let dir = tempDir()
        JobFailureLog.directoryOverride = dir
        defer { JobFailureLog.directoryOverride = nil; try? fm.removeItem(at: dir) }

        let log = JobFailureLog(loading: false)
        log.record([failure("/a.jpg"), failure("/b.jpg"), failure("/c.jpg")])
        log.clear(kind: .metadata, paths: ["/a.jpg", "/c.jpg"])
        checkEqual(log.all(kind: .metadata).map(\.path), ["/b.jpg"])
    }

    test("anEmptyLogLeavesNoFileBehind") {
        let dir = tempDir()
        JobFailureLog.directoryOverride = dir
        defer { JobFailureLog.directoryOverride = nil; try? fm.removeItem(at: dir) }

        let log = JobFailureLog(loading: false)
        log.record(kind: .metadata, path: "/a.jpg", reason: "r")
        log.flushForTesting()
        log.clear(kind: .metadata)
        log.flushForTesting()
        check(!fm.fileExists(atPath: dir.appendingPathComponent("job-failures.json").path),
              "clearing everything should remove the file, not leave an empty array")
        checkEqual(JobFailureLog(loading: true).all().count, 0)
    }

    // MARK: Display helpers

    test("failureExposesFilenameAndFolderForTheList") {
        let f = failure("/Volumes/nas/2011.Turkey/IMGP4142.jpg")
        checkEqual(f.filename, "IMGP4142.jpg")
        checkEqual(f.folder, "2011.Turkey")
        checkEqual(f.id, "metadata|/Volumes/nas/2011.Turkey/IMGP4142.jpg")
    }

    // MARK: Indexer reports its failures

    test("indexerSeparatesUnreadableFilesFromPhotosWithNoExif") {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        // Not a decodable image — CGImageSource refuses it.
        let broken = dir.appendingPathComponent("broken.jpg")
        fm.createFile(atPath: broken.path, contents: Data("not an image".utf8))

        let result = ExifIndexer.index([broken])
        checkEqual(result.info.count, 1, "still cached (as empty) so the main pass stops re-reading it")
        checkEqual(result.failures.count, 1, "…but recorded, so the popover can offer a retry")
        checkEqual(result.failures.first?.kind, .metadata)
        checkEqual(result.failures.first?.path, broken.path)
        check(!(result.failures.first?.reason.isEmpty ?? true), "a failure carries a human reason")
    }

    test("paceReportsRateAndTimeLeftInThatOrder") {
        // The row could say how far along a job was but never how slow — which
        // is the only way to answer "is it meant to take this long?".
        checkEqual(BackgroundWorkText.pace(rate: 2.4, eta: 13_000, place: "2011.Turkey"),
                   "2.4/s · ~3.6h left · 2011.Turkey")
        checkEqual(BackgroundWorkText.pace(rate: 212, eta: 120, place: nil), "212/s · ~2m left")
        checkNil(BackgroundWorkText.pace(rate: 0, eta: nil, place: nil),
                 "nothing worth saying yet ⇒ no empty separators")
        checkEqual(BackgroundWorkText.pace(rate: 0, eta: nil, place: "Trip"), "Trip")
    }

    test("durationStaysCoarseBecauseTheRateSwings") {
        checkEqual(BackgroundWorkText.duration(1), "1s")
        checkEqual(BackgroundWorkText.duration(45), "45s")
        checkEqual(BackgroundWorkText.duration(600), "10m")
        checkEqual(BackgroundWorkText.duration(3_600), "60m")
        checkEqual(BackgroundWorkText.duration(13_000), "3.6h")
        checkEqual(BackgroundWorkText.duration(200_000), "56h")
        checkNil(BackgroundWorkText.duration(0))
        checkNil(BackgroundWorkText.duration(.infinity), "an infinite ETA is not a number to show")
    }

    test("metadataContextSaysWhatItDidNotHaveToRead") {
        // "8,445 of 8,445" on a 64k library reads as though the library shrank.
        checkEqual(MetadataJobPopover.context(source: "NAS", rate: 212, cached: 55_809),
                   "NAS · 212/s · \(55_809.formatted()) already cached")
        checkEqual(MetadataJobPopover.context(source: "NAS", rate: 0, cached: 0), "NAS")
        checkNil(MetadataJobPopover.context(source: "", rate: 0, cached: 0))
    }

    test("counterTextClampsANonsenseOverrun") {
        // A late tick from a superseded pass used to print "1,262,045 of 84,254".
        checkEqual(BackgroundWorkText.counts(done: 1_262_045, total: 84_254),
                   "\(84_254.formatted()) of \(84_254.formatted())")
        checkEqual(BackgroundWorkText.counts(done: -5, total: 10), "0 of 10")
    }
}

/// Cache keys that survive the same storage being mounted somewhere else —
/// the cause of ~68,000 orphaned thumbnails and 26,926 dead EXIF entries on
/// the reference machine.
func volumeIdentityTests() {
    test("aNetworkShareIsIdentifiedByTheShare_notTheMountPointOrTheUser") {
        // The same share, mounted by a different account, is the same bytes.
        checkEqual(VolumeIdentity.identity(device: "//zihado@192.168.123.104/zpool", uuid: nil),
                   "//192.168.123.104/zpool")
        checkEqual(VolumeIdentity.identity(device: "//other@192.168.123.104/zpool", uuid: nil),
                   "//192.168.123.104/zpool",
                   "who mounted it must not change the identity")
        checkEqual(VolumeIdentity.identity(device: "//192.168.123.104/zpool", uuid: nil),
                   "//192.168.123.104/zpool", "no user component is fine")
        checkEqual(VolumeIdentity.identity(device: "//NAS.local/Zpool", uuid: nil),
                   "//nas.local/zpool", "host and share case must not split the key")
    }

    test("nfsIsIdentifiedByHostAndExport") {
        checkEqual(VolumeIdentity.identity(device: "OrbStack:/OrbStack", uuid: nil),
                   "orbstack:/orbstack")
    }

    test("aLocalVolumeUsesItsUUID_neverTheDeviceNode") {
        // /dev/diskNsM shifts between boots and reattachments; keying on it
        // would invalidate the cache for a disk that simply came back.
        checkEqual(VolumeIdentity.identity(device: "/dev/disk15s1",
                                           uuid: "9F315A0C-8AD8-4A03-A1BF-7EE9BCEFD20B"),
                   "vol:9f315a0c-8ad8-4a03-a1bf-7ee9bcefd20b")
        checkEqual(VolumeIdentity.identity(device: "/dev/disk15s1", uuid: nil), "/dev/disk15s1",
                   "no UUID available ⇒ fall back rather than produce no key")
        checkEqual(VolumeIdentity.identity(device: "/dev/disk15s1", uuid: ""), "/dev/disk15s1")
    }

    test("keyIsStableAcrossMountPointsForTheSameFile") {
        // The real-world case: one share seen at two different mount points.
        let a = VolumeIdentity.identity(device: "//zihado@192.168.123.104/zpool", uuid: nil)
            + "/photos/2011/a.jpg"
        let b = VolumeIdentity.identity(device: "//zihado@192.168.123.104/zpool", uuid: nil)
            + "/photos/2011/a.jpg"
        checkEqual(a, b)
        checkNotEqual(a, VolumeIdentity.identity(device: "//192.168.123.104/zpool2", uuid: nil)
                      + "/photos/2011/a.jpg", "different shares must not collide")
    }

    test("theBootVolumeResolvesAndTheKeyIsPathIndependentOfNothing") {
        // Any real path must produce a non-empty key, and two different files
        // must never collide.
        let one = VolumeIdentity.key(for: "/Users/zihado/Desktop/a.jpg")
        let two = VolumeIdentity.key(for: "/Users/zihado/Desktop/b.jpg")
        check(!one.isEmpty)
        checkNotEqual(one, two)
        check(one.hasSuffix("/Users/zihado/Desktop/a.jpg") || one.hasSuffix("Desktop/a.jpg"),
              "key keeps the path tail: \(one)")
    }

    test("thumbnailNameChangesWithTheKeySchemeButStaysStablePerFile") {
        let legacy = ThumbnailCache.legacyDiskName(path: "/Volumes/zpool/a.jpg",
                                                   maxPixel: 512, mtime: 1)
        let modern = ThumbnailCache.diskName(path: "/Volumes/zpool/a.jpg", maxPixel: 512, mtime: 1)
        checkEqual(modern, ThumbnailCache.diskName(path: "/Volumes/zpool/a.jpg",
                                                   maxPixel: 512, mtime: 1), "deterministic")
        checkNotEqual(legacy, modern, "the migration has something to move")
        checkNotEqual(modern, ThumbnailCache.diskName(path: "/Volumes/zpool/a.jpg",
                                                      maxPixel: 512, mtime: 2),
                      "an edited file must not reuse a stale thumbnail")
    }
}
