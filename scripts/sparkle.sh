#!/usr/bin/env bash

markup_sparkle_search_bases() {
  local root="$1"

  printf '%s\n' "$root/.build/artifacts" "$root/.build/checkouts"

  # Xcode stores binary SPM artifacts in DerivedData, not .build.
  if [[ -n "${BUILD_DIR:-}" ]]; then
    printf '%s\n' "$BUILD_DIR/../../SourcePackages/artifacts"
  fi
  if [[ -n "${OBJROOT:-}" ]]; then
    printf '%s\n' "$OBJROOT/../../SourcePackages/artifacts"
  fi
  if [[ -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
    printf '%s\n' "$BUILT_PRODUCTS_DIR"
  fi
}

markup_find_sparkle_in_base() {
  local base="$1"
  local candidate

  [[ -d "$base" ]] || return 1

  candidate="$(find "$base" -path '*/macos-*/Sparkle.framework' -type d -print 2>/dev/null | sort | head -n 1)"
  if [[ -z "$candidate" ]]; then
    candidate="$(find "$base" -path '*/Sparkle.framework' -type d -print 2>/dev/null | sort | head -n 1)"
  fi

  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

markup_find_sparkle_framework() {
  local root="$1"
  local candidate
  local base

  if [[ -n "${MARKUP_SPARKLE_FRAMEWORK:-}" ]]; then
    if [[ -d "$MARKUP_SPARKLE_FRAMEWORK" ]]; then
      printf '%s\n' "$MARKUP_SPARKLE_FRAMEWORK"
      return 0
    fi

    echo "MARKUP_SPARKLE_FRAMEWORK does not point to a Sparkle.framework directory: $MARKUP_SPARKLE_FRAMEWORK" >&2
    return 1
  fi

  while IFS= read -r base; do
    if candidate="$(markup_find_sparkle_in_base "$base")"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(markup_sparkle_search_bases "$root")

  echo "Could not find Sparkle.framework. Run 'swift package resolve' or build Markup.xcodeproj once so Xcode fetches Sparkle." >&2
  return 1
}

markup_find_sparkle_tool() {
  local root="$1"
  local tool="$2"
  local candidate
  local base

  while IFS= read -r base; do
    [[ -d "$base" ]] || continue

    candidate="$(find "$base" -path "*/bin/$tool" -type f -perm -111 -print 2>/dev/null | sort | head -n 1)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(markup_sparkle_search_bases "$root")

  echo "Could not find Sparkle tool '$tool'. Run 'swift package resolve' first." >&2
  return 1
}
