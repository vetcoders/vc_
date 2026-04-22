#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: distribution/macos/stage-vc-board-app.sh <install-prefix> <source-app> <vc-board-bin> <version>" >&2
  exit 1
fi

INSTALL_PREFIX="$1"
SOURCE_APP="$2"
VC_BOARD_BIN="$3"
VERSION="$4"
APP_BUNDLE="$INSTALL_PREFIX/vc-board.app"
PLIST_PATH="$APP_BUNDLE/Contents/Info.plist"

mkdir -p "$INSTALL_PREFIX"
rm -rf "$APP_BUNDLE"
cp -R "$SOURCE_APP" "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$VC_BOARD_BIN" "$APP_BUNDLE/Contents/MacOS/vc-board"
chmod +x "$APP_BUNDLE/Contents/MacOS/vc-board"
rm -f \
  "$APP_BUNDLE/Contents/MacOS/ghostty" \
  "$APP_BUNDLE/Contents/MacOS/Ghostty"

set_plist_string() {
  local key="$1"
  local value="$2"

  /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$PLIST_PATH"
}

set_plist_string CFBundleExecutable vc-board
set_plist_string CFBundleIdentifier com.vibecrafted.vc-board
set_plist_string CFBundleName vc-board
set_plist_string CFBundleDisplayName vc-board
set_plist_string CFBundleShortVersionString "$VERSION"
set_plist_string CFBundleVersion "$VERSION"
set_plist_string NSServices:0:NSMenuItem:default "New vc-board Tab Here"
set_plist_string NSServices:1:NSMenuItem:default "New vc-board Window Here"
