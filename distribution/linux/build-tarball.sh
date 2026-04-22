#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT_DIR/distribution/lib.sh"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/zig-out/dist}"
ARCH="$(normalize_arch "${ARCH:-$(uname -m)}")"
VERSION="${VC_BOARD_VERSION:-dev}"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vc-board-linux.XXXXXX")"
VC_BOARD_BINARY="${VC_BOARD_BINARY:-$ROOT_DIR/zig-out/bin/vc-board}"
trap 'rm -rf "$STAGE_DIR"' EXIT

ensure_binary() {
  if [[ -x "$VC_BOARD_BINARY" ]]; then
    return 0
  fi

  echo "Building vc-board binary for linux bundle..." >&2
  (
    cd "$ROOT_DIR"
    zig build -Druntime=vibecrafted
  )
}

mkdir -p "$ARTIFACT_DIR"
ensure_binary
"$ROOT_DIR/distribution/bundle.sh" \
  --layout linux \
  --output "$STAGE_DIR" \
  --binary "$VC_BOARD_BINARY" \
  --version "$VERSION"

ARTIFACT_BASENAME="vc-board-linux-${ARCH}"
if tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$STAGE_DIR" -czf "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.tar.gz" vc-board >/dev/null 2>&1; then
  :
else
  tar -C "$STAGE_DIR" -czf "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.tar.gz" vc-board
fi
write_sha256_file \
  "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.tar.gz" \
  "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.tar.gz.sha256"

cat <<EOF
Created:
  $ARTIFACT_DIR/${ARTIFACT_BASENAME}.tar.gz
  $ARTIFACT_DIR/${ARTIFACT_BASENAME}.tar.gz.sha256
EOF
