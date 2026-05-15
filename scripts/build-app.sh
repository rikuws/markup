#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Markup.app"
EXECUTABLE="$ROOT/.build/release/Markup"
RESOURCE_DIR="$ROOT/Sources/Markup/Resources"
VERSION="${MARKUP_VERSION:-0.1.0}"
BUILD_NUMBER="${MARKUP_BUILD_NUMBER:-1}"
SPARKLE_FEED_URL="${MARKUP_SPARKLE_FEED_URL:-https://github.com/rikuws/markup/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${MARKUP_SPARKLE_PUBLIC_ED_KEY:-}"

source "$ROOT/scripts/signing.sh"
source "$ROOT/scripts/sparkle.sh"

SIGN_IDENTITY="$(markup_resolve_sign_identity)"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"

cp "$EXECUTABLE" "$APP/Contents/MacOS/Markup"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Markup</string>
  <key>CFBundleIdentifier</key>
  <string>dev.rikuwikman.markup</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Markup</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
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
  <string>Markup can use microphone access when macOS dictation is used in the note field.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Markup captures screenshots and optional short recordings for local visual feedback tasks.</string>
</dict>
</plist>
PLIST

if [[ -d "$RESOURCE_DIR" ]]; then
  cp -R "$RESOURCE_DIR"/. "$APP/Contents/Resources/"
fi

SPARKLE_FRAMEWORK="$(markup_find_sparkle_framework "$ROOT")"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 86400" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool false" "$APP/Contents/Info.plist"

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
else
  echo "MARKUP_SPARKLE_PUBLIC_ED_KEY is unset; built app will not accept signed Sparkle updates." >&2
fi

markup_print_signing_choice "$SIGN_IDENTITY"

SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null

echo "$APP"
