#!/bin/bash
# Collects what is needed to find out why an auto-login failed into one zip:
# a summary with the likely causes, the log, the settings, permission probes,
# Chrome/Gmail state, the FortiClient windows and the VPN interfaces.
#
#   collect-report.sh [output-dir]     prints the path of the zip it wrote
#
# The zip goes to ~/Downloads (or output-dir). Downloads is privacy-protected,
# so macOS asks once; if that is refused, it goes to
# ~/Library/Logs/Forti Auto Login Reports instead.
#
# Run by the menu bar app's "Report a Problem…" item, so the probes run with the
# app's own permissions, or from Terminal via `forti-auto-login.sh --report`.
# Never collected: codes (masked), passwords, cookies, mail contents. Email
# addresses are masked to first and last letter plus the domain.
# The zip layout and the summary keys are a contract shared with the Windows
# port: see docs/problem-reports.md before renaming anything.
#
# Optional environment, set by the app:
#   FAL_APP_VERSION  FAL_APP_PATH  FAL_AX_TRUSTED (1/0)  FAL_WATCHER_RUNNING (1/0)
#   FAL_DESCRIPTION  what the user typed into the report dialog
set -u
umask 077

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${LOG:-$HOME/Library/Logs/forti-auto-login.log}"
CONF="$HOME/.forti-auto-login.conf"
STATE="$HOME/.forti-auto-login.last"
CHROME_DATA="$HOME/Library/Application Support/Google/Chrome"
OUT_DIR="${1:-$HOME/Downloads}"
FALLBACK_DIR="$HOME/Library/Logs/Forti Auto Login Reports"
NAME="forti-auto-login-report-$(date '+%Y%m%d-%H%M%S')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fal-report.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
R="$WORK/$NAME"
mkdir -p "$R" || exit 1
SUMMARY="$WORK/summary"; FINDINGS="$WORK/findings"
: > "$SUMMARY"; : > "$FINDINGS"

kv()      { printf '%s: %s\n' "$1" "$2" >> "$SUMMARY"; }
finding() { printf -- '- %s\n' "$1" >> "$FINDINGS"; }
section() { printf '\n==== %s ====\n' "$1"; }

# email local parts -> first+last letter, one-time codes -> ******
mask() {
    sed -E -e 's/([A-Za-z0-9])[A-Za-z0-9._%+-]*([A-Za-z0-9])@([A-Za-z0-9-]+\.[A-Za-z0-9.-]*[A-Za-z])/\1***\2@\3/g' \
           -e 's/(got code )[0-9*]+/\1******/g' \
           -e 's/([Aa][Uu][Tt][Hh][Cc][Oo][Dd][Ee]:? *)[0-9]{4,8}/\1******/g'
}

# run "$@", killed after $1 seconds (macOS has no timeout(1)); 124 = timed out
with_timeout() {
    local secs=$1 pid n=0; shift
    "$@" & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( n >= secs * 10 )); then
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            echo "[timed out after ${secs}s]"; return 124
        fi
        sleep 0.1; n=$((n + 1))
    done
    wait "$pid"
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
denied()      { [[ "$1" == *"assistive access"* || "$1" == *"not allowed"* || "$1" == *"(-1743)"* || "$1" == *"(-1719)"* ]]; }
utun_addrs()  { ifconfig | awk '/^[^ \t]/{i=($1 ~ /^utun/)?$1:""} /inet /{if(i!="")print i,$2}'; }

# ---------------------------------------------------------------- basics
APP="${FAL_APP_PATH:-}"
[[ -z "$APP" && "$LIB" == */Contents/Resources/lib ]] && APP="${LIB%/Contents/Resources/lib}"
VERSION="${FAL_APP_VERSION:-}"
[[ -z "$VERSION" && -n "$APP" ]] && VERSION="$(plist_value "$APP" CFBundleShortVersionString)"
kv report_format 1
kv created "$(date '+%Y-%m-%dT%H:%M:%S%z')"
kv platform macos
kv os_version "$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
kv arch "$(uname -m)"
kv app_version "${VERSION:-unknown}"
kv run_from "$([[ -n "${FAL_APP_PATH:-}" ]] && echo app || echo terminal)"
kv user "$USER"

