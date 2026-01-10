# bender environment variable reference

## complete .env documentation

**document version:** 1.0  
**infrastructure version:** 86  
**last updated:** january 10, 2026

---

## table of contents

1. [overview](#overview)
2. [variable categories](#variable-categories)
3. [complete variable reference](#complete-variable-reference)
4. [security considerations](#security-considerations)
5. [template file](#template-file)
6. [generating secure values](#generating-secure-values)

---

## overview

the `.env` file contains all configuration and secrets for bender's docker compose deployment.

### file location

```
/mnt/BIG/filme/docker-compose/.env
```

### security requirements

| requirement | implementation |
|-------------|----------------|
| **file permissions** | `chmod 600 .env` (read/write by root only) |
| **git exclusion** | add to `.gitignore` |
| **backup encryption** | use gpg for backups |
| **version control** | never commit actual secrets |

---

## variable categories

### category summary

| category | count | sensitivity | description |
|----------|-------|-------------|-------------|
| **system** | 5 | low | timezone, user ids, network, host ip |
| **paths** | 2 | low | base path, config path |
| **tailscale** | 2 | high | auth key, domain |
| **syncthing** | 1 | low | hostname |
| **transmission vpn** | 4 | high | vpn provider, config, credentials |
| **postgresql** | 1 | high | database password |
| **hedgedoc** | 1 | high | session secret |
| **beszel** | 2 | high | ssh key, token |
| **pihole** | 1 | medium | admin password |
| **notifications** | 2 | low | ntfy address, diun topic |
| **arr api keys** | 4 | medium | sonarr, radarr, lidarr, readarr |

---

## complete variable reference

### system variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `TIMEZONE` | container timezone | `America/Toronto` | yes |
| `PUID` | user id for file ownership | `1000` | yes |
| `PGID` | group id for file ownership | `1000` | yes |
| `LOCAL_NETWORK` | trusted network cidr | `192.168.21.0/24` | yes |
| `BENDER_HOST_IP` | bender's lan ip address | `192.168.21.121` | yes |

**usage notes:**
- `PUID`/`PGID` ensure consistent file permissions across containers
- `LOCAL_NETWORK` used by transmission for vpn bypass
- `BENDER_HOST_IP` used by tsdproxy hostname configuration

---

### path variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `BASE_PATH` | root data directory | `/mnt/BIG/filme` | yes |
| `CONFIG_PATH` | container configs directory | `/mnt/BIG/filme/configs` | yes |

**usage notes:**
- all volume mounts reference these base paths
- changing these requires updating all container volumes

---

### tailscale variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `TAILSCALE_DOMAIN` | your tailscale tailnet domain | `bunny-enigmatic.ts.net` | yes |
| `TSDPROXY_AUTHKEY` | tsdproxy authentication key | `tskey-auth-...` | yes |

**security:** high - the auth key allows devices to join your tailscale network.

**generating auth key:**
1. go to https://login.tailscale.com/admin/settings/keys
2. create new auth key
3. enable "reusable" and "ephemeral" options
4. copy the key (starts with `tskey-auth-`)

---

### syncthing variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `SYNCTHING_HOSTNAME` | syncthing device name | `bender` | yes |

---

### transmission vpn variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `TRANSMISSION_VPN_PROVIDER` | vpn service provider | `SURFSHARK` | yes |
| `TRANSMISSION_VPN_OPENVPN_CONFIG` | openvpn config file | `ro-buc.prod.surfshark.com_tcp` | yes |
| `TRANSMISSION_VPN_USERNAME` | vpn username | (from provider) | yes |
| `TRANSMISSION_VPN_PASSWORD` | vpn password | (from provider) | yes |

**security:** high - vpn credentials.

**supported providers:**
- surfshark, nordvpn, pia, mullvad, expressvpn, and many more
- see https://haugene.github.io/docker-transmission-openvpn/

---

### postgresql variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `POSTGRES_PASSWORD` | database superuser password | (generated) | yes |

**security:** high - grants full database access.

**generating password:**
```bash
openssl rand -base64 32
```

**databases using this password:**
- immich
- hedgedoc

---

### hedgedoc variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `HEDGEDOC_SESSION_SECRET` | session encryption secret | (generated) | yes |

**security:** high - protects user sessions.

**generating secret:**
```bash
openssl rand -hex 32
```

---

### beszel variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `BESZEL_KEY` | ssh public key for beszel agent | `ssh-ed25519 AAAA...` | yes |
| `BESZEL_TOKEN` | authentication token | (from beszel server) | no |

**security:** high - allows beszel server on amy to connect.

**obtaining values:**
1. deploy beszel server on amy first
2. add bender as a system in beszel
3. copy the ssh key and token from beszel ui

---

### pihole variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `PIHOLE_PASSWORD` | web admin password | (generated) | yes |

**security:** medium - admin access to dns settings.

**generating password:**
```bash
openssl rand -base64 16
```

---

### notification variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `NTFY_ADDRESS` | ntfy server address (amy) | `192.168.21.130:8080` | yes |
| `DIUN_NTFY_TOPIC` | ntfy topic for diun notifications | `diun-bender` | yes |

**usage:**
- `NTFY_ADDRESS` points to ntfy server running on amy
- `DIUN_NTFY_TOPIC` is the topic where diun sends update notifications

---

### arr api key variables

| variable | purpose | example | required |
|----------|---------|---------|----------|
| `SONARR_API_KEY` | sonarr api key | (from sonarr ui) | no |
| `RADARR_API_KEY` | radarr api key | (from radarr ui) | no |
| `LIDARR_API_KEY` | lidarr api key | (from lidarr ui) | no |
| `READARR_API_KEY` | readarr api key | (from readarr ui) | no |

**security:** medium - allows api access to arr services.

**obtaining api keys:**
1. open the arr service web ui
2. go to settings → general
3. copy the api key

**usage:** used by unpackerr for automatic extraction notifications.

---

## security considerations

### sensitivity levels

| level | description | handling |
|-------|-------------|----------|
| **high** | grants system access | rotate periodically, encrypt backups |
| **medium** | web ui access | strong passwords, limit exposure |
| **low** | non-sensitive config | standard handling |

### best practices

1. **never commit .env to git** - use `.env.template` for version control
2. **restrict file permissions** - `chmod 600 .env`
3. **encrypt backups** - use gpg before storing offsite
4. **rotate credentials** - change high sensitivity values annually
5. **use strong passwords** - minimum 20 characters for all secrets

### backup procedure

```bash
# encrypt .env for backup
gpg --symmetric --cipher-algo AES256 -o .env.gpg .env

# decrypt when needed
gpg -d .env.gpg > .env
chmod 600 .env
```

---

## template file

### complete .env.template

```bash
# ============================================
# bender (TrueNAS Scale) - environment variables
# version: 86
# ============================================
# important: this file contains secrets - protect accordingly
# chmod 600 /mnt/BIG/filme/docker-compose/.env
# ============================================

# ============================================
# system
# ============================================
TIMEZONE=America/Toronto
PUID=1000
PGID=1000
LOCAL_NETWORK=192.168.21.0/24
BENDER_HOST_IP=192.168.21.121

# ============================================
# paths
# ============================================
BASE_PATH=/mnt/BIG/filme
CONFIG_PATH=/mnt/BIG/filme/configs

# ============================================
# tailscale
# ============================================
TAILSCALE_DOMAIN=bunny-enigmatic.ts.net
# generate from: https://login.tailscale.com/admin/settings/keys
TSDPROXY_AUTHKEY=tskey-auth-REPLACE_WITH_YOUR_KEY

# ============================================
# syncthing
# ============================================
SYNCTHING_HOSTNAME=bender

# ============================================
# transmission vpn
# ============================================
TRANSMISSION_VPN_PROVIDER=SURFSHARK
TRANSMISSION_VPN_OPENVPN_CONFIG=ro-buc.prod.surfshark.com_tcp
TRANSMISSION_VPN_USERNAME=REPLACE_WITH_VPN_USERNAME
TRANSMISSION_VPN_PASSWORD=REPLACE_WITH_VPN_PASSWORD

# ============================================
# postgresql
# ============================================
# generate with: openssl rand -base64 32
POSTGRES_PASSWORD=REPLACE_WITH_SECURE_PASSWORD

# ============================================
# hedgedoc
# ============================================
# generate with: openssl rand -hex 32
HEDGEDOC_SESSION_SECRET=REPLACE_WITH_GENERATED_SECRET

# ============================================
# beszel agent
# ============================================
# get from beszel server on amy
BESZEL_KEY=ssh-ed25519 REPLACE_WITH_PUBLIC_KEY
BESZEL_TOKEN=

# ============================================
# pihole
# ============================================
PIHOLE_PASSWORD=REPLACE_WITH_SECURE_PASSWORD

# ============================================
# notifications
# ============================================
NTFY_ADDRESS=192.168.21.130:8080
DIUN_NTFY_TOPIC=diun-bender

# ============================================
# arr api keys (optional - for unpackerr)
# ============================================
# get from each service: settings → general → api key
SONARR_API_KEY=
RADARR_API_KEY=
LIDARR_API_KEY=
READARR_API_KEY=
```

---

## generating secure values

### password generation commands

```bash
# strong password (32 chars, base64)
openssl rand -base64 32

# hex string (64 chars)
openssl rand -hex 32

# alphanumeric (20 chars)
tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20

# with special characters
tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 24
```

### recommended password lengths

| variable | minimum length | recommended |
|----------|----------------|-------------|
| `POSTGRES_PASSWORD` | 20 | 32 |
| `HEDGEDOC_SESSION_SECRET` | 32 | 64 (hex) |
| `PIHOLE_PASSWORD` | 12 | 16 |
| `TRANSMISSION_VPN_PASSWORD` | (provider defined) | - |

---

*previous: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*  
*next: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
