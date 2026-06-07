import Foundation

/// Persists the set of favorited photo paths in UserDefaults.
/// Paths are used (rather than bookmarks) to keep the prototype simple.
final class FavoritesStore {
    private let key = "lumen.favorites.paths"
    private let defaults = UserDefaults.standard

    private(set) var paths: Set<String>

    init() {
        let stored = defaults.array(forKey: key) as? [String] ?? []
        self.paths = Set(stored)
    }

    func contains(_ url: URL) -> Bool {
        paths.contains(url.path)
    }

    func toggle(_ url: URL) {
        if paths.contains(url.path) {
            paths.remove(url.path)
        } else {
            paths.insert(url.path)
        }
        persist()
    }

    func set(_ url: URL, favorite: Bool) {
        if favorite { paths.insert(url.path) } else { paths.remove(url.path) }
        persist()
    }

    private func persist() {
        defaults.set(Array(paths), forKey: key)
    }
}
