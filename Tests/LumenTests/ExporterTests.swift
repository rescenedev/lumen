import Foundation
@testable import LumenKit

/// Integration tests for the export helpers. These copy/zip real files but never
/// modify the originals — the read-only guarantee is part of the product promise.
func exporterTests() {
    test("copyOriginalsLeavesSourcesIntact") {
        let src = try Fixtures.tempDir("ExportSrc")
        let dst = try Fixtures.tempDir("ExportDst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let a = try Fixtures.write(src, "a.jpg", Data("aaa".utf8))
        let b = try Fixtures.write(src, "b.jpg", Data("bbb".utf8))

        let copied = Exporter.copyOriginals([a, b], to: dst)
        checkEqual(copied, 2)
        check(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.jpg").path))
        check(FileManager.default.fileExists(atPath: dst.appendingPathComponent("b.jpg").path))
        // Originals untouched.
        check(FileManager.default.fileExists(atPath: a.url.path))
        check(FileManager.default.fileExists(atPath: b.url.path))
    }

    test("copyDeduplicatesFilenameCollisions") {
        let src = try Fixtures.tempDir("ExportSrc")
        let dst = try Fixtures.tempDir("ExportDst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        // Two different files share a filename (from different folders) → the
        // second copy must be renamed, not overwritten.
        let sub = src.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = try Fixtures.write(src, "photo.jpg", Data("first".utf8))
        let b = try Fixtures.write(sub, "photo.jpg", Data("second".utf8))

        let copied = Exporter.copyOriginals([a, b], to: dst)
        checkEqual(copied, 2)
        check(FileManager.default.fileExists(atPath: dst.appendingPathComponent("photo.jpg").path))
        check(FileManager.default.fileExists(atPath: dst.appendingPathComponent("photo 1.jpg").path))
    }

    test("zipCreatesArchive") {
        let src = try Fixtures.tempDir("ExportSrc")
        let dst = try Fixtures.tempDir("ExportDst")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let a = try Fixtures.write(src, "a.jpg", Data("aaa".utf8))
        let b = try Fixtures.write(src, "b.jpg", Data("bbb".utf8))
        let archive = dst.appendingPathComponent("out.zip")

        check(Exporter.zip([a, b], to: archive))
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        check(size > 0, "archive should be non-empty")
    }
}
