#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: distribution/macos/notarize.sh <vc-board.dmg>" >&2
  exit 1
fi

DMG_PATH="$1"
: "${APPLE_ID:?Set APPLE_ID for notarytool authentication}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID for notarytool authentication}"
: "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD for notarytool authentication}"

xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

xcrun stapler staple "$DMG_PATH"
echo "Notarized and stapled: $DMG_PATH"
