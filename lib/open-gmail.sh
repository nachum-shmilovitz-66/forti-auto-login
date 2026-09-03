#!/bin/bash
# Usage: open-gmail.sh <email> <domain>
# Opens Gmail in the Chrome profile signed in as <email> (or, if <email> is empty,
# as any account on <domain>), looked up in Chrome's "Local State".
# Falls back to the Default profile. Uses JXA for JSON, so no python needed.
set -u
email="${1:-}"; domain="${2:-}"
profile="$(osascript -l JavaScript - "$email" "$domain" <<'JXA' 2>/dev/null
function run(argv) {
  var email = argv[0].toLowerCase(), domain = argv[1].toLowerCase();
  var path = $.NSHomeDirectory().js + '/Library/Application Support/Google/Chrome/Local State';
  var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!text || !text.js) return 'Default';
  var cache = (JSON.parse(text.js).profile || {}).info_cache || {};
  for (var dir in cache) {
    var u = (cache[dir].user_name || '').toLowerCase();
    if ((email && u === email) || (!email && domain && u.slice(-(domain.length + 1)) === '@' + domain)) return dir;
  }
  return 'Default';
}
JXA
)"
[[ -z "$profile" ]] && profile="Default"
url="https://mail.google.com/mail/"
[[ -n "$email" ]] && url="$url?authuser=$email"
echo "opening Gmail for ${email:-@$domain} in Chrome profile '$profile'" >&2
open -na "Google Chrome" --args --profile-directory="$profile" "$url"
