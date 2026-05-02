# Mailcow CrowdSec Integration

Adds [CrowdSec](https://crowdsec.net/) threat detection and IP banning to a [Mailcow Dockerized](https://github.com/mailcow/mailcow-dockerized) installation via `docker-compose.override.yml` — no changes to Mailcow's own files, fully upgrade-safe.

## What this does

- **Detects** brute-force attacks on SMTP (Postfix), IMAP/POP3 (Dovecot), and the web UI (nginx) by reading their Docker logs
- **Bans** attacking IPs at the iptables level (INPUT, FORWARD, DOCKER-USER chains) using ipsets — blocks before traffic reaches any service
- **Shares** threat intelligence with the CrowdSec community network, pulling a live blocklist of known bad actors
- **Zero Mailcow modifications** — everything is in `docker-compose.override.yml`, which Docker Compose merges automatically

## Architecture

```
Mailcow containers (nginx, postfix, dovecot)
        │ logs via Docker socket
        ▼
┌─────────────────────────────┐
│  crowdsec container         │  ← LAPI + agent, port 127.0.0.1:8080
│  reads logs, detects attacks│
│  maintains ban decisions    │
└────────────┬────────────────┘
             │ decisions via API
             ▼
┌─────────────────────────────┐
│  cs-firewall-bouncer        │  ← network_mode: host
│  enforces bans in iptables  │
│  INPUT / FORWARD / DOCKER-USER chains
└─────────────────────────────┘
```

## Prerequisites

- [Mailcow Dockerized](https://github.com/mailcow/mailcow-dockerized) installed and running
- Docker Compose v2
- Root or sudo access on the host

## Installation

### 1. Copy files into your Mailcow directory

```bash
cp docker-compose.override.yml /opt/mailcow-dockerized/
cp -r crowdsec/ /opt/mailcow-dockerized/
```

> If you already have a `docker-compose.override.yml` (e.g. for the Prometheus exporter), merge the `services:` and `volumes:` blocks manually instead of overwriting.

### 2. Adjust container names in acquis.yaml

Mailcow container names follow the pattern `<project>-<service>-<index>`. The default project name is `mailcowdockerized`, giving names like `mailcowdockerized-nginx-mailcow-1`.

Verify your actual container names:

```bash
docker ps --format '{{.Names}}' | grep mailcow
```

If your names differ, edit `/opt/mailcow-dockerized/crowdsec/acquis.yaml` accordingly.

### 3. Adjust whitelists

Edit `/opt/mailcow-dockerized/crowdsec/parsers/s02-enrich/whitelists.yaml` and add any IPs or CIDRs that should never be banned — your home IP, monitoring server, VPN range, etc.

### 4. Start CrowdSec

```bash
cd /opt/mailcow-dockerized
docker compose pull crowdsec
docker compose up -d crowdsec
```

Wait ~10 seconds for startup, then verify log acquisition:

```bash
docker exec mailcowdockerized-crowdsec-1 cscli metrics show acquisition
```

All three sources (nginx, postfix, dovecot) should show non-zero **Lines read**.

### 5. Generate the bouncer API key

```bash
BOUNCER_KEY=$(docker exec mailcowdockerized-crowdsec-1 cscli bouncers add firewall-bouncer -o raw)
echo "Key: $BOUNCER_KEY"
```

### 6. Create the bouncer config

```bash
cp /opt/mailcow-dockerized/crowdsec/cs-firewall-bouncer.yaml.example \
   /opt/mailcow-dockerized/crowdsec/cs-firewall-bouncer.yaml

# Replace the placeholder with the generated key:
sed -i "s/REPLACE_WITH_YOUR_BOUNCER_API_KEY/${BOUNCER_KEY}/" \
   /opt/mailcow-dockerized/crowdsec/cs-firewall-bouncer.yaml
```

### 7. Build and start the firewall bouncer

```bash
cd /opt/mailcow-dockerized
docker compose build cs-firewall-bouncer
docker compose up -d cs-firewall-bouncer
```

### 8. Verify

```bash
# Bouncer is registered and valid
docker exec mailcowdockerized-crowdsec-1 cscli bouncers list

# iptables chains exist
iptables -L INPUT | grep CROWDSEC
iptables -L FORWARD | grep CROWDSEC

# Active bans (may be empty immediately, populates within minutes)
docker exec mailcowdockerized-crowdsec-1 cscli decisions list
```

## Optional: Enroll in CrowdSec Console

The [CrowdSec Console](https://app.crowdsec.net) gives you a web UI to view alerts, bans, and threat intelligence across all your enrolled machines.

```bash
docker exec mailcowdockerized-crowdsec-1 cscli console enroll <your-enrollment-id>
```

Accept the enrollment at `https://app.crowdsec.net`, then restart CrowdSec:

```bash
cd /opt/mailcow-dockerized && docker compose restart crowdsec
```

## Usage

### Check active bans

```bash
docker exec mailcowdockerized-crowdsec-1 cscli decisions list
```

### View alerts (what triggered a ban)

```bash
docker exec mailcowdockerized-crowdsec-1 cscli alerts list
```

### Unban an IP (e.g. if you locked yourself out)

```bash
docker exec mailcowdockerized-crowdsec-1 cscli decisions delete --ip <ip>
```

### Ban an IP manually

```bash
docker exec mailcowdockerized-crowdsec-1 cscli decisions add --ip <ip> --reason "manual ban" --duration 24h
```

### Update CrowdSec hub (parsers and scenarios)

```bash
docker exec mailcowdockerized-crowdsec-1 cscli hub update
docker exec mailcowdockerized-crowdsec-1 cscli hub upgrade
docker compose restart crowdsec
```

### Add more collections (e.g. SSH brute force)

Edit `docker-compose.override.yml`, update the `COLLECTIONS` environment variable:

```yaml
COLLECTIONS: "crowdsecurity/nginx crowdsecurity/postfix crowdsecurity/dovecot crowdsecurity/sshd"
```

Then recreate the container:

```bash
cd /opt/mailcow-dockerized && docker compose up -d crowdsec
```

## Upgrading the bouncer

To update the bouncer to a newer version, change `ARG VERSION` in `crowdsec/Dockerfile.bouncer`, then rebuild:

```bash
cd /opt/mailcow-dockerized
docker compose build --no-cache cs-firewall-bouncer
docker compose up -d cs-firewall-bouncer
```

## Compatibility with Mailcow updates

Mailcow's `./update.sh` uses `docker compose` from the installation directory, which automatically merges `docker-compose.override.yml`. CrowdSec services are unaffected by Mailcow updates.

## File overview

```
docker-compose.override.yml                        ← drop into /opt/mailcow-dockerized/
crowdsec/
  acquis.yaml                                      ← log sources (adjust container names)
  Dockerfile.bouncer                               ← builds the firewall bouncer image
  cs-firewall-bouncer.yaml.example                 ← copy to .yaml and fill in API key
  parsers/s02-enrich/
    whitelists.yaml                                ← trusted IPs/CIDRs (adjust to your setup)
```

## Security notes

- `cs-firewall-bouncer.yaml` contains the LAPI API key — it is listed in `.gitignore` and must not be committed
- The bouncer runs with `network_mode: host` and `CAP_NET_ADMIN` / `CAP_NET_RAW` — required to manipulate iptables on the host
- The Docker socket (`/var/run/docker.sock`) is mounted read-only into the CrowdSec container for log reading — standard practice for log collectors

## References

- [CrowdSec Documentation](https://docs.crowdsec.net/)
- [CrowdSec Hub](https://hub.crowdsec.net/) — parsers, scenarios, collections
- [Mailcow Documentation](https://docs.mailcow.email/)
- [mailcow/mailcow-dockerized#4433](https://github.com/mailcow/mailcow-dockerized/issues/4433) — original integration discussion
