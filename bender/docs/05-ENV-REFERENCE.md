# bender environment variable reference

## complete .env documentation

**document version:** 3.0
**infrastructure version:** 109
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

the `.env` file at `/mnt/BIG/filme/docker-compose/.env` contains all configuration values and secrets for bender's docker compose deployment. it is loaded automatically by `docker compose` and also sourced by the secure-container-update.sh script.

the file contains 28 variables across 12 categories. of these, 13 contain secrets and 15 are non-sensitive configuration values.

the TTS services (edge-tts, tts-pipeline, epub2tts-edge) added in v108–v109 do not require any additional .env variables — they only use `${TIMEZONE}` which was already present.

---

## variable categories

| category | count | secrets |
|----------|-------|---------|
| system | 5 | 0 |
| paths | 2 | 0 |
| tailscale | 2 | 1 |
| syncthing | 1 | 0 |
| surfshark VPN | 3 | 2 |
| postgresql | 1 | 1 |
| hedgedoc | 2 | 1 |
| vaultwarden | 1 | 1 |
| beszel | 2 | 2 |
| pihole | 1 | 1 |
| ntfy/diun | 2 | 0 |
| ARR stack | 4 | 4 |
| keepalived | 2 | 1 |
| **total** | **28** | **13** |

---

## complete variable reference

### system

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `TIMEZONE` | `America/Toronto` | no | nearly all containers |
| `PUID` | `1000` | no | linuxserver containers (jellyfin, transmission, sonarr, radarr, lidarr, readarr, bazarr, dockwatch) |
| `PGID` | `1000` | no | same as PUID |
| `LOCAL_NETWORK` | `192.168.21.0/24` | no | reference only (not used in docker-compose) |
| `BENDER_HOST_IP` | `192.168.21.121` | no | tsdproxy (TSDPROXY_HOSTNAME), pihole (FTLCONF_LOCAL_IPV4) |

### paths (reference only — not used by docker-compose)

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `BASE_PATH` | `/mnt/BIG/filme` | no | documentation reference |
| `CONFIG_PATH` | `/mnt/BIG/filme/configs` | no | documentation reference |

### tailscale

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `TAILSCALE_DOMAIN` | `bunny-enigmatic.ts.net` | no | hedgedoc (CMD_DOMAIN) |
| `TSDPROXY_AUTHKEY` | `tskey-auth-...` | **yes** | tsdproxy |

### syncthing

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `SYNCTHING_HOSTNAME` | `bender` | no | syncthing (hostname) |

### surfshark VPN (gluetun)

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `SURFSHARK_OPENVPN_USER` | (from Surfshark dashboard) | **yes** | gluetun (OPENVPN_USER) |
| `SURFSHARK_OPENVPN_PASSWORD` | (from Surfshark dashboard) | **yes** | gluetun (OPENVPN_PASSWORD) |
| `GLUETUN_SERVER_COUNTRY` | `Romania` | no | gluetun (SERVER_COUNTRIES) |

get OpenVPN credentials from: Surfshark → Manual setup → Router/Other → OpenVPN.

### postgresql

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `POSTGRES_PASSWORD` | (random string) | **yes** | postgres, postgres-backup, immich_server, hedgedoc |

### hedgedoc

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `HEDGEDOC_SESSION_SECRET` | (hex string) | **yes** | hedgedoc (CMD_SESSION_SECRET) |
| `HEDGEDOC_DOMAIN` | `pad.bunny-enigmatic.ts.net` | no | hedgedoc (CMD_DOMAIN) |

### vaultwarden

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `VAULTWARDEN_ADMIN_TOKEN` | (base64 or argon2 hash) | **yes** | vaultwarden (ADMIN_TOKEN) |

### beszel

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `BESZEL_KEY` | `ssh-ed25519 AAAA...` | **yes** | beszel-agent (KEY) |
| `BESZEL_TOKEN` | (random string) | **yes** | not used in docker-compose (agent registration) |

### pihole

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `PIHOLE_PASSWORD` | (random string) | **yes** | pihole (WEBPASSWORD), nebula-sync (PRIMARY/REPLICAS URLs) |

### ntfy/diun notifications

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `NTFY_ADDRESS` | `http://192.168.21.130:8080` | no | diun (DIUN_NOTIF_NTFY_ENDPOINT) |
| `DIUN_NTFY_TOPIC` | `container-updates-bender` | no | diun (DIUN_NOTIF_NTFY_TOPIC) |

note: `NTFY_ADDRESS` points to amy's ntfy on port 8080 (the ntfy internal port mapped to host 8888 on amy, but accessed directly via container port from bender's network).

### ARR stack API keys

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `SONARR_API_KEY` | (from Sonarr UI) | **yes** | unpackerr |
| `RADARR_API_KEY` | (from Radarr UI) | **yes** | unpackerr |
| `LIDARR_API_KEY` | (from Lidarr UI) | **yes** | unpackerr |
| `READARR_API_KEY` | (from Readarr UI) | **yes** | unpackerr |

get each key from the respective app's Settings → General → API Key. these are used by unpackerr to connect to the ARR apps through gluetun.

### keepalived

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `KEEPALIVED_PASSWORD` | (shared secret) | **yes** | keepalived (KEEPALIVED_PASSWORD) |
| `KEEPALIVED_VIP` | `192.168.21.100` | no | not used in docker-compose (keepalived.conf uses hardcoded VIP) |

