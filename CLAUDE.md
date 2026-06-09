# Lumen

Native macOS photo viewer/manager for large local/NAS/Apple Photos libraries.
Pure SwiftPM — there is no Xcode project. Requires macOS 14+.

## Build & test (always verify before claiming done)

- Build: `swift build`
- Tests: `./Scripts/test.sh` — custom zero-dependency harness.
  Do NOT use `swift test`; the LumenTests target is an *executable*, not an XCTest bundle.
- Release app bundle: `bash Scripts/make_app.sh` → `dist/Lumen.app`

## Layout

- `Sources/Lumen/` — `LumenKit` library target: ALL app code lives here (testable).
- `Sources/LumenMain/` — thin `Lumen` executable that just calls `runLumenApp()`.
- `Tests/LumenTests/` — `LumenTests` executable; register new test funcs in `main.swift`.
- `ios/` — separate iOS app (own project; not built by this package).
- `docs/` — GitHub Pages landing site (Korean). `docs/releases.html` is the release-notes page.
- `Casks/lumen-photos.rb` — copy of the Homebrew cask; the live tap is `rescenedev/homebrew-tap`.

## Conventions

- Performance matters: the reference library is ~60k photos on an SMB NAS.
  Never add per-photo filesystem calls (stat/read) on the main thread or per-cell display path.
- `AppModel` is `@Observable` + `@MainActor`; derived lists are cached
  (`visiblePhotos` signature cache) — invalidate via the existing version counters
  (`libraryVersion`, `metaRevision`, `indexVersion`), don't add ad-hoc flags.
- Commit messages: `type: description` (feat/fix/perf/chore/docs/test), no attribution lines.
- UI strings are English; in-app toasts may be Korean. Comments in English.
