# bender environment variable reference

## complete .env documentation

**document version:** 2.0
**infrastructure version:** 105
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

| property | value |
|----------|-------|
| **location** | `/mnt/BIG/filme/docker-compose/.env` |
| **total variables** | 28 |
| **referenced in yaml** | 22 |
| **used outside yaml** | 6 |
| **secret values** | 16 |
| **non-secret values** | 12 |

---

## variable categories

### system configuration (3 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `TIMEZONE` | `America/Toronto` | most services via `TZ=${TIMEZONE}` | container timezone |
| `PUID` | `1000` | dockwatch, jellyfin, transmission, sonarr, radarr, lidarr, readarr, bazarr, jdownloader, spotdl (as USER_ID) | container user id for file permissions |
| `PGID` | `1000` | dockwatch, jellyfin, transmission, sonarr, radarr, lidarr, readarr, bazarr, jdownloader, spotdl (as GROUP_ID) | container group id for file permissions |

### network configuration (3 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `LOCAL_NETWORK` | `192.168.21.0/24` | (available for future use) | local network CIDR |
| `BENDER_HOST_IP` | `192.168.21.121` | tsdproxy (`TSDPROXY_HOSTNAME`), pihole (`FTLCONF_LOCAL_IPV4`) | host ip for tailscale proxy routing and pihole binding |
| `BASE_PATH` | `/mnt/BIG/filme` | (documentation reference) | base path for all bender data |

### path configuration (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `CONFIG_PATH` | `/mnt/BIG/filme/configs` | (documentation reference) | base path for container configurations |

### tailscale (2 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `TAILSCALE_DOMAIN` | `bunny-enigmatic.ts.net` | (documentation reference) | tailscale magicDNS domain suffix |
| `TSDPROXY_AUTHKEY` | `tskey-auth-...` | tsdproxy | tailscale authentication key for automatic node registration |

### VPN (3 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `SURFSHARK_OPENVPN_USER` | (from surfshark) | gluetun (`OPENVPN_USER`) | surfshark OpenVPN username |
| `SURFSHARK_OPENVPN_PASSWORD` | (from surfshark) | gluetun (`OPENVPN_PASSWORD`) | surfshark OpenVPN password |
| `GLUETUN_SERVER_COUNTRY` | `Romania` | gluetun (`SERVER_COUNTRIES`) | VPN server country selection |

### database (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `POSTGRES_PASSWORD` | (generated) | postgres, postgres-backup, immich_server, hedgedoc | shared postgresql password |

### collaboration (2 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `HEDGEDOC_SESSION_SECRET` | (generated) | hedgedoc (`CMD_SESSION_SECRET`) | session cookie encryption secret |
| `HEDGEDOC_DOMAIN` | `pad.bunny-enigmatic.ts.net` | hedgedoc (`CMD_DOMAIN`) | hedgedoc public domain for link generation |

### security (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `VAULTWARDEN_ADMIN_TOKEN` | (generated) | vaultwarden (`ADMIN_TOKEN`) | admin panel authentication token |

### DNS (2 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `PIHOLE_PASSWORD` | (generated) | pihole (`WEBPASSWORD`), nebula-sync (PRIMARY and REPLICAS URLs) | pihole admin web interface password |
| `KEEPALIVED_PASSWORD` | (generated) | keepalived configuration | vrrp authentication between bender and amy |

### monitoring (2 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `BESZEL_KEY` | (generated) | beszel-agent (`KEY`) | authentication key for beszel agent → hub communication |
| `BESZEL_TOKEN` | (generated) | beszel hub on amy (web ui setup) | api token — used during initial agent registration, not in compose yaml |

### notifications (2 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `NTFY_ADDRESS` | `192.168.21.130:8888` | diun (`DIUN_NOTIF_NTFY_ENDPOINT`), secure-container-update.sh | remote ntfy server address on amy |
| `DIUN_NTFY_TOPIC` | `container-updates-bender` | diun, secure-container-update.sh | ntfy topic for container update notifications |

