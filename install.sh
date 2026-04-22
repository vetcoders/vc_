#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${VC_BOARD_RELEASE_BASE_URL:-https://vibecrafted.io/releases}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="arm64" ;;
esac

download() {
  local url="$1"
  local output="$2"
  curl -fsSL "$url" -o "$output"
}

if [[ "$OS" == "darwin" ]]; then
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/vc-board-install.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT
  artifact="vc-board-macos-${ARCH}.dmg"
  download "$BASE_URL/$artifact" "$tmpdir/$artifact"
  open "$tmpdir/$artifact"
  cat <<EOF
Mounted $artifact.
Drag vc-board.app into /Applications, then launch it once.
EOF
  exit 0
fi

if [[ "$OS" == "linux" ]]; then
  install_dir="${VC_BOARD_INSTALL_DIR:-$HOME/.local/opt/vc-board}"
  mkdir -p "$install_dir"
  artifact="vc-board-linux-${ARCH}.tar.gz"
  download "$BASE_URL/$artifact" /tmp/"$artifact"
  tar -xzf /tmp/"$artifact" -C "$install_dir" --strip-components=1
  cat <<EOF
Installed vc-board into $install_dir
Add $install_dir/bin to PATH to invoke vc-board directly.
EOF
  exit 0
fi

echo "Unsupported platform: $(uname -s) $(uname -m)" >&2
exit 1
