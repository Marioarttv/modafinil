#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Modafinil"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg-staging"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Packaging/Info.plist")"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
RW_DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-rw.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: HAMZA QAYYUM (3LF26Z4G2R)}"
export SIGN_IDENTITY
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-profile}"
MOUNT_DIR=""

cleanup() {
  if [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
    rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

cd "$ROOT_DIR"

if ! security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" >/dev/null; then
  echo "Missing signing identity: $SIGN_IDENTITY" >&2
  echo "Install the Developer ID Application certificate." >&2
  exit 1
fi

"$ROOT_DIR/build/build.sh"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -rf "$STAGING_DIR" "$DMG_PATH" "$RW_DMG_PATH"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"

MOUNT_DIR="$(mktemp -d /tmp/modafinil-dmg.XXXXXX)"
hdiutil attach "$RW_DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

osascript <<APPLESCRIPT
tell application "Finder"
  tell folder (POSIX file "$MOUNT_DIR" as alias)
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {180, 100, 1060, 650}
    set arrangement of icon view options of container window to not arranged
    set icon size of icon view options of container window to 144
    set position of item "$APP_NAME.app" to {305, 270}
    set position of item "Applications" to {575, 270}
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet
rmdir "$MOUNT_DIR"
MOUNT_DIR=""

hdiutil convert "$RW_DMG_PATH" -format UDZO -o "$DMG_PATH" -ov >/dev/null
rm -f "$RW_DMG_PATH"

codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH" >/dev/null
codesign --verify --verbose=2 "$DMG_PATH"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Missing or invalid notarytool profile: $NOTARY_PROFILE" >&2
  exit 1
fi

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

echo "Release DMG: $DMG_PATH"
