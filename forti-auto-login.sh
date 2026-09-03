#!/bin/bash
# FortiClient VPN token helper for macOS.
#
#   ./forti-auto-login.sh          one shot: wait for the token dialog, fill it, close window
#   ./forti-auto-login.sh --watch  keep running; handle every token dialog that appears
#
# Flow: FortiClient shows "An email message containing a Token Code will be sent..."
#   -> read newest unread "AuthCode: NNNNNN" mail via the Gmail tab in Chrome
#   -> type it into the dialog, click OK
#   -> wait until the VPN interface is up, then close the FortiClient window.
set -u

# ============================ CONFIG ========================================
GMAIL_ACCOUNT=""            # the mailbox that receives the AuthCode mail,
                            # e.g. first.last@example.com. Usually set from the
                            # menu bar app's Settings window instead of here.
VPN_IP_PREFIX=""            # optional: tunnel address prefix, e.g. 10.0.
                            # empty = any new utun address after the dialog
# ============================================================================
# Per-user settings written by the menu bar app's Settings window. Parsed, not
# sourced: only the two known keys, quotes stripped, nothing executed.
CONF="$HOME/.forti-auto-login.conf"
if [[ -f "$CONF" ]]; then
    while IFS='=' read -r k v; do
        v="${v%\"}"; v="${v#\"}"
        case "$k" in
            GMAIL_ACCOUNT) GMAIL_ACCOUNT="$v" ;;
            VPN_IP_PREFIX) VPN_IP_PREFIX="$v" ;;
        esac
    done < "$CONF"
fi
[[ "$VPN_IP_PREFIX" =~ ^[0-9.]*$ ]] || { echo "invalid VPN_IP_PREFIX '$VPN_IP_PREFIX' (digits and dots only)" >&2; VPN_IP_PREFIX=""; }
GMAIL_DOMAIN="${GMAIL_ACCOUNT#*@}"      # used to pick the Chrome profile
umask 077                               # log and state files are private

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib"
DIALOG_POLL="${DIALOG_POLL:-1.5}"           # seconds between dialog checks
MAIL_TIMEOUT="${MAIL_TIMEOUT:-120}"         # seconds to wait for the AuthCode mail
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-90}"    # seconds to wait for the tunnel
CLOSE_DELAY="${CLOSE_DELAY:-3}"             # seconds after connect before closing window
LOG="${LOG:-$HOME/Library/Logs/forti-auto-login.log}"

log()    { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG" >&2; }
notify() { osascript -e "display notification \"$1\" with title \"FortiClient auto-login\"" >/dev/null 2>&1; }

AX_WARNED=0
dialog_present() {
    local out
    out="$(osascript "$LIB/token-dialog.applescript" find 2>&1)"
    if [[ "$out" == *"assistive access"* || "$out" == *"not allowed"* || "$out" == *"(-1719)"* || "$out" == *"(-1743)"* ]]; then
        if (( AX_WARNED == 0 )); then
            log "cannot inspect windows: $out"
            log "grant Accessibility (and Automation for System Events) to the app running this script, then restart"
            notify "Needs Accessibility permission"
            AX_WARNED=1
        fi
        return 1
    fi
    [[ "$out" == found:* ]]
}
utun_addrs()     { ifconfig | awk '/^utun/{i=$1}/inet /{if(i!="")print i,$2}'; }
BASELINE=""
vpn_up() {
    if [[ -n "$VPN_IP_PREFIX" ]]; then ifconfig | grep -qF "inet ${VPN_IP_PREFIX}"; return; fi
    # connected = a utun address exists now that was not there when the dialog appeared
    comm -13 <(printf '%s\n' "$BASELINE" | sort) <(utun_addrs | sort) | grep -q .
}

STATE="$HOME/.forti-auto-login.last"        # issued time of the last code used
fetch_code() {   # $1 = since (ISO-8601 UTC); prints the code or returns 1
    local since="$1" deadline=$(( $(date +%s) + MAIL_TIMEOUT )) res after
    after="$(cat "$STATE" 2>/dev/null || true)"
    local may_open=1   # open a Gmail tab at most once per dialog, never when one exists
    while (( $(date +%s) < deadline )); do
        res="$(FC_MAY_OPEN=$may_open osascript "$LIB/gmail-code.applescript" "$since" "$GMAIL_ACCOUNT" "$GMAIL_DOMAIN" "$after" 2>&1)"
        may_open=0
        case "$res" in
            [0-9]*\|*) printf '%s' "${res#*|}" > "$STATE"; echo "${res%%|*}"; return 0 ;;
            none)      ;;
            *)         log "gmail: $res" ;;
        esac
        dialog_present || { log "dialog gone while waiting for mail"; return 2; }
        sleep 3
    done
    return 1
}

valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

handle_dialog() {
    if ! valid_email "$GMAIL_ACCOUNT"; then
        log "no valid email configured (GMAIL_ACCOUNT='$GMAIL_ACCOUNT'); set it in Settings"
        notify "Set your email address in Settings"
        return 1
    fi
    # mail is sent when the dialog appears; accept anything from 60 s before that
    local since code
    since="$(date -u -v-60S '+%Y-%m-%dT%H:%M:%SZ')"
    BASELINE="$(utun_addrs)"
    log "token dialog detected, waiting for AuthCode mail (since $since)"
    notify "Token dialog detected, reading Gmail..."
    if ! code="$(fetch_code "$since")"; then
        log "no AuthCode mail within ${MAIL_TIMEOUT}s"; notify "No AuthCode mail found"; return 1
    fi
    log "got code ${code:0:2}**** (issued $(cat "$STATE")), filling dialog"
    if ! osascript "$LIB/token-dialog.applescript" fill "$code" >/dev/null 2>>"$LOG"; then
        log "failed to fill dialog"; notify "Failed to fill token dialog"; return 1
    fi
    local deadline=$(( $(date +%s) + CONNECT_TIMEOUT ))
    while (( $(date +%s) < deadline )); do
        vpn_up && break
        if dialog_present; then log "dialog still open (code rejected?)"; notify "Token rejected"; return 1; fi
        sleep 1
    done
    if ! vpn_up; then log "tunnel not up after ${CONNECT_TIMEOUT}s"; notify "VPN did not connect"; return 1; fi
    sleep "$CLOSE_DELAY"
    log "VPN up, closing window: $(osascript "$LIB/close-main-window.applescript" 2>&1)"
    #notify "VPN connected"
}

wait_for_dialog() {
    while ! dialog_present; do sleep "$DIALOG_POLL"; done
}

mkdir -p "$(dirname "$LOG")"
case "${1:-}" in
    --watch)
        log "watching for FortiClient token dialog"
        while :; do
            wait_for_dialog
            handle_dialog || sleep 10
            # do not re-handle the same dialog in a tight loop
            while dialog_present; do sleep 2; done
        done ;;
    --dump)   osascript "$LIB/dump-ui.applescript" "${2:-FortiClient}" ;;
    --test-gmail)
        valid_email "$GMAIL_ACCOUNT" || { echo "no valid email configured (GMAIL_ACCOUNT='$GMAIL_ACCOUNT')"; exit 1; }
        osascript "$LIB/gmail-code.applescript" "$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ')" "$GMAIL_ACCOUNT" "$GMAIL_DOMAIN" ;;
    --help|-h) sed -n '2,10p' "$0" ;;
    *)
        log "waiting for token dialog (one shot)"
        wait_for_dialog
        handle_dialog ;;
esac
