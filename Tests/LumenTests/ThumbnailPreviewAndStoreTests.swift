import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LumenKit

/// Fixes for the recurring "grid fills in slowly" report (2026-07-17):
///
/// 1. The thumbnail store lived in ~/Library/Caches, which macOS (and cleaner
///    apps) purge under storage pressure — the user's 66k-photo warm was wiped
///    twice in two weeks. Rebuilding takes HOURS over a NAS/HDD, so this is
///    not a "cheaply regenerated" cache: it moves to Application Support, with
///    a migration that preserves whatever survived. `relocateLegacyStore` /
///    `mergeLegacyStore` cover the move.
/// 2. Cold cells now get a fast first paint from the photo's EMBEDDED
///    thumbnail (a few-KB header read — no full HEIC decode) while the sharp
///    512px tier decodes behind it. `embeddedThumbnail` must never fall back
///    to a full decode — that would re-serialize the grid on the slow path.
func thumbnailPreviewAndStoreTests() {

    let fm = FileManager.default

    func tempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("lumen-store-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func writeJPEG(to url: URL, width: Int = 800, height: Int = 600, embedThumbnail: Bool) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw NSError(domain: "test", code: 1) }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage() else { throw NSError(domain: "test", code: 2) }
        let props: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: embedThumbnail]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 3) }
    }

    // MARK: Embedded-thumbnail fast lane

    test("embeddedThumbnail: serves the embedded preview without a full decode") {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("embedded.jpg")
        try writeJPEG(to: file, embedThumbnail: true)

        let quick = ThumbnailCache.embeddedThumbnail(url: file, maxPixel: 512)
        checkNotNil(quick, "a photo with an embedded thumbnail must yield a fast preview")
        if let quick {
            check(quick.size.width <= 512 && quick.size.height <= 512)
            check(quick.size.width < 800, "must be the small embedded preview, not the full-resolution decode")
        }
    }

    test("embeddedThumbnail: returns nil (does NOT full-decode) when no embedded thumbnail exists") {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plain.jpg")
        try writeJPEG(to: file, embedThumbnail: false)

        checkNil(ThumbnailCache.embeddedThumbnail(url: file, maxPixel: 512),
                 "falling back to a full decode would re-serialize the grid on the slow path")
    }

    test("embeddedThumbnail: unreadable file is nil") {
        checkNil(ThumbnailCache.embeddedThumbnail(
            url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).jpg"), maxPixel: 512))
    }

    // MARK: Store relocation (Caches → Application Support)

    func plant(_ relative: String, _ content: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    test("relocateLegacyStore: whole-directory move when the new store doesn't exist yet") {
        let base = try tempDir(); defer { try? fm.removeItem(at: base) }
        let old = base.appendingPathComponent("old/Thumbnails")
        let new = base.appendingPathComponent("new/Thumbnails")
        try plant("ab/abc123.jpg", "x", in: old)
        try plant("cd/cde456.jpg", "y", in: old)

        ThumbnailCache.relocateLegacyStore(from: old, to: new)
        check(fm.fileExists(atPath: new.appendingPathComponent("ab/abc123.jpg").path))
        check(fm.fileExists(atPath: new.appendingPathComponent("cd/cde456.jpg").path))
        check(!fm.fileExists(atPath: old.path), "legacy store must be gone after the move")
    }

    test("relocateLegacyStore: no-op when there is no legacy store") {
        let base = try tempDir(); defer { try? fm.removeItem(at: base) }
        let new = base.appendingPathComponent("new/Thumbnails")
        try plant("ab/abc123.jpg", "x", in: new)
        ThumbnailCache.relocateLegacyStore(from: base.appendingPathComponent("missing"), to: new)
        check(fm.fileExists(atPath: new.appendingPathComponent("ab/abc123.jpg").path))
    }

    test("mergeLegacyStore: fills gaps, never overwrites, removes the legacy store") {
        let base = try tempDir(); defer { try? fm.removeItem(at: base) }
        let old = base.appendingPathComponent("old/Thumbnails")
        let new = base.appendingPathComponent("new/Thumbnails")
        try plant("ab/both.jpg", "OLD", in: old)
        try plant("ab/only-old.jpg", "keep-me", in: old)
        try plant("ab/both.jpg", "NEW", in: new)

        ThumbnailCache.mergeLegacyStore(from: old, to: new)
        checkEqual(try String(contentsOf: new.appendingPathComponent("ab/both.jpg"), encoding: .utf8), "NEW",
                   "an entry already in the new store must win (it's fresher)")
        checkEqual(try String(contentsOf: new.appendingPathComponent("ab/only-old.jpg"), encoding: .utf8), "keep-me")
        check(!fm.fileExists(atPath: old.path))
    }
}
