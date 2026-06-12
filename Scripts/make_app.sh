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
# Build only the app product. A bare `swift build` would also try to compile the
# LumenTests target, which uses `@testable import` and can't build in release.
swift build -c release --product Lumen

echo "==> Assembling app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$CONTENTS/Info.plist"

# LumenKit's processed resources (String Catalog → toast localization).
# Bundle.module resolves this bundle from Contents/Resources at runtime —
# without it the app aborts on the first localized string.
cp -R "$BUILD_DIR/Lumen_LumenKit.bundle" "$CONTENTS/Resources/"

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

# --- Code signing (conditional) ------------------------------------------
# If a Developer ID identity is available we sign + (optionally) notarize for
# distribution; otherwise we fall back to an ad-hoc signature so the app still
# runs locally. Configure for real signing via env vars:
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   export NOTARY_PROFILE="lumen-notary"   # from: xcrun notarytool store-credentials
# ENTITLEMENTS defaults to Scripts/Lumen.entitlements (Photos-library access
# under the hardened runtime); override the env var to use a different file.
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/Scripts/Lumen.entitlements}"
have_developer_id=false
if [ -n "${DEVELOPER_ID:-}" ] && \
   security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    have_developer_id=true
fi

if [ "$have_developer_id" = true ]; then
    echo "==> Signing with Developer ID (hardened runtime)…"
    sign_args=(--force --deep --timestamp --options runtime --sign "$DEVELOPER_ID")
    if [ -n "${ENTITLEMENTS:-}" ] && [ -f "$ENTITLEMENTS" ]; then
        sign_args+=(--entitlements "$ENTITLEMENTS")
    fi
    codesign "${sign_args[@]}" "$APP_BUNDLE"

    if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "==> Notarizing (this can take a few minutes)…"
        NOTARIZE_ZIP="$(mktemp -d)/Lumen-notarize.zip"
        ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
        if xcrun notarytool submit "$NOTARIZE_ZIP" \
               --keychain-profile "$NOTARY_PROFILE" --wait; then
            echo "==> Stapling notarization ticket…"
            xcrun stapler staple "$APP_BUNDLE"
            xcrun stapler validate "$APP_BUNDLE" && echo "    notarized & stapled ✓"
        else
            echo "    ⚠️  Notarization failed — app is signed but not notarized."
        fi
        rm -rf "$(dirname "$NOTARIZE_ZIP")"
    else
        echo "    (NOTARY_PROFILE unset — signed with Developer ID but NOT notarized)"
    fi
else
    # --- Ad-hoc signature (lets the app launch locally without Gatekeeper fuss) ---
    echo "==> Ad-hoc signing (no Developer ID — set DEVELOPER_ID to notarize)…"
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || \
        echo "    (codesign skipped — app will still run locally)"
fi

echo ""
echo "✅ Built: $APP_BUNDLE"
echo "   Launch with:  open \"$APP_BUNDLE\""
