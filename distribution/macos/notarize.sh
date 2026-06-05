#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: distribution/macos/notarize.sh <vc-board.dmg>" >&2
  exit 1
fi

DMG_PATH="$1"
KEYS="${KEYS:-$HOME/.keys}"
NOTARY_ENV="${NOTARY_ENV:-$KEYS/.notary.env}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
else
  if [[ -f "$NOTARY_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$NOTARY_ENV"
  fi

  APPLE_ID="${APPLE_ID:-${NOTARY_APPLE_ID:-}}"
  APPLE_TEAM_ID="${APPLE_TEAM_ID:-${NOTARY_TEAM_ID:-}}"
  APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-${NOTARY_PASSWORD:-}}"

  : "${APPLE_ID:?Set NOTARY_PROFILE or APPLE_ID/NOTARY_APPLE_ID for notarytool authentication}"
  : "${APPLE_TEAM_ID:?Set NOTARY_PROFILE or APPLE_TEAM_ID/NOTARY_TEAM_ID for notarytool authentication}"
  : "${APPLE_APP_PASSWORD:?Set NOTARY_PROFILE or APPLE_APP_PASSWORD/NOTARY_PASSWORD for notarytool authentication}"

  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
fi

xcrun stapler staple "$DMG_PATH"
echo "Notarized and stapled: $DMG_PATH"
