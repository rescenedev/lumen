import Foundation
import GRDB

/// Persists Lumen-owned metadata (favorites, ratings, labels, tags, albums) in
/// SQLite. Keeps an in-memory mirror for fast reads (so counting over 60k photos
/// stays a dictionary lookup) while writes go to the DB one row at a time —
/// no full-file rewrites. The image files are never modified.
final class MetadataStore {
    private let db: DatabaseQueue
    private var itemsCache: [String: PhotoMeta] = [:]
    private var albumsCache: [Album] = []

    /// Fired once per session on the first failed DB write. Without it a full
    /// disk or corrupt lumen.sqlite silently stops persisting favorites/
    /// ratings/albums while the in-memory mirror keeps "working" until quit.
    var onFirstWriteFailure: (() -> Void)?
    private var reportedWriteFailure = false

    /// All writes go through here so a failure is logged and surfaced (once).
    private func write(_ updates: (Database) throws -> Void) {
        do {
            try db.write(updates)
        } catch {
            NSLog("Lumen: metadata write failed: \(error)")
            if !reportedWriteFailure {
                reportedWriteFailure = true
                onFirstWriteFailure?()
            }
        }
    }

    init() {
        db = AppDatabase.shared.queue
        load()
        migrateLegacyJSONIfNeeded()
    }

    /// Test seam: run against an isolated database, skipping the one-time
    /// migration from the legacy `library.json` (which reads real user files).
    init(queue: DatabaseQueue) {
        db = queue
        load()
    }

    // MARK: - Access

    var items: [String: PhotoMeta] { itemsCache }
    var albums: [Album] { albumsCache }

    func meta(for path: String) -> PhotoMeta { itemsCache[path] ?? PhotoMeta() }

    func update(_ path: String, _ transform: (inout PhotoMeta) -> Void) {
        var meta = itemsCache[path] ?? PhotoMeta()
        transform(&meta)
        if meta.isEmpty {
            itemsCache.removeValue(forKey: path)
            write { try $0.execute(sql: "DELETE FROM photo_meta WHERE path = ?", arguments: [path]) }
        } else {
            itemsCache[path] = meta
            let tags = (try? String(data: JSONEncoder().encode(meta.tags), encoding: .utf8)) ?? "[]"
            write {
                try $0.execute(sql: """
                    INSERT INTO photo_meta (path, favorite, rating, label, tags, rejected) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET favorite=excluded.favorite, rating=excluded.rating,
                        label=excluded.label, tags=excluded.tags, rejected=excluded.rejected
                    """, arguments: [path, meta.favorite, meta.rating, meta.label.rawValue, tags, meta.rejected])
            }
        }
    }

    /// Apply one transform to many paths in a SINGLE transaction. The
    /// per-path `update` commits once per call — favoriting a ⌘A selection
    /// of 67k photos would mean 67k serial commits on the main thread.
    /// No-op transforms (meta unchanged) are skipped entirely.
    ///
    /// Pass `logAs` (kind + summary) to record the change in the history
    /// timeline so it can be reverted later. The per-path BEFORE state is
    /// captured here and stored as the undo payload — but only up to
    /// `maxLoggedPaths` affected photos (a huge ⌘A sweep isn't a "tidy-up
    /// action" worth keeping a 67k-entry payload for; it logs as not-undoable).
    static let maxLoggedPaths = 5_000