{
    section "sw_vers";  sw_vers
    section "uname";    uname -a
    section "hardware"; sysctl -n hw.model machdep.cpu.brand_string 2>/dev/null
    section "uptime";   uptime
    section "time";     date; echo "TZ=$(readlink /etc/localtime 2>/dev/null | sed 's#.*zoneinfo/##')"
    section "locale";   defaults read -g AppleLocale 2>/dev/null; locale 2>/dev/null | head -3
} > "$R/system.txt" 2>&1

[[ -n "${FAL_DESCRIPTION:-}" ]] && printf '%s\n' "$FAL_DESCRIPTION" > "$R/description.txt"

# ---------------------------------------------------------------- app + watcher
# top-level watchers only: the script briefly forks copies of itself for $(...)
WATCHERS="$(ps -axo pid=,ppid=,command= | awk '$3 == "/bin/bash" && /forti-auto-login\.sh --watch$/ {parent[$1] = $2}
    END {for (p in parent) if (!(parent[p] in parent)) printf "%s ", p}')"
NWATCH="$(wc -w <<< "$WATCHERS" | tr -d ' ')"
kv watcher_processes "$NWATCH"
if [[ -n "${FAL_WATCHER_RUNNING:-}" ]]; then
    kv watcher_running "$([[ "$FAL_WATCHER_RUNNING" == 1 ]] && echo yes || echo no)"
    [[ "$FAL_WATCHER_RUNNING" == 1 ]] || finding "The app's watcher is not running (script crashed or failed to start). Use Restart Watcher; see log.txt for its last lines."
fi
(( NWATCH == 0 )) && finding "No watcher process is running, so no token dialog is handled. Start the app (or add it to Login Items so it starts after a reboot)."
(( NWATCH > 1 ))  && finding "$NWATCH watcher processes are running (app and Terminal, or two app copies). They fight over the same dialog: keep only one."

SIG="unknown"; COPIES=""
LOGIN_ITEMS="$(with_timeout 15 osascript -e 'tell application "System Events" to get the name of every login item' 2>&1)"
if [[ "$LOGIN_ITEMS" == *"Forti Auto Login"* ]]; then kv login_item yes
elif [[ "$LOGIN_ITEMS" == *"timed out"* ]] || denied "$LOGIN_ITEMS"; then kv login_item unknown
else
    kv login_item no
    finding "Forti Auto Login is not in Login Items, so after a restart nothing handles the dialog until the app is opened. System Settings > General > Login Items: add it."
