#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/zig-out/dist}"
ARCH="${ARCH:-$(uname -m)}"
VERSION="${VC_BOARD_VERSION:-dev}"
APP_SOURCE="${APP_SOURCE:-}"
VC_BOARD_BINARY="${VC_BOARD_BINARY:-$ROOT_DIR/zig-out/bin/vc-board}"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vc-board-macos.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

find_existing_app() {
  local candidate=""
  for candidate in \
    "$ROOT_DIR/macos/build/ReleaseLocal/vc-board.app" \
    "$ROOT_DIR/macos/build/ReleaseLocal/Ghostty.app" \
    "$ROOT_DIR/macos/build/Debug/vc-board.app" \
    "$ROOT_DIR/macos/build/Debug/Ghostty.app"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_binary() {
  if [[ -d "$APP_SOURCE" || -x "$VC_BOARD_BINARY" ]]; then
    return 0
  fi

  echo "Building vc-board binary for macOS bundle..." >&2
  (
    cd "$ROOT_DIR"
    zig build -Druntime=vibecrafted
  )
}

mkdir -p "$ARTIFACT_DIR"
if [[ -z "$APP_SOURCE" ]]; then
  APP_SOURCE="$(find_existing_app || true)"
fi
ensure_binary
bundle_args=(
  --layout macos
  --output "$STAGE_DIR"
  --version "$VERSION"
  --binary "$VC_BOARD_BINARY"
)
if [[ -n "$APP_SOURCE" ]]; then
  bundle_args+=(--app "$APP_SOURCE")
fi
"$ROOT_DIR/distribution/bundle.sh" "${bundle_args[@]}"

ln -s /Applications "$STAGE_DIR/Applications"

ARTIFACT_BASENAME="vc-board-macos-${ARCH}"
hdiutil create \
  -volname "vc-board" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg"
shasum -a 256 "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg" >"$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg.sha256"

cat <<EOF
Created:
  $ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg
  $ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg.sha256
EOF
