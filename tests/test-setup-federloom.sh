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

exit "$fail"
