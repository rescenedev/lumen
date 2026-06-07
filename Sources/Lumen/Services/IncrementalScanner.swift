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

        func walk(_ dir: URL) {
            let dirMtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            mtimes[dir.path] = dirMtime

            let unchanged = dirMtime != nil
                && knownMtimes[dir.path] == dirMtime
                && cachedByFolder[dir.path] != nil

            if unchanged {
                // Reuse cached photos; only list to find subfolders (cheap — no per-file stat).
                photos.append(contentsOf: cachedByFolder[dir.path] ?? [])
                let subdirs = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
                for entry in subdirs where
                    (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    walk(entry)
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
