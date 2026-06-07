import Foundation

/// Persists Lumen-owned metadata (favorites, ratings, labels, tags, albums)
/// to a JSON file in Application Support. The image files are never modified.
final class MetadataStore {
    private struct Payload: Codable {
        var version: Int = 1
        var items: [String: PhotoMeta] = [:]
        var albums: [Album] = []
    }

    private var payload = Payload()
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        load()
        migrateLegacyFavoritesIfNeeded()
    }

    // MARK: - Access

    var items: [String: PhotoMeta] { payload.items }
    var albums: [Album] { payload.albums }

    func meta(for path: String) -> PhotoMeta {
        payload.items[path] ?? PhotoMeta()
    }

    func update(_ path: String, _ transform: (inout PhotoMeta) -> Void) {
        var meta = payload.items[path] ?? PhotoMeta()
        transform(&meta)
        if meta.isEmpty {
            payload.items.removeValue(forKey: path)
        } else {
            payload.items[path] = meta
        }
        save()
    }

    /// Every tag in use, with a count, sorted by name.
    func allTags() -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for meta in payload.items.values {
            for tag in meta.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    // MARK: - Albums

    func addAlbum(named name: String) -> Album {
        let album = Album(name: name)
        payload.albums.append(album)
        save()
        return album
    }

    func renameAlbum(_ id: UUID, to name: String) {
        guard let index = payload.albums.firstIndex(where: { $0.id == id }) else { return }
        payload.albums[index].name = name
        save()
    }

    func deleteAlbum(_ id: UUID) {
        payload.albums.removeAll { $0.id == id }
        save()
    }

    func addToAlbum(_ id: UUID, paths: [String]) {
        guard let index = payload.albums.firstIndex(where: { $0.id == id }) else { return }
        var existing = payload.albums[index].photoPaths
        for path in paths where !existing.contains(path) { existing.append(path) }
        payload.albums[index].photoPaths = existing
        save()
    }

    func removeFromAlbum(_ id: UUID, paths: [String]) {
        guard let index = payload.albums.firstIndex(where: { $0.id == id }) else { return }
        payload.albums[index].photoPaths.removeAll { paths.contains($0) }
        save()
    }

    /// Move metadata + album membership when a file is renamed.
    func rename(from: String, to: String) {
        if let meta = payload.items.removeValue(forKey: from) {
            payload.items[to] = meta
        }
        for index in payload.albums.indices {
            payload.albums[index].photoPaths = payload.albums[index].photoPaths.map { $0 == from ? to : $0 }
        }
        save()
    }

    /// Remap all item + album paths under `oldPrefix` to `newPrefix` (folder rename).
    func renamePrefix(from oldPrefix: String, to newPrefix: String) {
        func remap(_ path: String) -> String {
            path.hasPrefix(oldPrefix) ? newPrefix + path.dropFirst(oldPrefix.count) : path
        }
        var newItems: [String: PhotoMeta] = [:]
        for (path, meta) in payload.items { newItems[remap(path)] = meta }
        payload.items = newItems
        for index in payload.albums.indices {
            payload.albums[index].photoPaths = payload.albums[index].photoPaths.map(remap)
        }
        save()
    }

    /// Drop metadata + album membership for deleted files.
    func forget(paths: [String]) {
        for path in paths { payload.items.removeValue(forKey: path) }
        for index in payload.albums.indices {
            payload.albums[index].photoPaths.removeAll { paths.contains($0) }
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        payload = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func migrateLegacyFavoritesIfNeeded() {
        let key = "lumen.favorites.paths"
        guard let legacy = UserDefaults.standard.array(forKey: key) as? [String], !legacy.isEmpty else { return }
        for path in legacy {
            var meta = payload.items[path] ?? PhotoMeta()
            meta.favorite = true
            payload.items[path] = meta
        }
        UserDefaults.standard.removeObject(forKey: key)
        save()
    }
}
