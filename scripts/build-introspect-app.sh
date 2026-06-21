#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$REPO/.build/Introspect.app"
EXEC="$REPO/.build/release/Introspect"
SIGN_IDENTITY="${INTROSPECT_CODE_SIGN_IDENTITY:-}"

if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application: Companion, Inc./ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Apple Development:/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi
CODESIGN_FLAGS=(--force --deep --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
  CODESIGN_FLAGS=(--force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
BUNDLE_SHORT_VERSION="${INTROSPECT_BUNDLE_SHORT_VERSION:-0.1.1}"
BUNDLE_VERSION="${INTROSPECT_BUNDLE_VERSION:-$(git rev-list --count HEAD 2>/dev/null || date +%s)}"

cd "$REPO"
swift build -c release

ICON="$REPO/assets/AppIcon.icns"
echo "Rendering app icon..."
ICON_TMP="$(mktemp -d)"
swiftc -O -o "$ICON_TMP/render-icon" "$REPO/scripts/render-app-icon.swift"
"$ICON_TMP/render-icon" "$ICON_TMP/AppIcon-1024.png"
mkdir -p "$ICON_TMP/AppIcon.iconset"
cp "$ICON_TMP/AppIcon-1024.png" "$ICON_TMP/AppIcon.iconset/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON_TMP/AppIcon-1024.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$ICON_TMP/AppIcon-1024.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p "$REPO/assets"
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$ICON"
rm -rf "$ICON_TMP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXEC" "$APP/Contents/MacOS/Introspect"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

for resource in README.md hooks scripts skills models templates; do
  if [ -e "$REPO/$resource" ]; then
    rm -rf "$APP/Contents/Resources/$resource"
    ditto "$REPO/$resource" "$APP/Contents/Resources/$resource"
  fi
done

find "$APP/Contents/Resources" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$APP/Contents/Resources" -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '.DS_Store' \) -delete

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Introspect</string>
  <key>CFBundleIdentifier</key>
  <string>ai.companion.introspect</string>
  <key>CFBundleName</key>
  <string>Introspect</string>
  <key>CFBundleDisplayName</key>
  <string>Introspect</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_SHORT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
codesign "${CODESIGN_FLAGS[@]}" "$APP"

notarize_app() {
  local app="$1"
  local archive="$2"
  local key_path="${APPLE_API_KEY_PATH:-}"
  local key_id="${APPLE_API_KEY_ID:-}"
  local issuer_id="${APPLE_API_ISSUER_ID:-}"

  if [ -z "$key_path" ] || [ -z "$key_id" ] || [ -z "$issuer_id" ]; then
    echo "notarization requested but APPLE_API_KEY_PATH, APPLE_API_KEY_ID, or APPLE_API_ISSUER_ID is missing" >&2
    return 2
  fi
  if [ ! -f "$key_path" ]; then
    echo "notarization key not found: $key_path" >&2
    return 2
  fi

  rm -f "$archive"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
  xcrun notarytool submit "$archive" \
    --key "$key_path" \
    --key-id "$key_id" \
    --issuer "$issuer_id" \
    --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
}

if [ "${INTROSPECT_NOTARIZE:-0}" = "1" ]; then
  notarize_app "$APP" "$REPO/.build/Introspect-notary.zip"
fi

echo "$APP"
