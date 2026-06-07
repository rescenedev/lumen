import Foundation
@testable import LumenKit

/// Shared helpers for building synthetic photos and scratch files.
enum Fixtures {
    /// A photo value with no file behind it — for pure-logic tests
    /// (sorting, filtering) that never touch disk.
    static func photo(_ name: String, size: Int64 = 0, date: Date? = nil) -> Photo {
        Photo(url: URL(fileURLWithPath: "/tmp/lumen-fixtures/\(name)"),
              byteSize: size, creationDate: date, modificationDate: date)
    }

    /// A fresh, unique temporary directory. Caller deletes it.
    static func tempDir(_ label: String = "LumenTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write `content` to `name` inside `dir`, returning a Photo whose `byteSize`
    /// matches the file on disk (so DuplicateFinder's size-grouping is accurate).
    @discardableResult
    static func write(_ dir: URL, _ name: String, _ content: Data) throws -> Photo {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? content.count
        return Photo(url: url, byteSize: Int64(size), creationDate: nil, modificationDate: nil)
    }

    static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso) ?? .distantPast
    }
}
