#!/bin/bash
# Builds "~/Applications/Forti Auto Login.app": a menu bar app (shield icon) that runs
# the bundled forti-auto-login.sh --watch as a child process. Self-contained:
# the script and lib/ are copied into Contents/Resources, so the app can be
# moved or shipped in a DMG (see make-dmg.sh). Menu: status, Open Log,
# Restart Watcher, Quit. macOS asks for Accessibility / Automation permissions
# once, under the name "Forti Auto Login". Add the app to Login Items to autostart.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/Forti Auto Login.app"
VERSION="$(cat "$DIR/VERSION")"
BUILD="$DIR/app/build"
ID="com.nshmilovitz.fortiautologin"

mkdir -p "$BUILD" "$HOME/Applications"
echo "compiling…"
swiftc -O -swift-version 5 -framework AppKit -o "$BUILD/FortiAutoLogin" "$DIR/app/FortiAutoLogin.swift"

# stop a running copy (and its watcher) before replacing the bundle
pkill -f "Forti Auto Login.app/Contents/MacOS/FortiAutoLogin" 2>/dev/null || true
pkill -f "^/bin/bash .*forti-auto-login\.sh --watch$" 2>/dev/null || true
sleep 1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/FortiAutoLogin" "$APP/Contents/MacOS/FortiAutoLogin"
# self-contained: the watcher script and its helpers travel inside the bundle
cp "$DIR/forti-auto-login.sh" "$APP/Contents/Resources/"
cp -R "$DIR/lib" "$APP/Contents/Resources/lib"
chmod +x "$APP/Contents/Resources/forti-auto-login.sh" "$APP/Contents/Resources/lib/"*.sh
# Finder icon: reuse FortiClient's own icon when present
ICON_KEY=""
FC_ICON="/Applications/FortiClient.app/Contents/Resources/electron.icns"
if [[ -f "$FC_ICON" ]]; then
    cp "$FC_ICON" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Forti Auto Login</string>
  <key>CFBundleDisplayName</key><string>Forti Auto Login</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>FortiAutoLogin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Nachum Shmilovitz</string>
  $ICON_KEY
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Sign with a real identity when one exists: macOS ties Accessibility/Automation
# grants to the code signature, and an ad-hoc signature changes on every build,
# which silently invalidates the grants. Falls back to ad-hoc.
IDS="$(security find-identity -v -p codesigning 2>/dev/null)"
SIGN_ID="$(printf '%s' "$IDS" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[[ -z "$SIGN_ID" ]] && SIGN_ID="$(printf '%s' "$IDS" | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
codesign --force --sign "${SIGN_ID:--}" --identifier "$ID" --timestamp=none "$APP" >/dev/null
echo "signed as: ${SIGN_ID:-ad-hoc}"
echo "built $APP (scripts bundled inside)"
echo "start:  open -a \"Forti Auto Login\"      (quit from its menu bar icon)"
