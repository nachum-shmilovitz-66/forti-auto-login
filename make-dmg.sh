#!/bin/bash
# Builds dist/FortiAutoLogin.dmg for colleagues: the self-contained app plus an
# "Applications" shortcut. Signs the DMG with the same identity as the app.
#
#   ./make-dmg.sh              build app + DMG
#   ./make-dmg.sh --notarize   also notarize + staple (one-time setup below)
#
# Notarization removes the "Apple could not verify..." warning on other Macs.
# One-time setup, with an app-specific password from appleid.apple.com:
#   xcrun notarytool store-credentials FortiAutoLogin --apple-id <your apple id> --team-id 96Y4LX7FVB
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/FortiAutoLogin.app"
DIST="$DIR/dist"
DMG="$DIST/FortiAutoLogin.dmg"
STAGE="$DIST/stage"

"$DIR/make-app.sh"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$DIR/README.md" "$STAGE/README.md"
hdiutil create -volname "FortiAutoLogin" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

SIGN_ID="$(codesign -dvv "$APP" 2>&1 | grep -o 'Authority=Developer ID Application[^)]*)' | head -1 | sed 's/Authority=//')"
if [[ -n "$SIGN_ID" ]]; then
    codesign --force --sign "$SIGN_ID" --timestamp=none "$DMG" >/dev/null
    echo "DMG signed as: $SIGN_ID"
fi

if [[ "${1:-}" == "--notarize" ]]; then
    echo "notarizing (needs keychain profile 'FortiAutoLogin')…"
    xcrun notarytool submit "$DMG" --keychain-profile FortiAutoLogin --wait
    xcrun stapler staple "$DMG"
fi
echo "built $DMG"
du -h "$DMG"
