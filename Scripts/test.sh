#!/usr/bin/env bash
# Runs the Lumen test suite. macOS Command Line Tools ship neither XCTest nor
# swift-testing, so `swift test` can't run here — the tests are a plain
# executable target with a tiny zero-dependency assertion harness instead.
set -euo pipefail
cd "$(dirname "$0")/.."
swift run LumenTests "$@"