    @discardableResult
    func update(paths: [String],
                logAs log: (kind: OperationLogEntry.Kind, summary: String)? = nil,
                _ transform: (inout PhotoMeta) -> Void) -> Int64? {
        guard !paths.isEmpty else { return nil }
        var upserts: [(path: String, meta: PhotoMeta, tags: String)] = []
        var deletes: [String] = []
        var before: [String: PhotoMeta?] = [:]   // nil = no meta existed
        for path in paths {
            let prior = itemsCache[path]
            var meta = prior ?? PhotoMeta()
            transform(&meta)
            guard meta != (prior ?? PhotoMeta()) else { continue }
            // updateValue (not subscript): `before[path] = nil` would DELETE the
            // key; we need to store an explicit nil meaning "no meta existed".
            before.updateValue(prior, forKey: path)
            if meta.isEmpty {
                itemsCache.removeValue(forKey: path)
                deletes.append(path)
            } else {
                itemsCache[path] = meta
                let tags = (try? String(data: JSONEncoder().encode(meta.tags), encoding: .utf8)) ?? "[]"
                upserts.append((path, meta, tags))
            }
        }
        guard !upserts.isEmpty || !deletes.isEmpty else { return nil }
        var logID: Int64?
        write { db in
            for item in upserts {
                try db.execute(sql: """
                    INSERT INTO photo_meta (path, favorite, rating, label, tags, rejected) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET favorite=excluded.favorite, rating=excluded.rating,
                        label=excluded.label, tags=excluded.tags, rejected=excluded.rejected
                    """, arguments: [item.path, item.meta.favorite, item.meta.rating,
                                     item.meta.label.rawValue, item.tags, item.meta.rejected])
            }
            var rest = deletes[...]
            while !rest.isEmpty {
                let chunk = Array(rest.prefix(500))
                rest = rest.dropFirst(500)
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM photo_meta WHERE path IN (\(marks))",
                               arguments: StatementArguments(chunk))
            }
            if let log, !before.isEmpty {
                let count = before.count
                let undoable = count <= Self.maxLoggedPaths
                let payload = undoable
                    ? (try? String(data: JSONEncoder().encode(before), encoding: .utf8)) ?? "{}"
                    : ""   // too big to keep — recorded but not revertible
                try db.execute(sql: """
                    INSERT INTO op_log (ts, kind, summary, payload, undone) VALUES (?, ?, ?, ?, 0)
                    """, arguments: [Date().timeIntervalSince1970, log.kind.rawValue, log.summary, payload])
                logID = db.lastInsertedRowID
            }
        }
        return logID
    }

    // MARK: - Operation history

    func recentOperations(limit: Int = 200) -> [OperationLogEntry] {
        (try? db.read { db -> [OperationLogEntry] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, ts, kind, summary, payload, undone FROM op_log
                ORDER BY id DESC LIMIT ?
                """, arguments: [limit])
            return rows.map { row in
                let payload: String = row["payload"]
                let count = Self.payloadCount(payload)
                return OperationLogEntry(
                    id: row["id"],
                    date: Date(timeIntervalSince1970: row["ts"]),
                    kind: OperationLogEntry.Kind(rawValue: row["kind"]) ?? .other,
                    summary: row["summary"],
                    affectedCount: count,
                    undone: (row["undone"] as Int) != 0)
            }
        }) ?? []
    }

    /// True if the entry still has a revertible payload and isn't already undone.
    func canUndo(_ id: Int64) -> Bool {
        (try? db.read { db -> Bool in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT payload, undone FROM op_log WHERE id = ?", arguments: [id]) else { return false }
            let payload: String = row["payload"]
            return (row["undone"] as Int) == 0 && !payload.isEmpty
        }) ?? false
    }

    /// Revert one logged action: restore each path's metadata to the recorded
    /// BEFORE state, then mark the entry undone. Returns the affected paths so
    /// the caller can refresh derived counts.
    @discardableResult
    func undoOperation(_ id: Int64) -> [String] {
        guard let payload = (try? db.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM op_log WHERE id = ? AND undone = 0",
                                arguments: [id])
        }) ?? nil, !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let before = try? JSONDecoder().decode([String: PhotoMeta?].self, from: data)
        else { return [] }

        for (path, meta) in before {
            if let meta {
                itemsCache[path] = meta.isEmpty ? nil : meta
            } else {
                itemsCache.removeValue(forKey: path)
            }
        }
        write { db in
            for (path, meta) in before {
                if let meta, !meta.isEmpty {
                    let tags = (try? String(data: JSONEncoder().encode(meta.tags), encoding: .utf8)) ?? "[]"
                    try db.execute(sql: """
                        INSERT INTO photo_meta (path, favorite, rating, label, tags, rejected) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(path) DO UPDATE SET favorite=excluded.favorite, rating=excluded.rating,
                            label=excluded.label, tags=excluded.tags, rejected=excluded.rejected
                        """, arguments: [path, meta.favorite, meta.rating, meta.label.rawValue, tags, meta.rejected])
                } else {
                    try db.execute(sql: "DELETE FROM photo_meta WHERE path = ?", arguments: [path])
                }
            }
            try db.execute(sql: "UPDATE op_log SET undone = 1 WHERE id = ?", arguments: [id])
        }
        return Array(before.keys)
    }

    func clearOperationHistory() {
        write { try $0.execute(sql: "DELETE FROM op_log") }
    }

    private static func payloadCount(_ payload: String) -> Int {
        guard !payload.isEmpty, let data = payload.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: PhotoMeta?].self, from: data) else { return 0 }
        return dict.count
    }

    func allTags() -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for meta in itemsCache.values {
            for tag in meta.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    // MARK: - Albums

    func addAlbum(named name: String) -> Album {
        let album = Album(name: name)
        albumsCache.append(album)
        let pos = albumsCache.count - 1
        write {
            try $0.execute(sql: "INSERT INTO album (id, name, position) VALUES (?, ?, ?)",
                           arguments: [album.id.uuidString, name, pos])
        }
        return album
    }

    func renameAlbum(_ id: UUID, to name: String) {
        guard let index = albumsCache.firstIndex(where: { $0.id == id }) else { return }
        albumsCache[index].name = name
        write {
            try $0.execute(sql: "UPDATE album SET name = ? WHERE id = ?", arguments: [name, id.uuidString])
        }
    }

    func deleteAlbum(_ id: UUID) {
        albumsCache.removeAll { $0.id == id }
        write {
            try $0.execute(sql: "DELETE FROM album WHERE id = ?", arguments: [id.uuidString])
            try $0.execute(sql: "DELETE FROM album_photo WHERE album_id = ?", arguments: [id.uuidString])
        }
    }

    func addToAlbum(_ id: UUID, paths: [String]) {
        guard let index = albumsCache.firstIndex(where: { $0.id == id }) else { return }
        var existing = albumsCache[index].photoPaths
        // Set-based dedup and insert ONLY the added rows: the old version
        // checked membership with Array.contains (quadratic) and re-upserted
        // the WHOLE album to refresh positions — moving photos into a 20k
        // album measured 10s on the main thread. Existing rows keep their
        // positions, so appending at base+offset preserves order exactly.
        let existingSet = Set(existing)
        var seen = Set<String>()   // dedup within `paths` itself too
        let added = paths.filter { !existingSet.contains($0) && seen.insert($0).inserted }
        guard !added.isEmpty else { return }
        let base = existing.count
        existing.append(contentsOf: added)
        albumsCache[index].photoPaths = existing
        write { db in
            for (offset, path) in added.enumerated() {
                try db.execute(sql: """
                    INSERT INTO album_photo (album_id, path, position) VALUES (?, ?, ?)
                    ON CONFLICT(album_id, path) DO UPDATE SET position=excluded.position
                    """, arguments: [id.uuidString, path, base + offset])
            }
        }
    }

    func removeFromAlbum(_ id: UUID, paths: [String]) {
        guard let index = albumsCache.firstIndex(where: { $0.id == id }) else { return }
        // Set membership, not Array.contains — removing 10k from a 20k album
        // measured 7.6s on the main thread with the quadratic scan.
        let toRemove = Set(paths)
        albumsCache[index].photoPaths.removeAll { toRemove.contains($0) }
        write { db in
            // Chunked IN (…) deletes — SQLite's parameter limit is 999.
            var rest = paths[...]
            while !rest.isEmpty {
                let chunk = rest.prefix(500)
                rest = rest.dropFirst(500)
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM album_photo WHERE album_id = ? AND path IN (\(marks))",
                               arguments: StatementArguments([id.uuidString] + Array(chunk)))
            }
        }
    }

    /// Move metadata + album membership when a file is renamed.
    func rename(from: String, to: String) {
        rename(pairs: [(from: from, to: to)])
    }

    /// Batched rename: ONE pass over the album arrays and one transaction.
    /// The single-pair version remaps every album's full path array per call —
    /// 1k renames over a 20k-photo album would be 20M iterations and 1k commits.
    func rename(pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        let mapping = Dictionary(pairs.map { ($0.from, $0.to) }, uniquingKeysWith: { _, last in last })
        for (from, to) in pairs {
            if let meta = itemsCache.removeValue(forKey: from) { itemsCache[to] = meta }
        }
        for index in albumsCache.indices {
            albumsCache[index].photoPaths = albumsCache[index].photoPaths.map { mapping[$0] ?? $0 }
        }
        write { db in
            for (from, to) in pairs {
                try db.execute(sql: "UPDATE OR REPLACE photo_meta SET path = ? WHERE path = ?", arguments: [to, from])
                try db.execute(sql: "UPDATE OR REPLACE album_photo SET path = ? WHERE path = ?", arguments: [to, from])
            }
        }
    }

    /// Remap metadata + album paths under `oldPrefix` to `newPrefix` (folder rename).
    func renamePrefix(from oldPrefix: String, to newPrefix: String) {
        func remap(_ path: String) -> String {
            path.hasPrefix(oldPrefix) ? newPrefix + path.dropFirst(oldPrefix.count) : path
        }
        var newItems: [String: PhotoMeta] = [:]
        for (path, meta) in itemsCache { newItems[remap(path)] = meta }
        itemsCache = newItems
        for index in albumsCache.indices {
            albumsCache[index].photoPaths = albumsCache[index].photoPaths.map(remap)
        }
        write { db in
            let pattern = oldPrefix + "%"
            try db.execute(sql: "UPDATE photo_meta SET path = ? || substr(path, ?) WHERE path LIKE ?",
                           arguments: [newPrefix, oldPrefix.count + 1, pattern])
            try db.execute(sql: "UPDATE album_photo SET path = ? || substr(path, ?) WHERE path LIKE ?",
                           arguments: [newPrefix, oldPrefix.count + 1, pattern])
        }
    }

    /// Drop metadata + album membership for deleted files.
    func forget(paths: [String]) {
        // Set membership + chunked IN(…) deletes — same fix as removeFromAlbum:
        // Array.contains inside removeAll is quadratic, and per-path DELETEs
        // pay one statement each over a large batch.
        let toRemove = Set(paths)
        for path in paths { itemsCache.removeValue(forKey: path) }
        for index in albumsCache.indices {
            albumsCache[index].photoPaths.removeAll { toRemove.contains($0) }
        }
        write { db in
            var rest = paths[...]
            while !rest.isEmpty {
                let chunk = Array(rest.prefix(500))
                rest = rest.dropFirst(500)
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM photo_meta WHERE path IN (\(marks))",
                               arguments: StatementArguments(chunk))
                try db.execute(sql: "DELETE FROM album_photo WHERE path IN (\(marks))",
                               arguments: StatementArguments(chunk))
            }
        }
    }

    /// Which albums contain each of `paths` — captured before `forget` so a
    /// deletion can be undone with album memberships intact.
    func albumMemberships(forPaths paths: [String]) -> [UUID: [String]] {
        let wanted = Set(paths)
        var result: [UUID: [String]] = [:]
        for album in albumsCache {
            let members = album.photoPaths.filter { wanted.contains($0) }
            if !members.isEmpty { result[album.id] = members }
        }
        return result
    }

    // MARK: - Loading

    private func load() {
        try? db.read { db in
            let metaRows = try Row.fetchAll(db, sql: "SELECT path, favorite, rating, label, tags, rejected FROM photo_meta")
            for row in metaRows {
                let path: String = row["path"]
                var meta = PhotoMeta()
                meta.favorite = row["favorite"] != 0
                meta.rating = row["rating"]
                meta.label = ColorLabel(rawValue: row["label"]) ?? .none
                meta.rejected = ((row["rejected"] as Int?) ?? 0) != 0
                if let tagsJSON: String = row["tags"],
                   let data = tagsJSON.data(using: .utf8),
                   let tags = try? JSONDecoder().decode([String].self, from: data) {
                    meta.tags = tags
                }
                itemsCache[path] = meta
            }

            let albumRows = try Row.fetchAll(db, sql: "SELECT id, name FROM album ORDER BY position")
            for row in albumRows {
                guard let id = UUID(uuidString: row["id"]) else { continue }
                let name: String = row["name"]
                let paths = try String.fetchAll(db,
                    sql: "SELECT path FROM album_photo WHERE album_id = ? ORDER BY position",
                    arguments: [row["id"] as String])
                albumsCache.append(Album(id: id, name: name, photoPaths: paths))
            }
        }
    }

    // MARK: - One-time migration from the old JSON store

    private func migrateLegacyJSONIfNeeded() {
        guard itemsCache.isEmpty, albumsCache.isEmpty else { return }
        let url = AppDirectories.applicationSupport().appendingPathComponent("Lumen/library.json")
        guard let data = try? Data(contentsOf: url) else { return }

        struct Payload: Codable { var items: [String: PhotoMeta] = [:]; var albums: [Album] = [] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }

        for (path, meta) in payload.items where !meta.isEmpty {
            itemsCache[path] = meta
        }
        albumsCache = payload.albums
        persistAll()

        // Keep the old file as a backup rather than deleting it.
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bak"))
    }

    private func persistAll() {
        write { db in
            for (path, meta) in itemsCache {
                let tags = (try? String(data: JSONEncoder().encode(meta.tags), encoding: .utf8) ?? "[]") ?? "[]"
                try db.execute(sql: "INSERT OR REPLACE INTO photo_meta (path, favorite, rating, label, tags, rejected) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [path, meta.favorite, meta.rating, meta.label.rawValue, tags, meta.rejected])
            }
            for (pos, album) in albumsCache.enumerated() {
                try db.execute(sql: "INSERT OR REPLACE INTO album (id, name, position) VALUES (?, ?, ?)",
                               arguments: [album.id.uuidString, album.name, pos])
                for (offset, path) in album.photoPaths.enumerated() {
                    try db.execute(sql: "INSERT OR REPLACE INTO album_photo (album_id, path, position) VALUES (?, ?, ?)",
                                   arguments: [album.id.uuidString, path, offset])
                }
            }
        }
    }
}
