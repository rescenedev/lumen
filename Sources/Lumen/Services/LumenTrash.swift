import Foundation

/// Safety net for deletions on volumes without a system Trash (NAS/SMB).
/// Instead of deleting in place — unrecoverable unless the NAS happens to run
/// a server-side recycle bin — files move into a hidden
/// `<library root>/.LumenTrash/<timestamp>/` folder on the same volume, so the
/// move is a rename (instant even over SMB) and the deletion can be undone.
/// Staged batches older than 30 days are purged at startup. The folder is
/// dot-prefixed, so library scans (which use `.skipsHiddenFiles`) never pick
/// the staged files back up.
enum LumenTrash {
    static let folderName = ".LumenTrash"
    static let retentionDays = 30

    /// The library root containing `url` (deepest match), or nil if the file
    /// lives outside every open root.
    static func root(for url: URL, roots: [URL]) -> URL? {
        let path = url.path
        return roots
            .filter { path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// One human-readable batch name per delete action, e.g. "2026-06-12 21.30.45".
    static func stamp(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    /// Move `url` into `<root>/.LumenTrash/<stamp>/`, suffixing the filename
    /// on collision. Returns the staged location (needed to undo).
    static func stage(_ url: URL, under root: URL, stamp: String) throws -> URL {
        let fm = FileManager.default
        let batchDir = root
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try fm.createDirectory(at: batchDir, withIntermediateDirectories: true)

        var dest = batchDir.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        if fm.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var counter = 2
            repeat {
                let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                dest = batchDir.appendingPathComponent(name, isDirectory: false)
                counter += 1
            } while fm.fileExists(atPath: dest.path)
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    /// Purge staged batches older than `maxAge` in each root, and remove the
    /// `.LumenTrash` folder itself once empty. Cheap when nothing is staged:
    /// one directory listing per root.
    static func cleanup(roots: [URL],
                        maxAge: TimeInterval = TimeInterval(retentionDays) * 86_400,
                        now: Date = Date()) {
        let fm = FileManager.default
        for root in roots {
            let trashDir = root.appendingPathComponent(folderName, isDirectory: true)
            guard let batches = try? fm.contentsOfDirectory(
                at: trashDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []) else { continue }
            var remaining = batches.count
            for batch in batches {
                let modified = (try? batch.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                if now.timeIntervalSince(modified) > maxAge {
                    do { try fm.removeItem(at: batch); remaining -= 1 }
                    catch { NSLog("LumenTrash: cleanup failed for \(batch.path): \(error.localizedDescription)") }
                }
            }
            if remaining <= 0 { try? fm.removeItem(at: trashDir) }
        }
    }
}
