#!/bin/bash
# Puts this Mac back to "never installed" for testing a fresh install:
#   - quits the app and its watcher
#   - removes ~/Applications/FortiAutoLogin.app
#   - removes the user config, last-code state, and log
#   - revokes the app's Accessibility and Automation (Apple Events) grants
# Not touched: the project folder, dist/FortiAutoLogin.dmg, Chrome's
# "Allow JavaScript from Apple Events", and a Login Items entry (remove that
# by hand in System Settings > General > Login Items).
set -u
ID="com.nshmilovitz.fortiautologin"
pkill -f "FortiAutoLogin.app/Contents/MacOS/FortiAutoLogin" 2>/dev/null && echo "quit app"
pkill -f "^/bin/bash .*forti-auto-login\.sh --watch$" 2>/dev/null && echo "stopped watcher"
sleep 1
for f in "$HOME/Applications/FortiAutoLogin.app" "/Applications/FortiAutoLogin.app" \
         "$HOME/.forti-auto-login.conf" "$HOME/.forti-auto-login.last" \
         "$HOME/Library/Logs/forti-auto-login.log"; do
    [[ -e "$f" ]] && rm -rf "$f" && echo "removed $f"
done
tccutil reset Accessibility "$ID" >/dev/null 2>&1 && echo "revoked Accessibility"
tccutil reset AppleEvents "$ID"   >/dev/null 2>&1 && echo "revoked Automation (System Events / Chrome)"
echo "done. Fresh-install test: open dist/FortiAutoLogin.dmg, drag to Applications, open the app."
