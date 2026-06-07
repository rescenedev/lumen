#!/bin/bash
# Builds Lumen in release mode and packages it into a double-clickable .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Lumen"
BUILD_DIR="$ROOT/.build/release"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "==> Building release binary…"
swift build -c release

echo "==> Assembling app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$CONTENTS/Info.plist"

# --- App icon -------------------------------------------------------------
echo "==> Generating app icon…"
ICON_TMP="$(mktemp -d)"
if swift "$ROOT/Scripts/make_icon.swift" "$ICON_TMP/icon_1024.png" >/dev/null 2>&1; then
    ICONSET="$ICON_TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512; do
        sips -z "$size" "$size" "$ICON_TMP/icon_1024.png" \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_TMP/icon_1024.png" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
    echo "    icon embedded."
else
    echo "    (icon generation skipped)"
fi
rm -rf "$ICON_TMP"

# --- Ad-hoc code signature (lets the app launch without Gatekeeper fuss) ---
echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || \
    echo "    (codesign skipped — app will still run locally)"

echo ""
echo "✅ Built: $APP_BUNDLE"
echo "   Launch with:  open \"$APP_BUNDLE\""
