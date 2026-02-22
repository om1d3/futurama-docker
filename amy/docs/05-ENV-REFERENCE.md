# amy environment variable reference

## complete .env documentation

**document version:** 3.0
**infrastructure version:** 99
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [variable categories](#variable-categories)
3. [complete variable reference](#complete-variable-reference)
4. [variables referenced in docker-compose.yaml](#variables-referenced-in-docker-composeyaml)
5. [variables used outside docker-compose](#variables-used-outside-docker-compose)
6. [security classification](#security-classification)
7. [generating secure values](#generating-secure-values)

---

## overview

the `.env` file at `/docker-compose/.env` contains all configuration values and secrets for amy's docker compose deployment. it is loaded automatically by `docker compose` and also sourced by the secure-container-update.sh script.

the file contains 16 variables across 9 categories. of these, 7 contain secrets and 9 are non-sensitive configuration values.

---

## variable categories

| category | count | secrets |
|----------|-------|---------|
| system | 3 | 0 |
| network | 2 | 0 |
| tailscale | 1 | 1 |
| postgresql | 1 | 1 |
| pihole | 1 | 1 |
| miniflux | 2 | 1 |
| spendspentspent | 1 | 1 |
| beszel | 2 | 2 |
| diun | 1 | 0 |
| keepalived | 2 | 1 |
| **total** | **16** | **7** |

---

## complete variable reference

### system

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `TIMEZONE` | `America/Toronto` | no | dockwatch, pihole, ntfy, stirling, mealie, lubelogger, spendspentspent, limdius, telegraf, diun |
| `PUID` | `1000` | no | dockwatch, filebrowser, mealie |
| `PGID` | `1000` | no | same as PUID |

### network

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `AMY_HOST_IP` | `192.168.21.130` | no | tsdproxy (TSDPROXY_HOSTNAME) |
| `TAILSCALE_DOMAIN` | `bunny-enigmatic.ts.net` | no | mealie (BASE_URL) |

### tailscale

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `TSDPROXY_AUTHKEY` | `tskey-auth-...` | **yes** | tsdproxy |

### postgresql

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `POSTGRES_PASSWORD` | (random string) | **yes** | postgres, postgres-backup, atuin, miniflux, mealie, spendspentspent |

### pihole

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `PIHOLE_PASSWORD` | (random string) | **yes** | pihole (WEBPASSWORD) |

### miniflux

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `MINIFLUX_ADMIN_USERNAME` | `miniflux` | no | miniflux (ADMIN_USERNAME) |
| `MINIFLUX_ADMIN_PASSWORD` | (random string) | **yes** | miniflux (ADMIN_PASSWORD) |

### spendspentspent

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `SSS_SALT` | (random string) | **yes** | spendspentspent (SALT) |

### beszel

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `BESZEL_KEY` | `ssh-ed25519 AAAA...` | **yes** | beszel-agent (KEY) |
| `BESZEL_TOKEN` | (random string) | **yes** | not used in docker-compose (agent registration) |

### diun

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `DIUN_NTFY_TOPIC` | `container-updates-amy` | no | diun (DIUN_NOTIF_NTFY_TOPIC) |

### keepalived

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `KEEPALIVED_PASSWORD` | (shared secret) | **yes** | keepalived (via keepalived.conf — not directly used in compose) |
| `KEEPALIVED_VIP` | `192.168.21.100` | no | not used in docker-compose (keepalived.conf has hardcoded VIP) |

note: `KEEPALIVED_PASSWORD` must be identical on both bender and amy. on amy, it's defined in .env for documentation and encryption purposes but the actual keepalived.conf uses the hardcoded password directly.

---

## variables referenced in docker-compose.yaml

these variables are directly interpolated by `docker compose`:

| variable | services using it |
|----------|-------------------|
| `TIMEZONE` | dockwatch, pihole, ntfy, stirling, mealie, lubelogger, spendspentspent, limdius, telegraf, diun |
| `PUID` | dockwatch, filebrowser, mealie |
| `PGID` | same as PUID |
| `AMY_HOST_IP` | tsdproxy |
| `TAILSCALE_DOMAIN` | mealie |
| `TSDPROXY_AUTHKEY` | tsdproxy |
| `POSTGRES_PASSWORD` | postgres, postgres-backup, atuin, miniflux, mealie, spendspentspent |
| `PIHOLE_PASSWORD` | pihole |
| `MINIFLUX_ADMIN_USERNAME` | miniflux |
| `MINIFLUX_ADMIN_PASSWORD` | miniflux |
| `SSS_SALT` | spendspentspent |
| `BESZEL_KEY` | beszel-agent |
| `DIUN_NTFY_TOPIC` | diun |

---

## variables used outside docker-compose

| variable | used by | purpose |
|----------|---------|---------|
| `WATCHTOWER_NOTIFICATION_URL` | secure-container-update.sh | ntfy notification URL (legacy, currently commented out in .env) |
| `BESZEL_TOKEN` | agent registration | used during initial beszel agent setup, not in docker-compose |
| `KEEPALIVED_PASSWORD` | keepalived.conf | hardcoded in the config file, .env copy is for documentation/encryption |
| `KEEPALIVED_VIP` | reference | documentation only (keepalived.conf has hardcoded VIP) |

---

## security classification

### secrets (7 variables) — never commit to git

| variable | generation method |
|----------|-------------------|
| `TSDPROXY_AUTHKEY` | Tailscale admin console → Auth Keys |
| `POSTGRES_PASSWORD` | `openssl rand -base64 32` |
| `PIHOLE_PASSWORD` | user-chosen password |
| `MINIFLUX_ADMIN_PASSWORD` | `openssl rand -base64 24` |
| `SSS_SALT` | `openssl rand -hex 32` |
| `BESZEL_KEY` | generated by beszel hub during agent registration |
| `BESZEL_TOKEN` | generated by beszel hub during agent registration |
| `KEEPALIVED_PASSWORD` | `openssl rand -base64 16` (same on both hosts) |

### non-sensitive (9 variables) — safe to include in examples

TIMEZONE, PUID, PGID, AMY_HOST_IP, TAILSCALE_DOMAIN, MINIFLUX_ADMIN_USERNAME, DIUN_NTFY_TOPIC, KEEPALIVED_VIP

---

## generating secure values

```bash
# postgres password
openssl rand -base64 32

# pihole password
# choose a memorable password for the web UI

# miniflux admin password
openssl rand -base64 24

# spendspentspent salt
openssl rand -hex 32

# keepalived password (must match bender)
openssl rand -base64 16

# tailscale auth key
# generate at: https://login.tailscale.com/admin/settings/keys
```

---

*previous: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
*next: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
