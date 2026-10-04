#!/usr/bin/env bash
# Unit/integration tests for federloom/setup-federloom.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/federloom/setup-federloom.sh"
FIX="$HERE/fixtures"
fail=0
check() { # check "name" actual expected
  if [[ "$2" == "$3" ]]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n      got: %q\n      exp: %q\n' "$1" "$2" "$3"; fail=1; fi
}
contains() { # contains "name" haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s (missing: %q)\n' "$1" "$3"; fail=1; fi
}

# --- CLI behavior (run as a subprocess) ---
out="$(bash "$SCRIPT" --help 2>&1)"; rc=$?
check "help exits 0" "$rc" "0"
contains "help shows usage" "$out" "Usage:"
out="$(bash "$SCRIPT" --bogus 2>&1)"; rc=$?
check "unknown option exits 1" "$rc" "1"

# --- Source the script to unit-test functions (guard prevents main()) ---
# shellcheck disable=SC1090
source "$SCRIPT"

# (later tasks append more tests here)

# --- extract_api_key ---
key="$(extract_api_key < "$FIX/cscli-bouncers-add.txt")"
check "extract_api_key pulls the key" "$key" "a1b2c3d4e5f60718293a4b5c6d7e8f90"
empty="$(printf 'no key here\n' | extract_api_key)"
check "extract_api_key empty on no match" "$empty" ""

# --- generate_config ---
PUBLIC_IP="203.0.113.5"; TAILSCALE_IP="100.64.0.9"
MAILCOW_NETWORK="172.22.1.0/24"; DOCKER_BRIDGE="172.17.0.0/16"
POSTFIX_CTR="mailcowdockerized-postfix-mailcow-1"
DOVECOT_CTR="mailcowdockerized-dovecot-mailcow-1"
CROWDSEC_ENABLED="true"; API_KEY="DEADBEEFKEY1234567890"
cfg="$(mktemp)"; generate_config "$cfg"; body="$(cat "$cfg")"
contains "config has public IP whitelist"   "$body" "    - 203.0.113.5"
contains "config has tailscale whitelist"   "$body" "    - 100.64.0.9"
contains "config has mailcow net whitelist" "$body" "    - 172.22.1.0/24"
contains "config enables crowdsec"          "$body" "enabled: true"
contains "config carries api key"           "$body" 'api_key: "DEADBEEFKEY1234567890"'
contains "config sets postfix container"    "$body" "postfix_container: mailcowdockerized-postfix-mailcow-1"
contains "config references rules file"     "$body" "rules_file: /etc/federloom/rules.yaml"
# Empty values are skipped in the whitelist:
TAILSCALE_IP=""; cfg2="$(mktemp)"; generate_config "$cfg2"
if grep -q '    - $' "$cfg2"; then printf 'FAIL - no empty whitelist entries\n'; fail=1; else printf 'ok   - no empty whitelist entries\n'; fi
rm -f "$cfg" "$cfg2"

exit "$fail"
