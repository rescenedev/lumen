import Foundation
import GRDB

/// The app's SQLite database (via GRDB). Holds Lumen-owned metadata
/// (favorites/ratings/labels/tags/albums). The library and EXIF caches live
/// in separate binary/plist files managed by LibraryCache, NOT here.
/// `DatabaseQueue` serializes all access, so it's safe from any thread.
final class AppDatabase {
    static let shared = AppDatabase()

    let queue: DatabaseQueue
    let fileURL: URL

    private init() {
        let dir = AppDirectories.lumenSupport()
        fileURL = dir.appendingPathComponent("lumen.sqlite")

        var config = Configuration()
        config.busyMode = .timeout(5)
        // A corrupt DB, full disk, or sandboxing failure must NOT crash the app.
        // Fall back to an in-memory queue so the session stays usable (metadata
        // simply won't persist this run) instead of aborting on launch.
        if let onDisk = try? DatabaseQueue(path: fileURL.path, configuration: config) {
            queue = onDisk
        } else {
            // In-memory open touches no disk and cannot hit the failure modes
            // above (corrupt file, full disk, sandbox), so it is a safe last
            // resort that keeps the app running this session.
            // swiftlint:disable:next force_try
            queue = try! DatabaseQueue()
        }
        try? Self.migrate(queue)
    }

    /// An isolated in-memory database carrying the current schema. Used by tests
    /// so they never touch the user's real `lumen.sqlite`.
    static func inMemoryQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try migrate(queue)
        return queue
    }

    /// Apply the schema migrations to a queue (shared by the live DB and tests).
    static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE photo_meta (
                    path TEXT PRIMARY KEY,
                    favorite INTEGER NOT NULL DEFAULT 0,
                    rating INTEGER NOT NULL DEFAULT 0,
                    label TEXT NOT NULL DEFAULT 'none',
                    tags TEXT NOT NULL DEFAULT '[]'
                );
                CREATE TABLE album (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    position INTEGER NOT NULL
                );
                CREATE TABLE album_photo (
                    album_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (album_id, path)
                );
                """)
        }
        migrator.registerMigration("v2-rejected") { db in
            try db.execute(sql: "ALTER TABLE photo_meta ADD COLUMN rejected INTEGER NOT NULL DEFAULT 0;")
        }
        migrator.registerMigration("v3-oplog") { db in
            // Append-only history of metadata-organizing actions. `payload` is
            // the per-path PhotoMeta BEFORE the action (JSON), so each entry can
            // be reverted without touching the photo files. Photo files are
            // never recorded here — only Lumen-owned metadata.
            try db.execute(sql: """
                CREATE TABLE op_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    kind TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    undone INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
        migrator.registerMigration("v4-oplog-affected") { db in
            // Record the affected-photo count in its own column so the history view
            // never has to JSON-decode the (up to 5000-entry) payload just to count
            // it. Backfill existing rows once by counting top-level JSON keys —
            // without materializing PhotoMeta — so old entries keep their counts.
            try db.execute(sql: "ALTER TABLE op_log ADD COLUMN affected INTEGER NOT NULL DEFAULT 0;")
            let rows = try Row.fetchAll(db, sql: "SELECT id, payload FROM op_log")
            for row in rows {
                let payload: String = row["payload"]
                guard !payload.isEmpty, let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                try db.execute(sql: "UPDATE op_log SET affected = ? WHERE id = ?",
                               arguments: [obj.count, row["id"]])
            }
        }
        try migrator.migrate(queue)
    }
}
