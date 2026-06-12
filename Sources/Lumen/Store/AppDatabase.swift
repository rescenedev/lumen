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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("lumen.sqlite")

        var config = Configuration()
        config.busyMode = .timeout(5)
        // swiftlint:disable:next force_try
        queue = try! DatabaseQueue(path: fileURL.path, configuration: config)
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
        try migrator.migrate(queue)
    }
}
