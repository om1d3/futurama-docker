# bender environment variable reference

## complete .env documentation

**document version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

---

## table of contents

1. [overview](#overview)
2. [house rules](#house-rules)
3. [variable categories](#variable-categories)
4. [complete variable reference](#complete-variable-reference)
5. [variables referenced in docker-compose.yaml](#variables-referenced-in-docker-composeyaml)
6. [variables used outside docker-compose](#variables-used-outside-docker-compose)
7. [security classification](#security-classification)
8. [generating secure values](#generating-secure-values)
9. [known audit items](#known-audit-items)

---

## overview

the `.env` file at `/mnt/BIG/filme/docker-compose/.env` contains all configuration values and secrets for bender's docker compose deployment. it is loaded automatically by `docker compose` and also sourced by secure-container-update.sh (which reads `WATCHTOWER_NOTIFICATION_URL` from it).

the file contains **31 active variables** across 16 categories. of these, **16 contain secrets** and 15 are non-sensitive configuration values. the git-tracked forms are `.env.gpg` (AES256-encrypted full file) and `.env.example` (values stripped) in the futurama-docker repo – the plain `.env` is gitignored.

---

## house rules

these were each learned the hard way; they are rules, not suggestions:

1. **version correlation:** the `.env` header version tracks the docker-compose.yaml version. every compose bump that touches `.env` (add/remove/change a variable) also bumps the `.env` header to the same number with a dated changelog entry. an `.env` claiming v104 while carrying v111 and v115 variables is undocumented drift. since 2026-07-21, versions are calendar dates (`YYYYMMDD`; a second same-day edit appends `.2`, then `.3`), harmonized across both hosts; the older sequential numbers (bender …v115, amy …v104) remain valid historical identifiers.
2. **secrets in hex, not base64:** generated secrets use `openssl rand -hex N`. base64's `/`, `+`, `=` characters corrupted vikunja's JWT handling (v114 incident); hex is safe in every env, URL, and YAML context.
3. **no secret values in comments:** comments are not stripped by the `sed 's/=.*/=/'` sanitization used to produce `.env.example` or to share the file structure. a "to be reused" password stashed in a comment leaks the moment the file is sanitized-and-shared. metadata comments (expiry dates, generation instructions) are fine and encouraged.
4. **recreation is mandatory:** `.env` changes reach a running container only via `docker compose up -d --force-recreate <service>`. `up -d` alone does not re-read the environment.
5. **verify with inspect, not exec:** confirm what a container actually received with `docker inspect <c> --format '{{range .Config.Env}}{{println .}}{{end}}'`. `docker exec <c> env` shows the shell's view, which can differ (entrypoint mutations, PID-1 vs exec session).
6. **chmod 600:** the file contains 17 secrets. `chmod 600 /mnt/BIG/filme/docker-compose/.env`.

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
| update notifications | 1 | 0 |
| vikunja | 1 | 1 |
| forgejo | 1 | 1 |
| **total** | **31** | **16** |

---

## complete variable reference

### system

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `TIMEZONE` | `America/Toronto` | no | nearly all containers (TZ) – cron schedules and log timestamps assume this zone |
| `PUID` | `1000` | no | linuxserver-style containers: dockwatch, jellyfin, transmission, prowlarr, sonarr, radarr, lidarr, readarr, bazarr, syncthing; jdownloader (as USER_ID) |
| `PGID` | `1000` | no | same set (jdownloader as GROUP_ID) |
| `LOCAL_NETWORK` | `10.30.0.0/24` | no | reference only (not used in docker-compose) |
| `BENDER_HOST_IP` | `10.30.0.12` | no | tsdproxy (TSDPROXY_HOSTNAME), pihole (FTLCONF_LOCAL_IPV4) |

### paths (reference only – not used by docker-compose)

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `BASE_PATH` | `/mnt/BIG/filme` | no | documentation reference |
| `CONFIG_PATH` | `/mnt/BIG/filme/configs` | no | documentation reference |

### tailscale

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `TAILSCALE_DOMAIN` | `bunny-enigmatic.ts.net` | no | reference only (since v114, when vikunja's PUBLICURL stopped using it); hedgedoc uses HEDGEDOC_DOMAIN |
| `TSDPROXY_AUTHKEY` | `tskey-auth-...` | **yes** | tsdproxy – feeds BOTH `TSDPROXY_AUTHKEY` and `TS_AUTHKEY` in the container |

the auth key expires periodically – keep the expiry date in a comment above the variable (a good example of non-secret metadata in comments). when it lapses, tsdproxy re-auth fails after the next restart and every tailscale URL dies together.

(20260721 removed the redundant `TS_AUTHKEY` .env variable – the compose derives the container's `TS_AUTHKEY` from `TSDPROXY_AUTHKEY`.)

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

get OpenVPN credentials from: Surfshark → Manual setup → Router/Other → OpenVPN. the historical haugene/transmission-openvpn variables remain in the file as commented-out reference only.

### postgresql

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `POSTGRES_PASSWORD` | (hex string) | **yes** | postgres, postgres-backup, immich_server (DB_PASSWORD), hedgedoc (CMD_DB_URL), vikunja (VIKUNJA_DATABASE_PASSWORD); baikal uses it too, but via its web-UI database configuration rather than env |

this is the shared-superuser credential for four of the five tenants. forgejo deliberately does NOT use it – see FORGEJO_DB_PASSWORD.

### hedgedoc

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `HEDGEDOC_SESSION_SECRET` | (hex string) | **yes** | hedgedoc (CMD_SESSION_SECRET) |
| `HEDGEDOC_DOMAIN` | `pad.bunny-enigmatic.ts.net` | no | hedgedoc (CMD_DOMAIN) |

### vaultwarden

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `VAULTWARDEN_ADMIN_TOKEN` | (argon2 hash or random) | **yes** | vaultwarden (ADMIN_TOKEN) |

### beszel

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `BESZEL_KEY` | `ssh-ed25519 AAAA...` | **yes** | beszel-agent (KEY) |
| `BESZEL_TOKEN` | (random string) | **yes** | not used in docker-compose (agent registration with the hub on amy) |

### pihole

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `PIHOLE_PASSWORD` | (random string) | **yes** | pihole (WEBPASSWORD), nebula-sync (PRIMARY and REPLICAS URLs) |

nebula-sync assumes bender's and amy's pihole share this password – changing it means changing it on both hosts and recreating nebula-sync.

### ntfy/diun notifications

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `NTFY_ADDRESS` | `http://10.30.0.11:8888` | no | diun (DIUN_NOTIF_NTFY_ENDPOINT) |
| `DIUN_NTFY_TOPIC` | `container-updates-bender` | no | diun (DIUN_NOTIF_NTFY_TOPIC) |

`NTFY_ADDRESS` points at amy's ntfy. amy publishes ntfy on host port 8888 (container port 80), and lrrr demonstrably notifies via `http://10.30.0.11:8888/...`. <!-- VERIFY: the live NTFY_ADDRESS port (value was stripped during sanitization); align with 8888 if it differs -->

### ARR stack API keys

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `SONARR_API_KEY` | (from Sonarr UI) | **yes** | unpackerr (UN_SONARR_0_API_KEY) |
| `RADARR_API_KEY` | (from Radarr UI) | **yes** | unpackerr (UN_RADARR_0_API_KEY) |
| `LIDARR_API_KEY` | (from Lidarr UI) | **yes** | unpackerr (UN_LIDARR_0_API_KEY) |
| `READARR_API_KEY` | (from Readarr UI) | **yes** | unpackerr (UN_READARR_0_API_KEY) |

get each key from the respective app's Settings → General → API Key. unpackerr reaches the apps at `http://gluetun:<port>`.

### keepalived

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `KEEPALIVED_PASSWORD` | (hex string) | **yes** | keepalived (KEEPALIVED_PASSWORD) – must be identical on bender and amy |
| `KEEPALIVED_VIP` | `10.30.0.2` | no | reference only (keepalived.conf uses the hardcoded VIP) |

### update notifications

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `WATCHTOWER_NOTIFICATION_URL` | (ntfy URL incl. topic) | no | secure-container-update.sh (sourced from .env; legacy name from the watchtower era) |

### vikunja (v111, v114)

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `VIKUNJA_JWT_SECRET` | (hex string – `openssl rand -hex 32`) | **yes** | vikunja (VIKUNJA_SERVICE_JWTSECRET) |

**must be hex** (v114 incident) and must be a real secret – a placeholder here invalidates every session. changing it logs every user out (by design).

### forgejo (v115)

| variable | example value | secret | consumers |
|----------|--------------|--------|-----------|
| `FORGEJO_DB_PASSWORD` | (hex string) | **yes** | forgejo (FORGEJO__database__PASSWD) – password of the dedicated `forgejo` postgres user |

if this changes, it must change in postgres too: `ALTER USER forgejo WITH PASSWORD '<new>';` then force-recreate forgejo.

---

## variables referenced in docker-compose.yaml

these variables are directly interpolated by `docker compose`:

| variable | services using it |
|----------|-------------------|
| `TIMEZONE` | dockwatch, diun, gluetun, pihole, nebula-sync, postgres-backup, immich_server, immich_machine_learning, jellyfin, audiobookshelf, transmission, metube, jdownloader, spotdl, hedgedoc, vaultwarden, baikal, vikunja, forgejo, prowlarr, sonarr, radarr, lidarr, readarr, bazarr, unpackerr, flaresolverr, lrrr |
| `PUID` / `PGID` | dockwatch, jellyfin, transmission, prowlarr, sonarr, radarr, lidarr, readarr, bazarr, syncthing; jdownloader (USER_ID/GROUP_ID) |
| `BENDER_HOST_IP` | tsdproxy, pihole |
| `TSDPROXY_AUTHKEY` | tsdproxy (twice: TSDPROXY_AUTHKEY + TS_AUTHKEY) |
| `SYNCTHING_HOSTNAME` | syncthing |
| `SURFSHARK_OPENVPN_USER` / `SURFSHARK_OPENVPN_PASSWORD` | gluetun |
| `GLUETUN_SERVER_COUNTRY` | gluetun |
| `POSTGRES_PASSWORD` | postgres, postgres-backup, immich_server, hedgedoc, vikunja |
| `HEDGEDOC_SESSION_SECRET` / `HEDGEDOC_DOMAIN` | hedgedoc |
| `VAULTWARDEN_ADMIN_TOKEN` | vaultwarden |
| `BESZEL_KEY` | beszel-agent |
| `PIHOLE_PASSWORD` | pihole, nebula-sync |
| `NTFY_ADDRESS` / `DIUN_NTFY_TOPIC` | diun |
| `SONARR_API_KEY` / `RADARR_API_KEY` / `LIDARR_API_KEY` / `READARR_API_KEY` | unpackerr |
| `KEEPALIVED_PASSWORD` | keepalived |
| `VIKUNJA_JWT_SECRET` | vikunja |
| `FORGEJO_DB_PASSWORD` | forgejo |

---

## variables used outside docker-compose

| variable | used by | purpose |
|----------|---------|---------|
| `WATCHTOWER_NOTIFICATION_URL` | secure-container-update.sh | ntfy notification URL (script sources .env; `NTFY_URL="${WATCHTOWER_NOTIFICATION_URL:-}"`) |
| `BESZEL_TOKEN` | agent registration | used during initial beszel agent setup, not in docker-compose |
| `LOCAL_NETWORK` / `BASE_PATH` / `CONFIG_PATH` / `KEEPALIVED_VIP` / `TAILSCALE_DOMAIN` | reference | documentation only in 20260721 |

---

## security classification

### secrets (16 variables) – never commit to git, never in comments

| variable | generation method |
|----------|-------------------|
| `TSDPROXY_AUTHKEY` | Tailscale admin console → Auth Keys (note expiry in a comment) |
| `SURFSHARK_OPENVPN_USER` / `SURFSHARK_OPENVPN_PASSWORD` | Surfshark dashboard → Manual setup → OpenVPN |
| `POSTGRES_PASSWORD` | `openssl rand -hex 32` |
| `HEDGEDOC_SESSION_SECRET` | `openssl rand -hex 32` |
| `VAULTWARDEN_ADMIN_TOKEN` | argon2 hash (preferred) or `openssl rand -hex 32` |
| `BESZEL_KEY` / `BESZEL_TOKEN` | generated by beszel hub during agent registration |
| `PIHOLE_PASSWORD` | user-chosen (same on amy) |
| `KEEPALIVED_PASSWORD` | `openssl rand -hex 16` (same on both hosts) |
| `SONARR_API_KEY` / `RADARR_API_KEY` / `LIDARR_API_KEY` / `READARR_API_KEY` | auto-generated by each app (Settings → General) |
| `VIKUNJA_JWT_SECRET` | `openssl rand -hex 32` – hex mandatory |
| `FORGEJO_DB_PASSWORD` | `openssl rand -hex 24` – must match the postgres `forgejo` user |

### non-sensitive (15 variables) – safe to include in examples

TIMEZONE, PUID, PGID, LOCAL_NETWORK, BENDER_HOST_IP, BASE_PATH, CONFIG_PATH, TAILSCALE_DOMAIN, SYNCTHING_HOSTNAME, GLUETUN_SERVER_COUNTRY, HEDGEDOC_DOMAIN, NTFY_ADDRESS, DIUN_NTFY_TOPIC, KEEPALIVED_VIP, WATCHTOWER_NOTIFICATION_URL

---

## generating secure values

```bash
# postgres password / hedgedoc session secret / vikunja JWT secret
openssl rand -hex 32

# forgejo database user password
openssl rand -hex 24

# keepalived password (must match on both hosts)
openssl rand -hex 16

# vaultwarden admin token (argon2 – preferred)
# install argon2: apt install argon2  (developer mode + bookworm repo required)
echo -n "YourAdminPassword" | argon2 "$(openssl rand -hex 16)" -e -id -k 65540 -t 3 -p 4

# tailscale auth key
# generate at: https://login.tailscale.com/admin/settings/keys
# record the expiry date in a comment above the variable
```

house rule: **hex everywhere** for generated string secrets. base64 is reserved for cases where a consumer explicitly requires it.

---

## known audit items

- **header drift (being fixed):** the live `.env` header read "Version: 104" while carrying v111 (`VIKUNJA_JWT_SECRET`) and v115 (`FORGEJO_DB_PASSWORD`) additions with no changelog entries. rule 1 above is the corrective; the 20260721 deploy sets the header to 20260721 and logs the v111/v114/v115 entries retroactively (DEPLOY-2026-07-21.md step 2).
- **TS_AUTHKEY redundancy (resolved, 20260721):** removed from `.env` – the compose derives the container's TS_AUTHKEY from `${TSDPROXY_AUTHKEY}`, so the standalone variable was dead weight and a second copy of a secret.
- **secret leaked via comment (remediated):** a candidate keepalived password lived in a `# to be reused -->` comment and survived a sed-sanitization. treat that value as burned; rule 3 exists because of this.
- **TSDPROXY_AUTHKEY expiry:** the current key's noted expiry is 2026-07-24 – rotation is due imminently (new key in `.env`, then `docker compose up -d --force-recreate tsdproxy`).


---

## variables required by the 20260809 compose

**provenance.** verified against both the compose file and the `.env` file
on 2026-08-10. the compose consumes 27 variables. the `.env` file defines
34. the seven extra are covered further down.

27 variables are referenced:

| variable | consumed by | sensitive |
|----------|-------------|-----------|
| TIMEZONE | almost every service | no |
| PUID / PGID | dockwatch, jellyfin, transmission, the ARR stack, jdownloader, syncthing | no |
| BENDER_HOST_IP | tsdproxy, pihole (FTLCONF_LOCAL_IPV4) | no |
| TAILSCALE_DOMAIN | referenced by service URLs | no |
| SYNCTHING_HOSTNAME | syncthing | no |
| HEDGEDOC_DOMAIN | hedgedoc | no |
| NTFY_ADDRESS | diun | no |
| DIUN_NTFY_TOPIC | diun | no |
| GLUETUN_SERVER_COUNTRY | gluetun | no |
| TSDPROXY_AUTHKEY | tsdproxy, mapped to both TSDPROXY_AUTHKEY and TS_AUTHKEY | **yes** |
| POSTGRES_PASSWORD | postgres, postgres-backup, immich, hedgedoc, vikunja | **yes** |
| FORGEJO_DB_PASSWORD | forgejo | **yes** |
| INFLUXDB_ADMIN_PASSWORD | influxdb | **yes** |
| INFLUXDB_USER_PASSWORD | influxdb | **yes** |
| PIHOLE_PASSWORD | pihole, nebula-sync (both PRIMARY and REPLICAS) | **yes** |
| KEEPALIVED_PASSWORD | keepalived | **yes** |
| VAULTWARDEN_ADMIN_TOKEN | vaultwarden | **yes** |
| HEDGEDOC_SESSION_SECRET | hedgedoc | **yes** |
| VIKUNJA_JWT_SECRET | vikunja | **yes** |
| SURFSHARK_OPENVPN_USER | gluetun | **yes** |
| SURFSHARK_OPENVPN_PASSWORD | gluetun | **yes** |
| BESZEL_KEY | beszel-agent | **yes** |
| SONARR_API_KEY | unpackerr | **yes** |
| RADARR_API_KEY | unpackerr | **yes** |
| LIDARR_API_KEY | unpackerr | **yes** |
| READARR_API_KEY | unpackerr | **yes** |

17 of 27 are secrets. so this file is the single highest-value target on
bender, which is why it is committed only as GPG ciphertext.

---

## the two influxdb variables (20260807)

`INFLUXDB_USER_PASSWORD` must equal the value Home Assistant holds in its
`secrets.yaml` as `influxdb_password`. Home Assistant authenticates as the
`hass` user. if the two drift, Home Assistant connects and then fails on
every write.

`INFLUXDB_ADMIN_PASSWORD` belongs to the `admin` account, which has rights
over everything. it is used only for maintenance from bender. it is read
once, at first container start, when InfluxDB creates the user. after that
the variable is never consulted again. so losing it means resetting the
user from inside the container, not editing `.env`.

---

## nebula-sync carries the Pi-hole password twice

```
PRIMARY=http://10.30.0.12:8053|${PIHOLE_PASSWORD}
REPLICAS=http://10.30.0.11:8053|${PIHOLE_PASSWORD}
```

both hosts must use the same Pi-hole password, because one variable feeds
both sides. a rotation is therefore a two-host operation.

---

## a redaction caveat

a pattern that matches `NAME=value` lines will not catch a secret written
inside a comment. that exact case occurred on amy: a credential sat in a
comment marked "to be reused" and survived the redaction pass.

read the whole file before sharing it, not only the assignments.


---

## the file's own structure

`.env` is organised into commented sections, which the table above does not
reflect:

`SYSTEM`, `PATHS`, `TAILSCALE`, `SYNCTHING`, `SURFSHARK OPENVPN`,
`OLD OPENVPN CREDENTIALS` (commented out), `POSTGRESQL`, `HEDGEDOC`,
`VAULTWARDEN`, `BESZEL AGENT`, `PI-HOLE`, `NTFY NOTIFICATIONS`,
`ARR STACK API KEYS`, `SILVERBULLET` (commented out), `KEEPALIVED`.

two sections carry generation hints worth keeping:

```
# HEDGEDOC_SESSION_SECRET - generate with: openssl rand -hex 32
# VAULTWARDEN_ADMIN_TOKEN - generate with: echo "$(openssl rand -base64 48)"
```

---

## seven variables the compose does not consume

these exist in `.env` but appear in no `${...}` reference in the compose
file. three are used elsewhere, four are dead.

**used by scripts, not by compose:**

| variable | consumer |
|----------|----------|
| WATCHTOWER_NOTIFICATION_URL | secure-container-update.sh, for its ntfy notifications. the file says so in a comment. |
| LOCAL_NETWORK | referenced by scripts and documentation, not by a service |
| KEEPALIVED_VIP | documents the floating IP, 10.30.0.2. keepalived reads its own conf file rather than this variable. |

**dead or reference-only:**

| variable | status |
|----------|--------|
| BASE_PATH | the file marks it "reference only - not used by docker-compose" |
| CONFIG_PATH | same |
| BESZEL_TOKEN | defined, consumed by nothing. only BESZEL_KEY is used, by beszel-agent. amy carries the same unused variable. |
| TS_AUTHKEY | see the contradiction below |

do not delete the first three. a script failing for want of a variable is a
harder fault to find than a tidy file is worth.

---

## three drift findings (2026-08-10)

### the header is five versions behind

```
# Version: 104 - Switched to OpenVPN, cleaned up unused variables
```

the compose file is at 20260809. so house rule 1, which requires the `.env`
header to track the compose version, has not been applied since v104.

the changelog inside the file confirms it. a `v113 CHANGES` block sits below
the `v104` header, so changes were recorded without the header being bumped.

**note also that the changelog runs oldest-first here**, with v104 above
v113. the compose file's changelog runs newest-first. the two conventions
disagree, which makes the newest entry hard to find.

### TS_AUTHKEY still exists

the compose changelog for 20260721 states:

> ALSO (in .env, same version): REMOVED redundant TS_AUTHKEY variable –
> compose derives the container's TS_AUTHKEY from ${TSDPROXY_AUTHKEY}

the variable is still present in `.env`. so either the removal was never
applied, or it was reintroduced.

it is harmless, because the compose maps both container variables from
`${TSDPROXY_AUTHKEY}` regardless. but it is a duplicate credential, and a
rotation that updates one and not the other creates a mismatch that is hard
to see. **amy holds the same pair for the same reason**, and on amy both are
genuinely referenced by the compose.

### a credential sits in a comment

```
# to be reused --> ...
```

directly below `KEEPALIVED_PASSWORD`. amy carried an identical line, and it
held a live 32-character value.

this matters beyond the value itself. a redaction pass that matches
`NAME=value` lines does not catch a secret written inside a comment. so
**read the whole file before sharing it**, not only the assignments.

three commented blocks in this file follow the same pattern and should be
checked the same way: the old OpenVPN credentials, the SILVERBULLET_USER
line, and this one.

---

## pending edits

| edit | reason |
|------|--------|
| bump the header to the current compose version | house rule 1 |
| add a changelog block for the influxdb variables | they arrived in 20260807 with no entry |
| delete the "to be reused" comment line | plaintext credential in a comment |
| decide on TS_AUTHKEY | remove it, or record why it is kept |
| decide on BESZEL_TOKEN | consumed by nothing on either host |

the Tailscale expiry comment is already current, and reads
`### expires on 2026 October 29`.

---

*previous: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
*next: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
