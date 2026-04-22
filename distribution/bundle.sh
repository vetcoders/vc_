#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/distribution/lib.sh"
LAYOUT=""
OUTPUT_DIR=""
APP_SOURCE=""
BINARY_SOURCE="${VC_BOARD_BINARY:-$ROOT_DIR/zig-out/bin/vc-board}"
HELPERS_DIR="${VC_BOARD_HELPERS_DIR:-$HOME/.vibecrafted/bin}"
SKILLS_DIR="${VC_BOARD_SKILLS_DIR:-$ROOT_DIR/.agents/skills}"
VERSION="${VC_BOARD_VERSION:-dev}"
BUILD_HELPERS="${VC_BOARD_BUILD_HELPERS:-1}"

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

needs_binary=1
if [[ "$LAYOUT" == "macos" && -n "$APP_SOURCE" ]]; then
  needs_binary=0
fi

if [[ "$needs_binary" -eq 1 && ! -x "$BINARY_SOURCE" ]]; then
  echo "vc-board binary not found: $BINARY_SOURCE" >&2
  exit 1
fi

helper_env_var() {
  local name="$1"
  local normalized="${name//-/_}"
  normalized="${normalized^^}"
  printf 'VC_BOARD_%s_BIN\n' "$normalized"
}

helper_candidates() {
  case "$1" in
    loctree)
      printf '%s\n' loctree loct
      ;;
    rust-mux)
      printf '%s\n' rust-mux rust_mux
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

helper_repo_dir() {
  case "$1" in
    aicx) printf '%s\n' "$ROOT_DIR/../aicx" ;;
    loctree) printf '%s\n' "$ROOT_DIR/../loctree" ;;
    prview) printf '%s\n' "$ROOT_DIR/../prview" ;;
    rust-mux) printf '%s\n' "$ROOT_DIR/../rust-mux" ;;
    *) return 1 ;;
  esac
}

helper_repo_bin_paths() {
  local name="$1"
  local repo_dir="$2"
  case "$name" in
    aicx)
      printf '%s\n' \
        "$repo_dir/target/release/aicx" \
        "$repo_dir/target/debug/aicx"
      ;;
    loctree)
      printf '%s\n' \
        "$repo_dir/target/release/loctree" \
        "$repo_dir/target/debug/loctree"
      ;;
    prview)
      printf '%s\n' \
        "$repo_dir/target/release/prview" \
        "$repo_dir/target/debug/prview"
      ;;
    rust-mux)
      printf '%s\n' \
        "$repo_dir/target/release/rust-mux" \
        "$repo_dir/target/release/rust_mux" \
        "$repo_dir/target/debug/rust-mux" \
        "$repo_dir/target/debug/rust_mux"
      ;;
    *)
      return 1
      ;;
  esac
}

build_helper_from_repo() {
  local name="$1"
  local repo_dir

  [[ "$BUILD_HELPERS" == "0" ]] && return 1
  repo_dir="$(helper_repo_dir "$name")" || return 1
  [[ -f "$repo_dir/Cargo.toml" ]] || return 1

  echo "Building missing helper $name from $repo_dir" >&2
  (
    cd "$repo_dir"
    case "$name" in
      aicx) cargo build --release --bin aicx ;;
      loctree) cargo build --release --bin loctree ;;
      prview) cargo build --release --bin prview ;;
      rust-mux) cargo build --release --bin rust-mux ;;
      *) return 1 ;;
    esac
  )
}

resolve_helper_path() {
  local name="$1"
  local env_var
  local env_path=""
  local candidate=""
  local repo_dir=""

  env_var="$(helper_env_var "$name")"
  env_path="${!env_var:-}"
  if [[ -n "$env_path" ]]; then
    if [[ -x "$env_path" ]]; then
      printf '%s\n' "$env_path"
      return 0
    fi
    echo "Helper override $env_var points to a non-executable path: $env_path" >&2
    return 1
  fi

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue

    if [[ -x "$HELPERS_DIR/$candidate" ]]; then
      printf '%s\n' "$HELPERS_DIR/$candidate"
      return 0
    fi

    env_path="$(type -P "$candidate" || true)"
    if [[ -n "$env_path" && -x "$env_path" ]]; then
      printf '%s\n' "$env_path"
      return 0
    fi
  done < <(helper_candidates "$name")

  repo_dir="$(helper_repo_dir "$name" 2>/dev/null || true)"
  if [[ -n "$repo_dir" ]]; then
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(helper_repo_bin_paths "$name" "$repo_dir")

    if build_helper_from_repo "$name"; then
      while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if [[ -x "$candidate" ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done < <(helper_repo_bin_paths "$name" "$repo_dir")
    fi
  fi

  return 1
}

copy_helpers() {
  local destination="$1"
  mkdir -p "$destination"
  local helper
  for helper in aicx loctree prview rust-mux; do
    local resolved=""
    if ! resolved="$(resolve_helper_path "$helper")"; then
      echo "Missing required helper: $helper" >&2
      echo "Set $(helper_env_var "$helper") or VC_BOARD_HELPERS_DIR to a directory containing it." >&2
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

rewrite_macos_plist() {
  local plist_path="$1"

  if [[ -f "$plist_path" ]] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable vc-board" "$plist_path" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string vc-board" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.vibecrafted.vc-board" "$plist_path" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.vibecrafted.vc-board" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName vc-board" "$plist_path" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleName string vc-board" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName vc-board" "$plist_path" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string vc-board" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$plist_path" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$plist_path" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${VERSION}" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 13.0" "$plist_path" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$plist_path"
    return 0
  fi

  write_macos_plist "$plist_path"
}

bundle_macos() {
  local app_bundle="$OUTPUT_DIR/vc-board.app"
  rm -rf "$app_bundle"

  if [[ -n "$APP_SOURCE" ]]; then
    cp -R "$APP_SOURCE" "$app_bundle"
  else
    mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
  fi

  mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
  cp "$BINARY_SOURCE" "$app_bundle/Contents/MacOS/vc-board"
  chmod +x "$app_bundle/Contents/MacOS/vc-board"
  rm -f \
    "$app_bundle/Contents/MacOS/ghostty" \
    "$app_bundle/Contents/MacOS/Ghostty"
  rewrite_macos_plist "$app_bundle/Contents/Info.plist"

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
