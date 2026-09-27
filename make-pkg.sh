#!/bin/bash
# Builds the installer "dist/Forti Auto Login <version>.pkg": the standard macOS
# setup wizard (Introduction > Read Me > Install > Summary) that quits a running
# copy, puts the app in /Applications and starts it when it finishes. Pages and
# install scripts live in installer/macos/. Signed with the keychain's
# "Developer ID Installer" identity when there is one. This .pkg is the file
# colleagues get (release asset); there is no DMG.
#
#   ./make-pkg.sh              build app + installer
#   ./make-pkg.sh --notarize   also notarize + staple (one-time setup below)
#
# Notarization removes the "cannot be opened / could not be verified" block on
# other Macs. One-time setup, with an app-specific password from appleid.apple.com:
#   xcrun notarytool store-credentials FortiAutoLogin --apple-id <your apple id> --team-id <your team id>
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="Forti Auto Login"
ID="com.nshmilovitz.fortiautologin"
VERSION="$(cat "$DIR/VERSION")"
APP="$HOME/Applications/$NAME.app"
SRC="$DIR/installer/macos"
WORK="$DIR/app/build/pkg"
OUT="$DIR/dist/$NAME $VERSION.pkg"

"$DIR/make-app.sh"

rm -rf "$WORK"
mkdir -p "$WORK/root" "$WORK/scripts" "$WORK/resources" "$(dirname "$OUT")"
ditto "$APP" "$WORK/root/$NAME.app"
# Not relocatable: Installer would otherwise "upgrade" whichever copy with the
# same bundle id it finds (e.g. ~/Applications) instead of installing into /Applications.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
cp "$SRC/preinstall" "$SRC/postinstall" "$WORK/scripts/"
chmod +x "$WORK/scripts/"*
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts "$WORK/scripts" \
    --identifier "$ID" --version "$VERSION" --install-location /Applications "$WORK/app.pkg" >/dev/null

for page in welcome readme conclusion; do
    sed "s/@VERSION@/$VERSION/g" "$SRC/$page.html" > "$WORK/resources/$page.html"
done
ARCH="$(lipo -archs "$APP/Contents/MacOS/FortiAutoLogin" | tr ' ' ',')"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@ID@/$ID/g" -e "s/@ARCH@/$ARCH/g" \
    "$SRC/distribution.xml" > "$WORK/distribution.xml"

SIGN_ID="$(security find-identity -v 2>/dev/null | grep -o '"Developer ID Installer: [^"]*"' | head -1 | tr -d '"')"
rm -f "$OUT"
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" \
    --package-path "$WORK" ${SIGN_ID:+--sign "$SIGN_ID"} "$OUT" >/dev/null
# the staged app would otherwise show up in Spotlight (and in problem reports)
# as one more copy of the app
rm -rf "$WORK/root"
echo "installer signed as: ${SIGN_ID:-unsigned} (runs on: $ARCH)"
if [[ "${1:-}" == "--notarize" ]]; then
    echo "notarizing (needs keychain profile 'FortiAutoLogin')…"
    xcrun notarytool submit "$OUT" --keychain-profile FortiAutoLogin --wait
    xcrun stapler staple "$OUT"
fi
echo "built $OUT"
du -h "$OUT"
