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
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Transcribe and Practice</string>
    <key>CFBundleDisplayName</key><string>Transcribe and Practice</string>
    <key>CFBundleIdentifier</key><string>com.tamaskenez.transcribeandpractice.prototype</string>
    <key>CFBundleExecutable</key><string>TranscribeAndPractice</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
echo "Built $APP"
