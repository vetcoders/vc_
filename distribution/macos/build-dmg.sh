#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/zig-out/dist}"
ARCH="${ARCH:-$(uname -m)}"
VERSION="${VC_BOARD_VERSION:-dev}"
APP_SOURCE="${APP_SOURCE:-}"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vc-board-macos.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$ARTIFACT_DIR"
bundle_args=(
  --layout macos
  --output "$STAGE_DIR"
  --version "$VERSION"
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
