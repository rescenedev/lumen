# Lumen — a native macOS photo viewer

A fast, **read-only** photo viewer for macOS, built in SwiftUI + AppKit. No editing —
just a clean, keyboard-driven way to browse a photo library. Built as a prototype using
the native-macOS patterns from
[fayazara/macos-app-skills](https://github.com/fayazara/macos-app-skills).

![aperture icon] Built for macOS 14+ (developed/tested on macOS 26 “Tahoe”, Swift 6.3).

## Features

**Library & organization**
- Add folders or images (⌘O, **＋**, or drag-and-drop); recursive scan across JPEG, PNG,
  HEIC, TIFF, GIF, WebP, AVIF, PSD, and common RAW types (CR2/CR3, NEF, ARW, DNG, ORF…)
- **Albums** — create / rename / delete, add a selection, remove
- **Tags** and **color labels** (Finder-style), each with its own sidebar section
- **Star ratings** (0–5) — keys `1`–`5` in the viewer, click stars in the inspector
- **Smart collections** — All Photos, Favorites, Recently Added, On This Day, Duplicates
- **Folders** list, **live file-system watching** (FSEvents) auto-syncs add/remove
- Metadata (favorites/ratings/labels/tags/albums) persisted to `~/Library/Application Support/Lumen`

**Views**
- **Grid**, **List**, and **Map** (MapKit pins for geotagged photos) — ⌘1 / ⌘2 / ⌘3
- Adaptive grid with a Finder-style bottom size slider, optional **group-by-month** timeline
- Multi-selection everywhere: click, ⌘-click toggle, ⇧-click range, ⌘A, Esc to clear
- Sort by date / name / size; **filter** by type, rating, label, favorite, has-location, camera
- **Search** across filename, tags, and camera model

**Viewer**
- Pinch / scroll / double-click **zoom**, drag **pan**; ←/→ navigate, Esc close
- **EXIF overlay** (`i`), inline **rating** stars, side-by-side **Compare** (select 2)
- Auto-advancing **slideshow** (Space), favorite (`f`), Trash (⌫)

**Actions**
- **Move to Trash** (⌫ / ⌘⌫) with confirmation, batch-aware
- **Share** (system share sheet), **Export** (originals / resized / zip), **Set as Wallpaper**
- **Batch rename** with `{n}` pattern + live preview
- **Duplicate finder** (size + content hash)
- Quick Look (Space), Reveal in Finder, Copy, Open in default app

**Info inspector**
- Interactive rating / label / tag editor + add-to-album
- File facts, camera EXIF, GPS coordinates + “Show in Maps”
- Multi-selection summary with batch actions

**Performance & native integration**
- Two-tier thumbnail cache (memory + **disk**, survives relaunch)
- Background EXIF indexer powering filters / search / map
- `NavigationSplitView` + `.inspector()`, Quick Look, `NSSharingServicePicker`,
  `NSWorkspace`, **Settings** window (⌘,)

> Scope note: Lumen is a **viewer/manager** — it never alters image pixels. There is no
> crop/rotate/adjust. Everything above is non-destructive (Trash is recoverable; rename
> only changes filenames).

## Install (Homebrew)

```bash
# Private tap needs a token:
export HOMEBREW_GITHUB_API_TOKEN=$(gh auth token)

brew tap rescenedev/tap
brew install --cask lumen-photos
```

The cask token is `lumen-photos` (the plain `lumen` name is already taken by a
different app in homebrew-cask). Lumen is ad-hoc signed (not notarized): on
first launch, right-click → Open, or run
`xattr -dr com.apple.quarantine "/Applications/Lumen.app"`.

## Build & run

```bash
# Quick dev run:
swift run

# Build a double-clickable .app (release build + icon + ad-hoc sign):
./Scripts/make_app.sh
open dist/Lumen.app
```

Requires the Xcode Command Line Tools (no full Xcode needed — the bundle is built with
Swift Package Manager).

## Try it with sample images

```bash
swift Scripts/make_samples.swift "$HOME/LumenSamples"   # 15 images in 3 folders
open dist/Lumen.app                                      # then ⌘O → choose the folder
```

## Project layout

```
Sources/Lumen/
  App/          LumenApp.swift          @main scene + menu commands
  Models/       Photo, SortOrder, SidebarItem
  Store/        AppModel (central state), FavoritesStore
  Services/     PhotoScanner, ThumbnailCache, FullImageLoader, MetadataReader
  Views/        ContentView, SidebarView, PhotoGridView, ThumbnailCell,
                AsyncThumbnail, ViewerView, ZoomableImage, InspectorView,
                EmptyStateView, PhotoContextMenu
  Utils/        Formatters, QuickLookPreview
Scripts/        make_app.sh, Info.plist, make_icon.swift, make_samples.swift
```

Architecture: one observable `AppModel` owns the library and view state; services are
stateless/cached helpers; views are small and composable. Photos are immutable value types.