### ARR stack API keys (4 variables)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `SONARR_API_KEY` | (from sonarr ui) | unpackerr (`UN_SONARR_0_API_KEY`) | sonarr API authentication for unpackerr |
| `RADARR_API_KEY` | (from radarr ui) | unpackerr (`UN_RADARR_0_API_KEY`) | radarr API authentication for unpackerr |
| `LIDARR_API_KEY` | (from lidarr ui) | unpackerr (`UN_LIDARR_0_API_KEY`) | lidarr API authentication for unpackerr |
| `READARR_API_KEY` | (from readarr ui) | unpackerr (`UN_READARR_0_API_KEY`) | readarr API authentication for unpackerr |

### high availability (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `KEEPALIVED_VIP` | `192.168.21.100` | keepalived configuration | virtual ip shared between bender (master) and amy (backup) |

### syncthing (1 variable)

| variable | example value | used by | purpose |
|----------|--------------|---------|---------|
| `SYNCTHING_HOSTNAME` | `bender` | syncthing (`hostname:`) | device hostname for syncthing peer identification |

---

## variables referenced in docker-compose.yaml

these 22 variables are directly interpolated in the v105 docker-compose.yaml using `${VARIABLE}` syntax:

| variable | services that reference it |
|----------|---------------------------|
| `TIMEZONE` | dockwatch, gluetun, pihole, nebula-sync, immich_server, immich_machine_learning, jellyfin, audiobookshelf, transmission, metube, jdownloader, spotdl, hedgedoc, sonarr, radarr, lidarr, readarr, bazarr, unpackerr, diun |
| `PUID` | dockwatch, jellyfin, transmission, sonarr, radarr, lidarr, readarr, bazarr |
| `PGID` | dockwatch, jellyfin, transmission, sonarr, radarr, lidarr, readarr, bazarr |
| `BENDER_HOST_IP` | tsdproxy, pihole |
| `TSDPROXY_AUTHKEY` | tsdproxy |
| `SURFSHARK_OPENVPN_USER` | gluetun |
| `SURFSHARK_OPENVPN_PASSWORD` | gluetun |
| `GLUETUN_SERVER_COUNTRY` | gluetun |
| `POSTGRES_PASSWORD` | postgres, postgres-backup, immich_server, hedgedoc |
| `HEDGEDOC_SESSION_SECRET` | hedgedoc |
| `HEDGEDOC_DOMAIN` | hedgedoc |
| `VAULTWARDEN_ADMIN_TOKEN` | vaultwarden |
| `PIHOLE_PASSWORD` | pihole, nebula-sync (in PRIMARY and REPLICAS URLs) |
| `BESZEL_KEY` | beszel-agent |
| `NTFY_ADDRESS` | diun |
| `DIUN_NTFY_TOPIC` | diun |
| `SONARR_API_KEY` | unpackerr |
| `RADARR_API_KEY` | unpackerr |
| `LIDARR_API_KEY` | unpackerr |
| `READARR_API_KEY` | unpackerr |
| `SYNCTHING_HOSTNAME` | syncthing |
| `KEEPALIVED_PASSWORD` | keepalived (via environment variable) |

> **note on PUID/PGID:** jdownloader uses `USER_ID=${PUID}` and `GROUP_ID=${PGID}` instead of `PUID`/`PGID` directly, but it still references the same .env variables.

---

## variables used outside docker-compose

these 6 variables exist in the `.env` file but are **not** directly referenced in docker-compose.yaml:

| variable | where it's used | notes |
|----------|----------------|-------|
| `LOCAL_NETWORK` | available for future use | local network CIDR, not currently referenced |
| `BASE_PATH` | documentation and scripts | base path reference for bender data |
| `CONFIG_PATH` | documentation and scripts | base path reference for container configs |
| `TAILSCALE_DOMAIN` | documentation reference | the tailnet domain name, not used in compose |
| `BESZEL_TOKEN` | beszel hub web ui on amy | used once during agent registration |
| `KEEPALIVED_VIP` | `/mnt/BIG/filme/configs/keepalived/keepalived.conf` | virtual ip — must match amy's keepalived config |

