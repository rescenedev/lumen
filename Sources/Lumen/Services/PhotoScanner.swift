import Foundation

/// Recursively scans a directory tree for supported image files.
/// Runs off the main thread; returns immutable `Photo` values.
enum PhotoScanner {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .fileSizeKey, .creationDateKey,
        .contentModificationDateKey, .isDirectoryKey
    ]

    /// Scan a single root folder, descending into all subdirectories.
    /// Hidden files and package contents are skipped.
    static func scan(root: URL) -> [Photo] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var photos: [Photo] = []
        for case let fileURL as URL in enumerator {
            guard Photo.isSupported(fileURL) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { continue }
            photos.append(Photo(url: fileURL, resourceValues: values))
        }
        return photos
    }

    /// Build a `Photo` for an individual file (used for drag-and-drop of files).
    static func photo(for url: URL) -> Photo? {
        guard Photo.isSupported(url),
              let values = try? url.resourceValues(forKeys: resourceKeys),
              values.isRegularFile == true else { return nil }
        return Photo(url: url, resourceValues: values)
    }

    /// Expand a list of dropped URLs (which may be files or folders) into photos.
    static func expand(urls: [URL]) -> [Photo] {
        var result: [Photo] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                result.append(contentsOf: scan(root: url))
            } else if let photo = photo(for: url) {
                result.append(photo)
            }
        }
        return result
    }
}
