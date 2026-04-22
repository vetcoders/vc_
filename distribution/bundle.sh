#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYOUT=""
OUTPUT_DIR=""
APP_SOURCE=""
BINARY_SOURCE="${VC_BOARD_BINARY:-$ROOT_DIR/zig-out/bin/vc-board}"
HELPERS_DIR="${VC_BOARD_HELPERS_DIR:-$HOME/.vibecrafted/bin}"
SKILLS_DIR="${VC_BOARD_SKILLS_DIR:-$ROOT_DIR/.agents/skills}"
VERSION="${VC_BOARD_VERSION:-dev}"

usage() {
  cat <<'EOF'
Usage: distribution/bundle.sh --layout macos|linux --output <dir> [options]

Options:
  --app <path>         Existing .app bundle to augment (macOS only).
  --binary <path>      vc-board binary to package.
  --helpers-dir <dir>  Directory containing bundled helper binaries.
  --skills-dir <dir>   Directory containing skills to embed.
  --version <value>    Version string for generated metadata.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --layout) LAYOUT="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --app) APP_SOURCE="$2"; shift 2 ;;
    --binary) BINARY_SOURCE="$2"; shift 2 ;;
    --helpers-dir) HELPERS_DIR="$2"; shift 2 ;;
    --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$LAYOUT" || -z "$OUTPUT_DIR" ]]; then
  usage
  exit 1
fi

if [[ ! -x "$BINARY_SOURCE" ]]; then
  echo "vc-board binary not found: $BINARY_SOURCE" >&2
  exit 1
fi

resolve_helper() {
  local name="$1"
  if [[ -x "$HELPERS_DIR/$name" ]]; then
    printf '%s\n' "$HELPERS_DIR/$name"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  return 1
}

copy_helpers() {
  local destination="$1"
  mkdir -p "$destination"
  local helper
  for helper in aicx loctree prview rust-mux; do
    local resolved
    if ! resolved="$(resolve_helper "$helper")"; then
      echo "Missing required helper: $helper" >&2
      exit 1
    fi
    cp "$resolved" "$destination/$helper"
    chmod +x "$destination/$helper"
  done
}

copy_skills() {
  local destination="$1"
  if [[ ! -d "$SKILLS_DIR" ]]; then
    echo "Skills directory not found: $SKILLS_DIR" >&2
    exit 1
  fi
  rm -rf "$destination"
  mkdir -p "$(dirname "$destination")"
  cp -R "$SKILLS_DIR" "$destination"
}

write_default_config() {
  local config_path="$1"
  mkdir -p "$(dirname "$config_path")"
  cat >"$config_path" <<'EOF'
# vc-board bundled config
# Runtime-specific defaults land here as install behavior matures.
EOF
}

bundle_linux() {
  local bundle_root="$OUTPUT_DIR/vc-board"
  rm -rf "$bundle_root"
  mkdir -p "$bundle_root/bin" "$bundle_root/share" "$bundle_root/share/applications"

  cp "$BINARY_SOURCE" "$bundle_root/bin/vc-board"
  chmod +x "$bundle_root/bin/vc-board"
  copy_helpers "$bundle_root/bin"
  copy_skills "$bundle_root/share/skills"
  write_default_config "$bundle_root/share/config/config"
  if [[ -f "$ROOT_DIR/linux/vibecrafted.desktop" ]]; then
    cp "$ROOT_DIR/linux/vibecrafted.desktop" "$bundle_root/share/applications/vibecrafted.desktop"
  fi
}

write_macos_plist() {
  local plist_path="$1"
  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>vc-board</string>
  <key>CFBundleIdentifier</key>
  <string>com.vibecrafted.vc-board</string>
  <key>CFBundleName</key>
  <string>vc-board</string>
  <key>CFBundleDisplayName</key>
  <string>vc-board</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
}

bundle_macos() {
  local app_bundle="$OUTPUT_DIR/vc-board.app"
  rm -rf "$app_bundle"

  if [[ -n "$APP_SOURCE" ]]; then
    cp -R "$APP_SOURCE" "$app_bundle"
  else
    mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
    cp "$BINARY_SOURCE" "$app_bundle/Contents/MacOS/vc-board"
    chmod +x "$app_bundle/Contents/MacOS/vc-board"
    write_macos_plist "$app_bundle/Contents/Info.plist"
  fi

  mkdir -p "$app_bundle/Contents/Resources/bin"
  copy_helpers "$app_bundle/Contents/Resources/bin"
  copy_skills "$app_bundle/Contents/Resources/skills"
  write_default_config "$app_bundle/Contents/Resources/config/config"
}

mkdir -p "$OUTPUT_DIR"
case "$LAYOUT" in
  linux) bundle_linux ;;
  macos) bundle_macos ;;
  *) echo "Unsupported layout: $LAYOUT" >&2; exit 1 ;;
esac
