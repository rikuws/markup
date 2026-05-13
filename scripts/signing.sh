#!/usr/bin/env bash

markup_identity_names() {
  security find-identity -p codesigning -v 2>/dev/null \
    | sed -nE 's/^ *[0-9]+\) [A-Fa-f0-9]{40} "(.+)".*$/\1/p'
}

markup_find_identity_with_prefix() {
  local prefix="$1"
  local identity

  while IFS= read -r identity; do
    case "$identity" in
      "$prefix"*)
        printf '%s\n' "$identity"
        return 0
        ;;
    esac
  done < <(markup_identity_names)

  return 1
}

markup_missing_identity_message() {
  local wanted="$1"

  {
    echo "No $wanted code signing identity was found in your keychain."
    echo "Available code signing identities:"
    security find-identity -p codesigning -v 2>/dev/null || true
  } >&2
}

markup_resolve_sign_identity() {
  local explicit="${MARKUP_CODESIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
  local mode="${MARKUP_SIGNING_MODE:-auto}"
  local identity=""

  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  case "$mode" in
    auto)
      identity="$(markup_find_identity_with_prefix "Developer ID Application:")" || true
      if [[ -n "$identity" ]]; then
        printf '%s\n' "$identity"
        return 0
      fi

      identity="$(markup_find_identity_with_prefix "Apple Development:")" || true
      if [[ -n "$identity" ]]; then
        printf '%s\n' "$identity"
        return 0
      fi

      identity="$(markup_find_identity_with_prefix "Mac Developer:")" || true
      if [[ -n "$identity" ]]; then
        printf '%s\n' "$identity"
        return 0
      fi

      printf '%s\n' "-"
      ;;
    developer-id)
      identity="$(markup_find_identity_with_prefix "Developer ID Application:")" || true
      if [[ -z "$identity" ]]; then
        markup_missing_identity_message "Developer ID Application"
        return 1
      fi
      printf '%s\n' "$identity"
      ;;
    development)
      identity="$(markup_find_identity_with_prefix "Apple Development:")" || true
      if [[ -z "$identity" ]]; then
        identity="$(markup_find_identity_with_prefix "Mac Developer:")" || true
      fi
      if [[ -z "$identity" ]]; then
        markup_missing_identity_message "Apple Development"
        return 1
      fi
      printf '%s\n' "$identity"
      ;;
    adhoc)
      printf '%s\n' "-"
      ;;
    *)
      echo "Unknown MARKUP_SIGNING_MODE '$mode'. Use auto, developer-id, development, or adhoc." >&2
      return 1
      ;;
  esac
}

markup_print_signing_choice() {
  local identity="$1"

  if [[ "$identity" == "-" ]]; then
    echo "Signing Markup with ad hoc identity (-)." >&2
  else
    echo "Signing Markup with $identity." >&2
  fi
}
