import Foundation

/// Locates LumenKit's processed resource bundle (`Lumen_LumenKit.bundle`).
///
/// Do NOT use SwiftPM's generated `Bundle.module` in app code: the generated
/// accessor only checks `Bundle.main.bundleURL` (the .app *root* when
/// packaged) plus a hardcoded developer-machine `.build` path, and calls
/// `fatalError` when both miss. `make_app.sh` ships the bundle in
/// `Contents/Resources`, so 0.5.0 crashed on every user machine at the first
/// localized toast (GitHub issues #5/#6) — masked on the dev machine by the
/// `.build` fallback. Use `Bundle.lumen` instead.
enum LumenBundleLocator {
    static let bundleName = "Lumen_LumenKit.bundle"

    /// Candidate directories in priority order. `resourceURL` covers the
    /// shipped app (`Lumen.app/Contents/Resources`), the executable's
    /// directory covers `swift run` / `swift build` layouts (`.build/<config>`),
    /// and `bundleURL` keeps the generated accessor's legacy expectation.
    static func candidateDirectories(resourceURL: URL?,
                                     executableURL: URL?,
                                     bundleURL: URL) -> [URL] {
        var dirs: [URL] = []
        if let resourceURL { dirs.append(resourceURL) }
        if let executableURL { dirs.append(executableURL.deletingLastPathComponent()) }
        dirs.append(bundleURL)
        return dirs
    }

    /// First candidate directory that actually contains the resource bundle.
    static func locate(in directories: [URL],
                       exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        for dir in directories {
            let candidate = dir.appendingPathComponent(bundleName, isDirectory: true)
            if exists(candidate) { return candidate }
        }
        return nil
    }
}

extension Bundle {
    /// Crash-safe replacement for the generated `Bundle.module`. Falls back to
    /// `Bundle.main` when the resource bundle is missing — localized strings
    /// then render their default-language (English) text instead of aborting.
    static let lumen: Bundle = {
        let candidates = LumenBundleLocator.candidateDirectories(
            resourceURL: Bundle.main.resourceURL,
            executableURL: Bundle.main.executableURL,
            bundleURL: Bundle.main.bundleURL)
        if let url = LumenBundleLocator.locate(in: candidates),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .main
    }()
}