fi
{
    section "app bundle"; echo "${APP:-not running from an app bundle}"
    if [[ -n "$APP" ]]; then
        echo "version: $(plist_value "$APP" CFBundleShortVersionString)  bundle id: $(plist_value "$APP" CFBundleIdentifier)"
        section "codesign"; codesign -dv --verbose=2 "$APP" 2>&1 | grep -vE '^(CDHash|Hash|Sealed|Internal|Page|Executable)'
        section "codesign --verify"; codesign --verify --deep --strict "$APP" 2>&1 && echo valid
        section "Gatekeeper"; spctl --assess -vv "$APP" 2>&1
        section "extended attributes"; xattr "$APP" 2>&1
    fi
    section "all copies of the app (Spotlight)"
    COPIES="$(mdfind 'kMDItemCFBundleIdentifier == "com.nshmilovitz.fortiautologin"' 2>/dev/null)"
    while IFS= read -r c; do
        [[ -n "$c" ]] && echo "$c  (version $(plist_value "$c" CFBundleShortVersionString))"
    done <<< "$COPIES"
    section "processes"
    ps -axo pid,ppid,etime,command | grep -E 'FortiAutoLogin|forti-auto-login\.sh' | grep -v grep
    section "login items"
    echo "$LOGIN_ITEMS"
    section "crash reports"
    ls -lt "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i 'FortiAutoLogin' | head -5
} > "$R/app.txt" 2>&1
if [[ -n "$APP" ]]; then
    AUTH="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    if [[ -n "$AUTH" ]]; then SIG="$AUTH"
    elif codesign -dv "$APP" 2>&1 | grep -q 'Signature=adhoc'; then SIG="ad-hoc"
    else SIG="unsigned"; fi
    [[ "$SIG" == ad-hoc || "$SIG" == unsigned ]] && \
        finding "The app is signed $SIG: macOS drops its Accessibility/Automation grants on every rebuild. Build it with a Developer ID identity."
    [[ "$APP" == */AppTranslocation/* ]] && \
        finding "The app runs from a translocated (quarantined) copy. Drag it into Applications and start it from there."
    xattr "$APP" 2>/dev/null | grep -q com.apple.quarantine && kv app_quarantined yes || kv app_quarantined no
fi
kv app_path "${APP:-none}"
kv app_signature "$SIG"
NCOPIES="$(grep -c . <<< "$COPIES")"
kv app_copies "$NCOPIES"
(( NCOPIES > 1 )) && finding "$NCOPIES copies of the app exist (see app.txt). Permissions granted to one copy do not apply to the other; delete the extra copies."
mkdir -p "$R/crashes"
ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i 'FortiAutoLogin' | head -3 | while IFS= read -r f; do
    mask < "$HOME/Library/Logs/DiagnosticReports/$f" > "$R/crashes/$f"
done
rmdir "$R/crashes" 2>/dev/null

# ---------------------------------------------------------------- settings
EMAIL=""; PREFIX=""
if [[ -f "$CONF" ]]; then
    while IFS='=' read -r k v; do      # same parsing as forti-auto-login.sh
        v="${v%\"}"; v="${v#\"}"
        case "$k" in GMAIL_ACCOUNT) EMAIL="$v" ;; VPN_IP_PREFIX) PREFIX="$v" ;; esac
    done < "$CONF"
fi
DOMAIN="${EMAIL#*@}"
if [[ -z "$EMAIL" ]]; then EMAIL_STATE=missing
elif [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then EMAIL_STATE=valid
else EMAIL_STATE=invalid; fi
kv email_configured "$EMAIL_STATE ($(mask <<< "${EMAIL:-none}"))"
kv vpn_ip_prefix "${PREFIX:-(any new utun address)}"
[[ "$EMAIL_STATE" == valid ]] || finding "No valid email address is set ($EMAIL_STATE). Open Settings and enter the Google account that receives the AuthCode mail."
{
    section "config file $CONF"
    if [[ -f "$CONF" ]]; then ls -l "$CONF"; mask < "$CONF"; else echo "missing"; fi
    section "last used code's issued time ($STATE)"
    cat "$STATE" 2>/dev/null || echo "none"
    section "environment overrides"
    env | grep -E '^(DIALOG_POLL|MAIL_TIMEOUT|CONNECT_TIMEOUT|CLOSE_DELAY|LOG|FORTI_PROC_PREFIX|FC_DEBUG)=' || echo "none"
} > "$R/settings.txt" 2>&1

# ---------------------------------------------------------------- permissions
PROBE="$(with_timeout 30 osascript "$LIB/token-dialog.applescript" find 2>&1)"
if [[ "$PROBE" == *"timed out"* ]]; then UI=timeout
elif denied "$PROBE"; then UI="denied"
else UI=ok; fi
case "${FAL_AX_TRUSTED:-}" in
    1) AX=granted ;;
    0) AX=missing ;;
    *) [[ "$UI" == denied ]] && AX=missing || AX=unknown ;;
esac
kv accessibility "$AX"
kv ui_automation_probe "$UI"
kv token_dialog_open_now "$([[ "$PROBE" == found:* ]] && echo "yes (${PROBE#found:})" || echo no)"
[[ "$AX" == missing ]] && finding "Accessibility permission is missing. System Settings > Privacy & Security > Accessibility: enable Forti Auto Login (remove and re-add it if it is already listed), then Restart Watcher."
[[ "$UI" == denied && "$AX" != missing ]] && finding "Window inspection was refused (Automation of System Events). System Settings > Privacy & Security > Automation: allow Forti Auto Login to control System Events."
[[ "$UI" == timeout ]] && finding "Inspecting the FortiClient windows timed out; a pending permission prompt may be waiting for an answer."
{
    section "Accessibility (AXIsProcessTrusted, from the app)"; echo "${FAL_AX_TRUSTED:-not reported (run from Terminal)}"
    section "token dialog probe (lib/token-dialog.applescript find)"; echo "${PROBE:-<empty: no token dialog open>}"
} > "$R/permissions.txt"

# ---------------------------------------------------------------- Chrome + Gmail
CHROME_APP=""
for c in "/Applications/Google Chrome.app" "$HOME/Applications/Google Chrome.app"; do
    [[ -d "$c" ]] && { CHROME_APP="$c"; break; }
done
CHROME_RUNNING=no; pgrep -xq "Google Chrome" && CHROME_RUNNING=yes
if [[ -z "$CHROME_APP" ]]; then
    kv browser "Google Chrome not installed"
    finding "Google Chrome is not installed; the code is read from Gmail in Chrome."
else
    kv browser "Google Chrome $(plist_value "$CHROME_APP" CFBundleShortVersionString) (running: $CHROME_RUNNING)"
fi
# every profile: which one is signed in as the configured account, and whether
# it allows JavaScript from Apple Events (the per-profile switch Gmail reading needs)
PROFILES="$(osascript -l JavaScript - "$EMAIL" "$CHROME_DATA" <<'JXA' 2>&1
function run(argv) {
  var email = (argv[0] || '').toLowerCase(), base = argv[1];
  function readJSON(p) {
    var t = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null);
    try { return t && t.js ? JSON.parse(t.js) : null; } catch (e) { return null; }
  }
  var ls = readJSON(base + '/Local State');
  if (!ls) return 'no Chrome Local State';
  var cache = (ls.profile || {}).info_cache || {}, out = [];
  var key = 'allow_javascript_apple_events';
  for (var dir in cache) {
    var user = cache[dir].user_name || '';
    var prefs = readJSON(base + '/' + dir + '/Preferences') || {};
    var local = (prefs.browser || {})[key], account = ((prefs.account_values || {}).browser || {})[key];
    var effective = account !== undefined ? account : local !== undefined ? local : false;
    out.push([email && user.toLowerCase() === email ? 'MATCH' : '-', dir, cache[dir].name || '',
              user || '(not signed in)', 'js_from_apple_events=' + (effective ? 'on' : 'off') +
              ' (profile=' + local + ' account=' + account + ')'].join(' | '));
  }
  return out.join('\n');
}
JXA
)"
MATCH="$(grep '^MATCH' <<< "$PROFILES" | head -1)"
if [[ -n "$MATCH" ]]; then
    MDIR="$(cut -d'|' -f2 <<< "$MATCH" | sed 's/^ *//;s/ *$//')"
    kv browser_profile_for_email "$MDIR"
    if [[ "$MATCH" == *"js_from_apple_events=on"* ]]; then kv browser_js_from_apple_events on
    else
        kv browser_js_from_apple_events off
        finding "Chrome profile '$MDIR' does not allow JavaScript from Apple Events. In a window of that profile: View > Developer > Allow JavaScript from Apple Events."
    fi
elif [[ -n "$CHROME_APP" && "$EMAIL_STATE" == valid ]]; then
    kv browser_profile_for_email none
    finding "No Chrome profile is signed in to the configured account (see browser.txt). Sign in to it in Chrome, or fix a typo in Settings."
fi

TABS="skipped (Chrome not running)"; GMAIL="skipped"
if [[ "$CHROME_RUNNING" == yes ]]; then
    cat > "$WORK/tabs.applescript" <<'OSA'
tell application "Google Chrome"
    set out to "windows: " & (count of windows) & linefeed
    set wi to 0
    repeat with w in windows
        set wi to wi + 1
        repeat with t in tabs of w
            if (URL of t) starts with "https://mail.google.com/" then set out to out & "window " & wi & ": " & (title of t) & linefeed
        end repeat
    end repeat
    return out
end tell
OSA
    TABS="$(with_timeout 20 osascript "$WORK/tabs.applescript" 2>&1)"
    if [[ "$TABS" == *"timed out"* ]]; then kv browser_automation timeout
        finding "Talking to Chrome timed out; a pending 'Forti Auto Login wants to control Google Chrome' prompt may be waiting."
    elif denied "$TABS"; then kv browser_automation denied
        finding "Controlling Chrome was refused. System Settings > Privacy & Security > Automation: allow Forti Auto Login to control Google Chrome."
    else kv browser_automation ok
        kv gmail_tabs "$(grep -c '^window ' <<< "$TABS")"
    fi
    # the real code lookup, as the watcher does it, over the last 24 h; never opens a tab
    if [[ "$EMAIL_STATE" == valid && "$TABS" != *"timed out"* ]] && ! denied "$TABS"; then
        GMAIL="$(FC_MAY_OPEN=0 with_timeout 45 osascript "$LIB/gmail-code.applescript" \
                 "$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ')" "$EMAIL" "$DOMAIN" "" 2>&1)"
        [[ "$GMAIL" =~ ^[0-9]+\|(.*)$ ]] && GMAIL="code found (issued ${BASH_REMATCH[1]})"
        [[ "$GMAIL" == none ]] && GMAIL="none (Gmail read fine; no unread AuthCode mail in the last 24h)"
        [[ "$GMAIL" == ERR:* ]] && finding "Reading Gmail failed: $(mask <<< "${GMAIL#ERR:}")"
        [[ "$GMAIL" == *"timed out"* ]] && finding "Reading Gmail timed out: Chrome did not answer the JavaScript request within 45s (tab asleep, or a pending permission prompt)."
    fi
else
    kv browser_automation "skipped (Chrome not running)"
fi
kv gmail_probe "$(mask <<< "$GMAIL" | head -1)"
{
    section "Chrome"; echo "${CHROME_APP:-not installed}  running: $CHROME_RUNNING"
    section "profiles (MATCH = signed in as the configured account)"; echo "$PROFILES"
    section "Gmail tabs"; echo "$TABS"
    section "Gmail probe (lib/gmail-code.applescript, last 24h)"; echo "$GMAIL"
} | mask > "$R/browser.txt"

# ---------------------------------------------------------------- FortiClient
FC_APP="/Applications/FortiClient.app"
if [[ -d "$FC_APP" ]]; then kv vpn_client "FortiClient $(plist_value "$FC_APP" CFBundleShortVersionString)"
else kv vpn_client "FortiClient not found in /Applications"; finding "FortiClient is not installed in /Applications."; fi
FC_PROCS="$(with_timeout 15 osascript -e 'tell application "System Events" to get name of every process whose name begins with "Forti" and name is not "FortiAutoLogin"' 2>&1)"
kv vpn_client_processes "$FC_PROCS"
{
    section "processes"; ps -axo pid,etime,comm | grep -i forti | grep -v -e grep -e 'forti-auto-login'
    section "UI of every Forti* process (text field values masked)"
    names=()
    [[ "$UI" == ok && "$FC_PROCS" != *"timed out"* ]] && IFS=',' read -ra names <<< "$FC_PROCS"
    for n in ${names[@]+"${names[@]}"}; do
        n="$(sed 's/^ *//;s/ *$//' <<< "$n")"
        [[ -z "$n" ]] && continue
        echo "---- $n"
        with_timeout 30 osascript "$LIB/dump-ui.applescript" "$n" 2>&1 \
            | sed -E '/^ +AX(SecureTextField|TextField|TextArea) /s/\| value=[^|[:space:]][^|]*\|/| value=<masked> |/'
    done
} 2>&1 | mask > "$R/vpn-client.txt"

# ---------------------------------------------------------------- network
UTUN="$(utun_addrs)"
kv vpn_addresses_now "$(tr '\n' ' ' <<< "${UTUN:-none}")"
if [[ -n "$PREFIX" && -n "$UTUN" ]] && ! grep -q " ${PREFIX//./\\.}" <<< "$UTUN"; then
    finding "VPN_IP_PREFIX is '$PREFIX' but no utun address starts with it now ($(tr '\n' ' ' <<< "$UTUN")). If the VPN is connected, clear or fix the prefix in Settings."
fi
{
    section "utun IPv4 addresses"; echo "${UTUN:-none}"
    section "interfaces"; ifconfig -l
    section "default route"; route -n get default 2>&1 | grep -E 'gateway|interface'
    section "scutil --nwi"; scutil --nwi 2>&1
} > "$R/network.txt"

# ---------------------------------------------------------------- log
if [[ -f "$LOG" ]]; then
    tail -n 3000 "$LOG" | mask > "$R/log.txt"
    kv log_lines "$(wc -l < "$LOG" | tr -d ' ') (last change $(date -r "$LOG" '+%Y-%m-%d %H:%M:%S'))"
    OK="$(grep -c 'VPN up, closing window' "$LOG")"
    BAD="$(grep -cE 'no AuthCode mail within|failed to fill dialog|code rejected|tunnel not up|no valid email configured|gave up: dialog closed' "$LOG")"
    kv attempts_in_log "$OK connected, $BAD failed"
    # the last token dialog handled, from its detection to the end of the log
    LAST="$(awk '/token dialog detected/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$LOG" | tail -n 40 | mask)"
    case "$LAST" in
        *"VPN up, closing window"*) OUTCOME="connected" ;;
        *"gave up: dialog closed"*|*"dialog gone while waiting"*) OUTCOME="dialog closed before a code was found" ;;
        *"no AuthCode mail within"*) OUTCOME="no AuthCode mail found in time" ;;
        *"failed to fill dialog"*)   OUTCOME="could not type the code into the dialog" ;;
        *"code rejected"*)           OUTCOME="code typed but the dialog stayed open (rejected)" ;;
        *"tunnel not up"*)           OUTCOME="code accepted but no VPN address appeared" ;;
        *"no valid email"*)          OUTCOME="no email configured" ;;
        *"cannot inspect windows"*)  OUTCOME="no permission to inspect windows" ;;
        *"token dialog detected"*)   OUTCOME="in progress or cut off" ;;
        *)                           OUTCOME="no token dialog in the log" ;;
    esac
    kv last_attempt "$(grep -m1 'token dialog detected' <<< "$LAST" | cut -c1-19) $OUTCOME"
    case "$OUTCOME" in
        connected|"no token dialog in the log"|"in progress or cut off") ;;
        *) finding "Last attempt: $OUTCOME (see 'Last attempt' below and log.txt)." ;;
    esac
