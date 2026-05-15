#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
UPDATE_DIR="${MARKUP_SPARKLE_UPDATE_DIR:-$ROOT/.build/sparkle-updates}"
RELEASE_BASE_URL="${MARKUP_RELEASE_BASE_URL:-https://github.com/rikuws/markup/releases/latest/download}"
RELEASE_LINK="${MARKUP_RELEASE_LINK:-https://github.com/rikuws/markup/releases/latest}"

source "$ROOT/scripts/sparkle.sh"

ZIP="${1:-}"
if [[ -z "$ZIP" ]]; then
  ZIP="$(find "$DIST" -maxdepth 1 -name 'markup-*.zip' -print | sort | tail -n 1)"
fi

if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
  echo "No Markup zip archive found. Run ./scripts/package-app.sh first or pass the zip path." >&2
  exit 1
fi

if [[ -z "${MARKUP_SPARKLE_PRIVATE_ED_KEY:-}" && -z "${MARKUP_SPARKLE_PRIVATE_ED_KEY_FILE:-}" ]]; then
  echo "Set MARKUP_SPARKLE_PRIVATE_ED_KEY or MARKUP_SPARKLE_PRIVATE_ED_KEY_FILE before generating appcast.xml." >&2
  exit 1
fi

GENERATE_APPCAST="$(markup_find_sparkle_tool "$ROOT" "generate_appcast")"
ARCHIVE_NAME="$(basename "$ZIP")"
APPCAST="$UPDATE_DIR/appcast.xml"

case "$RELEASE_BASE_URL" in
  */) ;;
  *) RELEASE_BASE_URL="$RELEASE_BASE_URL/" ;;
esac

rm -rf "$UPDATE_DIR"
mkdir -p "$UPDATE_DIR"
cp "$ZIP" "$UPDATE_DIR/$ARCHIVE_NAME"

if [[ -n "${MARKUP_RELEASE_NOTES_FILE:-}" ]]; then
  if [[ ! -f "$MARKUP_RELEASE_NOTES_FILE" ]]; then
    echo "MARKUP_RELEASE_NOTES_FILE does not point to a file: $MARKUP_RELEASE_NOTES_FILE" >&2
    exit 1
  fi

  case "$MARKUP_RELEASE_NOTES_FILE" in
    *.html|*.md|*.txt)
      cp "$MARKUP_RELEASE_NOTES_FILE" "$UPDATE_DIR/${ARCHIVE_NAME%.*}.${MARKUP_RELEASE_NOTES_FILE##*.}"
      ;;
    *)
      echo "MARKUP_RELEASE_NOTES_FILE must end in .html, .md, or .txt." >&2
      exit 1
      ;;
  esac
fi

COMMAND=(
  "$GENERATE_APPCAST"
  --download-url-prefix "$RELEASE_BASE_URL"
  --link "$RELEASE_LINK"
  --maximum-versions 1
  -o "$APPCAST"
)

if [[ -n "${MARKUP_SPARKLE_PRIVATE_ED_KEY_FILE:-}" ]]; then
  COMMAND+=(--ed-key-file "$MARKUP_SPARKLE_PRIVATE_ED_KEY_FILE" "$UPDATE_DIR")
  "${COMMAND[@]}" >&2
else
  COMMAND+=(--ed-key-file - "$UPDATE_DIR")
  printf '%s\n' "$MARKUP_SPARKLE_PRIVATE_ED_KEY" | "${COMMAND[@]}" >&2
fi

echo "$APPCAST"
