import Foundation

/// Safe accessors for the standard app directories.
///
/// `FileManager.urls(for:in:)` *almost* always returns a non-empty array, but
/// it can be empty in sandboxed CI, restricted, or corrupted-filesystem
/// environments. Force-unwrapping `.first!` there crashes the app — and in the
/// case of the crash reporter, crashes the very code meant to record the crash.
/// These helpers fall back to the temporary directory so the app degrades
/// gracefully instead of aborting on startup.
enum AppDirectories {
    /// `~/Library/Application Support`, or the temp dir if unavailable.
    static func applicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// `~/Library/Caches`, or the temp dir if unavailable.
    static func caches() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// The app's own subdirectory under Application Support, created on demand.
    static func lumenSupport() -> URL {
        let url = applicationSupport().appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
