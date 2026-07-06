import Foundation
@testable import LumenKit

/// Regression tests for GitHub issues #5/#6 — 0.5.0 crashed on every user
/// machine the first time a localized toast was shown.
///
/// Root cause: SwiftPM's generated `Bundle.module` accessor only checks
/// `Bundle.main.bundleURL` (the .app *root* when packaged) plus a hardcoded
/// developer-machine `.build` path, then `fatalError`s. `make_app.sh` puts the
/// resource bundle in `Contents/Resources`, so neither candidate exists on a
/// user's machine — but the `.build` fallback exists on the dev machine, which
/// masked the bug in QA.
///
/// Fix: `Bundle.lumen` — a crash-safe accessor that searches
/// `Contents/Resources`, the executable's directory, and the bundle root,
/// falling back to `Bundle.main` (default-language strings) instead of dying.
func bundleLocatorTests() {

    let name = LumenBundleLocator.bundleName

    // MARK: Candidate order

    test("candidates: Resources dir first, then executable dir, then bundle root") {
        let resources = URL(fileURLWithPath: "/Applications/Lumen.app/Contents/Resources")
        let exe = URL(fileURLWithPath: "/Applications/Lumen.app/Contents/MacOS/Lumen")
        let root = URL(fileURLWithPath: "/Applications/Lumen.app")
        let dirs = LumenBundleLocator.candidateDirectories(
            resourceURL: resources, executableURL: exe, bundleURL: root)
        checkEqual(dirs.map(\.path),
                   [resources.path, exe.deletingLastPathComponent().path, root.path])
    }

    test("candidates: nil resourceURL/executableURL are skipped, bundle root always present") {
        let root = URL(fileURLWithPath: "/somewhere/Lumen.app")
        let dirs = LumenBundleLocator.candidateDirectories(
            resourceURL: nil, executableURL: nil, bundleURL: root)
        checkEqual(dirs.map(\.path), [root.path])
    }

    // MARK: locate()

    test("locate returns the first existing candidate") {
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        let hit = LumenBundleLocator.locate(in: [a, b]) { url in
            url.path == "/b/\(name)"
        }
        checkEqual(hit?.path, "/b/\(name)")
    }

    test("locate prefers the earliest candidate when several exist") {
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        let hit = LumenBundleLocator.locate(in: [a, b]) { _ in true }
        checkEqual(hit?.path, "/a/\(name)")
    }

    test("locate returns nil when the bundle exists nowhere") {
        let hit = LumenBundleLocator.locate(in: [URL(fileURLWithPath: "/a")]) { _ in false }
        checkNil(hit)
    }

    // MARK: Issue #5/#6 regression — the shipped .app layout must resolve

    test("issues #5/#6: bundle inside Contents/Resources is found (shipped app layout)") {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lumen-bundle-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        let app = tmp.appendingPathComponent("Lumen.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let exe = app.appendingPathComponent("Contents/MacOS/Lumen")
        try fm.createDirectory(at: resources.appendingPathComponent(name),
                               withIntermediateDirectories: true)

        let dirs = LumenBundleLocator.candidateDirectories(
            resourceURL: resources, executableURL: exe, bundleURL: app)
        let hit = LumenBundleLocator.locate(in: dirs)
        checkEqual(hit?.path, resources.appendingPathComponent(name).path,
                   "must resolve the bundle from Contents/Resources — the 0.5.0 accessor never looked there")
    }

    test("issues #5/#6: user machine with no bundle anywhere resolves nil (accessor must then fall back, not crash)") {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lumen-bundle-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        let app = tmp.appendingPathComponent("Lumen.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let exe = app.appendingPathComponent("Contents/MacOS/Lumen")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let dirs = LumenBundleLocator.candidateDirectories(
            resourceURL: resources, executableURL: exe, bundleURL: app)
        checkNil(LumenBundleLocator.locate(in: dirs))
    }

    // MARK: Bundle.lumen end-to-end

    test("Bundle.lumen resolves the real resource bundle in the build tree") {
        // `swift run LumenTests` puts Lumen_LumenKit.bundle next to the test
        // executable, so the executable-directory candidate must find it.
        checkEqual(Bundle.lumen.bundleURL.lastPathComponent, name,
                   "Bundle.lumen should find the processed resource bundle, not fall back to .main")
    }

    test("Bundle.lumen serves localized strings (ko present in the bundle)") {
        let ko = Bundle.lumen.path(forResource: "Localizable", ofType: "strings",
                                   inDirectory: nil, forLocalization: "ko")
        checkNotNil(ko, "ko localization must be loadable from Bundle.lumen")
    }
}