else
    kv log_lines "no log file at $LOG"
    LAST=""
    finding "No log file: the watcher has never run for this user."
fi

# ---------------------------------------------------------------- summary + zip
{
    echo "Forti Auto Login problem report"
    echo "==============================="
    cat "$SUMMARY"
    printf '\nLikely causes\n-------------\n'
    if [[ -s "$FINDINGS" ]]; then cat "$FINDINGS"; else echo "- none detected automatically; see log.txt"; fi
    printf '\nLast attempt (from the log)\n---------------------------\n%s\n' "${LAST:-none}"
    printf '\nUser description\n----------------\n%s\n' "${FAL_DESCRIPTION:-(none)}"
    printf '\nFiles: summary.txt, log.txt, settings.txt, permissions.txt, browser.txt,\n'
    printf 'vpn-client.txt, network.txt, app.txt, system.txt, description.txt and crashes/ (when present)\n'
} > "$R/summary.txt"

ZIP="$OUT_DIR/$NAME.zip"
if ! { mkdir -p "$OUT_DIR" && ditto -c -k --keepParent "$R" "$ZIP"; } 2>/dev/null; then
    echo "cannot write to $OUT_DIR, saving next to the log instead" >&2
    ZIP="$FALLBACK_DIR/$NAME.zip"
    mkdir -p "$FALLBACK_DIR" && ditto -c -k --keepParent "$R" "$ZIP" || { echo "failed to write $ZIP" >&2; exit 1; }
fi
[[ -z "${FAL_APP_PATH:-}" && -t 1 ]] && open -R "$ZIP"
echo "$ZIP"
