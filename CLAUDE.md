# CrowdSec + Mailcow Integration — Claude Code Context

This repository provides a non-invasive CrowdSec integration for [Mailcow Dockerized](https://github.com/mailcow/mailcow-dockerized) via `docker-compose.override.yml`. No Mailcow files are modified — fully upgrade-safe.

## Live Installation

> **Before doing any work, ask the user:** "Where is your Mailcow installation? (default: `/opt/mailcow-dockerized/`)"
> Use that path everywhere below in place of `<MAILCOW_ROOT>`.

- **Mailcow root:** `<MAILCOW_ROOT>` (ask user — commonly `/opt/mailcow-dockerized/`)
- **CrowdSec container:** `mailcowdockerized-crowdsec-1` (prefix matches the Docker Compose project name — verify with `docker ps | grep crowdsec`)
- **Bouncer container:** `mailcowdockerized-cs-firewall-bouncer-1`

When making changes: edit both the live files under `<MAILCOW_ROOT>/crowdsec/` **and** the repo copies in this directory, then commit and push.

## File Map

```
docker-compose.override.yml                         ← two services: crowdsec + cs-firewall-bouncer
crowdsec/
  acquis.yaml                                       ← log sources: nginx, postfix, dovecot
  Dockerfile.bouncer                                ← builds cs-firewall-bouncer:local image
  cs-firewall-bouncer.yaml.example                  ← template; live copy at .yaml (gitignored)
  parsers/
    s01-parse/
      postfix-auth-failures.yaml                    ← custom: parses disconnect auth=0/N lines
    s02-enrich/
      whitelists.yaml                               ← trusted IPs/CIDRs (localhost, Docker, Tailscale)
  scenarios/
    postfix-sasl-brute-world.yaml                   ← custom: non-DE IPs, ban on 1st failed connection
    postfix-sasl-brute-de.yaml                      ← custom: DE IPs, ban after 3 failed connections within 1h
```

## Architecture

```
postfix/dovecot/nginx containers
        │ logs via /var/run/docker.sock
        ▼
  crowdsec container (LAPI + agent, 127.0.0.1:8080)
  - crowdsecurity/postfix-logs parser  → spam-attempt events
  - local/postfix-auth-failures parser → spam-attempt events from disconnect lines
  - local/postfix-sasl-brute scenario  → ban on 3+ events from same IP within 2h
  - crowdsecurity/dovecot + nginx scenarios also active
        │ decisions via HTTP API
        ▼
  cs-firewall-bouncer (network_mode: host, CAP_NET_ADMIN)
  - iptables ipsets (hash:net, O(1) lookup)
  - Chains: CROWDSEC in INPUT, FORWARD, DOCKER-USER
```

## Custom Components (this repo adds these)

### `parsers/s01-parse/postfix-auth-failures.yaml`
Catches `disconnect from unknown[x.x.x.x] ... auth=0/N` lines (failed auth, N attempts, 0 successes). Emits a second `spam-attempt` event per attack connection, doubling the event count per bot to make the scenario fire.

**Why needed:** The upstream `crowdsecurity/postfix-logs` parser only catches the `SASL LOGIN authentication failed` warning line — one event per attack. Single-attempt bots never trigger the default `postfix-spam` scenario (needs 5 events in 10s).

### `scenarios/postfix-sasl-brute-world.yaml` and `postfix-sasl-brute-de.yaml`

Two geo-split scenarios replace the previous single scenario. Each SMTP auth failure produces 2 `spam-attempt` events: one from the SASL warning line (upstream parser) and one from the disconnect `auth=0/N` line (custom parser).

**World (non-DE):**
```yaml
filter: "evt.Meta.log_type_enh == 'spam-attempt' && evt.Enriched.IsoCode != 'DE'"
capacity: 1      # overflow on 2nd event = ban on 1st failed connection
leakspeed: "1h"
```
First failed connection → 2 events → event 2 overflows → immediate ban. Also catches rotating-IP campaigns (e.g. Cloudflare WARP bots) that previously evaded the old capacity:2 threshold.

**Germany:**
```yaml
filter: "evt.Meta.log_type_enh == 'spam-attempt' && evt.Enriched.IsoCode == 'DE'"
capacity: 4      # overflow on 5th event = ban on 3rd failed connection
leakspeed: "1h"
```
Connection 1: events 1+2 (bucket 2/4). Connection 2: events 3+4 (bucket 4/4, full). Connection 3: event 5 → overflow → ban. Allows two genuine mistype attempts before banning.

Country detection uses `evt.Enriched.IsoCode` set by `crowdsecurity/geoip-enrich`. IPs with no country data (private ranges, lookup failures) fall into the world scenario.

### `parsers/s02-enrich/whitelists.yaml`
Critical entries:
- `172.22.1.0/24` — Mailcow Docker IPv4 network
- `172.16.0.0/12` — all Docker bridge ranges
- `fc00::/7` — Docker ULA IPv6 (fd4d:6169:6c63:6f77::/64 falls in this range)
- `100.64.0.0/10` — Tailscale CGNAT range
- `100.120.31.14` — this host's Tailscale IP

## Common Operations

### Verify everything is working
```bash
# Parser and scenario loaded
docker exec mailcowdockerized-crowdsec-1 cscli parsers list | grep postfix-auth
docker exec mailcowdockerized-crowdsec-1 cscli scenarios list | grep sasl-brute

# Active bans and their reason
docker exec mailcowdockerized-crowdsec-1 cscli decisions list

# Parser hit counts
docker exec mailcowdockerized-crowdsec-1 cscli metrics show parsers | grep postfix

# Scenario overflow count
docker exec mailcowdockerized-crowdsec-1 cscli metrics show scenarios | grep sasl-brute

# iptables chains exist
iptables -L INPUT | grep CROWDSEC
ipset list crowdsec-blacklists-0 | tail -5
```

### Apply changes to parser or scenario
```bash
# After editing the yaml files:
docker compose -f <MAILCOW_ROOT>/docker-compose.yml \
               -f <MAILCOW_ROOT>/docker-compose.override.yml \
               restart crowdsec
```

### Recreate containers (after docker-compose.override.yml changes)
```bash
cd <MAILCOW_ROOT>
docker compose up -d --force-recreate crowdsec
docker compose up -d --force-recreate cs-firewall-bouncer
```

### Unban an IP
```bash
docker exec mailcowdockerized-crowdsec-1 cscli decisions delete --ip <ip>
```

### Check CrowdSec logs for errors
```bash
docker logs mailcowdockerized-crowdsec-1 2>&1 | grep -i "error\|warn" | tail -20
```

## Checking Effectiveness

Use these commands to judge whether CrowdSec is actively protecting the server.

### Overall ban count and breakdown by scenario
```bash
# How many IPs are banned right now and why
docker exec mailcowdockerized-crowdsec-1 cscli decisions list

# Count bans per scenario
docker exec mailcowdockerized-crowdsec-1 cscli decisions list -o json \
  | jq 'group_by(.reason) | map({reason: .[0].reason, count: length}) | sort_by(-.count)'
```

### How many attacks each scenario has caught (since container start)
```bash
docker exec mailcowdockerized-crowdsec-1 cscli metrics show scenarios
```
Key columns: **Current Count** (events in open buckets), **Overflows** (bans triggered), **Poured** (total events processed). If `local/postfix-sasl-brute` shows zero Overflows after 30+ minutes of postfix traffic, the parser is not feeding it — check parser metrics.

### Parser activity — confirm both postfix parsers are firing
```bash
docker exec mailcowdockerized-crowdsec-1 cscli metrics show parsers | grep -A3 postfix
```
- `crowdsecurity/postfix-logs` — upstream parser, catches SASL warning lines
- `child-local/postfix-auth-failures` — custom parser, catches disconnect auth=0/N lines

Both should have non-zero **Parsed** counts. If `postfix-auth-failures` shows zero, check that the file is mounted and CrowdSec was restarted after adding it.

### How many raw log lines are being read per service
```bash
docker exec mailcowdockerized-crowdsec-1 cscli metrics show acquisition
```
All three sources (nginx, postfix, dovecot) must show non-zero **Lines read**. Zero means the container name in `acquis.yaml` doesn't match the running container.

### Confirm bans are actually blocked at the firewall
```bash
# Number of IPs in each ipset
ipset list crowdsec-blacklists-0 | grep -c "^[0-9]"
ipset list crowdsec-blacklists-0-6 | grep -c "^[0-9]"   # IPv6 set

# Verify CROWDSEC_CHAIN is referenced in INPUT and DOCKER-USER
iptables -L INPUT --line-numbers | grep CROWDSEC
iptables -L DOCKER-USER --line-numbers | grep CROWDSEC
```
The ipset count should be ≥ the number of active decisions (community blocklist IPs are also included).

### Recent alerts with context (what triggered each ban)
```bash
docker exec mailcowdockerized-crowdsec-1 cscli alerts list --limit 20
```

### Interpret the numbers
- **Bans from `crowdsecurity/` scenarios** (postfix-spam, dovecot, nginx-scan-control) — community detections
- **Bans from `local/postfix-sasl-brute`** — custom single-attempt brute force detections; these are the ones this integration adds on top
- **`ip:crowdsec` decisions** — IPs pre-banned via community threat intelligence (no local attack needed)

If local scenario bans are low but the postfix log shows many SASL failures, check the scenario metrics — the bucket may be filling but not overflowing (capacity/leakspeed tuning needed).

## Key Design Constraints

1. **Never modify Mailcow's own files** — only `docker-compose.override.yml` and the `crowdsec/` directory alongside it.
2. **`cs-firewall-bouncer.yaml` must never be committed** — it contains the LAPI API key. It is in `.gitignore`. Use `cs-firewall-bouncer.yaml.example` as the template.
3. **The bouncer uses iptables mode** (not nftables) — required for Docker compatibility. The `DOCKER-USER` chain is critical; without it Docker's FORWARD rules bypass the ban.
4. **ipsets scale to ~400k IPs** across 4 sets (maxelem 131072 each) with O(1) lookup — not a performance concern.

## Scenario Tuning Reference

Each failed SMTP connection produces **2 events** (SASL warning + disconnect). This determines how `capacity` maps to connection counts:

| `capacity` | Events to overflow | Failed connections to ban |
|-----------|-------------------|--------------------------|
| 1 | 2 | 1 (immediate) |
| 3 | 4 | 2 |
| 4 | 5 | 3 |
| 5 | 6 | 3 |

| Setting | World | DE | Effect of changing |
|---------|-------|-----|-------------------|
| `capacity` | 1 | 4 | Lower → ban sooner; higher → more lenient |
| `leakspeed` | 1h | 1h | Shorter → tighter window; longer → forgiving across time |
| `blackhole` | 2m | 2m | Prevents double-banning on rapid disconnects |

To add more countries to the lenient group, extend the DE scenario filter: `evt.Enriched.IsoCode in ['DE', 'AT', 'CH']`.

## Repository Workflow

When changing any live file:
1. Edit the live file: `<MAILCOW_ROOT>/crowdsec/<path>`
2. Copy to repo: `<repo-root>/crowdsec/<path>`
3. Restart CrowdSec if parser/scenario changed
4. Verify the change worked (`cscli metrics`, `cscli decisions list`)
5. Commit and push from the repo root
