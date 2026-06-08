# Lumen iOS (scaffold — WIP)

A minimal iOS app proving the shared, cross-platform `ImageEditor` engine
(crop/resize/combine/watermark) runs on iOS. See [`../IOS_PORT.md`](../IOS_PORT.md)
for the full architecture and roadmap.

What it does today: pick photos → combine (strip/grid) + optional caption → save
to the photo library. It reuses `../Sources/Lumen/Services/ImageEditor.swift`
verbatim (no AppKit).

## Build & run

Requires Xcode (the macOS app uses SwiftPM; iOS needs an Xcode project, which we
generate from `project.yml` so no binary `.xcodeproj` is committed).

```sh
brew install xcodegen        # once
cd ios
xcodegen generate            # → LumenIOS.xcodeproj
open LumenIOS.xcodeproj       # pick a simulator, ⌘R
```

`LumenIOS.xcodeproj/` is git-ignored — regenerate it from `project.yml`.
