# amy environment variable reference

## complete .env documentation

**document version:** 2.0
**infrastructure version:** 98
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

| property | value |
|----------|-------|
| **location** | `/docker-compose/.env` |
| **total variables** | 16 |
| **referenced in yaml** | 13 |
| **used outside yaml** | 3 |
| **secret values** | 9 |
| **non-secret values** | 7 |

---

## variable categories

### system configuration (3 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `TIMEZONE` | `America/Toronto` | most services via `TZ=${TIMEZONE}` | container timezone |
| `PUID` | `1000` | dockwatch, filebrowser, mealie, lubelogger | container user id for file permissions |
| `PGID` | `1000` | dockwatch, filebrowser, mealie, lubelogger | container group id for file permissions |

### network configuration (2 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `AMY_HOST_IP` | `192.168.21.130` | tsdproxy (`TSDPROXY_HOSTNAME`) | host ip address for tailscale proxy routing |
| `TAILSCALE_DOMAIN` | `bunny-enigmatic.ts.net` | mealie (`BASE_URL`) | tailscale magicDNS domain suffix |

### tailscale (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `TSDPROXY_AUTHKEY` | `tskey-auth-...` | tsdproxy | tailscale authentication key for automatic node registration |

### database (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `POSTGRES_PASSWORD` | (generated) | postgres, postgres-backup, atuin, miniflux, mealie, spendspentspent | shared postgresql password for all databases |

### dns (2 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `PIHOLE_PASSWORD` | (generated) | pihole (`WEBPASSWORD`) | pihole admin web interface password |
| `KEEPALIVED_PASSWORD` | (generated) | keepalived configuration | vrrp authentication between bender and amy |

### service credentials (3 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `MINIFLUX_ADMIN_USERNAME` | `admin` | miniflux (`ADMIN_USERNAME`) | miniflux admin login username |
| `MINIFLUX_ADMIN_PASSWORD` | (generated) | miniflux (`ADMIN_PASSWORD`) | miniflux admin login password |
| `SSS_SALT` | (generated) | spendspentspent (`SALT`) | cryptographic salt for spendspentspent password hashing |

### monitoring (2 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `BESZEL_KEY` | (generated) | beszel-agent (`KEY`) | authentication key for beszel agent → hub communication |
| `BESZEL_TOKEN` | (generated) | beszel hub (web ui setup) | api token for beszel hub — used during initial setup, not in compose yaml |

### notifications (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `DIUN_NTFY_TOPIC` | `container-updates-amy` | diun, secure-container-update.sh | ntfy topic name for container update notifications |

### high availability (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `KEEPALIVED_VIP` | `192.168.21.100` | keepalived configuration | virtual ip address shared between bender (master) and amy (backup) |

---

## variables referenced in docker-compose.yaml

these 13 variables are directly interpolated in the v98 docker-compose.yaml using `${VARIABLE}` syntax:

| variable | services that reference it |
|----------|---------------------------|
| `TIMEZONE` | dockwatch, pihole, ntfy, stirling (as `TZ`), homepage, mealie, lubelogger, spendspentspent, limdius, beszel-agent (implicit), diun, telegraf |
| `PUID` | dockwatch, filebrowser, mealie, lubelogger |
| `PGID` | dockwatch, filebrowser, mealie, lubelogger |
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

these 3 variables exist in the `.env` file but are **not** directly referenced in docker-compose.yaml:

| variable | where it's used | notes |
|----------|----------------|-------|
| `BESZEL_TOKEN` | beszel hub web ui initial setup | used once during first-time configuration of beszel hub |
| `KEEPALIVED_PASSWORD` | `/docker/keepalived/keepalived.conf` | vrrp authentication password — must match bender's keepalived |
| `KEEPALIVED_VIP` | `/docker/keepalived/keepalived.conf` | virtual ip for dns failover — must match bender's configuration |

these are stored in `.env` for documentation and backup purposes, ensuring all configuration values are in one place even if not consumed by docker compose directly.

---

## security classification

### secret values (do not commit to git)

| variable | generation method | rotation frequency |
|----------|------------------|--------------------|
| `TSDPROXY_AUTHKEY` | tailscale admin console | when key expires |
| `POSTGRES_PASSWORD` | random generation | rarely (requires all dependent services restart) |
| `PIHOLE_PASSWORD` | random generation | as needed |
| `MINIFLUX_ADMIN_PASSWORD` | random generation | as needed |
| `SSS_SALT` | random generation | never (changing breaks existing password hashes) |
| `BESZEL_KEY` | beszel hub ui (add agent) | when re-adding agent |
| `BESZEL_TOKEN` | beszel hub ui | when regenerating api access |
| `KEEPALIVED_PASSWORD` | random generation | rarely (must match bender) |
| `KEEPALIVED_VIP` | network planning | rarely (requires both hosts + all clients update) |

### non-secret values (safe for .env.template)

| variable | typical value |
|----------|--------------|
| `TIMEZONE` | `America/Toronto` |
| `PUID` | `1000` |
| `PGID` | `1000` |
| `AMY_HOST_IP` | `192.168.21.130` |
| `TAILSCALE_DOMAIN` | `bunny-enigmatic.ts.net` |
| `MINIFLUX_ADMIN_USERNAME` | `admin` |
| `DIUN_NTFY_TOPIC` | `container-updates-amy` |

---

## generating secure values

### random passwords (32 characters, alphanumeric)

```bash
openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
```

### random salt (64 characters, hex)

```bash
openssl rand -hex 32
```

### tailscale auth key

1. go to https://login.tailscale.com/admin/settings/keys
2. generate a new auth key
3. set it as reusable if needed for container recreation
4. copy the `tskey-auth-...` value

### beszel key

1. open beszel hub web ui (https://beszel.bunny-enigmatic.ts.net)
2. click "add system"
3. copy the generated key value

### keepalived password

```bash
# must be 8 characters or fewer for vrrp compatibility
openssl rand -base64 6 | tr -dc 'a-zA-Z0-9' | head -c 8
```

> **important:** keepalived password must be identical on both bender and amy. after changing it, update both hosts and restart keepalived on both.

---

*previous: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
*next: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
