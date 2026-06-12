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

# If the app was notarized, the .dmg can be stapled too (offline Gatekeeper pass).
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "==> Stapling notarization ticket to DMG…"
    xcrun stapler staple "$DMG" && echo "    stapled ✓"
else
    echo "    (app not notarized — DMG works but needs xattr/quarantine clear on first run)"
fi

echo ""
echo "✅ Built: $DMG"