note: `KEEPALIVED_PASSWORD` must be identical on both bender and amy. `KEEPALIVED_VIP` is defined in the .env for documentation purposes but the actual keepalived.conf uses the hardcoded IP.

---

## variables referenced in docker-compose.yaml

these variables are directly interpolated by `docker compose`:

| variable | services using it |
|----------|-------------------|
| `TIMEZONE` | dockwatch, gluetun, pihole, diun, transmission, jdownloader, spotdl, hedgedoc, vaultwarden, metube, edge-tts, tts-pipeline |
| `PUID` | dockwatch, transmission, jellyfin, jdownloader, sonarr, radarr, lidarr, readarr, bazarr |
| `PGID` | same as PUID |
| `BENDER_HOST_IP` | tsdproxy, pihole |
| `TSDPROXY_AUTHKEY` | tsdproxy |
| `SYNCTHING_HOSTNAME` | syncthing |
| `SURFSHARK_OPENVPN_USER` | gluetun |
| `SURFSHARK_OPENVPN_PASSWORD` | gluetun |
| `GLUETUN_SERVER_COUNTRY` | gluetun |
| `POSTGRES_PASSWORD` | postgres, postgres-backup, immich_server, hedgedoc |
| `HEDGEDOC_SESSION_SECRET` | hedgedoc |
| `HEDGEDOC_DOMAIN` | hedgedoc |
| `VAULTWARDEN_ADMIN_TOKEN` | vaultwarden |
| `BESZEL_KEY` | beszel-agent |
| `PIHOLE_PASSWORD` | pihole, nebula-sync |
| `NTFY_ADDRESS` | diun |
| `DIUN_NTFY_TOPIC` | diun |
| `SONARR_API_KEY` | unpackerr |
| `RADARR_API_KEY` | unpackerr |
| `LIDARR_API_KEY` | unpackerr |
| `READARR_API_KEY` | unpackerr |
| `KEEPALIVED_PASSWORD` | keepalived |

---

## variables used outside docker-compose

| variable | used by | purpose |
|----------|---------|---------|
| `WATCHTOWER_NOTIFICATION_URL` | secure-container-update.sh | ntfy notification URL (legacy variable name, sourced from .env) |
| `BESZEL_TOKEN` | agent registration | used during initial beszel agent setup, not in docker-compose |
| `LOCAL_NETWORK` | reference | documentation only |
| `BASE_PATH` | reference | documentation only |
| `CONFIG_PATH` | reference | documentation only |
| `KEEPALIVED_VIP` | reference | documentation only (keepalived.conf has hardcoded VIP) |

note: `WATCHTOWER_NOTIFICATION_URL` is a legacy variable name from when watchtower was the update system. the secure-container-update.sh script sources the .env and reads this variable. if it's not set (which is the current state), notifications use the `NTFY_ADDRESS` variable through diun instead.

---

## security classification

### secrets (13 variables) — never commit to git

| variable | generation method |
|----------|-------------------|
| `TSDPROXY_AUTHKEY` | Tailscale admin console → Auth Keys |
| `SURFSHARK_OPENVPN_USER` | Surfshark dashboard → Manual setup → OpenVPN |
| `SURFSHARK_OPENVPN_PASSWORD` | Surfshark dashboard → Manual setup → OpenVPN |
| `POSTGRES_PASSWORD` | `openssl rand -base64 32` |
| `HEDGEDOC_SESSION_SECRET` | `openssl rand -hex 32` |
| `VAULTWARDEN_ADMIN_TOKEN` | `openssl rand -base64 48` or argon2 hash |
| `BESZEL_KEY` | generated by beszel hub during agent registration |
| `BESZEL_TOKEN` | generated by beszel hub during agent registration |
| `PIHOLE_PASSWORD` | user-chosen password |
| `KEEPALIVED_PASSWORD` | `openssl rand -base64 16` (same on both hosts) |
| `SONARR_API_KEY` | auto-generated by Sonarr (Settings → General) |
| `RADARR_API_KEY` | auto-generated by Radarr (Settings → General) |
| `LIDARR_API_KEY` | auto-generated by Lidarr (Settings → General) |
| `READARR_API_KEY` | auto-generated by Readarr (Settings → General) |

### non-sensitive (15 variables) — safe to include in examples

TIMEZONE, PUID, PGID, LOCAL_NETWORK, BENDER_HOST_IP, BASE_PATH, CONFIG_PATH, TAILSCALE_DOMAIN, SYNCTHING_HOSTNAME, GLUETUN_SERVER_COUNTRY, HEDGEDOC_DOMAIN, NTFY_ADDRESS, DIUN_NTFY_TOPIC, KEEPALIVED_VIP

---

## generating secure values

```bash
# postgres password
openssl rand -base64 32

# hedgedoc session secret
openssl rand -hex 32

# vaultwarden admin token (simple)
openssl rand -base64 48

# vaultwarden admin token (argon2 — more secure)
# install argon2: apt install argon2
echo -n "YourAdminPassword" | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4

# keepalived password (must match on both hosts)
openssl rand -base64 16

# tailscale auth key
# generate at: https://login.tailscale.com/admin/settings/keys
```

---

*previous: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
*next: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
