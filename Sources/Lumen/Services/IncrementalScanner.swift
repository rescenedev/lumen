import Foundation

/// Scans roots but skips re-stat'ing files in folders whose modification date
/// hasn't changed since last scan — reusing cached `Photo` values instead.
/// On a NAS this turns ~50k per-file stat round-trips into a few hundred.
enum IncrementalScanner {
    struct Result: Sendable {
        let photos: [Photo]
        let folderMtimes: [String: Date]
    }

    private static let fileKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey
    ]

    static func scan(roots: [URL],
                     knownMtimes: [String: Date],
                     cachedByFolder: [String: [Photo]]) -> Result {
        let fm = FileManager.default
        var photos: [Photo] = []
        var mtimes: [String: Date] = [:]
        // Resolved directory paths already visited — guards against symlink
        // cycles (a link pointing at an ancestor) that would otherwise recurse
        // until the stack overflows on a malformed library.
        var visited: Set<String> = []

        func walk(_ dir: URL) {
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
                let entries = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: Array(fileKeys) + [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: fileKeys.union([.isDirectoryKey]))
                    if values?.isDirectory == true {
                        walk(entry)
                    } else if values?.isRegularFile == true, Photo.isSupported(entry), let values {
                        photos.append(Photo(url: entry, resourceValues: values))
                    }
                }
            }
        }

        for root in roots {
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
        return Result(photos: photos, folderMtimes: mtimes)
    }
}
