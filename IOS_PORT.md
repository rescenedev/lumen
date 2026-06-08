# Lumen for iOS — Port Plan

Status: **scaffolding** on branch `feat/ios` (worktree `../photo-ios`). The macOS
app on `main` is untouched and stays the shipping product until an iOS app is
ready to merge.

## TL;DR

The **editing/combine/watermark engine is already portable** — `ImageEditor`
uses only CoreGraphics / CoreImage / ImageIO / CoreText / Foundation (no
AppKit). It now compiles AppKit-free and macOS still builds + 89 tests pass.
The macOS-specific parts (NAS browsing, FSEvents folder watching, the
`NSCollectionView` grid, AppKit menus/panels) do **not** port; on iOS the
library is **PhotoKit + the Files app**, and the UI is rebuilt in SwiftUI/UIKit.

So the iOS app is *not* a 1:1 port of the macOS window — it's a focused
**Photos-based viewer + the same non-destructive editor/combine/watermark**.

## What ports as-is (cross-platform core)

These rely only on Foundation / CoreGraphics / ImageIO / GRDB and are reusable:

- `Services/ImageEditor.swift` — crop · resize · rotate · straighten · padded
  canvas · combine (strip/grid) · text+logo watermark. **The crown jewel.**
- `Services/BatchProcessor.swift` — batch apply an `Edit` to many files.
- `Services/DuplicateFinder.swift`, `IncrementalScanner.swift` (file logic),
  `MetadataReader.swift`, `ExifIndexer.swift` — Foundation/ImageIO.
- `Store/MetadataStore.swift`, `AppDatabase.swift` (GRDB SQLite) — albums,
  ratings, labels, tags, **reject flag**. Cross-platform.
- Most of `Models/*` (Photo, FilterState, SortOrder, RenamePattern, Album,
  ExifInfo). `PhotoMeta`/`ColorLabel` use `NSColor` → needs a tiny shim
  (`#if canImport(UIKit)` → `UIColor`).

## What does NOT port (macOS-only) → reimplement on iOS

| macOS | iOS replacement |
|---|---|
| NAS / arbitrary folder scanning, `FolderWatcher` (FSEvents) | PhotoKit library + Files app via `UIDocumentPicker` / security-scoped bookmarks |
| `NSCollectionView` grid (`PhotoCollectionView`) | SwiftUI `LazyVGrid` (or a `UICollectionView` rep for 60k perf) |
| `NSOpenPanel`, `NSWorkspace`, `NSMenu`, `NSPasteboard` | `PhotosPicker`, share sheet (`UIActivityViewController`), context menus |
| `QuickLookPreview` panel | `QLPreviewController` |
| Window sizing, `NSScreen`, keyboard culling | Touch UI; gestures; hardware-keyboard shortcuts optional |
| Wallpaper, "Reveal in Finder" | n/a on iOS |

## Recommended architecture

Extract a cross-platform **`LumenEngine`** target (the "ports as-is" list above)
that both apps depend on:

```
LumenEngine (cross-platform: Models + ImageEditor + stores + scanners)
├── LumenKit  (macOS: + AppKit views)        → Lumen.app          [main]
└── LumenIOS  (iOS:   + SwiftUI/UIKit views)  → Lumen.ipa          [feat/ios]
```

Until that refactor lands, the iOS scaffold under `ios/` pulls the portable
source files **directly** into the Xcode project (no Package surgery), so we can
iterate on the iOS UI without touching the macOS build.

## Build (iOS)

The macOS app builds with SwiftPM (`swift build`). iOS needs Xcode. We use
[XcodeGen](https://github.com/yonaskolb/XcodeGen) so the project is generated
from a checked-in `ios/project.yml` (no binary `.xcodeproj` in git):

```sh
brew install xcodegen          # once
cd ios && xcodegen generate     # writes LumenIOS.xcodeproj
open LumenIOS.xcodeproj          # build/run on a simulator or device
```

## Phased roadmap

1. **Engine proof (done)** — `ImageEditor` is AppKit-free; macOS still green.
2. **Scaffold (in progress)** — minimal SwiftUI iOS app + `PhotosPicker` →
   combine via `ImageEditor` → save to Photos. Proves the engine on-device.
3. **Extract `LumenEngine`** target; shim `PhotoMeta`/`ColorLabel` colors.
4. **iOS library**: PhotoKit grid (`LazyVGrid` + `PHCachingImageManager`),
   asset thumbnails, favorites/ratings/labels/reject via `MetadataStore`.
5. **iOS editor**: SwiftUI crop canvas (reuse `ImageEditor.Edit`), resize,
   rotate, straighten, watermark — save edited copy to Photos / Files.
6. **Combine + batch + share**; Files-app sources via document picker.
7. **Polish**: iPad layout, Live Text, Handoff, keyboard shortcuts.

## Notes / risks

- 60k-asset scroll perf on iOS: prefer `PHCachingImageManager` + a
  `UICollectionView`-backed grid for the worst case.
- iOS sandbox: no free NAS browsing. SMB shares are reachable only through the
  Files app (document picker) — acceptable, but it's a different mental model
  than the macOS NAS-first design.
- Saving edits: write to the Photos library (`PHPhotoLibrary` creation request)
  and/or export to Files. RAW edits still save as JPG (same engine rule).
