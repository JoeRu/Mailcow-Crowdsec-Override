# post_update_hook example + FederLoom setup script — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `post_update_hook.sh.example` for Mailcow and a locally-run, auto-configuring FederLoom installer to the Mailcow-Crowdsec-Override repo.

**Architecture:** Two self-contained deliverables. (1) A hardened `post_update_hook.sh.example` at repo root that rebuilds the firewall bouncer and restarts FederLoom if present. (2) `federloom/setup-federloom.sh`, a single idempotent bash script that **generates** the dynamic bits (`config.local.yaml`, the merged `federloom` compose service — both carry detected IPs / API key / advertise address) and **fetches** only the genuinely-static upstream files (`rules.yaml`, `federation.invite`) from `JoeRu/federloom`. It auto-detects host specifics, registers a CrowdSec bouncer, merges the service into the existing `docker-compose.override.yml` (backup + validate + restore on failure), starts FederLoom, and offers an opt-in federation join.

**Tech Stack:** Bash, Docker Compose v2, CrowdSec `cscli`, git sparse-checkout, `awk`/`grep`/`sed`. Tests use `bash -n` syntax checks, sourced-function unit tests, and `docker compose config` for YAML/compose validation.

**Note on a spec refinement discovered while reading upstream:** the spec said "fetch config.yaml and rules.yaml". The real upstream standalone compose mounts `config.local.yaml` **as** `/etc/federloom/config.yaml` (the complete generated config) plus `rules.yaml` separately; the upstream *override* is an incomplete scaffold. So this plan fetches only `rules.yaml` + `federation.invite` (static) and **generates** `config.local.yaml` and the compose service block (dynamic). This honors "fetch from upstream" for static files and "auto-detect + confirm" for the dynamic config.

**Testability convention:** `setup-federloom.sh` defines functions and calls `main "$@"` only under a `BASH_SOURCE`/`$0` guard, so tests can `source` it and exercise individual functions without triggering installation. Extraction helpers read from stdin; generators write to a caller-supplied path; the merge operates on a caller-supplied file. No function requires Docker or network at unit-test time except where explicitly integration-tested.

---

## File Structure

- Create: `post_update_hook.sh.example` — Mailcow post-update hook (repo root).
- Create: `federloom/setup-federloom.sh` — the installer.
- Create: `tests/test-setup-federloom.sh` — sourced-function unit/integration tests.
- Create: `tests/fixtures/cscli-bouncers-add.txt` — sample `cscli bouncers add` output.
- Create: `tests/fixtures/federloom-peerid.log` — sample FederLoom startup log.
- Modify: `.gitignore` — ignore `federloom/config.local.yaml` and backups.
- Modify: `README.md` — add "Keeping the bouncer current after Mailcow updates" and "Optional: FederLoom federated reputation sharing" sections.

---

## Task 1: `post_update_hook.sh.example`

**Files:**
- Create: `post_update_hook.sh.example`
- Test: inline (`bash -n`, `grep`)

- [ ] **Step 1: Create the hook file**

Create `post_update_hook.sh.example` with exactly:

```bash
#!/usr/bin/env bash
# Mailcow post-update hook.
#
# Copy to your Mailcow root as post_update_hook.sh and make it executable:
#   cp post_update_hook.sh.example /opt/mailcow-dockerized/post_update_hook.sh
#   chmod +x /opt/mailcow-dockerized/post_update_hook.sh
#
# Mailcow's ./update.sh runs this automatically at the end of an update.
set -euo pipefail
cd "$(dirname "$0")"

# Rebuild the firewall bouncer so it re-fetches the latest release
# (the image layer is cached, so a plain `up` would keep the old version).
docker compose build --no-cache cs-firewall-bouncer
docker compose up -d cs-firewall-bouncer

# If FederLoom is installed, pull and restart it too (no-op otherwise).
if docker compose config --services 2>/dev/null | grep -qx federloom; then
  docker compose pull federloom
  docker compose up -d federloom
fi
```

- [ ] **Step 2: Syntax check**

Run: `bash -n post_update_hook.sh.example`
Expected: no output, exit 0.

- [ ] **Step 3: Verify the FederLoom guard uses an exact-line match**

Run: `grep -q 'grep -qx federloom' post_update_hook.sh.example && echo OK`
Expected: `OK` (confirms `-qx`, so a service merely containing the substring "federloom" is not mismatched).

