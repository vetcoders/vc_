#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT_DIR/distribution/lib.sh"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/zig-out/dist}"
ARCH="$(normalize_arch "${ARCH:-$(uname -m)}")"
VERSION="${VC_BOARD_VERSION:-dev}"
APP_SOURCE="${APP_SOURCE:-}"
KEYS="${KEYS:-$HOME/.keys}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
SIGNING_IDENTITY_FILE="${SIGNING_IDENTITY_FILE:-$KEYS/signing-identity.txt}"
CODESIGN_ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-$ROOT_DIR/macos/Ghostty.entitlements}"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"
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

resolve_signing_identity() {
  if [[ -n "$SIGNING_IDENTITY" ]]; then
    printf '%s\n' "$SIGNING_IDENTITY"
    return 0
  fi

  if [[ -f "$SIGNING_IDENTITY_FILE" ]]; then
    sed -e 's/[[:space:]]*$//' -e '/^$/d' "$SIGNING_IDENTITY_FILE" | head -1
    return 0
  fi

  return 1
}

sign_app_bundle() {
  local app_bundle="$1"
  local identity=""

  if ! identity="$(resolve_signing_identity)" || [[ -z "$identity" ]]; then
    if [[ "$REQUIRE_SIGNING" == "1" ]]; then
      echo "Signing required, but no identity found. Expected SIGNING_IDENTITY or $SIGNING_IDENTITY_FILE." >&2
      exit 1
    fi
    echo "No signing identity found; leaving app/DMG unsigned." >&2
    return 0
  fi

  echo "Signing vc_.app with Hardened Runtime..." >&2
  if ! security find-identity -v -p codesigning | grep -Fq "$identity"; then
    echo "Signing identity is not available in the keychain: $identity" >&2
    exit 1
  fi

  find "$app_bundle/Contents" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 \
    | while IFS= read -r -d '' nested; do
        codesign --force --options runtime --sign "$identity" --timestamp "$nested"
      done

  local sign_args=(--force --options runtime --sign "$identity" --timestamp)
  if [[ -f "$CODESIGN_ENTITLEMENTS" ]]; then
    sign_args+=(--entitlements "$CODESIGN_ENTITLEMENTS")
  fi
  codesign "${sign_args[@]}" "$app_bundle"
  codesign --verify --deep --strict --verbose=2 "$app_bundle" >/dev/null
}

sign_dmg() {
  local dmg_path="$1"
  local identity=""

  if ! identity="$(resolve_signing_identity)" || [[ -z "$identity" ]]; then
    return 0
  fi

  echo "Signing DMG..." >&2
  codesign --force --sign "$identity" --timestamp "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path" >/dev/null
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

sign_app_bundle "$STAGE_DIR/vc_.app"

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
sign_dmg "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg"
write_sha256_file \
  "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg" \
  "$ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg.sha256"

cat <<EOF
Created:
  $ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg
  $ARTIFACT_DIR/${ARTIFACT_BASENAME}.dmg.sha256
EOF
