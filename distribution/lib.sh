#!/usr/bin/env bash
set -euo pipefail

normalize_arch() {
  case "${1:-$(uname -m)}" in
    x86_64|amd64) printf '%s\n' "x86_64" ;;
    arm64|aarch64) printf '%s\n' "arm64" ;;
    *) printf '%s\n' "${1:-$(uname -m)}" ;;
  esac
}

write_sha256_file() {
  local input="$1"
  local output="$2"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$input" >"$output"
    return 0
  fi

  shasum -a 256 "$input" >"$output"
}
