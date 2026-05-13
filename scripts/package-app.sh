#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Markup.app"
DIST="$ROOT/dist"
STAGING="$ROOT/.build/package/markup"

source "$ROOT/scripts/signing.sh"

export MARKUP_SIGNING_MODE="${MARKUP_SIGNING_MODE:-developer-id}"
SIGN_IDENTITY="$(markup_resolve_sign_identity)"
export MARKUP_CODESIGN_IDENTITY="$SIGN_IDENTITY"

"$ROOT/scripts/build-app.sh" >/dev/null

if [[ "${MARKUP_ALLOW_DEVELOPMENT_PACKAGE:-0}" != "1" ]]; then
  SIGN_DETAILS="$(codesign -dvv "$APP" 2>&1)"
  if ! grep -q "Authority=Developer ID Application" <<<"$SIGN_DETAILS"; then
    echo "Package builds intended for downloads must use a Developer ID Application certificate." >&2
    echo "Install that certificate, or set MARKUP_ALLOW_DEVELOPMENT_PACKAGE=1 for a local-only package." >&2
    exit 1
  fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
BASENAME="markup-${VERSION}-macos-${ARCH}"
ZIP="$DIST/$BASENAME.zip"
DMG="$DIST/$BASENAME.dmg"

rm -rf "$STAGING"
mkdir -p "$DIST" "$STAGING"
rm -f "$ZIP" "$DMG"

cp -R "$APP" "$STAGING/Markup.app"
ln -s /Applications "$STAGING/Applications"

ditto -c -k --keepParent "$APP" "$ZIP"
hdiutil create -volname "Markup" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG" >/dev/null

cat <<EOF
$DMG
$ZIP
EOF
