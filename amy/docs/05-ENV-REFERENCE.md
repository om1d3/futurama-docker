# amy environment variable reference

## complete .env documentation

**document version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

---

## table of contents

1. [overview](#overview)
2. [house rules](#house-rules)
3. [complete variable reference](#complete-variable-reference)
4. [variables referenced in docker-compose.yaml](#variables-referenced-in-docker-composeyaml)
5. [variables used outside docker-compose](#variables-used-outside-docker-compose)
6. [security classification](#security-classification)
7. [generating secure values](#generating-secure-values)
8. [known audit items](#known-audit-items)

---

## overview

the `.env` file at `/docker-compose/.env` contains all configuration values and secrets for amy's deployment. it holds **16 variables**: 8 secrets and 8 non-sensitive values. git-tracked forms: `.env.gpg` (encrypted) and `.env.example` (values stripped).

two important secrets on amy live **outside** .env: the VRRP password (inline in `/docker/keepalived/keepalived.conf`) and the GitHub PAT (inside `/docker/oxidized/`'s config). both must stay out of git.

---

## house rules

identical to bender's (docs/05 there) – restated because they bind both hosts:

1. **version correlation:** the .env header version tracks docker-compose.yaml; bump together with a dated changelog entry since 2026-07-21, versions are calendar dates (`YYYYMMDD`; a second same-day edit appends `.2`, then `.3`), harmonized across both hosts; the older sequential numbers (bender …v115, amy …v104) remain valid historical identifiers.
2. **secrets in hex** (`openssl rand -hex N`), never base64
3. **no secret values in comments** – comments survive sed-sanitization
4. **env changes apply only via** `docker compose up -d --force-recreate <svc>`
5. **verify with** `docker inspect`, never `docker exec env`
6. `chmod 600 /docker-compose/.env`

---

## complete variable reference

### system

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `TIMEZONE` | `America/Toronto` | no | most containers (TZ) |
| `PUID` | `1000` | no | dockwatch, filebrowser, mealie |
| `PGID` | `1000` | no | same |
| `AMY_HOST_IP` | `10.30.0.11` | no | tsdproxy (TSDPROXY_HOSTNAME) – **fixed in v104** after the migration left it on the dead 192.168.21.130, sending every proxy to nowhere |

### tailscale

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `TAILSCALE_DOMAIN` | `bunny-enigmatic.ts.net` | no | mealie (BASE_URL) |
| `TSDPROXY_AUTHKEY` | `tskey-auth-...` | **yes** | tsdproxy (both TSDPROXY_AUTHKEY and TS_AUTHKEY since v104) |

same expiry discipline as bender: note the date in a comment, rotate before it lapses, force-recreate tsdproxy after.

### postgresql

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `POSTGRES_PASSWORD` | (hex) | **yes** | postgres, postgres-backup, atuin (DB URI), miniflux (DATABASE_URL), mealie, spendspentspent (DB_PASSWORD) |

### pihole

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `PIHOLE_PASSWORD` | (same as bender's) | **yes** | pihole (WEBPASSWORD) – must match bender's, nebula-sync authenticates against both ends |

### miniflux

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `MINIFLUX_ADMIN_USERNAME` | `miniflux` | no | miniflux (ADMIN_USERNAME) |
| `MINIFLUX_ADMIN_PASSWORD` | (random) | **yes** | miniflux (ADMIN_PASSWORD) |

### spendspentspent

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `SSS_SALT` | (hex) | **yes** | spendspentspent (SALT) – changing it breaks existing password hashes; treat as immutable |

### beszel

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `BESZEL_KEY` | `ssh-ed25519 ...` | **yes** | beszel-agent (KEY) |
| `BESZEL_TOKEN` | (random) | **yes** | agent registration only, not in compose |

### diun

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `DIUN_NTFY_TOPIC` | `container-updates-amy` | no | diun |

### keepalived

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `KEEPALIVED_PASSWORD` | (hex, = bender's) | **yes** | **not consumed by amy's compose** – amy's keepalived.conf hardcodes auth_pass inline. the .env copy documents the value that MUST equal both bender's env and amy's conf file |
| `KEEPALIVED_VIP` | `10.30.0.2` | no | reference only |

---

## variables referenced in docker-compose.yaml

| variable | services using it |
|----------|-------------------|
| `TIMEZONE` | dockwatch, oxidized, pihole, postgres, postgres-backup, ntfy, homepage, mealie, lubelogger, spendspentspent (TZ + TIMEZONE), tax-calculator, limdius, netalertx, telegraf, diun |
| `PUID` / `PGID` | dockwatch, filebrowser, mealie |
| `AMY_HOST_IP` | tsdproxy |
| `TSDPROXY_AUTHKEY` | tsdproxy (twice) |
| `TAILSCALE_DOMAIN` | mealie |
| `POSTGRES_PASSWORD` | postgres, postgres-backup, atuin, miniflux, mealie, spendspentspent |
| `PIHOLE_PASSWORD` | pihole |
| `MINIFLUX_ADMIN_USERNAME` / `MINIFLUX_ADMIN_PASSWORD` | miniflux |
| `SSS_SALT` | spendspentspent |
| `BESZEL_KEY` | beszel-agent |
| `DIUN_NTFY_TOPIC` | diun |

---

## variables used outside docker-compose

| variable | used by | purpose |
|----------|---------|---------|
| `BESZEL_TOKEN` | agent registration | initial setup only |
| `KEEPALIVED_PASSWORD` | reference | must match bender's env and amy's conf-file value |
| `KEEPALIVED_VIP` | reference | conf hardcodes the VIP |

---

## security classification

### secrets (8) – never commit, never in comments

TSDPROXY_AUTHKEY, POSTGRES_PASSWORD, PIHOLE_PASSWORD, MINIFLUX_ADMIN_PASSWORD, SSS_SALT, BESZEL_KEY, BESZEL_TOKEN, KEEPALIVED_PASSWORD

### non-sensitive (8)

TIMEZONE, PUID, PGID, AMY_HOST_IP, TAILSCALE_DOMAIN, MINIFLUX_ADMIN_USERNAME, DIUN_NTFY_TOPIC, KEEPALIVED_VIP

### secrets outside .env (tracked here because they're easy to forget)

| secret | location | rotation note |
|--------|----------|---------------|
| VRRP auth_pass | /docker/keepalived/keepalived.conf (inline) | must change in lockstep with bender's KEEPALIVED_PASSWORD; restart keepalived on both hosts |
| GitHub PAT (amy-oxidized) | /docker/oxidized config | expires – regenerate on GitHub, update config, restart oxidized |

---

## generating secure values

```bash
openssl rand -hex 32     # postgres password
openssl rand -hex 16     # keepalived (both hosts + amy's conf file)
openssl rand -hex 16     # miniflux admin password (or user-chosen)
# SSS_SALT: generate ONCE (openssl rand -hex 16) – never rotate casually
# tailscale auth key: https://login.tailscale.com/admin/settings/keys (note expiry)
# GitHub PAT: github.com → Settings → Developer settings → fine-grained PAT scoped to nod-config
```

---

## known audit items

- **VRRP password committed to git:** the futurama-docker repo's `amy/configs/keepalived/keepalived.conf` contains the live auth_pass in plaintext. remediation: rotate the VRRP password on both hosts, replace the repo copy with a templated version (`auth_pass __KEEPALIVED_PASSWORD__`), and add the real conf to .gitignore. until rotated, treat the current VRRP password as public.
- **header/version drift:** the .env header should be synced to **20260721** – DEPLOY-2026-07-21.md step 3d does this – with a retroactive v104 entry for the AMY_HOST_IP fix (rule 1).
- **repo .env.example stale:** the repo copy is v99-era with pre-migration values in its examples; regenerate after the next .env touch.


---

## 20260810 changes

the `.env` header sat at `Version: 85` while the compose file was at 104,
then 20260810. it now reads `20260810`.

three edits were applied:

| edit | reason |
|------|--------|
| header `85` → `20260810` | align with the compose version, per house rule 1 |
| `### expires on 2026 July 24` → `2026 October 29` | the Tailscale key was rotated on 2026-08-08 |
| removed a commented credential | a plaintext value sat in a comment as "to be reused" |

that third item is worth remembering. a redaction pass that matches
`NAME=value` lines will miss a secret written inside a comment. so read
the whole file, not only the assignments.

---

## the Tailscale key exists in three places

`TSDPROXY_AUTHKEY` in `.env` is not sufficient. the key must be identical
in three locations, or tsdproxy fails in a way that looks like a network
fault:

1. `TSDPROXY_AUTHKEY` in `/docker-compose/.env`
2. `TS_AUTHKEY` in the same file, which the compose maps from the same variable
3. `authKey` in `/docker/tsdproxy/config/tsdproxy.yaml`

the third is the one that is missed. the v3 beta reads its configuration
from the yaml, so a rotation applied only to `.env` has no effect.

two variable names exist because the tsdproxy image has accepted both
spellings across versions. older builds read `TSDPROXY_AUTHKEY`, newer ones
read `TS_AUTHKEY`. feeding both survives an image update that switches.

**rotation runbook.** mint a reusable, pre-authorized key. copy the secret
from the creation dialog, because it is shown once. store it in
Vaultwarden. update all three locations. then
`docker compose up -d --force-recreate tsdproxy` and watch the log for
`invalid key`.

---

## unused and stale variables

| variable | status |
|----------|--------|
| `BESZEL_TOKEN` | defined, referenced by no service in the compose. only `BESZEL_KEY` is used, by beszel-agent. |
| `#ROUTER_IP=192.168.21.1` | commented leftover from before the network migration |
| `KEEPALIVED_PASSWORD` | present, but amy's keepalived.conf carries `auth_pass` inline instead. see 06. |

---

## HOMEPAGE_ALLOWED_HOSTS is not here

it is set inline in the compose file, not in `.env`, because it contains no
secret. it lists hostnames. see 02 for the values and the reason.

---

*previous: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
*next: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
