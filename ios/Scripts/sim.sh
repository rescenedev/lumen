#!/bin/bash
# Build the iOS app + tests, run the tests on a simulator, and launch the app.
#
# Why -target/SYMROOT + simctl instead of `xcodebuild test`: on a fresh Xcode
# 26.5 the iOS *platform* component may be missing, which breaks xcodebuild's
# destination resolver ("iOS 26.x is not installed") even though simulator
# runtimes exist. We side-step it: build for the simulator SDK with `-target`
# (no destination needed) and run the .xctest bundle directly on a booted
# simulator via `simctl spawn xctest`. After you download the iOS platform
# (Xcode ▸ Settings ▸ Components, or `xcodebuild -downloadPlatform iOS`), the
# usual `xcodebuild test -scheme LumenIOS -destination ...` works too.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SIM_NAME="${1:-iPhone 17}"
SIM=$(xcrun simctl list devices available | grep "$SIM_NAME (" | head -1 | grep -oE '[0-9A-F-]{36}')
[ -z "$SIM" ] && { echo "No available simulator named '$SIM_NAME'"; exit 1; }
echo "▸ Simulator: $SIM_NAME ($SIM)"

xcodegen generate >/dev/null
SYM="$PWD/build/sym"; PROD="$SYM/Debug-iphonesimulator"

echo "▸ Building app + tests (simulator SDK)…"
for t in LumenIOS LumenIOSTests; do
  xcodebuild -project LumenIOS.xcodeproj -target "$t" -sdk iphonesimulator \
    -configuration Debug SYMROOT="$SYM" CODE_SIGNING_ALLOWED=NO build >/dev/null
done

echo "▸ Booting simulator…"
xcrun simctl boot "$SIM" >/dev/null 2>&1 || true
open -a Simulator

echo "▸ Running tests…"
xcrun simctl spawn "$SIM" \
  "$DEVELOPER_DIR/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest" \
  -XCTest All "$PROD/LumenIOSTests.xctest" 2>&1 | grep -E "Test Suite 'All|passed|failed" | tail -3

echo "▸ Installing + launching the app…"
xcrun simctl install "$SIM" "$PROD/LumenIOS.app"
xcrun simctl launch "$SIM" com.prototype.lumen.ios
echo "✅ Done."
