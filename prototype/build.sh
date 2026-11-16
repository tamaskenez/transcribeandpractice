#!/bin/bash
# Builds the prototype and wraps it into build/TranscribeAndPractice.app
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TranscribeAndPractice"
APP="build/TranscribeAndPractice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TranscribeAndPractice"
cp Info.plist "$APP/Contents/Info.plist"
echo "Built $APP"
