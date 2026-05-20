#!/usr/bin/env bash
# Stages a vc_ runtime app bundle (formerly vc-board.app) by re-using
# the upstream Ghostty .app shell and re-branding it as "vc_" with the
# spoken name "VC Underscore". The hyphenated "vc-term" fallback is
# added as a symlink for launchers / shells that cannot render the
# trailing underscore.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: distribution/macos/stage-vc-board-app.sh <install-prefix> <source-app> <vc-runtime-bin> <version>" >&2
  exit 1
fi

INSTALL_PREFIX="$1"
SOURCE_APP="$2"
VC_BIN="$3"
VERSION="$4"
APP_BUNDLE="$INSTALL_PREFIX/vc_.app"
PLIST_PATH="$APP_BUNDLE/Contents/Info.plist"

mkdir -p "$INSTALL_PREFIX"
rm -rf "$APP_BUNDLE"
cp -R "$SOURCE_APP" "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$VC_BIN" "$APP_BUNDLE/Contents/MacOS/vc_"
chmod +x "$APP_BUNDLE/Contents/MacOS/vc_"
ln -sf vc_ "$APP_BUNDLE/Contents/MacOS/vc-term"
rm -f \
  "$APP_BUNDLE/Contents/MacOS/ghostty" \
  "$APP_BUNDLE/Contents/MacOS/Ghostty" \
  "$APP_BUNDLE/Contents/MacOS/vc-board"

# Drop the brand asset next to the executable so the bundle ships a
# visible vc_ mark even if the .icns is not generated yet.
ROOT_DIR_FROM_BIN="$(cd "$(dirname "$VC_BIN")/../.." && pwd 2>/dev/null || true)"
for svg_candidate in \
  "$ROOT_DIR_FROM_BIN/vc_.svg" \
  "$(dirname "$0")/../../vc_.svg"; do
  if [[ -f "$svg_candidate" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    cp "$svg_candidate" "$APP_BUNDLE/Contents/Resources/vc_.svg"
    break
  fi
done

set_plist_string() {
  local key="$1"
  local value="$2"

  /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$PLIST_PATH"
}

set_plist_string CFBundleExecutable vc_
set_plist_string CFBundleIdentifier com.vibecrafted.vc-term
set_plist_string CFBundleName vc_
set_plist_string CFBundleDisplayName vc_
set_plist_string CFBundleSpokenName "VC Underscore"
set_plist_string CFBundleShortVersionString "$VERSION"
set_plist_string CFBundleVersion "$VERSION"
set_plist_string NSServices:0:NSMenuItem:default "New vc_ Tab Here"
set_plist_string NSServices:1:NSMenuItem:default "New vc_ Window Here"
