# FortiClient auto-login (macOS)

Fills the FortiClient "Token Code" dialog with the code from the `AuthCode: NNNNNN`
mail in Gmail, clicks OK, and closes the FortiClient window once the VPN is up.
Connect from the menu bar app (its menu lists FortiClient's connections) and the
token dialog is kept off-screen while it is filled in; connecting from FortiClient
itself works as before, with the dialog visible. A password that FortiClient does
not save is still typed by you.

## Demo

![Forti Auto Login demo](docs/demo.gif)

The token dialog appears, fills itself, and the FortiClient window closes once the
VPN is up. Full-quality recording:
[demo.mov](https://github.com/nachum-shmilovitz-66/forti-auto-login/releases/download/v1.0.0/demo.mov)

## How it works

0. Connect from the menu bar app (optional): the menu lists the connections in
   FortiClient's `/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist`
   and shows the state of FortiClient's VPN service (`scutil --nc list`).
   FortiClient has no command line for SSL VPN, so Connect and Disconnect click
   the same items in FortiClient's own menu bar menu (`lib/fortitray.applescript`),
   which opens for a moment. The app then watches FortiClient's windows every
   0.1 s and moves the token dialog to a display corner as it appears (macOS keeps
   about a pixel of it on screen). If the watcher cannot fill it in (no mail, code
   rejected, watcher stopped, 150 s), the dialog is put back for you to type the code.
1. `lib/token-dialog.applescript` polls System Events for a window of any `Forti*`
   process that contains the text "Token Code" and a text field.
2. `lib/gmail-code.applescript` walks every Gmail tab in every Chrome window (each
   Chrome profile has its own cookies) and, from inside the tab, fetches Gmail's
   unread-inbox Atom feed for account indexes `/u/0` to `/u/5`. It keeps the feed whose
   title says `Inbox for <GMAIL_ACCOUNT>`, so extra Google logins, profiles, and
   tabs do not matter. Tabs whose page title names that account are tried first, so it normally
   takes a few seconds regardless of window order or whether the tab shows Chat. Discarded (Memory Saver) tabs are reloaded once. If no tab is signed
   in as that account, `lib/open-gmail.sh` opens Gmail in the Chrome profile whose
   sign-in matches `GMAIL_ACCOUNT` (found in Chrome's `Local State`) and the scan
   runs again. No window needs
   focus. It returns the newest `AuthCode` mail issued after the dialog appeared.
3. The code is typed into the dialog and OK is clicked; the app you were working in
   gets the focus back.
4. `forti-auto-login.sh` waits until a new `utun` address shows up that was not there
   when the dialog appeared (any FortiClient connection, not only PreProd), then
   `lib/close-main-window.applescript` closes the FortiClient window. The app keeps
   running in the menu bar. Set `VPN_IP_PREFIX` (e.g. `10.0.`) to require a specific
   subnet instead.

Nothing leaves the machine; no Google API keys, no stored passwords. The only
request out is the menu bar app's update check, which asks GitHub for the latest
release and sends no data about you (it can be turned off in Settings).

## Setup

One setting is required: the email address that receives the AuthCode mail. Enter
it in the menu bar app under Settings… (opens automatically on first run), or for
the plain script edit the CONFIG block at the top of `forti-auto-login.sh`:

```bash
GMAIL_ACCOUNT=""            # e.g. first.last@example.com
VPN_IP_PREFIX=""            # leave empty; any FortiClient connection
```

Chrome must be signed in to that Google account in some profile. A wrong or
misspelled address fails every dialog with `ERR:no login for ...`. A Gmail tab is
opened at most once per dialog, and never when a signed-in tab exists.

## Usage

```bash
./forti-auto-login.sh --watch     # keep running, handles every token dialog
./forti-auto-login.sh             # one shot: handle the next dialog, then exit
./forti-auto-login.sh --test-gmail   # prints newest AuthCode from the last 24h
./forti-auto-login.sh --dump      # prints FortiClient's accessibility tree (debug)
./forti-auto-login.sh --report    # problem report zip for support (see below)
```

Log: `~/Library/Logs/forti-auto-login.log`. `FC_DEBUG=1 ./forti-auto-login.sh --test-gmail`
traces every Chrome tab tried. Timing tunables via env:
`MAIL_TIMEOUT` (120 s), `CONNECT_TIMEOUT` (90 s), `CLOSE_DELAY` (3 s), `DIALOG_POLL` (1.5 s).

## First run (permissions)

Run `./forti-auto-login.sh --test-gmail` once from Terminal. macOS will ask:

- Terminal -> control "System Events" (Automation) — Allow
- Terminal -> control "Google Chrome" (Automation) — Allow
- Terminal in System Settings > Privacy & Security > Accessibility — must be on

Chrome must have View > Developer > "Allow JavaScript from Apple Events" enabled in
the profile signed in as `GMAIL_ACCOUNT`. Tabs of other
profiles where it is off are skipped, and minimized windows are fine. No Gmail tab needs to be open; the script opens one in
the right profile if needed.

## Menu bar app (optional)

```bash
./make-app.sh
```

Compiles `app/FortiAutoLogin.swift` (needs Xcode command line tools) into
`~/Applications/Forti Auto Login.app`: a shield icon in the menu bar that runs the
watcher as a child process. The script and `lib/` are copied inside the bundle, so
the app is self-contained; rerun `make-app.sh` after editing the scripts. Filled shield = handling a dialog right now. Its menu
shows a short status (hover it for the last log line), FortiClient's connections
(`Connect to <name>` for each, or `Disconnect <name>` while connected), an
**Auto-Reconnect** switch, and offers Open Log, Restart Watcher, Settings…, Report a
Problem…, Check for Updates…, About (version and GitHub link), Quit.

Auto-Reconnect (off by default, saved as `AUTO_RECONNECT="1"` in the config file)
connects the last connection again when it drops, including after the Mac slept,
through the same hidden-dialog flow. It does not reconnect after a disconnect from
this menu or from FortiClient (FortiClient logs "VPN stopped by user" in
`~/Library/Application Support/Fortinet/FortiClient/Logs/fortitray.log`), and only
runs while the user is logged in with the screen unlocked and the network is up;
a drop while locked is reconnected after unlocking. Connections whose password
FortiClient does not save are skipped. It waits 10 s, then tries up to 3 times (30 s
and 2 min apart) and then gives up with a notification. Its log lines start with
`auto-reconnect:`.

Updates: once a day (first a minute after launch) the app asks GitHub for the
latest release of this repository. When it is newer, a notification appears once
and the menu item turns into **Install Update X.Y.Z…**, which shows the release
notes with Install, Later and Skip This Version. Install downloads the release's
.pkg, checks it against GitHub's SHA-256 and that it is signed by a Developer ID
Installer certificate of the same team as the running app, and opens it in
Installer; the package quits the app and starts the new version. A copy that is not
Developer ID signed opens the releases page instead. Turn the daily check off in
Settings; Check for Updates… still works. Log lines start with `update:`. To try it
without installing: `defaults write com.nshmilovitz.fortiautologin FALUpdateTestAs 1.0.0`
makes the app act as 1.0.0 and stop before opening Installer (`defaults delete` the
key afterwards).

Settings… is a small window for the email address (validated), VPN prefix and the
daily update check; it writes `~/.forti-auto-login.conf`, which the script sources
after its CONFIG block, and restarts the watcher. Non-technical colleagues never touch the script. The Finder
icon is FortiClient's own. Grant the same permissions on first launch, then add the
app to System Settings > General > Login Items. Start by hand:

```bash
open -a "Forti Auto Login"
```

Quit from the menu bar icon; that also stops the watcher. Do not run the Terminal
watcher at the same time.

## Reporting a problem

When a login is not filled in, the user picks **Report a Problem…** in the menu bar
icon, optionally types what happened, and clicks Create Report. After up to a minute
the zip (`forti-auto-login-report-<date>-<time>.zip`) is in the **Downloads** folder,
ready to attach to a mail or chat. macOS asks once to let the app use Downloads; if
that is refused, the zip goes to `~/Library/Logs/Forti Auto Login Reports/` instead
and the app says so. Start with `summary.txt` in it: the key facts and a **Likely causes** list
(missing permissions, no email set, Chrome profile or JavaScript switch, Gmail
errors, extra app copies, the outcome of the last attempt).

It runs `lib/collect-report.sh` as a child of the app, so the permission checks see
the app's own grants. When the app itself does not start, run it from Terminal
(the checks then use Terminal's permissions):

```bash
"/Applications/Forti Auto Login.app/Contents/Resources/forti-auto-login.sh" --report
```

No codes, passwords, cookies or mail content are collected; email addresses are
masked to first and last letter plus the domain. The file layout and summary keys
are in [docs/problem-reports.md](docs/problem-reports.md), which a Windows port must
follow.

## Installer for colleagues

```bash
./make-pkg.sh              # dist/Forti Auto Login <version>.pkg (version from VERSION)
./make-pkg.sh --notarize   # also notarize + staple (see script header for setup)
```

Colleagues get that one .pkg file; there is no DMG. Double-clicking it opens the
standard macOS setup wizard (Introduction, Read Me, Install, Summary; pages and
scripts in `installer/macos/`). It quits a running copy, installs
the app into /Applications and starts it for the logged-in user, so the Settings
window and the permission prompts appear right away. Colleagues then enter their
email, grant Accessibility plus the two Automation prompts, enable Chrome's "Allow
JavaScript from Apple Events" in their Gmail profile, and add the app to Login
Items. The installer is signed with the Developer ID Installer certificate and the
app with Developer ID Application, so permission grants survive updates. It runs on
Apple Silicon only, because the app is built for arm64. Without notarization macOS
blocks the installer on first open; they get past it via System Settings > Privacy
& Security > Open Anyway.

## Releases

Download the latest installer (.pkg) from
https://github.com/nachum-shmilovitz-66/forti-auto-login/releases.

| Version | Date       | Notes |
|---------|------------|-------|
| 1.0.0   | 2026-09-03 | First release: menu bar app, Settings window with validated email, token dialog auto-fill from Gmail, window auto-close, styled DMG. |
| 1.0.1   | 2026-09-27 | Setup wizard installer that starts the app when done; Report a Problem (diagnostics zip with likely causes); shorter menu (short status, About, Quit, © in About); clearer watcher log on failures. |
| 1.0.2   | 2026-09-27 | Fix: a Gmail tab that does not answer no longer blocks reading the code (10 s limit per tab, so the dialog is filled before it closes); problem reports saved to Downloads; no false "extra app copy" in reports. Installer (.pkg) instead of a DMG. |
| 1.0.3   | 2026-09-28 | Connect FortiClient's connections from the menu, with the token dialog kept off-screen while it is filled in (FortiClient's own menu works as before); Auto-Reconnect switch (not after a disconnect by the user, only while logged in with the screen unlocked); Check for Updates, also daily, verifies the download's SHA-256 and Developer ID signature before opening Installer; the app you were in gets the focus back after the fill; fix: token dialogs with an unreadable element were missed; problem reports add the VPN connections and state, FortiClient's log, a stuck-session finding and the update status. |

To cut a new release: bump the patch number in `VERSION`, then

```bash
./make-pkg.sh && gh release create v$(cat VERSION) "dist/Forti Auto Login $(cat VERSION).pkg" --title "Forti Auto Login $(cat VERSION)" --notes "..."
```

Add a row to the table above. The app's update check relies on this: the tag is
`vX.Y.Z`, the release is not a draft or pre-release, and it has exactly one `.pkg`
asset signed with the same Developer ID team as the app.

## Status / caveats

- The dialog detection and the fill/OK step were verified against a mock secure-text
  dialog with the same wording. The real FortiClient dialog has not been exercised
  from this repo yet; if it is not picked up, run `--dump` while the dialog is open
  and compare the tree with the finder in `lib/token-dialog.applescript`.
- Gmail's Trusted Types policy blocks `DOMParser` inside the page, so the feed is
  parsed with regex (`lib/gmail-parse.js`).
- `--test-gmail` prints `none` when no **unread** AuthCode mail exists in the last 24 h;
  it prints `ERR:no login for ...` if no Chrome profile is signed in to that mailbox.
- Any FortiClient connection works as long as its mail subject is `AuthCode: NNNNNN`
  (sender is not checked). A different subject format needs the regex in
  `lib/gmail-parse.js` adjusted.
- A code is used once: the issued time of the last used mail is kept in
  `~/.forti-auto-login.last`, so a second dialog never gets the previous code.
- The Gmail feed only lists **unread** inbox mail. Do not open the AuthCode mails
  before the script reads them (you no longer need to).
- If FortiClient refuses every connect with "Previous VPN session is not ended"
  (seen after the Mac locked while a token dialog was open), restart its menu bar
  icon: `launchctl kickstart -k gui/$(id -u)/com.fortinet.forticlient.fortitray`.
  The problem report flags this.
## Security notes

- This makes the email second factor as strong as the unlocked Mac plus its
  signed-in Chrome session. Anyone at the unlocked machine could connect the VPN.
- Chrome's "Allow JavaScript from Apple Events" lets every app the user has approved
  for Chrome automation run JavaScript in Chrome pages. Enable it only in the Gmail
  profile.
- Nothing leaves the machine except the update check (an anonymous request for this
  repository's latest release). No passwords are stored. The config file holds only
  the email address, VPN prefix and two switches and is parsed, never executed; log,
  state, and config files are created mode 600, and one-time codes are masked in the log.
- An update is opened only after its SHA-256 matches GitHub's and its signature is a
  Developer ID Installer certificate of the running app's own team, so a changed or
  foreign package is refused. Installer still asks for an admin password if needed.
- Any unread inbox mail whose subject is `AuthCode: nnnnnn` is accepted, sender not
  checked; a spoofed mail can make a login fail, not succeed.
- Prefer a notarized installer (`./make-pkg.sh --notarize`) so users are not trained to
  click "Open Anyway".
