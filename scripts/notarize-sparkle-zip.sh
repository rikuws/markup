#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Markup.app"
ZIP="${1:-}"
PROFILE="${NOTARYTOOL_PROFILE:-markup-notary}"

if [[ -z "$ZIP" && -d "$ROOT/dist" ]]; then
  ZIP="$(find "$ROOT/dist" -maxdepth 1 -name 'markup-*.zip' -print | sort | tail -n 1)"
fi

if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
  echo "No ZIP found. Run ./scripts/package-app.sh first, or pass the ZIP path." >&2
  exit 1
fi

if [[ ! -d "$APP" ]]; then
  echo "No app bundle found at $APP. Run ./scripts/package-app.sh first." >&2
  exit 1
fi

SIGN_DETAILS="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q "Authority=Developer ID Application" <<<"$SIGN_DETAILS"; then
  echo "The app is not signed with a Developer ID Application certificate." >&2
  echo "Run ./scripts/package-app.sh after installing a Developer ID Application certificate." >&2
  exit 1
fi

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null
spctl -a -vv -t exec "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "$ZIP"
