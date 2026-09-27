# Problem report format

"Report a Problem…" in the menu bar app writes one zip that should be enough to find
out why an auto-login failed, without access to the user's computer. On macOS it is
built by `lib/collect-report.sh`. This file is the contract: a Windows port must
produce the same file names and summary keys, so one reader (a person, or Claude)
handles reports from both platforms. Change the format only together with
`report_format`.

## Zip

`forti-auto-login-report-YYYYMMDD-HHMMSS.zip`, containing one folder of the same name.

| File | Contents | macOS source |
| --- | --- | --- |
| `summary.txt` | key facts, **Likely causes**, last attempt, user description | computed |
| `log.txt` | last 3000 lines of the watcher log | `~/Library/Logs/forti-auto-login.log` |
| `settings.txt` | config file (masked), last used code's issued time, env overrides | `~/.forti-auto-login.conf`, `~/.forti-auto-login.last` |
| `permissions.txt` | Accessibility state, live token-dialog probe | `AXIsProcessTrusted`, `token-dialog.applescript find` |
| `browser.txt` | Chrome profiles (which one is the configured account, JavaScript-from-Apple-Events switch), Gmail tab titles, live Gmail probe | Chrome `Local State` and `Preferences`, `gmail-code.applescript` |
| `vpn-client.txt` | FortiClient processes and the UI tree of each Forti* process (text fields masked) | `ps`, `dump-ui.applescript` |
| `network.txt` | VPN interface addresses, interfaces, default route | `ifconfig`, `route`, `scutil --nwi` |
| `app.txt` | bundle path, signature, Gatekeeper, every copy of the app, processes, login items, crash reports | `codesign`, `spctl`, `mdfind` |
| `system.txt` | OS version, hardware, uptime, time zone, locale | `sw_vers`, `sysctl` |
| `description.txt` | what the user typed (only when they typed something) | report dialog |
| `crashes/` | up to 3 newest crash reports of the app (only when present) | `~/Library/Logs/DiagnosticReports` |

## summary.txt

A title line, then one `key: value` per line in this order, then three sections:
`Likely causes` (one `- ` line per detected problem, most specific first), `Last
attempt (from the log)` (log lines from the last token dialog on), `User description`.

| Key | Values |
| --- | --- |
| `report_format` | `1` |
| `created` | ISO-8601 local time with offset |
| `platform` | `macos` / `windows` |
| `os_version`, `arch`, `app_version`, `user` | free text |
| `run_from` | `app` (probes use the app's permissions) / `terminal` |
| `watcher_processes` | count; anything but 1 is a problem |
| `watcher_running` | `yes` / `no` (app only) |
| `login_item` | `yes` / `no` / `unknown`: starts at login |
| `app_quarantined`, `app_path`, `app_signature`, `app_copies` | signature: signer name, `ad-hoc`, `unsigned` |
| `email_configured` | `valid` / `invalid` / `missing`, plus the masked address |
| `vpn_ip_prefix` | the prefix, or `(any new utun address)` |
| `accessibility` | `granted` / `missing` / `unknown` |
| `ui_automation_probe` | `ok` / `denied` / `timeout` |
| `token_dialog_open_now` | `yes (<process>)` / `no` |
| `browser` | name, version, running |
| `browser_profile_for_email` | profile folder signed in as the configured account, or `none` |
| `browser_js_from_apple_events` | `on` / `off` |
| `browser_automation` | `ok` / `denied` / `timeout` / `skipped (...)` |
| `gmail_tabs` | count of open Gmail tabs |
| `gmail_probe` | `code found (issued ...)` / `none (...)` / `ERR:...` / `[timed out ...]` / `skipped` |
| `vpn_client`, `vpn_client_processes` | FortiClient version, its processes |
| `vpn_addresses_now` | `utunN: a.b.c.d` pairs, or `none` |
| `log_lines`, `attempts_in_log` | size and last change; connected vs failed count |
| `last_attempt` | timestamp and outcome of the last token dialog |

Keys that do not apply on a platform are still written, with `not_applicable`.

## Privacy

Never collected: one-time codes (masked to `******`, including old log lines),
passwords, cookies, mail content. Email local parts are masked to first and last
letter (`n***z@example.com`); compare addresses before masking (as the
`MATCH` column in `browser.txt` does). Text field values in UI dumps are masked.

## Windows mapping (for the port)

| macOS | Windows equivalent to report under the same key |
| --- | --- |
| `~/Library/Logs/forti-auto-login.log` | `%LOCALAPPDATA%\FortiAutoLogin\forti-auto-login.log` |
| `~/Library/Logs/Forti Auto Login Reports/` | `%LOCALAPPDATA%\FortiAutoLogin\Reports\` |
| `accessibility` (TCC grant) | `not_applicable`: UI Automation needs no grant |
| `ui_automation_probe` | find the token dialog through UI Automation |
| `login_item` | Startup folder shortcut or `HKCU\...\Run` entry |
| `app_signature`, `app_quarantined` | Authenticode signer; Mark-of-the-Web on the exe |
| `browser_js_from_apple_events` | whatever the port uses to read Gmail, or `not_applicable` |
| `vpn_addresses_now` | IPv4 of the Fortinet virtual adapter |
| `system.txt` | `systeminfo`-style OS build, uptime, time zone, locale |
| zip | `Compress-Archive` (same layout) |
