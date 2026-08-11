import Foundation

/// Wire format between Lumen and the `lumen-thumb-bg` helper.
///
/// Same framing choices as the metadata helper and for the same reasons:
/// NUL-separated in (a filename may contain a newline, never a NUL), one JSON
/// line out (JSON escapes newlines, and it lets the parent see each photo land
/// rather than waiting for a batch).
///
/// A request item is a path plus the modification time the library scanned, so
/// the helper derives exactly the same cache key the app would — the helper
/// must never invent its own or it would write files the app can't find.
enum ThumbnailHelper {
    static let executableName = "lumen-thumb-bg"

    struct Item: Equatable {
        var path: String
        var mtime: TimeInterval
    }

    struct Reply: Codable, Equatable {
        var p: String
        /// Non-nil when no thumbnail could be produced.
        var e: String?
    }

    /// `path\0mtime\0` pairs.
    static func encodeRequest(_ items: [Item]) -> Data {
        var data = Data()
        for item in items {
            data.append(contentsOf: Array(item.path.utf8))
            data.append(0x00)
            data.append(contentsOf: Array(String(item.mtime).utf8))
            data.append(0x00)
        }
        return data
    }

    static func decodeRequest(_ data: Data) -> [Item] {
        let fields = data.split(separator: 0x00, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var out: [Item] = []
        var index = 0
        // Pairs, and a trailing empty field from the final separator. A dangling
        // half-pair is dropped rather than guessed: a wrong mtime would write a
        // cache entry under a key nothing ever looks up.
        while index + 1 < fields.count {
            let path = fields[index]
            let mtime = TimeInterval(fields[index + 1])
            index += 2
            guard !path.isEmpty, let mtime else { continue }
            out.append(Item(path: path, mtime: mtime))
        }
        return out
    }

    static func encode(_ reply: Reply) -> Data? {
        guard var data = try? JSONEncoder().encode(reply) else { return nil }
        data.append(0x0A)
        return data
    }

    static func decode(line: Data) -> Reply? {
        guard !line.isEmpty else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: line)
    }
}
