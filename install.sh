#!/usr/bin/env bash
set -euo pipefail

# Installer for vc_ (spoken: "VC Underscore"). The remote artifact
# names still carry the legacy "vc-board" tag because the GitHub
# release channel uses them, but the binaries inside install as
# vc_ with a vc-term symlink fallback.
BASE_URL="${VC_BOARD_RELEASE_BASE_URL:-https://vibecrafted.io/releases}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/vc-term-install.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="arm64" ;;
esac

download() {
  local url="$1"
  local output="$2"
  curl -fsSL "$url" -o "$output"
}

verify_sha256() {
  local artifact="$1"
  local checksum_file="$2"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$checksum_file"
    return 0
  fi

  shasum -a 256 -c "$checksum_file"
}

if [[ "$OS" == "darwin" ]]; then
  artifact="vc-board-macos-${ARCH}.dmg"
  checksum="${artifact}.sha256"
  download "$BASE_URL/$artifact" "$tmpdir/$artifact"
  download "$BASE_URL/$checksum" "$tmpdir/$checksum"
  (
    cd "$tmpdir"
    verify_sha256 "$artifact" "$checksum"
  )
  open "$tmpdir/$artifact"
  cat <<EOF
Mounted $artifact.
Drag vc_.app into /Applications, then launch it once.
(The installed command is "vc_"; a hyphenated "vc-term" symlink is
included for environments that cannot render the trailing underscore.)
EOF
  exit 0
fi

if [[ "$OS" == "linux" ]]; then
  install_dir="${VC_BOARD_INSTALL_DIR:-${VC_INSTALL_DIR:-$HOME/.local/opt/vc_}}"
  artifact="vc-board-linux-${ARCH}.tar.gz"
  checksum="${artifact}.sha256"
  mkdir -p "$install_dir"
  download "$BASE_URL/$artifact" "$tmpdir/$artifact"
  download "$BASE_URL/$checksum" "$tmpdir/$checksum"
  (
    cd "$tmpdir"
    verify_sha256 "$artifact" "$checksum"
  )
  tar -xzf "$tmpdir/$artifact" -C "$install_dir" --strip-components=1
  cat <<EOF
Installed vc_ (VC Underscore) into $install_dir
Add $install_dir/bin to PATH to invoke "vc_" (or the fallback alias
"vc-term") from any shell.
EOF
  exit 0
fi

echo "Unsupported platform: $(uname -s) $(uname -m)" >&2
exit 1
