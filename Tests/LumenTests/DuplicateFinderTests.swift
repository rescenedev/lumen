import Foundation
@testable import LumenKit

/// Integration tests over real scratch files — this is the data-safety surface
/// (a false "duplicate" could lead a user to delete a unique photo).
func duplicateFinderTests() {
    test("identicalContentAreDuplicates") {
        let dir = try Fixtures.tempDir("Dupes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Fixtures.write(dir, "a.jpg", Data("hello world".utf8))
        let b = try Fixtures.write(dir, "b.jpg", Data("hello world".utf8))   // same bytes
        let unique = try Fixtures.write(dir, "c.jpg", Data("totally different bytes".utf8))

        let dupes = DuplicateFinder.duplicatePaths(in: [a, b, unique])
        checkEqual(dupes, [a.url.path, b.url.path])
        check(!dupes.contains(unique.url.path))
    }

    test("sameSizeDifferentContentAreNotDuplicates") {
        let dir = try Fixtures.tempDir("Dupes")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Both are 11 bytes → same size bucket, but different content hashes.
        let a = try Fixtures.write(dir, "a.jpg", Data("hello world".utf8))
        let b = try Fixtures.write(dir, "b.jpg", Data("hello worle".utf8))
        checkEqual(a.byteSize, b.byteSize)
        check(DuplicateFinder.duplicatePaths(in: [a, b]).isEmpty)
    }

    test("zeroByteFilesAreIgnored") {
        let dir = try Fixtures.tempDir("Dupes")
        defer { try? FileManager.default.removeItem(at: dir) }
        // byteSize == 0 is skipped, so empty files never count as duplicates.
        let a = try Fixtures.write(dir, "empty1.jpg", Data())
        let b = try Fixtures.write(dir, "empty2.jpg", Data())
        checkEqual(a.byteSize, 0)
        check(DuplicateFinder.duplicatePaths(in: [a, b]).isEmpty)
    }

    test("threeWayDuplicate") {
        let dir = try Fixtures.tempDir("Dupes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data("repeat me".utf8)
        let a = try Fixtures.write(dir, "a.jpg", content)
        let b = try Fixtures.write(dir, "b.jpg", content)
        let c = try Fixtures.write(dir, "c.jpg", content)
        checkEqual(DuplicateFinder.duplicatePaths(in: [a, b, c]),
                   [a.url.path, b.url.path, c.url.path])
    }

    test("emptyInputIsSafe") {
        check(DuplicateFinder.duplicatePaths(in: []).isEmpty)
    }
}
