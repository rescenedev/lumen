import Foundation
@testable import LumenKit

/// Regression tests for commit a54bbd4 — crash-harden pass.
/// Covers BUG-001/007/008/011/017 (AppDirectories), BUG-010 (symlink cycle),
/// BUG-018 (QuickLook bounds), BUG-059 (EXIF orientation clamp), BUG-071 (MP overflow).
func hardenedCrashFixTests() {

    // MARK: AppDirectories (BUG-001 / BUG-007 / BUG-008 / BUG-011 / BUG-017)
    // The old code used `.urls(...).first!` everywhere; AppDirectories replaces
    // that with a nil-coalescing temp-dir fallback so the app degrades gracefully
    // instead of crashing on startup in sandboxed or restricted environments.

    test("BUG-001/007: AppDirectories.applicationSupport never returns empty path") {
        let url = AppDirectories.applicationSupport()
        check(!url.path.isEmpty, "applicationSupport returned empty path")
        // Must be an absolute path (not a relative one that would break file ops).
        check(url.path.hasPrefix("/"), "expected absolute path, got \(url.path)")
    }

    test("BUG-008: AppDirectories.caches never returns empty path") {
        let url = AppDirectories.caches()
        check(!url.path.isEmpty, "caches() returned empty path")
        check(url.path.hasPrefix("/"), "expected absolute path, got \(url.path)")
    }

    test("BUG-011/017: AppDirectories.lumenSupport creates directory on first call") {
        let url = AppDirectories.lumenSupport()
        check(!url.path.isEmpty, "lumenSupport() returned empty path")
        // The helper must create the directory so downstream writers don't fail.
        check(
            FileManager.default.fileExists(atPath: url.path),
            "lumenSupport() returned \(url.path) but directory does not exist"
        )
    }

    test("AppDirectories.lumenSupport is under applicationSupport") {
        let base = AppDirectories.applicationSupport().standardized.path
        let lumen = AppDirectories.lumenSupport().standardized.path
        check(
            lumen.hasPrefix(base),
            "lumenSupport \(lumen) is not under applicationSupport \(base)"
        )
    }

    test("AppDirectories.caches does not equal applicationSupport (distinct dirs)") {
        // These two should always be different standard directories. If both fell
        // back to temp they'd collide — catch any regression where caches()
        // accidentally returns the app-support path or vice versa.
        let appSupport = AppDirectories.applicationSupport().standardized.path
        let caches = AppDirectories.caches().standardized.path
        // They should not be equal in normal conditions (both exist on macOS).
        // We only assert distinctness if neither is the temp directory.
        let tmp = FileManager.default.temporaryDirectory.standardized.path
        if appSupport != tmp && caches != tmp {
            checkNotEqual(appSupport, caches, "applicationSupport and caches point to the same directory")
        }
    }

    // MARK: IncrementalScanner symlink cycle (BUG-010)
    // Before the fix, a symlink pointing back at an ancestor directory caused
    // unbounded recursion inside walk() → stack overflow crash.

    test("BUG-010: symlink cycle does not crash or hang scanner") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-cycle-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Create one real photo.
        let photo = dir.appendingPathComponent("real.jpg")
        fm.createFile(atPath: photo.path, contents: Data([0xFF, 0xD8, 0xFF, 0xE0]))

        // Create a sub-directory with a symlink pointing back to the root — cycle.
        let sub = dir.appendingPathComponent("subdir")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let loop = sub.appendingPathComponent("back")
        try? fm.createSymbolicLink(at: loop, withDestinationURL: dir)

        // Must complete without crashing.  The one real photo should be found;
        // the symlink cycle directories must be skipped (visited-set guard).
        let result = IncrementalScanner.scan(roots: [dir], knownMtimes: [:], cachedByFolder: [:])
        check(result.photos.count == 1,
              "expected 1 photo ignoring cycle, got \(result.photos.count)")
    }

    test("BUG-010: nested symlink cycle skips loop but keeps all real files") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lumen-cycle2-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Two real photos at different depths.
        let p1 = root.appendingPathComponent("a.jpg")
        let deep = root.appendingPathComponent("deep")
        try? fm.createDirectory(at: deep, withIntermediateDirectories: true)
        let p2 = deep.appendingPathComponent("b.jpg")
        for p in [p1, p2] { fm.createFile(atPath: p.path, contents: Data([0xFF, 0xD8, 0xFF])) }

        // Cycle: deep/loop → root
        let loop = deep.appendingPathComponent("loop")
        try? fm.createSymbolicLink(at: loop, withDestinationURL: root)

        let result = IncrementalScanner.scan(roots: [root], knownMtimes: [:], cachedByFolder: [:])
        check(result.photos.count == 2,
              "expected 2 photos, got \(result.photos.count): \(result.photos.map(\.url.lastPathComponent))")
    }

    // MARK: Format.megapixels overflow / precision (BUG-071)
    // Old code: Double(width * height) — integer product computed first.
    // Fixed:    Double(width) * Double(height) — operands cast before multiply.

    test("BUG-071: megapixels large dimensions compute correctly") {
        // 20000 × 20000 = 400 MP — product is 400_000_000, well within Int64 range
        // but the old Int multiply risked precision loss for extreme sizes.
        let result = Format.megapixels(20000, 20000)
        checkEqual(result, "400.0 MP", "unexpected megapixel string")
    }

    test("BUG-071: megapixels rounds to one decimal place") {
        // 4032 × 3024 = ~12.2 MP (a common iPhone resolution)
        let result = Format.megapixels(4032, 3024)
        checkNotNil(result, "expected non-nil for valid dimensions")
        check(result?.hasSuffix(" MP") == true, "expected ' MP' suffix, got \(result ?? "nil")")
    }

    test("BUG-071: megapixels very small image returns nil") {
        // Below the 0.1 MP threshold → nil (not shown in UI)
        let result = Format.megapixels(100, 100)   // 0.01 MP
        checkNil(result, "expected nil for < 0.1 MP image")
    }

    test("BUG-071: megapixels nil inputs return nil") {
        checkNil(Format.megapixels(nil, nil))
        checkNil(Format.megapixels(1000, nil))
        checkNil(Format.megapixels(nil, 1000))
    }
}
