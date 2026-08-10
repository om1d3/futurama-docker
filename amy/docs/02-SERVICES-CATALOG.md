# amy services catalog

## complete service reference

**document version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

---

## table of contents

1. [services overview](#services-overview)
2. [infrastructure services](#infrastructure-services)
3. [network config backup](#network-config-backup)
4. [DNS and high availability](#dns-and-high-availability)
5. [databases and cache](#databases-and-cache)
6. [notifications](#notifications)
7. [productivity](#productivity)
8. [finance](#finance)
9. [automation and support](#automation-and-support)
10. [monitoring](#monitoring)
11. [updates](#updates)
12. [commented services](#commented-services)
13. [port reference](#port-reference)
14. [tailscale URL reference](#tailscale-url-reference)
15. [service dependencies](#service-dependencies)

---

## services overview

amy defines 31 services and runs 25. six are parked with `profiles: ["parked"]` and are marked PARKED below. of the 25 running, 21 are on the bridge network (utility-network) and 4 on host networking.

| category | count | services |
|----------|-------|----------|
| infrastructure | 3 | tsdproxy, dockwatch, dozzle |
| network config backup | 1 | oxidized |
| DNS & HA | 2 | pihole, keepalived |
| databases & cache | 3 | postgres, postgres-backup, valkey |
| notifications | 1 | ntfy |
| productivity | 9 | stirling, homepage, atuin, miniflux, it-tools, filebrowser, wallos, mealie, lubelogger |
| release tracking | 1 | argus |
| finance | 2 | spendspentspent, tax-calculator |
| automation & support | 2 | limdius, playwright-chrome |
| monitoring | 5 | beszel, beszel-agent, cadvisor, netalertx, telegraf |
| updates | 2 | diun, trivy |
| **total defined** | **31** | |
| **running by default** | **25** | six parked: limdius, lubelogger, playwright-chrome, spendspentspent, tax-calculator, wallos |

---

## infrastructure services

### tsdproxy

| setting | value |
|---------|-------|
| image | `almeidapaulopt/tsdproxy@sha256:e75357d5...` (pinned 20260808) |
| container | tsdproxy |
| port | 8085:8080 |
| network | utility-network |
| tsdproxy.name | `amy-proxy` (LOCKED) |
| environment | TSDPROXY_AUTHKEY + TS_AUTHKEY (both `${TSDPROXY_AUTHKEY}`), TSDPROXY_HOSTNAME=`${AMY_HOST_IP}`, TSNET_FORCE_LOGIN=1 |
| purpose | tailscale reverse proxy for all amy services |

v101 added TSNET_FORCE_LOGIN=1 (silent auth failures → visible login prompt); v104 added TS_AUTHKEY and fixed AMY_HOST_IP after the subnet migration – tsnet nodes failing to re-authenticate after reboot, and proxies routing to the dead old IP, were the two post-migration tsdproxy failure modes.

### dockwatch

| setting | value |
|---------|-------|
| image | `ghcr.io/notifiarr/dockwatch:main` |
| container | dockwatch |
| port | 9999:80 |
| tsdproxy.name | `amy-dockwatch` (LOCKED) |
| purpose | container management web UI |

### dozzle

| setting | value |
|---------|-------|
| image | `amir20/dozzle:latest` |
| container | dozzle |
| port | 8182:8080 |
| tsdproxy.name | `logs` (LOCKED) |
| socket | read-only |
| purpose | live container log viewer |

---

## network config backup

### oxidized (v102)

| setting | value |
|---------|-------|
| image | `oxidized/oxidized:0.36.0` (pinned 20260810) |
| container | oxidized |
| port | 8889:8888 (REST API) |
| tsdproxy | disabled |
| schedule | hourly (CONFIG_RELOAD_INTERVAL=3600) |
| config | /docker/oxidized/config |
| device list | /docker/oxidized/router.db |
| target | nod (Cisco Catalyst 3750X) → GitHub om1d3/nod-config (private) |

the GitHub PAT (amy-oxidized) expires – when pushes stop while pulls of the device still succeed, the PAT is the first suspect. the PAT lives in the oxidized config, NOT in .env – keep it out of the futurama-docker repo.

---

## DNS and high availability

> **NAC rollout note (2026-07-29):** switch logins move to RADIUS-first AAA (`aaa authentication login default group radius local`). oxidized must keep a working login – an LLDAP service account or the local fallback – and **mom (Cisco SG350XG-24F) joins its targets**. Design: infrastructure-requirements.md §7 (futurama-terraform).

### pihole

| setting | value |
|---------|-------|
| image | `pihole/pihole:latest` |
| container | pihole |
| ports | 53:53 (TCP+UDP), 8053:80 |
| network | utility-network (no DNS anchor – it IS the DNS) |
| tsdproxy.name | `pihole-amy` (LOCKED) |
| upstream DNS | 9.9.9.9, 1.1.1.1 – DNSSEC=true |
| reverse lookups | REV_SERVER → 10.30.0.1 (fry), domain `lan`, CIDR 10.30.0.0/24 |
| FTLCONF_LOCAL_IPV4 | 10.30.0.11 |
| healthcheck | `dig +norecurse +retry=0 @127.0.0.1 pi.hole` – added in 20260810 (parity with bender). verified healthy. |

configuration is **owned by bender**: nebula-sync overwrites amy's pihole hourly with FULL_SYNC. local edits do not survive.

> **platform note (2026-07-29):** as the HA BACKUP, this instance receives the platform's `*.apps.<domain>` split-horizon records via nebula-sync – infrastructure-requirements.md §2.

### keepalived

| setting | value |
|---------|-------|
| image | `osixia/keepalived@sha256:19026918...` (20260810.2: pinned by digest, keepalived 2.3.4) |
| container | keepalived |
| network | host |
| config mount | /docker/keepalived/keepalived.conf → /etc/keepalived/keepalived.conf |
| role | BACKUP (priority 100), interface enp4s0, VRRP ID 53 |
| unicast | src 10.30.0.11 → peer 10.30.0.12 |
| VIP | 10.30.0.2/24 dev enp4s0 |
| health check | wget 127.0.0.1:8053/admin every 2s, weight -150, fall 3, rise 2 |

unlike bender, amy's compose passes no KEEPALIVED_PASSWORD env – the VRRP auth_pass sits **inline in keepalived.conf**. that value must equal bender's `${KEEPALIVED_PASSWORD}`, and because the conf is a plain mounted file it must never land in git unredacted (see 05 audit items).

---

## databases and cache

### postgres

| setting | value |
|---------|-------|
| image | `postgres:17-alpine` |
| container | postgres |
| port | 5432:5432 |
| databases | atuin, miniflux, sss, mealie, stirling (five tenants, `postgres` superuser) |
| data path | `/portainer/postgresql/data` (**legacy path – canonical**, restored in v94) |
| healthcheck | `pg_isready -U postgres` |

### postgres-backup

| setting | value |
|---------|-------|
| image | `prodrigestivill/postgres-backup-local:17` (major-matched tag, unlike bender's :latest) |
| container | postgres-backup |
| databases backed up | atuin, miniflux, sss, mealie, stirling |
| schedule | daily (internal @daily) |
| retention | 7 days, 4 weeks, 6 months |
| backup path | `/docker/postgres-backup` |
| depends on | postgres (condition: service_healthy) |

### valkey

| setting | value |
|---------|-------|
| image | `valkey/valkey:8-alpine` |
| container | valkey |
| port | 6379:6379 |
| persistence | appendonly yes |
| data path | /docker/valkey |
| purpose | redis-compatible cache – **no consumer found in the v104 compose** (no service references a valkey/redis host). either a consumer configures it outside env, or it runs unused <!-- VERIFY: valkey consumers, or retire it --> |

---

## notifications

### ntfy

| setting | value |
|---------|-------|
| image | `binwiederhier/ntfy:latest` |
| container | ntfy |
| port | 8888:80 |
| tsdproxy.name | `ntfy` (LOCKED) |
| volumes | /docker/ntfy/cache, /docker/ntfy/etc |
| purpose | notification hub for the ENTIRE infrastructure |

consumers: bender's diun, update script, smart-test, replication, lrrr; amy's own diun (via `http://ntfy:80` in-network). topics of note: container-updates-bender, container-updates-amy, tts-pipeline, plus the update/replication/SMART event streams. an ntfy outage means silent infrastructure – treat it as amy's most important service.

---

## productivity

### stirling

| setting | value |
|---------|-------|
| image | `stirlingtools/stirling-pdf:latest` (v96: corrected) |
| container | stirling |
| port | 8080:8080 |
| tsdproxy.name | `pdf` (LOCKED) |
| config | SYSTEM_MAXDPI=1200 (v97 – fixes the DPI-limit error), LANGS=en_US |
| database | a `stirling` database exists in postgres-backup's list, but this compose entry has **no DB config and no depends_on** – app↔DB linkage unverified <!-- VERIFY: stirling postgres usage (config files? vestigial DB?) --> |

### homepage

| setting | value |
|---------|-------|
| image | `ghcr.io/gethomepage/homepage:latest` |
| container | homepage |
| port | 3003:3000 |
| tsdproxy.name | `home` (LOCKED) |
| volumes | /docker/homepage (20260810: corrected from /docker/homepage/config), /docker/homepage/images, docker.sock (ro) |
| environment | TZ, HOMEPAGE_ALLOWED_HOSTS (20260810.2: REQUIRED, see below) |
| cross-host | bender widget via dockerproxy at 10.30.0.12:2375 |

### atuin

| setting | value |
|---------|-------|
| image | `ghcr.io/atuinsh/atuin:latest` |
| container | atuin |
| port | 8777:8888 |
| tsdproxy.name | `atuin` (LOCKED) |
| command | `start` (v99 – upstream renamed the binary; `server start` no longer exists) |
| registration | closed (ATUIN_OPEN_REGISTRATION=false) |
| database | atuin (postgres tenant) |

### miniflux

| setting | value |
|---------|-------|
| image | `miniflux/miniflux:latest` |
| container | miniflux |
| port | 8385:8080 |
| tsdproxy.name | `rss` (LOCKED) |
| origin config | BASE_URL=http://rss.home.arpa:8385, DISABLE_HTTP_ORIGIN_CHECK=1 (v103 – fixes cross-origin login failures) |
| admin | ADMIN_USERNAME/PASSWORD from .env, CREATE_ADMIN=1, RUN_MIGRATIONS=1 |
| database | miniflux (postgres tenant) |

the v103 origin fix is miniflux's version of vikunja's v114 lesson on bender: apps that validate their public URL bind to one access path.

### it-tools

| setting | value |
|---------|-------|
| image | `corentinth/it-tools:latest` |
| container | it-tools |
| port | 8181:80 |
| tsdproxy.name | `it-tools` (LOCKED) |
| purpose | developer utility grab-bag; stateless |

### filebrowser

| setting | value |
|---------|-------|
| image | `filebrowser/filebrowser:latest` |
| container | filebrowser |
| port | 8082:80 |
| tsdproxy.name | `files` |
| browse roots | /docker → /srv/docker, /portainer → /srv/portainer |

### wallos

| setting | value |
|---------|-------|
| image | `bellamy/wallos:latest` |
| container | wallos |
| port | 8283:80 |
| tsdproxy.name | `wallos` (LOCKED) |
| data | /docker/wallos/db |
| purpose | subscription tracking |

### mealie

| setting | value |
|---------|-------|
| image | `ghcr.io/mealie-recipes/mealie:latest` (v96: corrected) |
| container | mealie |
| port | 8456:9000 |
| tsdproxy.name | `mealie` (LOCKED) |
| BASE_URL | https://mealie.${TAILSCALE_DOMAIN} |
| workers | MAX_WORKERS=1, WEB_CONCURRENCY=1 (i3 courtesy) |
| database | mealie (postgres tenant, v85.3 migration) |

### lubelogger

| setting | value |
|---------|-------|
| image | `ghcr.io/hargata/lubelogger:latest` |
| container | lubelogger |
| port | 8989:8080 |
| tsdproxy.name | `lube` (LOCKED) |
| volumes | config, data, temp, log, keys, documents under /docker/lubelogger |
| note | v91 removed unauthorized SMTP config – minimal configuration is the approved state |

### argus

| setting | value |
|---------|-------|
| image | `releaseargus/argus:latest` (v85.3: corrected) |
| container | argus |
| port | 8282:8080 |
| tsdproxy.name | `argus` (LOCKED) |
| purpose | upstream release tracking |

---

## finance

### spendspentspent

| setting | value |
|---------|-------|
| image | `gonzague/spendspentspent:latest` |
| container | spendspentspent |
| port | 9021:9001 |
| tsdproxy.name | `money` (LOCKED) |
| database | sss (postgres tenant), SALT=`${SSS_SALT}` |
| browser automation | PLAYWRIGHT_URL=ws://playwright-chrome:3000 |
| signups | disabled |
| volumes | app-files, files (v86), config (v95) |
| criticality | one of amy's four critical update-system services |

### tax-calculator (v100)

| setting | value |
|---------|-------|
| image | `nginx:alpine` |
| container | tax-calculator |
| port | 8484:80 |
| tsdproxy.name | `tax` (LOCKED) |
| content | /docker/tax/html (read-only) – Ontario T1 calculator, 2024 & 2025, multi-T4, CPP/EI overpayment detection |
| state | none – pure static site |

---

## automation and support

### limdius

| setting | value |
|---------|-------|
| image | `python:3.11-slim` (v85.3: corrected) |
| container | limdius |
| port | 5050:5050 |
| tsdproxy.name | `limdius` |
| app | /docker/limdius/limdius.py, deps installed at start (requests, flask, playwright) |
| browser automation | PLAYWRIGHT_DRIVER_URL=ws://playwright-chrome:3000 |

### playwright-chrome

| setting | value |
|---------|-------|
| image | `browserless/chrome:latest` |
| container | playwright-chrome |
| port | 3100:3000 |
| tsdproxy | disabled |
| limits | 10 concurrent sessions, 300s connection timeout, queue 10 |
| consumers | spendspentspent, limdius |

(distinct from bender's commented playwright-chrome – amy's actually runs.)

---

## monitoring

### beszel (hub)

| setting | value |
|---------|-------|
| image | `henrygd/beszel:latest` |
| container | beszel |
| port | 8090:8090 |
| tsdproxy.name | `beszel` (LOCKED) |
| data | /docker/beszel/data |
| agents | bender's beszel-agent + amy's own |
| criticality | critical update-system service |

### beszel-agent

| setting | value |
|---------|-------|
| image | `henrygd/beszel-agent:latest` |
| network | host, PORT=45876 |
| purpose | amy's own metrics into the hub |

### cadvisor

| setting | value |
|---------|-------|
| image | `gcr.io/cadvisor/cadvisor:latest` |
| port | 9099:8080 |
| tsdproxy.name | `cadvisor` (LOCKED) |
| flags | docker_only, 30s housekeeping, disabled unused metrics (v98) |
| pipeline | → prometheus (10.30.0.41:9090) → grafana (instance Constant 10.30.0.11:9099) |

### netalertx

| setting | value |
|---------|-------|
| image | `jokobsk/netalertx:latest` (v96: fixed volume + capabilities) |
| network | host, PORT=20211 |
| tsdproxy.name | `netalertx` |
| caps | NET_RAW, NET_ADMIN, NET_BIND_SERVICE |
| purpose | LAN device discovery/alerting |

### telegraf (v98)

| setting | value |
|---------|-------|
| image | `telegraf:latest` |
| network | host |
| config | /portainer/telegraf/config/telegraf.conf (legacy path – canonical) |
| targets | nod (Cisco 3750X) + Brother MFC-L3710CW via SNMP |
| outputs | <!-- VERIFY: destination in telegraf.conf --> |

---

## updates

> **NAC rollout note (2026-07-29):** the printer's future 802.1X-era firewall policy explicitly permits **SNMP UDP 161 from amy** so this polling survives the rollout – encoded in infrastructure-requirements.md §9.

### diun

| setting | value |
|---------|-------|
| image | `crazymax/diun:latest` |
| command | serve |
| schedule | wednesday 04:00 (`0 4 * * 3`), 10 workers, watch-by-default |
| notifications | endpoint `http://ntfy:80` (in-network), topic `${DIUN_NTFY_TOPIC}` |

### trivy

| setting | value |
|---------|-------|
| image | `aquasec/trivy:latest` |
| command | `server --listen 0.0.0.0:4954` |
| port | 8083:4954 |
| cache | /docker/trivy/cache → /tmp/trivy (TRIVY_CACHE_DIR) |
| script URL | http://localhost:8083 (matches the mapping – no bender-style port mismatch here) |

---

## commented services

### watchtower

kept commented as an emergency fallback updater (`!! DO NOT REMOVE !!`). the secure update system replaced it; the legacy `WATCHTOWER_NOTIFICATION_URL` variable name on bender is its fossil.

---

## port reference

| host port | container port | service |
|-----------|---------------|---------|
| 53 | 53 | pihole (TCP+UDP) |
| 3003 | 3000 | homepage |
| 3100 | 3000 | playwright-chrome |
| 5050 | 5050 | limdius |
| 5432 | 5432 | postgres |
| 6379 | 6379 | valkey |
| 8053 | 80 | pihole web |
| 8080 | 8080 | stirling |
| 8082 | 80 | filebrowser |
| 8083 | 4954 | trivy |
| 8085 | 8080 | tsdproxy |
| 8090 | 8090 | beszel |
| 8181 | 80 | it-tools |
| 8182 | 8080 | dozzle |
| 8282 | 8080 | argus |
| 8283 | 80 | wallos |
| 8385 | 8080 | miniflux |
| 8456 | 9000 | mealie |
| 8484 | 80 | tax-calculator |
| 8777 | 8888 | atuin |
| 8888 | 80 | ntfy |
| 8889 | 8888 | oxidized |
| 8989 | 8080 | lubelogger |
| 9021 | 9001 | spendspentspent |
| 9099 | 8080 | cadvisor |
| 9999 | 80 | dockwatch |
| 20211 | (host) | netalertx |
| 45876 | (host) | beszel-agent |

---

## tailscale URL reference

21 services with `tsdproxy.enable: "true"`:

| tsdproxy.name | URL | service |
|---------------|-----|---------|
| amy-proxy | https://amy-proxy.bunny-enigmatic.ts.net | tsdproxy |
| amy-dockwatch | https://amy-dockwatch.bunny-enigmatic.ts.net | dockwatch |
| logs | https://logs.bunny-enigmatic.ts.net | dozzle |
| pihole-amy | https://pihole-amy.bunny-enigmatic.ts.net | pihole |
| ntfy | https://ntfy.bunny-enigmatic.ts.net | ntfy |
| pdf | https://pdf.bunny-enigmatic.ts.net | stirling |
| home | https://home.bunny-enigmatic.ts.net | homepage |
| atuin | https://atuin.bunny-enigmatic.ts.net | atuin |
| rss | https://rss.bunny-enigmatic.ts.net | miniflux (full login on LAN origin only – v103) |
| it-tools | https://it-tools.bunny-enigmatic.ts.net | it-tools |
| files | https://files.bunny-enigmatic.ts.net | filebrowser |
| wallos | https://wallos.bunny-enigmatic.ts.net | wallos |
| mealie | https://mealie.bunny-enigmatic.ts.net | mealie |
| argus | https://argus.bunny-enigmatic.ts.net | argus |
| lube | https://lube.bunny-enigmatic.ts.net | lubelogger |
| money | https://money.bunny-enigmatic.ts.net | spendspentspent |
| tax | https://tax.bunny-enigmatic.ts.net | tax-calculator |
| limdius | https://limdius.bunny-enigmatic.ts.net | limdius |
| beszel | https://beszel.bunny-enigmatic.ts.net | beszel |
| cadvisor | https://cadvisor.bunny-enigmatic.ts.net | cadvisor |
| netalertx | https://netalertx.bunny-enigmatic.ts.net | netalertx |

LAN equivalents: `http://<name>.home.arpa:<host port>` (DNS entries harvested by bender's scraper via SSH).

---

## service dependencies

### startup order

```
postgres (healthcheck: pg_isready; dependents gate on service_healthy)
├── postgres-backup
├── atuin
├── miniflux
├── mealie
└── spendspentspent

playwright-chrome (no formal depends_on)
├── spendspentspent (PLAYWRIGHT_URL)
└── limdius (PLAYWRIGHT_DRIVER_URL)
```

### cross-host dependencies

| amy service | depends on (bender) |
|------------|---------------------|
| homepage | dockerproxy (:2375) |
| pihole | nebula-sync push |

| bender service | depends on (amy) |
|---------------|-----------------|
| all notification producers | ntfy (:8888) |
| bender-replicate.sh | SSH + replica directory |
| nebula-sync | pihole (:8053) |
| beszel-agent | beszel hub (:8090) |
| pihole-dns-update.sh | docker API via SSH |


---

## parked services (20260810)

six services carry `profiles: ["parked"]`. they are defined but do not start
with a plain `docker compose up -d`. they were stopped by hand on
2026-08-08, and the profile makes that state part of the configuration
instead of a manual act that every `up -d` reversed.

| service | port | tsdproxy.name | why parked |
|---------|------|---------------|------------|
| limdius | 5050 | `limdius` | owner decision |
| lubelogger | 8989 | `lube` | owner decision |
| playwright-chrome | 3100 | disabled | owner decision |
| spendspentspent | 9021 | `money` | owner decision |
| tax-calculator | 8484 | `tax` | owner decision |
| wallos | 8283 | `wallos` | owner decision |

### starting a parked service

```bash
docker compose up -d tax-calculator      # one service, on demand
docker compose --profile parked up -d    # all six
```

**caution.** `docker compose start <name>` does NOT enable the profile.
only `up -d` does. this is a documented compose behaviour, not a local
quirk.

**caution.** explicitly targeting one parked service starts only that
service, plus anything it declares in `depends_on`. other services in the
same profile stay down.

three homepage tiles report NOT FOUND for lubelogger, limdius and
spendspentspent, because their containers were removed. the tiles are kept
on purpose, so the dashboard shows what is parked.

---

## homepage host validation (20260810.2)

homepage 16.2.6 refuses any request whose `Host` header is not listed in
`HOMEPAGE_ALLOWED_HOSTS`. only `localhost:3000` and `127.0.0.1:3000` are
allowed by default. every other request returns:

```
Error
Host validation failed. See logs for more details.
```

the log names the exact rejected value, including the port:

```bash
docker logs --tail 20 homepage | grep -i "host validation"
```

amy is reached three ways, so all three are listed:

```yaml
- HOMEPAGE_ALLOWED_HOSTS=10.30.0.11:3003,home.arpa:3003,home.bunny-enigmatic.ts.net
```

the value must match the log output exactly. the browser sends the
published host port, 3003, not the container port 3000. the tailnet name
carries no port, because tsdproxy terminates on 443.

adding a new access path to homepage means adding an entry here.

---

*previous: [01-ARCHITECTURE.md](./01-ARCHITECTURE.md)*
*next: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
