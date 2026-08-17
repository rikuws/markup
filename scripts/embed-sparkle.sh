#!/usr/bin/env bash
# Copy Sparkle.framework into the app from SwiftPM artifacts.
# Xcode's Embed Frameworks phase looks for $BUILT_PRODUCTS_DIR/Sparkle, which
# binary SPM packages never create.
set -euo pipefail

ROOT="${PROJECT_DIR:?PROJECT_DIR is not set}"
# shellcheck source=sparkle.sh
source "$ROOT/scripts/sparkle.sh"

FRAMEWORK="$(markup_find_sparkle_framework "$ROOT")"
DEST="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/Sparkle.framework"

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
ditto "$FRAMEWORK" "$DEST"

if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
    --preserve-metadata=identifier,entitlements,flags \
    "$DEST"
fi

echo "Embedded Sparkle.framework from $FRAMEWORK"
