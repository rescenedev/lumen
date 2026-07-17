#!/bin/bash
# One-command release. Builds, signs, notarizes, packages (zip + DMG), updates
# the cask (repo + tap), publishes the GitHub release with BOTH assets, and
# verifies the result. Exists so no release step can be forgotten — in
# particular the unversioned Lumen.dmg asset, which the landing pages link via
# /releases/latest/download/Lumen.dmg (a release without it breaks that URL).
#
# Usage:
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   export NOTARY_PROFILE="lumen-notary"
#   bash Scripts/release.sh [notes.md] [--dry-run]
#
# Before running: bump CFBundleShortVersionString/CFBundleVersion in
# Scripts/Info.plist, add release-notes entries, and commit. The script
# releases whatever version Info.plist declares.
# --dry-run builds and packages everything but pushes/publishes nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTES_FILE=""
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) NOTES_FILE="$arg" ;;
    esac
done

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Scripts/Info.plist)"
TAG="v$VERSION"
ZIP="dist/Lumen-$VERSION.zip"
TAP_REPO="rescenedev/homebrew-tap"

# --- Preflight (fail fast, before any slow work) ---------------------------
echo "==> Preflight for Lumen ${VERSION}…"
fail() { echo "✗ $1" >&2; exit 1; }

[ -n "${DEVELOPER_ID:-}" ] || fail "DEVELOPER_ID not set — releases must be Developer ID signed (ad-hoc builds regress Gatekeeper behavior)"
security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID" \
    || fail "identity \"$DEVELOPER_ID\" not found in keychain"
[ -n "${NOTARY_PROFILE:-}" ] || fail "NOTARY_PROFILE not set — releases must be notarized"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notary profile \"$NOTARY_PROFILE\" invalid (agreement expired? run: xcrun notarytool history --keychain-profile $NOTARY_PROFILE)"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated"
[ -z "$(git status --porcelain)" ] || fail "working tree not clean — commit the version bump and release notes first"
gh release view "$TAG" >/dev/null 2>&1 && fail "release $TAG already exists — bump the version in Scripts/Info.plist"
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || fail "notes file $NOTES_FILE not found"
grep -q "version \"$VERSION\"" Casks/lumen-photos.rb 2>/dev/null \
    && fail "cask already claims $VERSION — did a previous run half-finish?"

echo "==> Running tests…"
./Scripts/test.sh >/dev/null || fail "tests failed — not releasing"
echo "    tests green ✓"

# --- Build & package --------------------------------------------------------
bash Scripts/make_app.sh
spctl -a -t exec dist/Lumen.app || fail "Gatekeeper rejected dist/Lumen.app — notarization did not take"

echo "==> Zipping…"
ditto -c -k --keepParent dist/Lumen.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "    $ZIP  sha256=$SHA"

bash Scripts/make_dmg.sh
[ -f dist/Lumen.dmg ] || fail "dist/Lumen.dmg missing"

# --- Cask update ------------------------------------------------------------
echo "==> Updating cask…"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
          -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/lumen-photos.rb
# Keep the landing pages' JSON-LD version stamp in sync (forgotten twice by hand).
sed -i '' "s/\"softwareVersion\": \"[0-9.]*\"/\"softwareVersion\": \"$VERSION\"/" docs/index.html docs/en/index.html
git diff --stat Casks/lumen-photos.rb docs/index.html docs/en/index.html

if $DRY_RUN; then
    git checkout -- Casks/lumen-photos.rb
    echo
    echo "✅ Dry run complete — artifacts built ($ZIP, dist/Lumen.dmg), nothing published."
    exit 0
fi

git add Casks/lumen-photos.rb docs/index.html docs/en/index.html
git commit -m "chore: release $VERSION (cask sha)"
git push origin HEAD

# --- Publish ----------------------------------------------------------------
echo "==> Creating GitHub release ${TAG}…"
notes_args=(--generate-notes)
[ -n "$NOTES_FILE" ] && notes_args=(--notes-file "$NOTES_FILE")
gh release create "$TAG" "$ZIP" dist/Lumen.dmg --title "Lumen $VERSION" "${notes_args[@]}"

echo "==> Updating tap ($TAP_REPO)…"
TAP_DIR="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q --depth 1
cp Casks/lumen-photos.rb "$TAP_DIR/Casks/lumen-photos.rb"
git -C "$TAP_DIR" commit -aqm "lumen-photos $VERSION"
git -C "$TAP_DIR" push -q origin HEAD
rm -rf "$TAP_DIR"

# --- Verify -----------------------------------------------------------------
echo "==> Verifying…"
assets="$(gh release view "$TAG" --json assets -q '.assets[].name')"
echo "$assets" | grep -q "^Lumen-$VERSION.zip$" || fail "zip asset missing from $TAG"
echo "$assets" | grep -q "^Lumen.dmg$" || fail "Lumen.dmg asset missing from $TAG (landing page DMG link would 404)"
code="$(curl -sIL -o /dev/null -w "%{http_code}" https://github.com/rescenedev/lumen/releases/latest/download/Lumen.dmg)"
[ "$code" = "200" ] || fail "latest/download/Lumen.dmg returned HTTP $code"
brew update >/dev/null 2>&1 || true
brew fetch --cask "rescenedev/tap/lumen-photos" --force >/dev/null \
    && echo "    brew fetch + sha256 ✓" \
    || fail "brew fetch failed — cask/asset mismatch"

echo
echo "✅ Released Lumen $VERSION — zip + DMG published, cask updated, brew verified."
