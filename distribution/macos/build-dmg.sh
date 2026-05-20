#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT_DIR/distribution/lib.sh"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/zig-out/dist}"
ARCH="$(normalize_arch "${ARCH:-$(uname -m)}")"
VERSION="${VC_BOARD_VERSION:-dev}"
APP_SOURCE="${APP_SOURCE:-}"
# Prefer the vc_-rebranded binary; fall back to the legacy vc-board
# path for checkouts built before the rebrand commit.
VC_BOARD_BINARY="${VC_BOARD_BINARY:-$ROOT_DIR/zig-out/bin/vc_}"
if [[ ! -x "$VC_BOARD_BINARY" && -x "$ROOT_DIR/zig-out/bin/vc-board" ]]; then
  VC_BOARD_BINARY="$ROOT_DIR/zig-out/bin/vc-board"
fi
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vc-term-macos.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

find_existing_app() {
  local candidate=""
  for candidate in \
    "$ROOT_DIR/zig-out/vc_.app" \
    "$ROOT_DIR/zig-out/vc-board.app" \
    "$ROOT_DIR/zig-out/Ghostty.app" \
    "$ROOT_DIR/macos/build/ReleaseLocal/vc_.app" \
    "$ROOT_DIR/macos/build/ReleaseLocal/vc-board.app" \
    "$ROOT_DIR/macos/build/ReleaseLocal/Ghostty.app" \
    "$ROOT_DIR/macos/build/Debug/vc_.app" \
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
  if [[ -x "$VC_BOARD_BINARY" ]]; then
    return 0
  fi

  echo "Building vc_ runtime binary for macOS bundle..." >&2
  (
    cd "$ROOT_DIR"
    zig build -Druntime=vibecrafted
  )
}

ensure_app_source() {
  if [[ -n "$APP_SOURCE" && -d "$APP_SOURCE" ]]; then
    return 0
  fi

  APP_SOURCE="$(find_existing_app || true)"
  if [[ -n "$APP_SOURCE" ]]; then
    return 0
  fi

  echo "Building vc_ macOS app shell..." >&2
  (
    cd "$ROOT_DIR"
    zig build vc-board-app -Druntime=vibecrafted
  )

  APP_SOURCE="$(find_existing_app || true)"
  if [[ -z "$APP_SOURCE" ]]; then
    echo "vc_ app bundle was not produced by zig build vc-board-app" >&2
    exit 1
  fi
}

mkdir -p "$ARTIFACT_DIR"
ensure_binary
ensure_app_source
bundle_args=(
  --layout macos
  --output "$STAGE_DIR"
  --version "$VERSION"
  --binary "$VC_BOARD_BINARY"
)
bundle_args+=(--app "$APP_SOURCE")
"$ROOT_DIR/distribution/bundle.sh" "${bundle_args[@]}"

ln -s /Applications "$STAGE_DIR/Applications"

# Artifact basename stays vc-board-* so existing GitHub release URLs
# and install.sh keep resolving; the .dmg now contains vc_.app inside.
ARTIFACT_BASENAME="vc-board-macos-${ARCH}"
hdiutil create \
  -volname "vc_" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg"
write_sha256_file \
  "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg" \
  "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg.sha256"

cat <<EOF
Created:
  $ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg
  $ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg.sha256
EOF
