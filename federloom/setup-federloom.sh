#!/usr/bin/env bash
# Optional FederLoom installer for the Mailcow-Crowdsec-Override integration.
#
# Runs locally on the Mailcow host. Generates the dynamic config (config.local.yaml
# and the federloom compose service — with detected IPs, CrowdSec API key, and
# advertise address), fetches the static upstream files (rules.yaml,
# federation.invite), registers a CrowdSec bouncer, merges the service into the
# existing docker-compose.override.yml (backup + validate + restore on failure),
# starts FederLoom, and offers an opt-in federation join.
#
# Idempotent. Never modifies Mailcow-owned files.
set -euo pipefail

FEDERLOOM_REPO="https://github.com/JoeRu/federloom"
FINGERPRINT="79bb d13a 114b 88fe"
DEFAULT_MAILCOW_ROOT="/opt/mailcow-dockerized"
ASSUME_YES=0
MAILCOW_ROOT=""
CROWDSEC_CTR=""
POSTFIX_CTR=""
DOVECOT_CTR=""
PUBLIC_IP=""
TAILSCALE_IP=""
MAILCOW_NETWORK="172.22.1.0/24"
DOCKER_BRIDGE="172.17.0.0/16"
CROWDSEC_ENABLED="false"
API_KEY=""
TMPDIR_FL=""

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [MAILCOW_ROOT] [--yes]

Installs and auto-configures FederLoom alongside the CrowdSec integration.

  MAILCOW_ROOT   Path to the Mailcow install (default: \$MAILCOW_ROOT env or
                 ${DEFAULT_MAILCOW_ROOT}).
  --yes          Accept auto-detected values without prompting. Does NOT
                 auto-join the maintainer's federation (that always prompts).
  -h, --help     Show this help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "Unknown option: $1" ;;
      *) MAILCOW_ROOT="$1" ;;
    esac
    shift
  done
  [[ -n "$MAILCOW_ROOT" ]] || MAILCOW_ROOT="${MAILCOW_ROOT:-${DEFAULT_MAILCOW_ROOT}}"
  [[ -n "$MAILCOW_ROOT" ]] || MAILCOW_ROOT="$DEFAULT_MAILCOW_ROOT"
}

preflight() {
  [[ -d "$MAILCOW_ROOT" ]] || die "Mailcow root not found: $MAILCOW_ROOT"
  [[ -f "$MAILCOW_ROOT/docker-compose.yml" && -f "$MAILCOW_ROOT/mailcow.conf" ]] \
    || die "$MAILCOW_ROOT does not look like a Mailcow install (missing docker-compose.yml or mailcow.conf)."
  command -v docker >/dev/null 2>&1 || die "docker not found in PATH."
  command -v git >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 \
    || die "need either git or curl to fetch upstream files."
  CROWDSEC_CTR="$(detect_container crowdsec || true)"
  [[ -n "$CROWDSEC_CTR" ]] \
    || die "No running CrowdSec container found. Install the CrowdSec integration first."
  log "Mailcow root : $MAILCOW_ROOT"
  log "CrowdSec ctr : $CROWDSEC_CTR"
}

detect_container() {
  # $1 = name substring; prints first matching running container name (if any)
  docker ps --format '{{.Names}}' | grep -m1 -- "$1" || true
}

extract_api_key() {
  # Reads `cscli bouncers add` output on stdin; prints the API key or nothing.
  awk 'tolower($0) ~ /api key for/ {found=1; next}
       found && /[A-Za-z0-9+\/=]{16,}/ {gsub(/[[:space:]]/,""); print; exit}'
}

main() {
  parse_args "$@"
  preflight
  # later tasks append: fetch_upstream; detect_and_confirm; register_bouncer;
  # generate_config; merge_compose; start_and_report; offer_federation_join
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
