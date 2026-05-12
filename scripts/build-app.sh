#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/punchlist.app"
EXECUTABLE="$ROOT/.build/release/punchlist"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/punchlist"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>punchlist</string>
  <key>CFBundleIdentifier</key>
  <string>dev.rikuwikman.punchlist</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>punchlist</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>punchlist can use microphone access when macOS dictation is used in the note field.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>punchlist captures screenshots and optional short recordings for local visual feedback tasks.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

echo "$APP"
