#!/usr/bin/env bash

markup_find_sparkle_framework() {
  local root="$1"
  local candidate

  if [[ -n "${MARKUP_SPARKLE_FRAMEWORK:-}" ]]; then
    if [[ -d "$MARKUP_SPARKLE_FRAMEWORK" ]]; then
      printf '%s\n' "$MARKUP_SPARKLE_FRAMEWORK"
      return 0
    fi

    echo "MARKUP_SPARKLE_FRAMEWORK does not point to a Sparkle.framework directory: $MARKUP_SPARKLE_FRAMEWORK" >&2
    return 1
  fi

  for base in "$root/.build/artifacts" "$root/.build/checkouts"; do
    [[ -d "$base" ]] || continue

    candidate="$(find "$base" -path '*/Sparkle.framework' -type d -print | sort | head -n 1)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Could not find Sparkle.framework. Run 'swift package resolve' or 'swift build -c release' first." >&2
  return 1
}

markup_find_sparkle_tool() {
  local root="$1"
  local tool="$2"
  local candidate

  for base in "$root/.build/artifacts" "$root/.build/checkouts"; do
    [[ -d "$base" ]] || continue

    candidate="$(find "$base" -path "*/bin/$tool" -type f -perm -111 -print | sort | head -n 1)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Could not find Sparkle tool '$tool'. Run 'swift package resolve' first." >&2
  return 1
}