- [ ] **Step 4: Commit**

```bash
git add post_update_hook.sh.example
git commit -m "Add post_update_hook.sh example (rebuild bouncer, restart federloom if present)"
```

---

## Task 2: Setup script skeleton + preflight

**Files:**
- Create: `federloom/setup-federloom.sh`
- Test: `tests/test-setup-federloom.sh`

- [ ] **Step 1: Create the script skeleton with the source guard**

Create `federloom/setup-federloom.sh`:

```bash
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

main() {
  parse_args "$@"
  preflight
  # later tasks append: fetch_upstream; detect_and_confirm; register_bouncer;
  # generate_config; merge_compose; start_and_report; offer_federation_join
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Note: the parse_args default line is intentionally defensive; the final effective
default is always `$DEFAULT_MAILCOW_ROOT` when neither arg nor `$MAILCOW_ROOT` env
is set.

- [ ] **Step 2: Make executable and syntax-check**

Run:
```bash
chmod +x federloom/setup-federloom.sh
bash -n federloom/setup-federloom.sh
```
Expected: no output, exit 0.

- [ ] **Step 3: Write the test harness with the first test (help + unknown option)**

Create `tests/test-setup-federloom.sh`:

```bash
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

exit "$fail"
```

- [ ] **Step 4: Run the tests**

Run: `bash tests/test-setup-federloom.sh`
Expected: all `ok` lines, exit 0. (`--help` exits 0; `--bogus` exits 1 via `die`.)

- [ ] **Step 5: Commit**

```bash
git add federloom/setup-federloom.sh tests/test-setup-federloom.sh
git commit -m "Add FederLoom setup script skeleton + preflight with tests"
```

---

## Task 3: API key extraction helper (TDD)

**Files:**
- Modify: `federloom/setup-federloom.sh`
- Create: `tests/fixtures/cscli-bouncers-add.txt`
- Modify: `tests/test-setup-federloom.sh`

- [ ] **Step 1: Create the fixture**

Create `tests/fixtures/cscli-bouncers-add.txt` with representative `cscli bouncers add federloom` output:

```
Api key for 'federloom':

   a1b2c3d4e5f60718293a4b5c6d7e8f90