these are stored in `.env` for documentation and backup purposes, ensuring all configuration values are in one place.

---

## security classification

### secret values (do not commit to git)

| variable | generation method | rotation frequency |
|----------|------------------|--------------------|
| `TSDPROXY_AUTHKEY` | tailscale admin console | when key expires |
| `SURFSHARK_OPENVPN_USER` | surfshark account dashboard | when credentials change |
| `SURFSHARK_OPENVPN_PASSWORD` | surfshark account dashboard | when credentials change |
| `POSTGRES_PASSWORD` | random generation | rarely (requires all dependent services restart) |
| `HEDGEDOC_SESSION_SECRET` | random generation | rarely (invalidates all active sessions) |
| `VAULTWARDEN_ADMIN_TOKEN` | random generation | as needed |
| `PIHOLE_PASSWORD` | random generation | as needed (must match amy + nebula-sync) |
| `KEEPALIVED_PASSWORD` | random generation | rarely (must match amy) |
| `KEEPALIVED_VIP` | network planning | rarely (requires both hosts + all clients update) |
| `BESZEL_KEY` | beszel hub ui (add agent) | when re-adding agent |
| `BESZEL_TOKEN` | beszel hub ui | when regenerating api access |
| `SONARR_API_KEY` | sonarr web ui → settings → general | when regenerated |
| `RADARR_API_KEY` | radarr web ui → settings → general | when regenerated |
| `LIDARR_API_KEY` | lidarr web ui → settings → general | when regenerated |
| `READARR_API_KEY` | readarr web ui → settings → general | when regenerated |
| `NTFY_ADDRESS` | infrastructure configuration | when amy's ntfy changes |

### non-secret values (safe for .env.template)

| variable | typical value |
|----------|--------------|
| `TIMEZONE` | `America/Toronto` |
| `PUID` | `1000` |
| `PGID` | `1000` |
| `LOCAL_NETWORK` | `192.168.21.0/24` |
| `BENDER_HOST_IP` | `192.168.21.121` |
| `BASE_PATH` | `/mnt/BIG/filme` |
| `CONFIG_PATH` | `/mnt/BIG/filme/configs` |
| `TAILSCALE_DOMAIN` | `bunny-enigmatic.ts.net` |
| `GLUETUN_SERVER_COUNTRY` | `Romania` |
| `HEDGEDOC_DOMAIN` | `pad.bunny-enigmatic.ts.net` |
| `DIUN_NTFY_TOPIC` | `container-updates-bender` |
| `SYNCTHING_HOSTNAME` | `bender` |

---

## generating secure values

### random passwords (32 characters, alphanumeric)

```bash
openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
```

### hedgedoc session secret

```bash
openssl rand -hex 32
```

### vaultwarden admin token

vaultwarden recommends using argon2 hashed tokens:

```bash
# generate a plain token first
openssl rand -base64 48

# or use the vaultwarden wiki recommendation for argon2
# https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page
```

### tailscale auth key

1. go to https://login.tailscale.com/admin/settings/keys
2. generate a new auth key (reusable recommended for container recreation)
3. copy the `tskey-auth-...` value

### surfshark OpenVPN credentials

1. log in to https://my.surfshark.com
2. go to VPN → manual setup → OpenVPN
3. copy the username and password (these are NOT your account credentials)

### ARR stack API keys

each ARR application generates its own API key:

1. open the service web UI (e.g., https://sonarr.bunny-enigmatic.ts.net)
2. go to settings → general
3. copy the "API Key" value

### beszel key

1. open beszel hub web ui (https://beszel.bunny-enigmatic.ts.net)
2. click "add system"
3. copy the generated key value

### keepalived password

```bash
# must be 8 characters or fewer for vrrp compatibility
openssl rand -base64 6 | tr -dc 'a-zA-Z0-9' | head -c 8
```

> **important:** keepalived password and pihole password must be identical on both bender and amy. after changing either, update both hosts and restart the affected services on both.

---

*previous: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
*next: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
