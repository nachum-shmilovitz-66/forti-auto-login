#!/bin/bash
# Builds "dist/Forti Auto Login <version>.dmg" for colleagues: the installer
# "Install Forti Auto Login.pkg" (setup wizard from make-pkg.sh, which installs
# the app into /Applications and starts it) and a READ ME FIRST.txt, laid out in a
# fixed Finder window (Finder is scripted to set icon size and positions). Signs
# the DMG with the same identity as the app.
#
#   ./make-dmg.sh              build app + installer + DMG
#   ./make-dmg.sh --notarize   also notarize + staple (one-time setup below)
#
# Notarization removes the "Apple could not verify..." warning on other Macs.
# One-time setup, with an app-specific password from appleid.apple.com:
#   xcrun notarytool store-credentials FortiAutoLogin --apple-id <your apple id> --team-id <your team id>
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="Forti Auto Login"
VERSION="$(cat "$DIR/VERSION")"
APP="$HOME/Applications/$NAME.app"
PKG="Install $NAME.pkg"
DIST="$DIR/dist"
VOL="$NAME $VERSION"
DMG="$DIST/$NAME $VERSION.dmg"
RW="$DIST/rw.dmg"
STAGE="$DIST/stage"

rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE"
"$DIR/make-pkg.sh" "$STAGE/$PKG"     # also builds and signs the app
cat > "$STAGE/READ ME FIRST.txt" <<TXT
$NAME $VERSION - installing on a Mac

1. Double-click "$PKG" and click Continue through the installer. It
   asks for your Mac password, puts the app in Applications and starts it:
   a shield icon appears in the menu bar (top right).
2. Enter the email address that receives the FortiClient AuthCode mail in the
   Settings window that opens, then Save & Restart.
3. Allow the permissions macOS asks for: Accessibility, System Events, and
   Google Chrome. Chrome must be signed in to that Google account.
4. In Chrome, enable View > Developer > "Allow JavaScript from Apple Events".
5. Optional: System Settings > General > Login Items > add "$NAME".

Then connect in FortiClient as usual; the token is filled in by itself and the
FortiClient window closes once the VPN is up.

If macOS says the installer "could not be verified" or "cannot be opened":
System Settings > Privacy & Security > scroll down > Open Anyway, then
double-click it again.

If a login is not filled in later: shield icon > Report a Problem..., and
send the zip file it creates.
TXT

# A volume with the same name must not be mounted (e.g. a previous DMG opened
# for review): Finder would apply the layout to that one instead of ours.
while [[ -d "/Volumes/$VOL" ]]; do
    echo "ejecting already-mounted volume '$VOL'"
    hdiutil detach "/Volumes/$VOL" -force -quiet || { echo "cannot eject /Volumes/$VOL"; exit 1; }
    sleep 1
done

# read-write image first, so Finder can store the window layout in it
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -quiet "$RW"
rm -rf "$STAGE"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
sleep 1
osascript - "$VOL" "$PKG" <<'APPLESCRIPT'
on run argv
	set vol to item 1 of argv
	set pkgName to item 2 of argv
	tell application "Finder"
		tell disk vol
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			try
				set pathbar visible of container window to false
			end try
			set sidebar width of container window to 0
			set the bounds of container window to {200, 120, 860, 460}
			set opts to the icon view options of container window
			set arrangement of opts to not arranged
			set icon size of opts to 128
			set text size of opts to 14
			set position of item pkgName of container window to {165, 150}
			set position of item "READ ME FIRST.txt" of container window to {495, 150}
			close
			open
			update without registering applications
			delay 2
			-- read back and verify; a wrong value here means the layout did not stick
			set sz to icon size of the icon view options of container window
			set posApp to position of item pkgName of container window
			close
			if sz is not 128 then error "icon size is " & sz & ", expected 128"
			if item 1 of posApp is not 165 then error "installer icon position is " & (item 1 of posApp) & ", expected 165"
		end tell
	end tell
	return "layout verified: icon size " & sz & ", installer at " & (item 1 of posApp) & "," & (item 2 of posApp)
end run
APPLESCRIPT
sync
[[ -f "/Volumes/$VOL/.DS_Store" ]] || { echo "no .DS_Store written, layout lost"; hdiutil detach "$DEV" -quiet; exit 1; }
hdiutil detach "$DEV" -quiet
hdiutil convert "$RW" -format UDZO -o "$DMG" -quiet
rm -f "$RW"

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
