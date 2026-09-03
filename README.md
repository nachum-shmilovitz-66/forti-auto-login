# FortiClient auto-login (macOS)

Fills the FortiClient "Token Code" dialog with the code from the `AuthCode: NNNNNN`
mail in Gmail, clicks OK, and closes the FortiClient window once the VPN is up.
You still click Connect and enter the password yourself; only the token step and
the window cleanup are automated.

## How it works

1. `lib/token-dialog.applescript` polls System Events for a window of any `Forti*`
   process that contains the text "Token Code" and a text field.
2. `lib/gmail-code.applescript` walks every Gmail tab in every Chrome window (each
   Chrome profile has its own cookies) and, from inside the tab, fetches Gmail's
   unread-inbox Atom feed for account indexes `/u/0` to `/u/5`. It keeps the feed whose
   title says `Inbox for <GMAIL_ACCOUNT>` (or any `@GMAIL_DOMAIN` mailbox when
   `GMAIL_ACCOUNT` is empty), so extra Google logins, profiles, and tabs do not
   matter. Tabs whose page title names that account are tried first, so it normally
   takes a few seconds regardless of window order or whether the tab shows Chat. Discarded (Memory Saver) tabs are reloaded once. If no tab is signed
   in as that account, `lib/open-gmail.sh` opens Gmail in the Chrome profile whose
   sign-in matches `GMAIL_ACCOUNT` or `GMAIL_DOMAIN` (found in Chrome's `Local State`)
   and the scan runs again. No window needs
   focus. It returns the newest `AuthCode` mail issued after the dialog appeared.
3. The code is typed into the dialog and OK is clicked.
4. `forti-auto-login.sh` waits until a new `utun` address shows up that was not there
   when the dialog appeared (any FortiClient connection, not only PreProd), then
   `lib/close-main-window.applescript` closes the FortiClient window. The app keeps
   running in the menu bar. Set `VPN_IP_PREFIX=10.212.` to require a specific subnet
   instead.

Nothing leaves the machine; no Google API keys, no stored passwords.

## Setup for a new person

Edit the CONFIG block at the top of `forti-auto-login.sh`:

```bash
GMAIL_ACCOUNT=""            # your work mailbox, or leave empty to auto-pick
GMAIL_DOMAIN="em.aus.com"   # any Google login on this domain is used when empty
VPN_IP_PREFIX=""            # leave empty; any FortiClient connection
```

With `GMAIL_ACCOUNT` empty the script uses whichever `@em.aus.com` account Chrome is
signed in to, so the same copy works for colleagues without edits. Set the email
only if Chrome has several accounts on that domain, and only to an address Chrome is
actually signed in with; otherwise every dialog fails with `ERR:no login for ...`.
A Gmail tab is opened at most once per dialog, and never when a signed-in tab exists.

## Usage

```bash
./forti-auto-login.sh --watch     # keep running, handles every token dialog
./forti-auto-login.sh             # one shot: handle the next dialog, then exit
./forti-auto-login.sh --test-gmail   # prints newest AuthCode from the last 24h
./forti-auto-login.sh --dump      # prints FortiClient's accessibility tree (debug)
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
the profile signed in as `GMAIL_ACCOUNT` (it already is for Profile 32). Tabs of other
profiles where it is off are skipped, and minimized windows are fine. No Gmail tab needs to be open; the script opens one in
the right profile if needed.

## Menu bar app (optional)

```bash
./make-app.sh
```

Compiles `app/FortiAutoLogin.swift` (needs Xcode command line tools) into
`~/Applications/FortiAutoLogin.app`: a shield icon in the menu bar that runs the
watcher as a child process. The script and `lib/` are copied inside the bundle, so
the app is self-contained; rerun `make-app.sh` after editing the scripts. Filled shield = handling a dialog right now. Its menu
shows the last log line and offers Open Log, Restart Watcher, Settings…, Quit.
Settings… is a small window for the email address, mail domain, and VPN prefix; it
writes `~/.forti-auto-login.conf`, which the script sources after its CONFIG block,
and restarts the watcher. Non-technical colleagues never touch the script. The Finder
icon is FortiClient's own. Grant the same permissions on first launch, then add the
app to System Settings > General > Login Items. Start by hand:

```bash
open -a FortiAutoLogin
```

Quit from the menu bar icon; that also stops the watcher. Do not run the Terminal
watcher at the same time.

## DMG for colleagues

```bash
./make-dmg.sh              # dist/FortiAutoLogin.dmg
./make-dmg.sh --notarize   # also notarize + staple (see script header for setup)
```

The DMG holds the self-contained app, an Applications shortcut, and this README.
Colleagues drag the app to Applications, open it, grant Accessibility plus the two
Automation prompts, enable Chrome's "Allow JavaScript from Apple Events" in their
work profile, and add the app to Login Items. Without notarization macOS shows
"Apple could not verify..." on first open; they get past it via System Settings >
Privacy & Security > Open Anyway. The app is signed with a Developer ID
certificate, so permission grants survive updates.

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
- Security: this makes the second factor as strong as the logged-in Chrome session
  on this Mac. Anyone with the unlocked machine could connect the VPN.
