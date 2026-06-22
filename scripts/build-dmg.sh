#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="${INTROSPECT_APP_PATH:-$REPO/.build/Introspect.app}"
DMG="${INTROSPECT_DMG_PATH:-$REPO/.build/Introspect.dmg}"
VOLUME_NAME="${INTROSPECT_DMG_VOLUME_NAME:-Introspect}"
SIGN_IDENTITY="${INTROSPECT_CODE_SIGN_IDENTITY:-}"

if [ ! -d "$APP" ]; then
  echo "build-dmg: app bundle missing: $APP" >&2
  echo "build-dmg: run ./scripts/build-introspect-app.sh first" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

ditto "$APP" "$STAGE/Introspect.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"
hdiutil verify "$DMG"

if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application: Companion, Inc./ { print $2; exit }')"
fi
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [ "${INTROSPECT_NOTARIZE_DMG:-${INTROSPECT_NOTARIZE:-0}}" = "1" ]; then
  key_path="${APPLE_API_KEY_PATH:-}"
  key_id="${APPLE_API_KEY_ID:-}"
  issuer_id="${APPLE_API_ISSUER_ID:-}"
  if [ -z "$key_path" ] || [ -z "$key_id" ] || [ -z "$issuer_id" ]; then
    echo "build-dmg: notarization requested but APPLE_API_KEY_PATH, APPLE_API_KEY_ID, or APPLE_API_ISSUER_ID is missing" >&2
    exit 2
  fi
  xcrun notarytool submit "$DMG" \
    --key "$key_path" \
    --key-id "$key_id" \
    --issuer "$issuer_id" \
    --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

echo "$DMG"
