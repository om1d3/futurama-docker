# bender services catalog

## complete service reference

**document version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

---

## table of contents

1. [services overview](#services-overview)
2. [infrastructure services](#infrastructure-services)
3. [VPN](#vpn)
4. [DNS and high availability](#dns-and-high-availability)
5. [databases and cache](#databases-and-cache)
6. [photo management](#photo-management)
7. [media servers](#media-servers)
8. [download clients](#download-clients)
9. [ARR stack – media automation](#arr-stack--media-automation)
10. [collaboration](#collaboration)
11. [calendar and contacts](#calendar-and-contacts)
12. [task management](#task-management)
13. [git forge](#git-forge)
14. [text-to-speech](#text-to-speech)
15. [monitoring](#monitoring)
16. [commented and profiles services](#commented-and-profiles-services)
17. [port reference](#port-reference)
18. [tailscale URL reference](#tailscale-url-reference)
19. [service dependencies](#service-dependencies)

---

## services overview

bender defines 42 services and runs 41; epub2tts-edge is `profiles: tools` and runs on demand. 30 use the bridge network (media-network), 3 use host networking, 8 route through gluetun's VPN tunnel, and 1 uses docker.sock only (autoheal).

| category | count | services |
|----------|-------|----------|
| infrastructure | 4 | tsdproxy, dockwatch, dockerproxy, autoheal |
| VPN | 1 | gluetun |
| DNS & HA | 3 | pihole, keepalived, nebula-sync |
| databases & cache | 3 | postgres, postgres-backup, immich_redis |
| photo management | 2 | immich_server, immich_machine_learning |
| media servers | 2 | jellyfin, audiobookshelf |
| download clients | 4 | transmission, metube, jdownloader, spotdl |
| ARR stack | 7 | prowlarr, sonarr, radarr, lidarr, readarr, bazarr, unpackerr |
| collaboration | 3 | hedgedoc, vaultwarden, syncthing |
| calendar & contacts | 1 | baikal |
| task management | 1 | vikunja |
| git forge | 1 | forgejo |
| text-to-speech | 2 | edge-tts, audiobook-foundry |
| time-series | 1 | influxdb |
| remote management | 1 | meshcentral |
| monitoring | 2 | beszel-agent, cadvisor |
| updates | 2 | diun, trivy |
| support | 1 | flaresolverr |
| **total active** | **41** | |
| **total defined** | **42** | epub2tts-edge is `profiles: tools` |

---

## infrastructure services

### tsdproxy

| setting | value |
|---------|-------|
| image | `almeidapaulopt/tsdproxy@sha256:e75357d5...` (pinned 20260808) |
| container | tsdproxy |
| port | 8085:8080 |
| network | media-network |
| tsdproxy.name | `bender-proxy` (LOCKED) |
| environment | TSDPROXY_AUTHKEY + TS_AUTHKEY (both from `${TSDPROXY_AUTHKEY}`), TSDPROXY_HOSTNAME=`${BENDER_HOST_IP}`, TSNET_FORCE_LOGIN=1 |
| purpose | tailscale reverse proxy – provides `*.bunny-enigmatic.ts.net` URLs for all tsdproxy-enabled services |

the TS_AUTHKEY duplication and TSNET_FORCE_LOGIN=1 exist to force tsnet nodes to re-authenticate cleanly after a host reboot (mirrors amy's v101/v104 fixes). **the auth key expires periodically** – when tailscale URLs die en masse after a reboot, a fresh key in `.env` plus `docker compose up -d --force-recreate tsdproxy` is the fix.

### dockwatch

| setting | value |
|---------|-------|
| image | `ghcr.io/notifiarr/dockwatch:main` |
| container | dockwatch |
| port | 9999:80 |
| network | media-network |
| tsdproxy.name | `bender-dockwatch` (LOCKED) |
| healthcheck | curl http://localhost:80 |
| purpose | container management web UI |

### dockerproxy

| setting | value |
|---------|-------|
| image | `ghcr.io/tecnativa/docker-socket-proxy:latest` |
| container | dockerproxy |
| port | 2375:2375 |
| network | media-network |
| tsdproxy | disabled |
| exposed API | CONTAINERS, IMAGES, INFO, NETWORKS, SERVICES, TASKS, VOLUMES (read-only socket) |
| purpose | read-only docker socket proxy for homepage on amy – DO NOT REMOVE |

### autoheal (v106)

| setting | value |
|---------|-------|
| image | `willfarrell/autoheal:latest` |
| container | autoheal |
| port | none |
| network | none (docker.sock only) |
| tsdproxy | disabled |
| config | AUTOHEAL_CONTAINER_LABEL=autoheal, AUTOHEAL_INTERVAL=60, AUTOHEAL_START_PERIOD=300, AUTOHEAL_DEFAULT_STOP_TIMEOUT=10 |
| purpose | auto-restarts containers with `autoheal: "true"` label when Docker reports them unhealthy. currently targets gluetun for stale VPN session recovery |

---

## VPN

### gluetun

| setting | value |
|---------|-------|
| image | `qmcgaw/gluetun:latest` |
| container | gluetun |
| network | media-network |
| tsdproxy | disabled |
| labels | `autoheal: "true"` (v106) |
| VPN provider | Surfshark |
| VPN type | OpenVPN (v104: switched from WireGuard) |
| server country | `${GLUETUN_SERVER_COUNTRY}` (Romania) |
| healthcheck | `wget http://1.1.1.1/cdn-cgi/trace \| grep warp=` – IP-based, avoids DNS (v106) |
| update pipeline | **critical service** since script v1.3 – see [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md) |

**ports exposed through gluetun:**

| port | service |
|------|---------|
| 9091:9091 | transmission |
| 51413:51413 TCP+UDP | transmission peer |
| 9696:9696 | prowlarr |
| 8989:8989 | sonarr |
| 7878:7878 | radarr |
| 8686:8686 | lidarr |
| 8787:8787 | readarr |
| 6767:6767 | bazarr |
| 5800:5800 | jdownloader |

when gluetun is recreated (update or manual `--force-recreate`), all eight namespace tenants must be recreated too – a container attached to a destroyed namespace does not recover on its own.

---

## DNS and high availability

### pihole

| setting | value |
|---------|-------|
| image | `pihole/pihole:latest` |
| container | pihole |
| ports | 53:53 (TCP+UDP), 8053:80 |
| network | media-network (no DNS anchor – it IS the DNS) |
| tsdproxy.name | `pihole-bender` (LOCKED) |
| upstream DNS | 1.1.1.1, 8.8.8.8 |
| FTLCONF_LOCAL_IPV4 | `${BENDER_HOST_IP}` (10.30.0.12) |
| healthcheck | `dig +norecurse +retry=0 @127.0.0.1 pi.hole` |

> **platform note (2026-07-29):** this HA pair is the designated split-horizon resolver for the k8s platform's `*.apps.<domain>` names – records created here on the MASTER, distributed by nebula-sync. Design: infrastructure-requirements.md §2 (futurama-terraform).

### keepalived

| setting | value |
|---------|-------|
| image | `osixia/keepalived:2.0.20` (pinned) |
| container | keepalived |
| network | host |
| interface | ens1f0 (v113: moved from enp4s0 to the 10G NIC) |
| role | MASTER (priority 200) |
| VIP | 10.30.0.2 |
| VRRP ID | 53 |
| mode | unicast (peer: 10.30.0.11) |
| health check | wget pihole admin (:8053) every 2s, weight -150 |
| purpose | pihole DNS failover with amy |

### nebula-sync

| setting | value |
|---------|-------|
| image | `ghcr.io/lovelaze/nebula-sync:latest` |
| container | nebula-sync |
| network | media-network |
| tsdproxy | disabled |
| PRIMARY | http://10.30.0.12:8053 |
| REPLICAS | http://10.30.0.11:8053 (amy) |
| schedule | hourly (`0 * * * *`), FULL_SYNC=true, RUN_GRAVITY=true |
| healthcheck | disabled (minimal container has no binaries) |
| purpose | replicates pihole config from bender to amy |

---

## databases and cache

### postgres

| setting | value |
|---------|-------|
| image | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` |
| container | postgres |
| port | 5432:5432 |
| network | media-network |
| databases | **immich, hedgedoc, baikal, vikunja, forgejo** (five tenants) |
| users | `postgres` superuser (immich, hedgedoc, baikal, vikunja) + dedicated `forgejo` user (v115) |
| data path | `/mnt/BIG/filme/immich/postgresql` (CRITICAL – path name historical, carries all five databases) |
| init scripts | `/mnt/BIG/filme/configs/postgres/init` (read-only) |
| healthcheck | `pg_isready -U postgres -d immich` |
| extensions | vchord.so, vectors.so (shared_preload_libraries) |
| tuning | max_wal_size=2GB, shared_buffers=512MB, wal_compression=on |

forgejo's dedicated user is the exception to the superuser-sharing pattern and the template for future tenants. creating a new tenant the forgejo way:

```bash
docker exec -it postgres psql -U postgres -c "CREATE USER <svc> WITH PASSWORD '<secret>';"
docker exec -it postgres psql -U postgres -c "CREATE DATABASE <svc> OWNER <svc>;"
```

### postgres-backup

| setting | value |
|---------|-------|
| image | `prodrigestivill/postgres-backup-local:14` (20260721: pinned – major-matched to postgres 14) |
| container | postgres-backup |
| network | media-network |
| databases backed up | immich, hedgedoc, baikal, vikunja, forgejo |
| schedule | daily (`SCHEDULE=@daily` – container-internal, unaffected by host cron) |
| retention | 7 days, 4 weeks, 6 months |
| backup path | `/mnt/BIG/filme/backups/postgres` |
| healthcheck | curl http://localhost:8080 |
| depends on | postgres |

adding a database to postgres is not enough – it must also be appended to this container's `POSTGRES_DB` list **and the container recreated** (`up -d` alone does not apply env changes). verify with:

```bash
docker inspect postgres-backup --format '{{json .Config.Env}}' | tr ',' '\n' | grep POSTGRES_DB
```

### immich_redis

| setting | value |
|---------|-------|
| image | `redis:7-alpine` (v94: upgraded from 6.2) |
| container | immich_redis |
| network | media-network |
| data path | `/mnt/BIG/filme/immich/redis` |
| healthcheck | `redis-cli ping` |

---

## photo management

### immich_server

| setting | value |
|---------|-------|
| image | `ghcr.io/immich-app/immich-server:release` |
| container | immich_server |
| port | 2283:2283 |
| network | media-network |
| tsdproxy.name | `photo` (LOCKED) |
| photo path | `/mnt/BIG/filme/immich/photos` |
| resource limits | mem_limit 2G, cpus 2.0 (v112) |
| depends on | postgres, immich_redis |

### immich_machine_learning

| setting | value |
|---------|-------|
| image | `ghcr.io/immich-app/immich-machine-learning:release` |
| container | immich_machine_learning |
| network | media-network |
| cache path | `/mnt/BIG/filme/immich/ml-cache` |
| resource limits | mem_limit 3G, cpus 1.5 (v112) |
| job concurrency | 1 for all jobs – set in Admin UI, stored in DB, re-verify after restores |
| healthcheck | python3 HTTP GET to localhost:3003/ping (v104) |

the v112 limits exist because unconstrained ML workers OOMed the host during bulk uploads (load 10.96, `txg_sync` stalls >120s). do not raise them without re-reading that incident.

---

## media servers

### jellyfin

| setting | value |
|---------|-------|
| image | `lscr.io/linuxserver/jellyfin:10.11.11` (v114: **PINNED**) |
| container | jellyfin |
| port | 8096:8096 |
| network | media-network |
| tsdproxy.name | `media` (LOCKED) |
| libraries | movies (`/data/movies`), tvshows (`/data/tvshows`), music (`/data/music`) |
| GPU | disabled (HP BIOS limitation – commented out for future use) |

**pin policy (v114):** the floating `10.11` tag does not exist on lscr.io, so the pin is to the full patch version. bump 10.11.x patch tags manually when Diun notifies; NEVER move to major 12 without a deliberate migration. **Diun blind spot:** Diun watches the pinned tag, so it announces re-pushes of 10.11.11 but not the existence of 10.11.12 – check linuxserver's tags when a patch is rumored.

### audiobookshelf

| setting | value |
|---------|-------|
| image | `ghcr.io/advplyr/audiobookshelf:latest` |
| container | audiobookshelf |
| port | 8081:80 |
| network | media-network |
| tsdproxy.name | `books` (LOCKED) |
| libraries | audiobooks, podcasts, metadata |
| integration | audiobook-foundry outputs to `/audiobooks/cărți/` for automatic pickup |

---

## download clients

### transmission (v108: custom build)

| setting | value |
|---------|-------|
| build | `/mnt/BIG/filme/configs/transmission/Dockerfile` |
| base image | `lscr.io/linuxserver/transmission:4.0.5` (PINNED – FileList whitelist) |
| container | transmission |
| port | 9091:9091, 51413 TCP+UDP (via gluetun) |
| network | service:gluetun |
| tsdproxy.name | `transmission` (LOCKED) |
| web UI | Flood (pre-baked in custom image, v108) |
| download queue | 10 concurrent (v107) |
| seed queue | 50 concurrent (v107) |
| cache | 64 MB (v107) |
| peer limits | 300 global, 30 per torrent (v107) |
| depends on | gluetun |

**DO NOT UPGRADE** past 4.0.5 – FileList whitelist requirement. transmission 4.0.6+ results in immediate ban.

### metube

| setting | value |
|---------|-------|
| image | `ghcr.io/alexta69/metube:latest` |
| container | metube |
| port | 8383:8081 |
| network | media-network |
| tsdproxy.name | `metube` (LOCKED) |

### jdownloader

| setting | value |
|---------|-------|
| image | `jlesage/jdownloader-2:latest` |
| container | jdownloader |
| port | 5800:5800 (via gluetun) |
| network | service:gluetun |
| tsdproxy.name | `jdown` (LOCKED) |
| depends on | gluetun |

### spotdl

| setting | value |
|---------|-------|
| image | `spotdl/spotify-downloader:latest` (v94: corrected) |
| container | spotdl |
| port | 8800:8800 |
| network | media-network |
| tsdproxy.name | `spotdl` (LOCKED) |
| command | `web --host 0.0.0.0 --port 8800 --web-use-output-dir --keep-alive --format mp3` |

---

## ARR stack – media automation

all ARR services route through gluetun VPN and depend on it.

### prowlarr

| setting | value |
|---------|-------|
| image | `lscr.io/linuxserver/prowlarr:latest` |
| container | prowlarr |
| port | 9696:9696 (via gluetun) |
| network | service:gluetun |
| tsdproxy.name | `prowlarr` (LOCKED) |
| purpose | indexer manager for all ARR apps |

### sonarr

| setting | value |
|---------|-------|
| image | `lscr.io/linuxserver/sonarr:latest` |
| container | sonarr |
| port | 8989:8989 (via gluetun) |
| network | service:gluetun |
| tsdproxy.name | `sonarr` (LOCKED) |
| volumes | /tv → seriale, /downloads → transmission |

### radarr

| setting | value |
|---------|-------|
| image | `lscr.io/linuxserver/radarr:latest` |
| container | radarr |
| port | 7878:7878 (via gluetun) |
| network | service:gluetun |
| tsdproxy.name | `radarr` (LOCKED) |
| volumes | /movies → filme, /downloads → transmission |

### lidarr

| setting | value |
|---------|-------|
| image | `lscr.io/linuxserver/lidarr:latest` |
| container | lidarr |
| port | 8686:8686 (via gluetun) |
| network | service:gluetun |
| tsdproxy.name | `lidarr` (LOCKED) |
| volumes | /music → music, /downloads → transmission |

### readarr

| setting | value |
|---------|-------|
| image | `linuxserver/readarr:0.4.19-nightly` (v94: pinned) |
| container | readarr |
| port | 8787:8787 (via gluetun) |
| network | service:gluetun |
| tsdproxy.name | `readarr` (LOCKED) |
| volumes | /books → books, /downloads → transmission |

### bazarr

| setting | value |
|---------|-------|
| image | `lscr.io/linuxserver/bazarr:latest` |
| container | bazarr |
| port | 6767:6767 (via gluetun) |
| network | service:gluetun |
| tsdproxy.name | `bazarr` (LOCKED) |
| volumes | /movies → filme, /tv → seriale |

### unpackerr

| setting | value |
|---------|-------|
| image | `golift/unpackerr:latest` |
| container | unpackerr |
| network | media-network |
| tsdproxy | disabled |
| purpose | auto-extracts downloaded archives for sonarr, radarr, lidarr, readarr |
| note | connects to ARR apps via `http://gluetun:<port>` using API keys |

### flaresolverr

| setting | value |
|---------|-------|
| image | `ghcr.io/flaresolverr/flaresolverr:latest` |
| container | flaresolverr |
| port | 8191:8191 |
| network | media-network |
| tsdproxy | disabled |
| purpose | Cloudflare challenge solver for prowlarr |

---

## collaboration

### hedgedoc

| setting | value |
|---------|-------|
| image | `quay.io/hedgedoc/hedgedoc:latest` |
| container | hedgedoc |
| port | 3000:3000 |
| network | media-network |
| tsdproxy.name | `pad` (LOCKED) |
| database | postgres (hedgedoc DB, postgres superuser) |
| depends on | postgres |

### vaultwarden (migrated from amy in v92)

| setting | value |
|---------|-------|
| image | `vaultwarden/server:latest` |
| container | vaultwarden |
| port | 8484:80 |
| network | media-network |
| tsdproxy.name | `vault` (LOCKED) |
| healthcheck | curl http://localhost:80/alive |
| data | `/mnt/BIG/filme/configs/vaultwarden` (replicated nightly to amy) |

### syncthing

| setting | value |
|---------|-------|
| image | `syncthing/syncthing:latest` |
| container | syncthing |
| network | host |
| hostname | `${SYNCTHING_HOSTNAME}` |
| tsdproxy.name | `sync` (LOCKED), container_port 8384 |
| data path | `/mnt/BIG/filme/syncthing` |
| healthcheck | curl 127.0.0.1:8384/rest/noauth/health |

---

## calendar and contacts

### baikal (v110)

| setting | value |
|---------|-------|
| image | `ckulka/baikal:nginx` |
| container | baikal |
| port | 8001:80 |
| network | media-network |
| tsdproxy.name | `calendar` (LOCKED) |
| database | postgres (baikal DB, postgres superuser – configured via Baikal web UI) |
| volumes | configs/baikal/config → /var/www/baikal/config, configs/baikal/data → /var/www/baikal/Specific |
| healthcheck | curl http://localhost/ |
| depends on | postgres |
| purpose | CalDAV/CardDAV server for calendar and contact sync |

---

## task management

### vikunja (v111, v114)

| setting | value |
|---------|-------|
| image | `vikunja/vikunja:latest` |
| container | vikunja |
| port | 3456:3456 |
| network | media-network |
| tsdproxy.name | `tasks` (LOCKED) |
| database | postgres (vikunja DB, postgres superuser) |
| PUBLICURL | `http://tasks.home.arpa:3456` (v114 – must match the browsed origin) |
| JWT secret | `${VIKUNJA_JWT_SECRET}` – **hex, not base64** |
| session TTL | 2592000s (30 days); 7776000s (90 days with "Stay logged in") – v114 |
| registration | enabled (`VIKUNJA_SERVICE_ENABLEREGISTRATION=true`) |
| files | configs/vikunja/files → /app/vikunja/files (chown 1000) |
| depends on | postgres |

**v114 session lessons, encoded here so they never recur:**
- PUBLICURL must equal the origin users actually browse. mismatch with the tailscale URL caused malformed-token logouts. trade-off accepted: generated links use the LAN URL, and the app only fully works on the `tasks.home.arpa:3456` path.
- the JWT secret must be a real secret in hex (`openssl rand -hex 32`). a base64 value's `/`, `+`, `=` characters corrupted sessions; a placeholder value invalidated them.
- env changes reach the container only via `docker compose up -d --force-recreate vikunja`.

---

## git forge

### forgejo (v115)

| setting | value |
|---------|-------|
| image | `codeberg.org/forgejo/forgejo:15` (v15 LTS, supported to 2027-07) |
| container | forgejo |
| ports | 3030:3000 (HTTP), 2222:22 (git SSH) |
| network | media-network |
| tsdproxy.name | `git` (LOCKED) |
| database | postgres – dedicated `forgejo` user and database (`${FORGEJO_DB_PASSWORD}`) |
| ROOT_URL | `http://git.home.arpa:3030/` |
| SSH | DOMAIN git.home.arpa, SSH_PORT 2222 |
| registration | disabled (single-user; admin created on first launch) |
| UID/GID | 1000:1000 (`chown 1000:1000 /mnt/BIG/filme/configs/forgejo`) |
| data | configs/forgejo → /data (replicated nightly to amy) |
| depends on | postgres |
| purpose | version control for futurama-terraform IaC; permanently on bender – source of truth must not live on the cluster it defines |

**operational notes:** push-to-create is off – create the repo in the UI (uninitialized) first, then push. the rolling `:15` tag covers minor/patch only; major upgrades are manual and deliberate. clone URLs: `http://git.home.arpa:3030/<user>/<repo>.git` or `ssh://git@git.home.arpa:2222/<user>/<repo>.git`.

---

## text-to-speech

### edge-tts (v108)

| setting | value |
|---------|-------|
| image | `travisvn/openai-edge-tts:latest` |
| container | edge-tts |
| port | 5050:5050 |
| network | media-network |
| tsdproxy | disabled |
| default voice | ro-RO-AlinaNeural |
| API | OpenAI-compatible TTS endpoint |
| resource limits | 512 MB memory, 0.6 CPU |

### audiobook-foundry (v108, v109, v113, 20260729)

| setting | value |
|---------|-------|
| build | `/mnt/BIG/filme/configs/tts-pipeline/Dockerfile` (context path kept after rename) |
| container | audiobook-foundry (v113: tts-pipeline to lrrr; 20260729: lrrr to audiobook-foundry) |
| port | 5051:5051 |
| network | media-network |
| tsdproxy.name | `tts` (LOCKED – name survived the rename) |
| resource limits | 4 GB memory, 0.6 CPU |
| notifications | ntfy via `NTFY_URL=http://10.30.0.11:8888/tts-pipeline` (topic kept from before the rename) |
| input directories | /input/ro-emil, /input/ro-alina, /input/en-ryan, /input/en-sonia |
| output | `/audiobooks/cărți/` (audiobookshelf library) |
| web UI | Flask app on port 5051 (file upload + URL pasting) |

voice mapping:

| directory | voice | language |
|-----------|-------|----------|
| ro-emil | ro-RO-EmilNeural | Romanian male |
| ro-alina | ro-RO-AlinaNeural | Romanian female |
| en-ryan | en-GB-RyanNeural | British male |
| en-sonia | en-GB-SoniaNeural | British female |

---

## monitoring

### beszel-agent

| setting | value |
|---------|-------|
| image | `henrygd/beszel-agent:latest` |
| container | beszel-agent |
| network | host |
| tsdproxy | disabled |
| purpose | reports system metrics to beszel hub on amy (10.30.0.11:8090) |

### cadvisor (20260721)

| setting | value |
|---------|-------|
| image | `gcr.io/cadvisor/cadvisor:latest` |
| container | cadvisor |
| port | 9099:8080 |
| network | media-network |
| tsdproxy.name | `bender-cadvisor` (LOCKED) |
| flags | `--docker_only`, `--housekeeping_interval=30s`, disabled unused metrics |
| purpose | container resource metrics → prometheus (HA VM) → grafana |

### diun

| setting | value |
|---------|-------|
| image | `crazymax/diun:latest` |
| container | diun |
| network | media-network |
| tsdproxy | disabled |
| schedule | daily 06:00 (`DIUN_WATCH_SCHEDULE=0 6 * * *`), 20 workers, watch-by-default |
| notifications | ntfy – endpoint `${NTFY_ADDRESS}`, topic `${DIUN_NTFY_TOPIC}` |
| purpose | notifies on new image tags (including re-pushes of pinned tags – see jellyfin blind-spot note) |

### trivy

| setting | value |
|---------|-------|
| image | `aquasec/trivy:latest` |
| container | trivy |
| port | 8083:8080 (`server --listen 0.0.0.0:8080`) |
| network | media-network |
| tsdproxy | disabled |
| cache | configs/trivy → /root/.cache/trivy |
| purpose | CVE scanning server for the secure update pipeline |

---

## commented and profiles services

### qbittorrent (commented – v103)

removed in v103 after causing repeated system crashes due to ZFS I/O patterns on HP MicroServer Gen8. kept commented for potential future use.

### playwright-chrome (commented)

kept for future ARR stack browser automation. not currently needed.

### epub2tts-edge (profiles: tools – v108)

on-demand manual EPUB/TXT → M4B converter (mem_limit 4G, cpus 0.6). not part of the regular active stack. run with:

```bash
docker compose run --rm epub2tts-edge
```

---

## port reference

### direct ports (host:container)

| host port | container port | service |
|-----------|---------------|---------|
| 53 | 53 | pihole (TCP+UDP) |
| 2222 | 22 | forgejo (git SSH) |
| 2283 | 2283 | immich_server |
| 2375 | 2375 | dockerproxy |
| 3000 | 3000 | hedgedoc |
| 3030 | 3000 | forgejo (HTTP) |
| 3456 | 3456 | vikunja |
| 5050 | 5050 | edge-tts |
| 5051 | 5051 | audiobook-foundry |
| 8086 | 8086 | influxdb |
| 8584 | 80 | meshcentral (redirect) |
| 8585 | 443 | meshcentral (web, KVM) |
| 5432 | 5432 | postgres |
| 8001 | 80 | baikal |
| 8053 | 80 | pihole web |
| 8081 | 80 | audiobookshelf |
| 8083 | 8080 | trivy |
| 8085 | 8080 | tsdproxy |
| 8096 | 8096 | jellyfin |
| 8191 | 8191 | flaresolverr |
| 8383 | 8081 | metube |
| 8484 | 80 | vaultwarden |
| 8800 | 8800 | spotdl |
| 9099 | 8080 | cadvisor |
| 9999 | 80 | dockwatch |

### ports exposed via gluetun

| host port | container port | service |
|-----------|---------------|---------|
| 5800 | 5800 | jdownloader |
| 6767 | 6767 | bazarr |
| 7878 | 7878 | radarr |
| 8686 | 8686 | lidarr |
| 8787 | 8787 | readarr |
| 8989 | 8989 | sonarr |
| 9091 | 9091 | transmission |
| 9696 | 9696 | prowlarr |
| 51413 | 51413 | transmission peer (TCP+UDP) |

---

## tailscale URL reference

all 24 services with `tsdproxy.enable: "true"` are accessible via tailscale:

| tsdproxy.name | URL | service |
|---------------|-----|---------|
| bender-proxy | https://bender-proxy.bunny-enigmatic.ts.net | tsdproxy |
| bender-dockwatch | https://bender-dockwatch.bunny-enigmatic.ts.net | dockwatch |
| pihole-bender | https://pihole-bender.bunny-enigmatic.ts.net | pihole |
| photo | https://photo.bunny-enigmatic.ts.net | immich_server |
| media | https://media.bunny-enigmatic.ts.net | jellyfin |
| books | https://books.bunny-enigmatic.ts.net | audiobookshelf |
| transmission | https://transmission.bunny-enigmatic.ts.net | transmission |
| metube | https://metube.bunny-enigmatic.ts.net | metube |
| jdown | https://jdown.bunny-enigmatic.ts.net | jdownloader |
| spotdl | https://spotdl.bunny-enigmatic.ts.net | spotdl |
| pad | https://pad.bunny-enigmatic.ts.net | hedgedoc |
| vault | https://vault.bunny-enigmatic.ts.net | vaultwarden |
| calendar | https://calendar.bunny-enigmatic.ts.net | baikal |
| tasks | https://tasks.bunny-enigmatic.ts.net | vikunja (see PUBLICURL caveat – full functionality on LAN URL only) |
| git | https://git.bunny-enigmatic.ts.net | forgejo |
| sync | https://sync.bunny-enigmatic.ts.net | syncthing |
| prowlarr | https://prowlarr.bunny-enigmatic.ts.net | prowlarr |
| sonarr | https://sonarr.bunny-enigmatic.ts.net | sonarr |
| radarr | https://radarr.bunny-enigmatic.ts.net | radarr |
| lidarr | https://lidarr.bunny-enigmatic.ts.net | lidarr |
| readarr | https://readarr.bunny-enigmatic.ts.net | readarr |
| bazarr | https://bazarr.bunny-enigmatic.ts.net | bazarr |
| tts | https://tts.bunny-enigmatic.ts.net | audiobook-foundry |
| meshcentral | https://meshcentral.bunny-enigmatic.ts.net | meshcentral (verify-on-deploy: tsdproxy fronts an HTTPS backend) |
| bender-cadvisor | https://bender-cadvisor.bunny-enigmatic.ts.net | cadvisor |

LAN equivalents follow the pattern `http://<tsdproxy.name>.home.arpa:<host port>` via the pihole DNS auto-population (hourly scraper).

---

## service dependencies

### startup order

```
postgres (healthcheck: pg_isready)
├── immich_server
├── hedgedoc
├── baikal
├── vikunja
├── forgejo
└── postgres-backup

immich_redis (healthcheck: redis-cli ping)
└── immich_server

gluetun (healthcheck: wget http://1.1.1.1/cdn-cgi/trace)
├── transmission
├── jdownloader
├── prowlarr
├── sonarr
├── radarr
├── lidarr
├── readarr
└── bazarr
```

### cross-host dependencies

| bender service | depends on (amy) |
|---------------|-----------------|
| diun | ntfy (for notifications) |
| secure-container-update.sh | ntfy (for notifications) |
| smart-test.sh | ntfy (degradation alerts) |
| bender-replicate.sh | SSH + /docker/backups/bender-replica (replica target) |
| nebula-sync | pihole on amy (as replica target) |
| beszel-agent | beszel hub on amy (metrics collection) |
| pihole-dns-update.sh | docker API on amy via SSH (label scanning) |
| audiobook-foundry | ntfy (conversion notifications) |

| amy service | depends on (bender) |
|------------|---------------------|
| homepage | dockerproxy on bender (:2375) |
| pihole (amy) | nebula-sync push from bender |


---

## influxdb (20260807, 20260809)

| setting | value |
|---------|-------|
| image | `influxdb:1.11` (pinned; 1.x is REQUIRED) |
| container | influxdb |
| port | 8086:8086 |
| tsdproxy | disabled deliberately; this is a database, not a web service |
| network | media-network |
| database | homeassistant |
| users | admin (all privileges), hass (rights on `homeassistant` only) |
| data | `/mnt/BIG/filme/influxdb` – deliberately OUTSIDE `configs/` |
| ownership | uid **1500**, not 1000 |
| index | `INFLUXDB_DATA_INDEX_VERSION=tsi1` |
| retention | infinite (`autogen`), intentional |
| limits | mem 2G, cpus 1.0 |
| healthcheck | none; the image may not ship curl |

**why 1.x and not 2.x.** Home Assistant's `influxdb:` block uses
database, username and password, which is the 1.x API. a 2.x server needs
bucket, org and token instead. so the pin cannot be "upgraded" without
rewriting the Home Assistant configuration in the same change.

**why the data sits outside configs/.** `configs/` is a source in
bender-replicate.sh. ten years of telemetry does not belong in a nightly
config replica to amy. protection is ZFS snapshots instead.

**why uid 1500.** the influxdb image runs as that user, unlike forgejo
which uses 1000. the first deployment failed with
`mkdir /var/lib/influxdb/meta: permission denied` because of this.

**startup cost, and it repeats.** with the default in-memory index, opening
57 shards took hours, and one shard alone took 302 seconds. the in-memory
index is rebuilt at every start. with `tsi1` the same shards open in under
ten minutes. even so, this container needs several minutes before it
accepts connections, and every restart repeats that work. **do not
casually recreate it.**

**shard growth.** the default shard duration is 7 days, so about 52 shards
per year. against a 10-year retention target that reaches roughly 520
shards, and startup time scales with shard count. a longer shard duration
on the retention policy would cap this, and it applies to new shards only.
open decision.

---

## meshcentral (20260729)

| setting | value |
|---------|-------|
| image | `ghcr.io/ylianst/meshcentral:latest` |
| container | meshcentral |
| ports | 8584:80 (redirect), 8585:443 (web, KVM) – LOCKED |
| tsdproxy.name | `meshcentral` (LOCKED), container_port 443 |
| database | NeDB, built in; no postgres tenant, no mongo |
| data | `configs/meshcentral/meshcentral-data`, `meshcentral-files` |
| purpose | Intel AMT and vPro management for the 10.50.x fleet |

it manages zoidberg plus the EliteDesks (hermes, kif, zapp, nibbler) once
each has been provisioned through MEBx.

**NeDB is the right size here.** a fleet of about ten AMT devices does not
justify a database server.

**`meshcentral-data` will hold AMT credentials** once devices are enrolled.
confirm the `configs/` tree sits inside a backup scope.

**it needs a fry rule.** source 10.30.0.12 to destination 10.50.0.0/16, TCP
16992-16995 and 5900. inter-VLAN traffic is blocked by default.

**the tailscale path is verify-on-deploy.** tsdproxy terminates TLS and
proxies HTTP, while meshcentral is HTTPS-native. the LAN path at
`https://10.30.0.12:8585` works regardless. if the tailnet URL misbehaves,
flip `tsdproxy.container_port` to `"80"`.

**the first account to register becomes site admin.** create it immediately
after the first start.

---

*previous: [01-ARCHITECTURE.md](./01-ARCHITECTURE.md)*
*next: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