Please keep this key since you will not be able to retrieve it!
```

- [ ] **Step 2: Add the failing test**

In `tests/test-setup-federloom.sh`, before `exit "$fail"`, add:

```bash
# --- extract_api_key ---
key="$(extract_api_key < "$FIX/cscli-bouncers-add.txt")"
check "extract_api_key pulls the key" "$key" "a1b2c3d4e5f60718293a4b5c6d7e8f90"
empty="$(printf 'no key here\n' | extract_api_key)"
check "extract_api_key empty on no match" "$empty" ""
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test-setup-federloom.sh`
Expected: FAIL on "extract_api_key pulls the key" (function not defined → empty).

- [ ] **Step 4: Implement `extract_api_key`**

In `federloom/setup-federloom.sh`, add after `detect_container`:

```bash
extract_api_key() {
  # Reads `cscli bouncers add` output on stdin; prints the API key or nothing.
  awk 'tolower($0) ~ /api key for/ {found=1; next}
       found && /[A-Za-z0-9+\/=]{16,}/ {gsub(/[[:space:]]/,""); print; exit}'
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-setup-federloom.sh`
Expected: both extract_api_key checks `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add federloom/setup-federloom.sh tests/
git commit -m "Add API key extraction helper with tests"
```

---

## Task 4: config.local.yaml generator (TDD)

**Files:**
- Modify: `federloom/setup-federloom.sh`
- Modify: `tests/test-setup-federloom.sh`

- [ ] **Step 1: Add the failing test**

In `tests/test-setup-federloom.sh`, before `exit "$fail"`, add:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-setup-federloom.sh`
Expected: FAIL (generate_config not defined).

- [ ] **Step 3: Implement `generate_config`**

In `federloom/setup-federloom.sh`, add after `extract_api_key`:

```bash
generate_config() {
  # $1 = output path. Uses globals set by detect_and_confirm/register_bouncer.
  local out="$1" ip
  cat > "$out" <<EOF
# FederLoom config for this Mailcow node.
# Generated by setup-federloom.sh — do not commit (gitignored).
federation_mode: federated
store:
  dir: /var/lib/federloom
enforce:
  backend: ipset
  set_name: federloom
  chains:
    - DOCKER-USER
    - INPUT
  extra_whitelist:
EOF
  for ip in "$PUBLIC_IP" "$TAILSCALE_IP" "$MAILCOW_NETWORK" "$DOCKER_BRIDGE"; do
    [[ -n "$ip" ]] && printf '    - %s\n' "$ip" >> "$out"
  done
  cat >> "$out" <<EOF
reputation:
  block_threshold: 75
  unblock_threshold: 60
  half_life: 168h
  decay_interval: 1h
  rules_file: /etc/federloom/rules.yaml
ingest:
  mailcow_logs:
    enabled: true
    postfix_container: ${POSTFIX_CTR}
    dovecot_container: ${DOVECOT_CTR}
    poll_interval: 30s
  spamtrap:
    enabled: false
    log_file: /var/log/federloom-spamtrap.log
    poll_interval: 5s
  crowdsec:
    enabled: ${CROWDSEC_ENABLED}
    lapi_url: "http://127.0.0.1:8080"
    api_key: "${API_KEY}"
    poll_interval: 30s
    enable_decisions: true
    enable_alerts: false
observability:
  prometheus_addr: ":9101"
api:
  addr: ":9102"
  purpose: "mail"
  taxonomy:
    mail:
      - smtp-*
      - imap-*
      - pop3-*
bootstrap_peers:
  - /ip4/167.233.115.41/tcp/7700/p2p/12D3KooWBvpzbEBgcFbHrw3kEFjfdFB2AwimGMhMrVGQBHMpZNjD
dnsbl:
  addr: ":5353"
  zone: "dnsbl.federloom.mail."
EOF
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-setup-federloom.sh`
Expected: all generate_config checks `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add federloom/setup-federloom.sh tests/test-setup-federloom.sh
git commit -m "Add config.local.yaml generator with tests"
```

---

## Task 5: Compose merge (backup + idempotent insert + validate/restore) (TDD)

**Files:**
- Modify: `federloom/setup-federloom.sh`
- Modify: `tests/test-setup-federloom.sh`

- [ ] **Step 1: Add the failing test (merge against the real repo override)**

In `tests/test-setup-federloom.sh`, before `exit "$fail"`, add:

```bash
# --- merge_compose_file (operates on a copy of the real override) ---
work="$(mktemp -d)"; cp "$REPO/docker-compose.override.yml" "$work/dco.yml"
PUBLIC_IP="203.0.113.5"
merge_compose_file "$work/dco.yml"
# federloom service inserted under services:, volume under volumes:
contains "merge adds federloom service" "$(cat "$work/dco.yml")" "    federloom:"
contains "merge adds federloom-data volume" "$(cat "$work/dco.yml")" "    federloom-data:"
contains "merge sets advertise IP" "$(cat "$work/dco.yml")" "/ip4/203.0.113.5/tcp/7700"
contains "merge wraps in start marker" "$(cat "$work/dco.yml")" "# >>> federloom"
# A timestamped backup was created:
if ls "$work"/dco.yml.bak.* >/dev/null 2>&1; then printf 'ok   - merge made a backup\n'; else printf 'FAIL - merge made a backup\n'; fail=1; fi
# Idempotency: second run is a no-op (marker count stays 1)
merge_compose_file "$work/dco.yml"
mc="$(grep -c '# >>> federloom' "$work/dco.yml")"
check "merge is idempotent (one marker)" "$mc" "1"
# Compose still validates (docker available in CI/host):
if command -v docker >/dev/null 2>&1; then
  if ( cd "$work" && docker compose -f dco.yml config -q ) 2>/dev/null; then
    printf 'ok   - merged override validates with docker compose\n'
  else
    printf 'FAIL - merged override failed docker compose config\n'; fail=1
  fi
fi
rm -rf "$work"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-setup-federloom.sh`
Expected: FAIL (merge_compose_file not defined).

- [ ] **Step 3: Implement `merge_compose_file`**

In `federloom/setup-federloom.sh`, add after `generate_config`:

```bash
merge_compose_file() {
  # $1 = path to docker-compose.override.yml. Idempotent; backs up before editing.
  local override="$1"
  if grep -q '# >>> federloom' "$override"; then
    log "federloom already present in $(basename "$override") — skipping merge."
    return 0
  fi
  cp "$override" "${override}.bak.$(date +%Y%m%d-%H%M%S)"

  local adv="${PUBLIC_IP:-0.0.0.0}"
  local svc
  # 4-space indent for the service key, 6-space for its properties — matches the
  # existing crowdsec service block in this repo's override.
  svc=$(cat <<EOF
    # >>> federloom (added by setup-federloom.sh) >>>
    federloom:
      image: ghcr.io/joeru/federloom:latest
      container_name: federloom
      restart: unless-stopped
      cap_add: [ NET_ADMIN, NET_RAW ]
      network_mode: host
      depends_on:
        - crowdsec
      environment:
        DOCKER_HOST: unix:///host-run/docker.sock
      volumes:
        - /run:/host-run:ro
        - ./federloom/config.local.yaml:/etc/federloom/config.yaml:ro
        - ./federloom/rules.yaml:/etc/federloom/rules.yaml:ro
        - federloom-data:/var/lib/federloom
      command: >
        --config /etc/federloom/config.yaml
        --listen /ip4/0.0.0.0/tcp/7700
        --advertise /ip4/${adv}/tcp/7700
    # <<< federloom <<<
EOF
)
  local vol="    federloom-data:"

  # Insert the service after the first top-level 'services:' and the volume after
  # the first top-level 'volumes:'. If no 'volumes:' exists, append one.
  awk -v svc="$svc" -v vol="$vol" '
    { print }
    /^services:[[:space:]]*$/ && !s { print svc; s=1 }
    /^volumes:[[:space:]]*$/  && !v { print vol; v=1 }
    END { if (!v) { print "volumes:"; print vol } }
  ' "$override" > "${override}.tmp" && mv "${override}.tmp" "$override"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-setup-federloom.sh`
Expected: all merge checks `ok` including `docker compose config` validation, exit 0.

- [ ] **Step 5: Add the orchestrating `merge_compose` wrapper (validate + restore)**

In `federloom/setup-federloom.sh`, add after `merge_compose_file`:

```bash
merge_compose() {
  local override="$MAILCOW_ROOT/docker-compose.override.yml"
  [[ -f "$override" ]] || die "No docker-compose.override.yml in $MAILCOW_ROOT — install the CrowdSec integration first."
  local before_bak
  before_bak="$(ls -1 "${override}".bak.* 2>/dev/null | wc -l)"
  merge_compose_file "$override"
  # Validate the merged result; restore the newest backup if it broke.
  if ! ( cd "$MAILCOW_ROOT" && docker compose config -q ) 2>/dev/null; then
    local newest
    newest="$(ls -1t "${override}".bak.* 2>/dev/null | head -1)"
    if [[ -n "$newest" && "$(ls -1 "${override}".bak.* 2>/dev/null | wc -l)" -gt "$before_bak" ]]; then
      cp "$newest" "$override"
      die "Merged docker-compose.override.yml failed validation — restored from $newest."
    fi
    die "docker-compose.override.yml failed validation."
  fi
  log "federloom service merged into docker-compose.override.yml."
}
```

- [ ] **Step 6: Syntax check**

Run: `bash -n federloom/setup-federloom.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add federloom/setup-federloom.sh tests/test-setup-federloom.sh
git commit -m "Add idempotent compose merge (backup + validate + restore) with tests"
```

---

## Task 6: Peer ID extraction helper (TDD)

**Files:**
- Modify: `federloom/setup-federloom.sh`
- Create: `tests/fixtures/federloom-peerid.log`
- Modify: `tests/test-setup-federloom.sh`

- [ ] **Step 1: Create the fixture**

Create `tests/fixtures/federloom-peerid.log`:

```
2026-10-04T10:00:00Z INFO starting federloomd
2026-10-04T10:00:01Z INFO host listening /ip4/0.0.0.0/tcp/7700
2026-10-04T10:00:01Z INFO peer ID: 12D3KooWABCDschema1234567890abcdefghijklmnopqrstuv
2026-10-04T10:00:02Z INFO ingest mailcow_logs enabled
```

- [ ] **Step 2: Add the failing test**

In `tests/test-setup-federloom.sh`, before `exit "$fail"`, add:

```bash
# --- extract_peer_id ---
pid="$(extract_peer_id < "$FIX/federloom-peerid.log")"
check "extract_peer_id reads peer ID" "$pid" "12D3KooWABCDschema1234567890abcdefghijklmnopqrstuv"
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/test-setup-federloom.sh`
Expected: FAIL (extract_peer_id not defined).

- [ ] **Step 4: Implement `extract_peer_id`**

In `federloom/setup-federloom.sh`, add after `merge_compose`:

```bash
extract_peer_id() {
  # Reads federloom logs on stdin; prints the last "peer ID:" value or nothing.
  grep 'peer ID:' | tail -1 | awk '{print $NF}'
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/test-setup-federloom.sh`
Expected: `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add federloom/setup-federloom.sh tests/
git commit -m "Add peer ID extraction helper with tests"
```

---

## Task 7: Fetch, detect/confirm, bouncer, start, federation-join (runtime wiring)

These functions require live Docker/network and are not unit-tested; they are
syntax-checked and exercised during the live verification in Task 9. Implement
each completely.

**Files:**
- Modify: `federloom/setup-federloom.sh`

- [ ] **Step 1: Implement `fetch_upstream`**

Add after `extract_peer_id`:

```bash
fetch_upstream() {
  # Fetches only the static upstream files into $TMPDIR_FL: rules.yaml + federation.invite.
  TMPDIR_FL="$(mktemp -d)"
  if command -v git >/dev/null 2>&1; then
    git clone --quiet --depth 1 --filter=blob:none --sparse "$FEDERLOOM_REPO" "$TMPDIR_FL/repo" \
      || die "git clone of $FEDERLOOM_REPO failed."
    ( cd "$TMPDIR_FL/repo" && git sparse-checkout set deploy/mailcow >/dev/null 2>&1 ) \
      || die "sparse-checkout failed."
    cp "$TMPDIR_FL/repo/deploy/mailcow/rules.yaml" "$TMPDIR_FL/rules.yaml" \
      || die "rules.yaml not found in upstream."
    if [[ -f "$TMPDIR_FL/repo/federation.invite" ]]; then
      cp "$TMPDIR_FL/repo/federation.invite" "$TMPDIR_FL/federation.invite"
    fi
  else
    curl -fsSL "https://raw.githubusercontent.com/JoeRu/federloom/main/deploy/mailcow/rules.yaml" \
      -o "$TMPDIR_FL/rules.yaml" || die "curl of rules.yaml failed."
    curl -fsSL "https://raw.githubusercontent.com/JoeRu/federloom/main/federation.invite" \
      -o "$TMPDIR_FL/federation.invite" || warn "federation.invite not fetched; join step will print manual steps."
  fi
  log "Fetched upstream rules.yaml$( [[ -f "$TMPDIR_FL/federation.invite" ]] && echo ' + federation.invite' )."
}
```

- [ ] **Step 2: Implement `detect_and_confirm`**

Add after `fetch_upstream`:

```bash
detect_and_confirm() {
  POSTFIX_CTR="$(detect_container postfix || true)"; POSTFIX_CTR="${POSTFIX_CTR:-mailcowdockerized-postfix-mailcow-1}"
  DOVECOT_CTR="$(detect_container dovecot || true)"; DOVECOT_CTR="${DOVECOT_CTR:-mailcowdockerized-dovecot-mailcow-1}"
  PUBLIC_IP="$(curl -fsS --max-time 5 https://ifconfig.co 2>/dev/null || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if command -v tailscale >/dev/null 2>&1; then
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  fi
  # Prefer the Mailcow-configured network if present.
  local net
  net="$(grep -E '^IPV4_NETWORK=' "$MAILCOW_ROOT/mailcow.conf" 2>/dev/null | cut -d= -f2 || true)"
  [[ -n "$net" ]] && MAILCOW_NETWORK="${net}.0/24"

  cat <<EOF

Detected configuration:
  Public IP        : ${PUBLIC_IP:-<none>}
  Tailscale IP     : ${TAILSCALE_IP:-<none>}
  Mailcow network  : ${MAILCOW_NETWORK}
  Docker bridge    : ${DOCKER_BRIDGE}
  CrowdSec ctr     : ${CROWDSEC_CTR}
  Postfix ctr      : ${POSTFIX_CTR}
  Dovecot ctr      : ${DOVECOT_CTR}
EOF
  if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "Proceed with these values? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted by user. Re-run and edit values, or set them via env before running."
  fi
}
```

- [ ] **Step 3: Implement `register_bouncer`**

Add after `detect_and_confirm`:

```bash
register_bouncer() {
  if docker exec "$CROWDSEC_CTR" cscli bouncers list 2>/dev/null | grep -q '\bfederloom\b'; then
    warn "A CrowdSec bouncer named 'federloom' already exists. Reusing it; its key cannot be re-read."
    warn "If you need a fresh key: docker exec $CROWDSEC_CTR cscli bouncers delete federloom, then re-run."
    CROWDSEC_ENABLED="true"; API_KEY=""
    return 0
  fi
  local raw
  raw="$(docker exec "$CROWDSEC_CTR" cscli bouncers add federloom 2>&1 || true)"
  API_KEY="$(printf '%s\n' "$raw" | extract_api_key)"
  if [[ -z "$API_KEY" ]]; then
    warn "Could not extract the CrowdSec API key automatically. CrowdSec ingest left disabled."
    warn "Run: docker exec $CROWDSEC_CTR cscli bouncers add federloom"
    warn "Then set api_key in $MAILCOW_ROOT/federloom/config.local.yaml and restart federloom."
    CROWDSEC_ENABLED="false"
  else
    CROWDSEC_ENABLED="true"
    log "Registered CrowdSec bouncer 'federloom'."
  fi
}
```

- [ ] **Step 4: Implement `install_files`**

Add after `register_bouncer`:

```bash
install_files() {
  local dir="$MAILCOW_ROOT/federloom"
  mkdir -p "$dir"
  cp "$TMPDIR_FL/rules.yaml" "$dir/rules.yaml"
  generate_config "$dir/config.local.yaml"
  chmod 600 "$dir/config.local.yaml"
  log "Wrote $dir/rules.yaml and $dir/config.local.yaml."
}
```

- [ ] **Step 5: Implement `start_and_report`**

Add after `install_files`:

```bash
start_and_report() {
  ( cd "$MAILCOW_ROOT" && docker compose up -d federloom ) || die "Failed to start federloom."
  sleep 10
  local peer
  peer="$(cd "$MAILCOW_ROOT" && docker compose logs federloom 2>/dev/null | extract_peer_id || true)"
  echo ""
  if [[ -n "$peer" ]]; then
    log "FederLoom is running."
    echo "  Peer ID  : $peer"
    echo "  Multiaddr: /ip4/${PUBLIC_IP:-<your-ip>}/tcp/7700/p2p/$peer"
  else
    warn "Could not read the peer ID yet. Check: cd $MAILCOW_ROOT && docker compose logs federloom"
  fi
  echo ""
  echo "NOTE: open inbound tcp/7700 in your firewall for full p2p peering."
}
```

- [ ] **Step 6: Implement `offer_federation_join`**

Add after `start_and_report`:

```bash
offer_federation_join() {
  echo ""
  echo "Optional: join the maintainer's FederLoom federation (federloom.jru.me honeypot)."
  echo "  Verify this fingerprint out-of-band before joining: ${FINGERPRINT}"
  if [[ ! -f "$TMPDIR_FL/federation.invite" ]]; then
    warn "No federation.invite was fetched. To join manually later:"
    echo "  docker compose cp federation.invite federloom:/tmp/federation.invite"
    echo "  docker compose exec federloom federloomctl federation join /tmp/federation.invite --config /etc/federloom/config.yaml"
    return 0
  fi
  read -r -p "Join the federation now? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    ( cd "$MAILCOW_ROOT" \
      && docker compose cp "$TMPDIR_FL/federation.invite" federloom:/tmp/federation.invite \
      && docker compose exec -T federloom federloomctl federation join /tmp/federation.invite \
           --config /etc/federloom/config.yaml ) \
      && log "Joined the federation." \
      || warn "Federation join failed — you can retry the two commands above manually."
  else
    log "Skipped federation join. The invite is at $TMPDIR_FL/federation.invite (temporary)."
  fi
}
```

- [ ] **Step 7: Wire the pipeline and cleanup into `main`**

Replace the `main` body's comment line with the full pipeline, and add a trap:

```bash
cleanup() { [[ -n "$TMPDIR_FL" && -d "$TMPDIR_FL" ]] && rm -rf "$TMPDIR_FL"; }

main() {
  parse_args "$@"
  preflight
  trap cleanup EXIT
  fetch_upstream
  detect_and_confirm
  register_bouncer
  install_files
  merge_compose
  start_and_report
  offer_federation_join
}
```

- [ ] **Step 8: Syntax check and run the unit tests (functions still source-able)**

Run:
```bash
bash -n federloom/setup-federloom.sh
bash tests/test-setup-federloom.sh
```
Expected: `bash -n` clean; all unit tests still `ok` (sourcing runs no live steps because `main` is guarded).

- [ ] **Step 9: Commit**

```bash
git add federloom/setup-federloom.sh
git commit -m "Wire FederLoom setup pipeline: fetch, detect, bouncer, install, start, join"
```

---

## Task 8: .gitignore + README

**Files:**
- Modify: `.gitignore`
- Modify: `README.md`

- [ ] **Step 1: Read current .gitignore**

Run: `cat .gitignore`
Expected: shows existing entries (currently ignores `cs-firewall-bouncer.yaml`).

- [ ] **Step 2: Append FederLoom secret-bearing files to .gitignore**

Add these lines to `.gitignore`:

```
# FederLoom generated config (contains the CrowdSec API key)
federloom/config.local.yaml
# docker-compose.override.yml backups made by setup-federloom.sh
docker-compose.override.yml.bak.*
```

- [ ] **Step 3: Verify the ignore works**

Run:
```bash
mkdir -p federloom && : > federloom/config.local.yaml
git check-ignore federloom/config.local.yaml && rm -f federloom/config.local.yaml
```
Expected: prints `federloom/config.local.yaml` (ignored). Remove the probe file.

- [ ] **Step 4: Add the README "post_update_hook" section**

In `README.md`, after the "Upgrading the bouncer" section (ends before "## Compatibility with Mailcow updates"), insert:

```markdown
## Keeping the bouncer current after Mailcow updates

Mailcow runs `post_update_hook.sh` from the install root at the end of every
`./update.sh`. Copy the example so the firewall bouncer is rebuilt (and re-fetches
its latest release) automatically after each Mailcow update:

```bash
cp post_update_hook.sh.example /opt/mailcow-dockerized/post_update_hook.sh
chmod +x /opt/mailcow-dockerized/post_update_hook.sh
```

The hook also pulls and restarts FederLoom if it is installed (see below); it is a
no-op otherwise.
```

- [ ] **Step 5: Add the README "Optional: FederLoom" section**

In `README.md`, after the new post_update_hook section, insert:

```markdown
## Optional: FederLoom federated reputation sharing

[FederLoom](https://github.com/JoeRu/federloom) is a decentralized, federated
IP-reputation sidecar. Where CrowdSec shares intel through its **central**
community network, FederLoom shares trust-weighted reputation **peer-to-peer**
between self-hosted servers. It runs alongside this CrowdSec integration —
CrowdSec for local detection and enforcement, FederLoom for federated intel — and
consumes the same local CrowdSec LAPI.

A helper script installs and auto-configures it:

```bash
cd /opt/mailcow-dockerized   # or wherever this repo's files were copied
./federloom/setup-federloom.sh /opt/mailcow-dockerized
```

The script auto-detects your public IP, Tailscale IP, Docker networks, and
Mailcow container names and asks you to confirm before applying. It registers a
CrowdSec bouncer named `federloom`, writes `federloom/config.local.yaml` (which is
gitignored — it holds the API key), fetches `rules.yaml` from upstream, merges a
`federloom` service into your existing `docker-compose.override.yml` (after a
timestamped backup), and starts the container. Re-running it is safe.

After it starts, open inbound **tcp/7700** in your firewall for full peer-to-peer
federation.

### Joining the maintainer's federation

The script offers (opt-in) to join the `federloom.jru.me` honeypot federation
using the bundled trust invite. Verify this fingerprint out-of-band first:

```
79bb d13a 114b 88fe
```

To join later by hand:

```bash
cd /opt/mailcow-dockerized
docker compose cp federation.invite federloom:/tmp/federation.invite
docker compose exec federloom federloomctl federation join /tmp/federation.invite \
    --config /etc/federloom/config.yaml
```
```

- [ ] **Step 6: Commit**

```bash
git add .gitignore README.md
git commit -m "Document post_update_hook and FederLoom setup; gitignore federloom secrets"
```

---

## Task 9: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Syntax-check both scripts**

Run:
```bash
bash -n post_update_hook.sh.example
bash -n federloom/setup-federloom.sh
```
Expected: both clean, exit 0.

- [ ] **Step 2: Run the full test suite**

Run: `bash tests/test-setup-federloom.sh`
Expected: all `ok`, exit 0.

- [ ] **Step 3: Confirm the merged override validates end-to-end**

Run:
```bash
work="$(mktemp -d)"; cp docker-compose.override.yml "$work/dco.yml"
PUBLIC_IP=203.0.113.5 bash -c '
  source federloom/setup-federloom.sh
  PUBLIC_IP=203.0.113.5
  merge_compose_file "'"$work"'/dco.yml"
'
( cd "$work" && docker compose -f dco.yml config --services )
rm -rf "$work"
```
Expected: service list includes `crowdsec`, `cs-firewall-bouncer`, and `federloom`.

- [ ] **Step 4: Live install (on the Mailcow host — documented, run by the user)**

Run on the host:
```bash
cd /opt/mailcow-dockerized
./federloom/setup-federloom.sh /opt/mailcow-dockerized
docker compose config --services | grep -x federloom
docker exec mailcowdockerized-crowdsec-1 cscli bouncers list | grep federloom
grep -q 'api_key' federloom/config.local.yaml && echo "config ok"
docker compose logs federloom | grep 'peer ID:'
```
Expected: `federloom` listed as a service; bouncer registered; config has a key;
a peer ID appears in the logs.

- [ ] **Step 5: Push**

```bash
git push
```

---

## Self-Review

**Spec coverage:**
- post_update_hook.sh.example (hardened, bouncer + guarded federloom) → Task 1. ✔
- README post_update_hook section → Task 8 Step 4. ✔
- Setup script location `federloom/setup-federloom.sh` → Task 2. ✔
- Preflight (MAILCOW_ROOT default/arg/env, mailcow checks, tool checks, crowdsec running) → Task 2. ✔
- Fetch upstream (git sparse + curl fallback; rules.yaml + federation.invite) → Task 7 Step 1. ✔ (refined: config.yaml no longer fetched — generated instead; documented in header note.)
- Auto-detect + confirm (public IP, tailscale, CIDRs from mailcow.conf, container names) → Task 7 Step 2. ✔
- CrowdSec bouncer registration, idempotent, key extraction + graceful failure → Task 3 + Task 7 Step 3. ✔
- Generate config.local.yaml with enforce.extra_whitelist + crowdsec block → Task 4. ✔
- Compose merge: backup, idempotent, yq-or-text (resolved to robust text insert), validate + restore → Task 5. ✔ (yq dropped; text-insert + `docker compose config` validation is more portable and was the user-approved "auto-merge with backup".)
- Start & report peer ID + tcp/7700 note → Task 6 + Task 7 Step 5. ✔
- Opt-in federation join with fingerprint, --yes does not auto-join → Task 7 Step 6. ✔
- config.local.yaml gitignored → Task 8. ✔
- README FederLoom section incl. fingerprint → Task 8 Step 5. ✔
- Idempotency & safety, never modifies Mailcow files → Tasks 5/7 (merge touches only override; files land under federloom/). ✔
- Testing approach (bash -n, idempotency fixture, live) → Tasks 1–9. ✔

**Placeholder scan:** No TBD/TODO; every code step shows complete content; commands have expected output.

**Type/name consistency:** Function names referenced across tasks are consistent: `detect_container`, `extract_api_key`, `generate_config`, `merge_compose_file`, `merge_compose`, `extract_peer_id`, `fetch_upstream`, `detect_and_confirm`, `register_bouncer`, `install_files`, `start_and_report`, `offer_federation_join`, `cleanup`, `main`. Globals (`PUBLIC_IP`, `TAILSCALE_IP`, `MAILCOW_NETWORK`, `DOCKER_BRIDGE`, `POSTFIX_CTR`, `DOVECOT_CTR`, `CROWDSEC_ENABLED`, `API_KEY`, `CROWDSEC_CTR`, `TMPDIR_FL`, `MAILCOW_ROOT`, `ASSUME_YES`) are declared in Task 2 and used consistently. The compose service mounts `config.local.yaml` as `/etc/federloom/config.yaml` and `rules.yaml` as `/etc/federloom/rules.yaml`, matching what `install_files` writes and `generate_config` references (`rules_file: /etc/federloom/rules.yaml`).

**Deviations from spec (intentional, noted):** (1) config.yaml is generated as config.local.yaml rather than fetched, because upstream mounts the generated config *as* config.yaml. (2) Compose merge uses portable text-insertion + `docker compose config` validation instead of `yq`, since `yq` is not guaranteed present; behavior (auto-merge with backup) matches the user's choice.
