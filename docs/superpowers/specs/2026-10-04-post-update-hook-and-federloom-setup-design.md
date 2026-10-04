# Design: post_update_hook example + optional FederLoom setup script

**Date:** 2026-10-04
**Status:** Approved (design); pending spec review

## Overview

Two independent additions to the Mailcow-Crowdsec-Override repo:

1. A `post_update_hook.sh.example` that users copy into their Mailcow root so that
   Mailcow's `./update.sh` automatically rebuilds the firewall bouncer (and
   restarts FederLoom if installed) after each update.
2. An optional, self-contained setup script that installs and auto-configures
   [FederLoom](https://github.com/JoeRu/federloom) alongside the existing
   CrowdSec integration.

Both are opt-in. Neither changes any Mailcow-owned file. The repo's core
constraint holds: only `docker-compose.override.yml` and files under the repo
directory are touched on the live host.

**Mailcow root:** `/opt/mailcow-dockerized/` (confirmed).

## Part 1 — `post_update_hook.sh.example`

### Purpose

Mailcow's `./update.sh` executes `<MAILCOW_ROOT>/post_update_hook.sh` at the end
of an update if the file exists. The firewall bouncer is built from
`Dockerfile.bouncer`, which fetches the latest release at build time; a plain
`docker compose up` after an update will not pick up a new bouncer release
because the image layer is cached. This hook forces a `--no-cache` rebuild so the
bouncer stays current. It also pulls/restarts FederLoom when that service is
present.

### Deliverable

New file at repo root: `post_update_hook.sh.example`.

```bash
#!/usr/bin/env bash
# Mailcow post-update hook — place at <MAILCOW_ROOT>/post_update_hook.sh
# Runs automatically at the end of ./update.sh.
set -euo pipefail
cd "$(dirname "$0")"

# Rebuild the firewall bouncer so it re-fetches the latest release.
docker compose build --no-cache cs-firewall-bouncer
docker compose up -d cs-firewall-bouncer

# If FederLoom is installed, pull and restart it too (no-op otherwise).
if docker compose config --services 2>/dev/null | grep -qx federloom; then
  docker compose pull federloom
  docker compose up -d federloom
fi
```

Design notes:
- Hardened form (`set -euo pipefail`, `cd` to the script's directory) rather than
  the bare two-liner, so the hook fails loudly and runs from the correct dir
  regardless of Mailcow's invocation cwd.
- The FederLoom block is guarded by a service-existence check, so the same
  example works whether or not FederLoom is installed.

### README

Add a short "Keeping the bouncer current after Mailcow updates" section:
copy `post_update_hook.sh.example` to `<MAILCOW_ROOT>/post_update_hook.sh`,
`chmod +x` it, done. Note that it also handles FederLoom if present.

## Part 2 — FederLoom optional setup script

### Purpose

Provide a one-command, idempotent, locally-run installer that stands up FederLoom
(a decentralized / federated IP-reputation sidecar) next to the existing CrowdSec
services, auto-detecting host specifics and wiring FederLoom to the local CrowdSec
LAPI.

FederLoom's upstream `deploy/mailcow/` already contains `config.yaml`,
`rules.yaml`, a `docker-compose.override.yml` (federloom service only), and a
remote rsync/SSH `bootstrap-mailcow.sh`. The upstream bootstrap targets the
maintainer's push-to-remote workflow; this repo instead ships a **local**
installer meant to be run on the mailcow host itself.

### Delivery model

- Setup script lives in this repo at `federloom/setup-federloom.sh`.
- The script **fetches** FederLoom's deploy files from upstream at install time
  (no vendored copies of `config.yaml` / `rules.yaml` kept in this repo), so there
  is nothing to keep in sync. Fetch via sparse `git clone` of
  `https://github.com/JoeRu/federloom` (fallback: `curl` the raw files).
- Requires network access to GitHub at install time.

### Behavior (ordered steps)

1. **Preflight**
   - Resolve `MAILCOW_ROOT`: first positional arg, else `$MAILCOW_ROOT` env, else
     default `/opt/mailcow-dockerized/`.
   - Verify the dir looks like a Mailcow install (`docker-compose.yml` +
     `mailcow.conf` present).
   - Verify required tools: `docker`, and one of `git`/`curl`.
   - Verify the CrowdSec container is running (name auto-detected via
     `docker ps`, default `mailcowdockerized-crowdsec-1`); abort with guidance if
     not — FederLoom's CrowdSec ingest depends on it.

2. **Fetch upstream deploy files**
   - Sparse-checkout `deploy/mailcow` from `JoeRu/federloom` into a temp dir.
   - Copy `config.yaml` and `rules.yaml` into `<MAILCOW_ROOT>/federloom/`
     (do not overwrite an existing `config.yaml`/`rules.yaml` without confirming).
   - Keep the fetched upstream `docker-compose.override.yml` in the temp dir for
     the compose-merge step.

3. **Auto-detect + confirm**
   Detect and present a confirmation table:
   - Public IPv4 (`curl -s https://ifconfig.co` or similar; allow manual override)
   - Tailscale IPv4 (`tailscale ip -4` if the binary exists; else skip)
   - Mailcow Docker network CIDR (default `172.22.1.0/24`, read from
     `mailcow.conf` `IPV4_NETWORK` if present)
   - Docker default bridge CIDR (default `172.17.0.0/16`)
   - CrowdSec / Postfix / Dovecot container names (from `docker ps` name match)

   Print the detected values and prompt the user to confirm or edit before
   applying. Non-interactive mode (`--yes`) accepts detected values.

4. **Register CrowdSec bouncer**
   - If a bouncer named `federloom` already exists (`cscli bouncers list`), reuse
     it / warn; otherwise `cscli bouncers add federloom -o raw` to capture the
     API key. Handle extraction failure gracefully (print manual instructions,
     continue with CrowdSec ingest left disabled).

5. **Write `config.local.yaml`**
   - Generate `<MAILCOW_ROOT>/federloom/config.local.yaml` (merged with the
     fetched `config.yaml` at FederLoom runtime). It contains only the host- and
     secret-specific overrides:
     - `ingest.crowdsec.enabled: true`, `lapi_url`, `api_key: <key>`
     - whitelist entries for the detected public IP, Tailscale IP, Docker CIDRs
     - the detected `postfix_container` / `dovecot_container` names if they differ
       from upstream defaults
   - `config.local.yaml` must never be committed — add it (and any secret-bearing
     federloom files) to `.gitignore`.

6. **Merge compose (auto-merge with backup)**
   - Back up `<MAILCOW_ROOT>/docker-compose.override.yml` to
     `docker-compose.override.yml.bak.<timestamp>`.
   - If a `federloom:` service already exists in the override, skip (idempotent).
   - Otherwise merge the `federloom` service and the `federloom-data` volume from
     the fetched upstream override into the existing override:
     - Preferred: structural merge with `yq` when available.
     - Fallback (no `yq`): text-append the federloom service under `services:`
       and the `federloom-data:` entry under `volumes:`, wrapped in
       `# >>> federloom >>>` / `# <<< federloom <<<` marker comments for clean
       idempotent detection and removal.

7. **Start & report**
   - `cd <MAILCOW_ROOT> && docker compose up -d federloom`.
   - Print the FederLoom peer ID / multiaddr (from the container) and the reminder
     to open **tcp/7700** inbound for p2p federation.
   - Print next-step notes: spamtrap stays disabled by default; CrowdSec ingest is
     now enabled.

### Idempotency & safety

- Re-running the script is safe: existing bouncer reused, existing federloom
  service detected and skipped, config files not clobbered without confirmation.
- Every edit to `docker-compose.override.yml` is preceded by a timestamped backup.
- Secrets (`config.local.yaml`) are gitignored.
- The script never modifies Mailcow-owned files.

### README

Add an "Optional: FederLoom federated reputation sharing" section: one-paragraph
explanation of what FederLoom is and that it is independent of and complementary
to CrowdSec, the single `./federloom/setup-federloom.sh` command, the tcp/7700
firewall note, and how to confirm it is running.

## Testing approach

This is shell-script + docs work against Docker/CrowdSec, which cannot be fully
unit-tested in this repo. Verification strategy:

- **Static:** `bash -n` syntax check and `shellcheck` on both scripts.
- **Dry-run guards:** confirm the compose-merge marker logic is idempotent by
  running the merge function twice against a sample override fixture and diffing.
- **Live (on the user's host, documented):** run the setup script on the mailcow
  host, confirm `docker compose config --services` lists `federloom`, the bouncer
  is registered, `config.local.yaml` has the key, and the container starts and
  reports a peer ID. Confirm the post_update_hook runs clean via `./update.sh`
  (or by invoking the hook directly).

## Out of scope

- Vendoring FederLoom's `config.yaml` / `rules.yaml` into this repo (we fetch).
- Replicating upstream's SSH/rsync remote-deploy bootstrap.
- Enabling the spamtrap ingest (left disabled; documented as a follow-up).
- Any change to the existing CrowdSec parsers/scenarios.

## Repository workflow reminder

Per CLAUDE.md: when changing live files, edit both the live copy under
`<MAILCOW_ROOT>/` and the repo copy, restart/verify, then commit and push from the
repo root. For these additions the deliverables are repo files
(`post_update_hook.sh.example`, `federloom/setup-federloom.sh`, README, `.gitignore`);
they are deployed to the host by the user following the README.
