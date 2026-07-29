import Foundation

/// Scans roots but skips re-stat'ing files in folders whose modification date
/// hasn't changed since last scan — reusing cached `Photo` values instead.
/// On a NAS this turns ~50k per-file stat round-trips into a few hundred.
enum IncrementalScanner {
    struct Result: Sendable {
        let photos: [Photo]
        let folderMtimes: [String: Date]
        /// False when the walk was abandoned early (the caller cancelled).
        /// `folderMtimes` is then NOT safe to persist: a directory records its
        /// mtime before its entries are read, so a folder abandoned mid-read
        /// would be remembered as fully scanned and skipped forever after.
        let completed: Bool

        init(photos: [Photo], folderMtimes: [String: Date], completed: Bool = true) {
            self.photos = photos
            self.folderMtimes = folderMtimes
            self.completed = completed
        }
    }

    /// Optional streaming hooks. Without them `scan` behaves exactly as before:
    /// one result once the whole tree has been walked. With them the caller
    /// receives photos and a running count *while* the walk is still going —
    /// which is the difference between "the app froze" and "it's importing" when
    /// a 30k-photo NAS folder takes minutes to enumerate.
    ///
    /// Every hook is invoked on the scanning thread, at folder boundaries only.
    struct Stream: Sendable {
        /// Hand over accumulated photos once this many are pending. The caller
        /// picks it: each hand-off costs the UI a library-version bump, so a
        /// large library wants larger batches.
        var batchSize: Int = 1000
        /// Hand over a short batch anyway once this long has passed, so a slow
        /// (or sparse) NAS walk still shows the grid growing.
        var flushInterval: TimeInterval = 3
        /// How often the running count may be republished.
        var progressInterval: TimeInterval = 0.25
        var onBatch: @Sendable ([Photo]) -> Void
        var onProgress: @Sendable (_ found: Int, _ folder: String?) -> Void = { _, _ in }
        /// Polled at every folder boundary; `true` abandons the walk.
        var isCancelled: @Sendable () -> Bool = { false }
    }

    private static let fileKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey
    ]

    static func scan(roots: [URL],
                     knownMtimes: [String: Date],
                     cachedByFolder: [String: [Photo]],
                     stream: Stream? = nil) -> Result {
        let fm = FileManager.default
        var photos: [Photo] = []
        var mtimes: [String: Date] = [:]
        // Resolved directory paths already visited — guards against symlink
        // cycles (a link pointing at an ancestor) that would otherwise recurse
        // until the stack overflows on a malformed library.
        var visited: Set<String> = []

        // Streaming bookkeeping: `flushed` is how much of `photos` the caller
        // already has, so batches need no second buffer.
        var flushed = 0
        var lastFlush = CFAbsoluteTimeGetCurrent()
        var lastProgress: CFAbsoluteTime = 0
        var cancelled = false

        func publish(folder: String?, force: Bool) {
            guard let stream else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let pending = photos.count - flushed
            if pending > 0, force || pending >= stream.batchSize
                || now - lastFlush >= stream.flushInterval {
                stream.onBatch(Array(photos[flushed...]))
                flushed = photos.count
                lastFlush = now
            }
            // The count moves even through folders that yield nothing, so a walk
            // over a deep tree of empty directories still looks alive.
            if force || now - lastProgress >= stream.progressInterval {
                lastProgress = now
                stream.onProgress(photos.count, folder)
            }
        }

        func checkCancelled() -> Bool {
            if !cancelled, stream?.isCancelled() == true { cancelled = true }
            return cancelled
        }

        func walk(_ dir: URL) {
            guard !checkCancelled() else { return }
            guard visited.insert(dir.resolvingSymlinksInPath().path).inserted else { return }
            let dirMtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            mtimes[dir.path] = dirMtime

            let unchanged = dirMtime != nil
                && knownMtimes[dir.path] == dirMtime
                && cachedByFolder[dir.path] != nil

            if unchanged {
                // Mtime says the folder is untouched — but the mtime cache and the
                // photo cache are persisted separately and can drift out of sync
                // (a stale entry then survives forever). So instead of blindly
                // trusting the cache, reconcile it against the live listing: reuse
                // cached metadata for files still present (NO per-file stat — the
                // NAS win), drop files that vanished, and stat only genuinely new
                // ones. The listing is the one readdir we already do for subfolders.
                let listing = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
                if let entries = listing {
                    let cached = Dictionary(
                        (cachedByFolder[dir.path] ?? []).map { ($0.url, $0) },
                        uniquingKeysWith: { a, _ in a })
                    for entry in entries {
                        if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                            walk(entry)
                        } else if Photo.isSupported(entry) {
                            if let hit = cached[entry] {
                                photos.append(hit)                          // present — reuse, no stat
                            } else if let values = try? entry.resourceValues(forKeys: fileKeys),
                                      values.isRegularFile == true {
                                photos.append(Photo(url: entry, resourceValues: values))   // new — stat just this one
                            }
                        }
                    }
                } else {
                    // Listing failed (e.g. a transient NAS hiccup) — keep the cached
                    // photos as-is rather than wrongly dropping the whole folder.
                    photos.append(contentsOf: cachedByFolder[dir.path] ?? [])
                }
            } else {
                // Changed (or first time): full listing with file metadata prefetched.
                let listing = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: Array(fileKeys) + [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
                guard let entries = listing else {
                    // Listing failed (e.g. a transient NAS hiccup) while the folder is
                    // still reachable. Mirror the unchanged branch: keep the cached
                    // photos rather than pruning the whole folder. A failed dir-mtime
                    // read lands us here (not the unchanged branch), so this is the
                    // common transient-failure path — substituting [] would silently
                    // drop the folder's photos and EXIF until the next good scan.
                    photos.append(contentsOf: cachedByFolder[dir.path] ?? [])
                    return
                }
                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: fileKeys.union([.isDirectoryKey]))
                    if values?.isDirectory == true {
                        walk(entry)
                    } else if values?.isRegularFile == true, Photo.isSupported(entry), let values {
                        photos.append(Photo(url: entry, resourceValues: values))
                    }
                }
            }
            // Folder boundary: everything found under `dir` is complete, so it is
            // safe to hand to the caller.
            guard !cancelled else { return }
            publish(folder: dir.lastPathComponent, force: false)
        }

        for root in roots {
            guard !checkCancelled() else { break }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                walk(root)
            } else if Photo.isSupported(root),
                      let values = try? root.resourceValues(forKeys: fileKeys),
                      values.isRegularFile == true {
                photos.append(Photo(url: root, resourceValues: values))
            }
        }
        // Final hand-off: the tail batch always ships, even after a cancel, so
        // the caller keeps the photos it already paid the NAS to enumerate.
        publish(folder: nil, force: true)
        return Result(photos: photos, folderMtimes: mtimes, completed: !cancelled)
    }
}
