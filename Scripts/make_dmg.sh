#!/bin/bash
# Packages dist/Lumen.app into a drag-to-install DMG (dist/Lumen.dmg).
# Run AFTER make_app.sh. If the bundled app is signed + notarized, the DMG is
# stapled too so it opens offline with no Gatekeeper prompt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Lumen.app"
DMG="$ROOT/dist/Lumen.dmg"          # fixed name → releases/latest/download/Lumen.dmg always resolves
VOLNAME="Lumen"

[ -d "$APP" ] || { echo "✗ $APP not found — run Scripts/make_app.sh first"; exit 1; }

echo "==> Staging…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

echo "==> Building DMG…"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Sign + notarize the DMG itself so it opens offline with no Gatekeeper prompt.
# (Stapling requires the DMG to be notarized in its own right — the app's
# ticket doesn't transfer.) Same env contract as make_app.sh:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="lumen-notary"
if [ -n "${DEVELOPER_ID:-}" ] && \
   security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    echo "==> Signing DMG…"
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "==> Notarizing DMG (this can take a few minutes)…"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        echo "==> Stapling notarization ticket to DMG…"
        xcrun stapler staple "$DMG" && echo "    stapled ✓"
        spctl -a -t open --context context:primary-signature "$DMG" && echo "    Gatekeeper: accepted ✓"
    else
        echo "    (NOTARY_PROFILE not set — DMG signed but not notarized)"
    fi
else
    echo "    (DEVELOPER_ID not set — DMG unsigned; the app inside keeps its own signature)"
fi

echo ""
echo "✅ Built: $DMG"
