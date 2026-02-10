# bender services catalog

## complete service reference

**document version:** 2.0
**infrastructure version:** 105
**last updated:** february 2026

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
9. [ARR stack — media automation](#arr-stack--media-automation)
10. [collaboration](#collaboration)
11. [utilities](#utilities)
12. [monitoring](#monitoring)
13. [commented services](#commented-services)
14. [port reference](#port-reference)
15. [tailscale URL reference](#tailscale-url-reference)
16. [service dependencies](#service-dependencies)

---

## services overview

bender runs 33 active services. 22 use the bridge network (media-network), 3 use host networking, and 8 route through gluetun's VPN tunnel.

| category | count | services |
|----------|-------|----------|
| infrastructure | 5 | tsdproxy, dockwatch, dockerproxy, diun, trivy |
| VPN | 1 | gluetun |
| DNS and HA | 3 | pihole, keepalived, nebula-sync |
| databases and cache | 4 | postgres, postgres-backup, immich_redis, flaresolverr |
| photo management | 2 | immich_server, immich_machine_learning |
| media servers | 2 | jellyfin, audiobookshelf |
| download clients | 4 | transmission, metube, jdownloader, spotdl |
| ARR stack | 7 | prowlarr, sonarr, radarr, lidarr, readarr, bazarr, unpackerr |
| collaboration | 2 | hedgedoc, vaultwarden |
| utilities | 1 | syncthing |
| monitoring | 2 | beszel-agent, cadvisor |
| **total** | **33** | |

---

## infrastructure services

### tsdproxy

| property | value |
|----------|-------|
| **image** | `almeidapaulopt/tsdproxy:latest` |
| **container** | tsdproxy |
| **host port** | 8085 |
| **internal port** | 8080 |
| **tsdproxy.name** | `bender-proxy` (LOCKED) |
| **network** | media-network |
| **purpose** | tailscale reverse proxy — automatically creates tailscale nodes for services with `tsdproxy.enable: "true"` labels |
| **volumes** | docker.sock (rw), tsdproxy data + config |
| **depends on** | docker socket |

### dockwatch

| property | value |
|----------|-------|
| **image** | `ghcr.io/notifiarr/dockwatch:main` |
| **container** | dockwatch |
| **host port** | 9999 |
| **internal port** | 80 |
| **tsdproxy.name** | `bender-dockwatch` (LOCKED) |
| **network** | media-network |
| **purpose** | container management web UI |
| **healthcheck** | curl http://localhost:80 |

### dockerproxy

| property | value |
|----------|-------|
| **image** | `ghcr.io/tecnativa/docker-socket-proxy:latest` |
| **container** | dockerproxy |
| **host port** | 2375 |
| **internal port** | 2375 |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | read-only docker socket proxy for homepage on amy — exposes container/image/network info without full docker access |
| **⚠️ warning** | do not remove — required for homepage widget on amy |

### diun

| property | value |
|----------|-------|
| **image** | `crazymax/diun:latest` |
| **container** | diun |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | monitors all container images for available updates, sends notifications to ntfy on amy |
| **schedule** | `0 6 * * *` (daily 06:00) |
| **ntfy endpoint** | `${NTFY_ADDRESS}` (remote — amy's ntfy) |
| **ntfy topic** | `${DIUN_NTFY_TOPIC}` |

### trivy

| property | value |
|----------|-------|
| **image** | `aquasec/trivy:latest` |
| **container** | trivy |
| **host port** | 8083 |
| **internal port** | 8080 |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | vulnerability scanner for container images — used by secure-container-update.sh |
| **cache** | `/mnt/BIG/filme/configs/trivy` |

---

## VPN

### gluetun

| property | value |
|----------|-------|
| **image** | `qmcgaw/gluetun:latest` |
| **container** | gluetun |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **VPN provider** | surfshark |
| **VPN type** | OpenVPN (v104 — WireGuard blocked peer connections) |
| **DNS-over-TLS** | off (`DOT=off`) |
| **server selection** | `${GLUETUN_SERVER_COUNTRY}` |
| **capabilities** | NET_ADMIN |
| **devices** | /dev/net/tun |
| **healthcheck** | wget http://ipinfo.io |

gluetun exposes ports for all VPN-routed services:

| port | service |
|------|---------|
| 9091 | transmission |
| 51413/tcp+udp | transmission peer port |
| 9696 | prowlarr |
| 8989 | sonarr |
| 7878 | radarr |
| 8686 | lidarr |
| 8787 | readarr |
| 6767 | bazarr |
| 5800 | jdownloader |

---

## DNS and high availability

### pihole

| property | value |
|----------|-------|
| **image** | `pihole/pihole:latest` |
| **container** | pihole |
| **host ports** | 53/tcp, 53/udp, 8053 |
| **tsdproxy.name** | `pihole-bender` (LOCKED) |
| **network** | media-network |
| **purpose** | primary DNS server with ad-blocking |
| **upstream DNS** | 1.1.1.1, 8.8.8.8 |
| **healthcheck** | `dig +norecurse +retry=0 @127.0.0.1 pi.hole` |
| **capabilities** | NET_ADMIN |

### keepalived

| property | value |
|----------|-------|
| **image** | `osixia/keepalived:2.0.20` (pinned) |
| **container** | keepalived |
| **network** | host |
| **role** | MASTER (priority 150) |
| **VIP** | 192.168.21.100 |
| **interface** | enp4s0 |
| **purpose** | VRRP failover — bender holds VIP under normal operation, amy takes over if bender fails |
| **config mount** | `/mnt/BIG/filme/configs/keepalived/keepalived.conf` (read-only) |
| **command** | `--copy-service` |

### nebula-sync

| property | value |
|----------|-------|
| **image** | `ghcr.io/lovelaze/nebula-sync:latest` |
| **container** | nebula-sync |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | synchronizes pihole configuration from bender (primary) to amy (replica) |
| **schedule** | `0 * * * *` (hourly) |
| **primary** | `http://192.168.21.121:8053` |
| **replica** | `http://192.168.21.130:8053` |
| **sync mode** | full sync with gravity rebuild |
| **healthcheck** | disabled (minimal container — no binaries available) |

---

## databases and cache

### postgres

| property | value |
|----------|-------|
| **image** | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` |
| **container** | postgres |
| **host port** | 5432 |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | shared postgresql with vector extensions for immich and hedgedoc |
| **databases** | immich (default), hedgedoc |
| **data path** | `/mnt/BIG/filme/immich/postgresql` (⚠️ CRITICAL — do not move) |
| **healthcheck** | `pg_isready -U postgres -d immich` |
| **extensions** | vchord.so, vectors.so (loaded via `shared_preload_libraries`) |
| **tuning** | max_wal_size=2GB, shared_buffers=512MB, wal_compression=on |

### postgres-backup

| property | value |
|----------|-------|
| **image** | `prodrigestivill/postgres-backup-local:latest` |
| **container** | postgres-backup |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | daily automated postgresql backups |
| **databases** | immich, hedgedoc |
| **schedule** | daily |
| **retention** | 7 daily, 4 weekly, 6 monthly |
| **backup path** | `/mnt/BIG/filme/backups/postgres` |
| **healthcheck** | curl http://localhost:8080 |

### immich_redis

| property | value |
|----------|-------|
| **image** | `redis:7-alpine` |
| **container** | immich_redis |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | redis cache for immich job queue and sessions |
| **data path** | `/mnt/BIG/filme/immich/redis` |
| **healthcheck** | `redis-cli ping` |
| **note** | upgraded from redis:6.2-alpine in v94 — fixes "Can't handle RDB format version 11" error |

### flaresolverr

| property | value |
|----------|-------|
| **image** | `ghcr.io/flaresolverr/flaresolverr:latest` |
| **container** | flaresolverr |
| **host port** | 8191 |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | CAPTCHA/cloudflare challenge solver for prowlarr indexer requests |

---

## photo management

### immich_server

| property | value |
|----------|-------|
| **image** | `ghcr.io/immich-app/immich-server:release` |
| **container** | immich_server |
| **host port** | 2283 |
| **tsdproxy.name** | `photo` (LOCKED) |
| **network** | media-network |
| **purpose** | photo and video management with face/object recognition |
| **photos path** | `/mnt/BIG/filme/immich/photos` |
| **depends on** | postgres, immich_redis |
| **ML connection** | `http://immich_machine_learning:3003` |

### immich_machine_learning

| property | value |
|----------|-------|
| **image** | `ghcr.io/immich-app/immich-machine-learning:release` |
| **container** | immich_machine_learning |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | ML model inference for face detection, object classification, and smart search |
| **cache path** | `/mnt/BIG/filme/immich/ml-cache` |
| **healthcheck** | python3 HTTP check on port 3003 (v104 fix — curl not available) |

---

## media servers

### jellyfin

| property | value |
|----------|-------|
| **image** | `lscr.io/linuxserver/jellyfin:latest` |
| **container** | jellyfin |
| **host port** | 8096 |
| **tsdproxy.name** | `media` (LOCKED) |
| **network** | media-network |
| **purpose** | media server for movies, TV shows, and music |
| **media volumes** | movies (`/data/movies`), TV shows (`/data/tvshows`), music (`/data/music`) |
| **GPU** | not available (HP BIOS disables iGPU) — CPU-only transcoding |
| **note** | v96 corrected image from `jellyfin/jellyfin` to `lscr.io/linuxserver/jellyfin`. v105 added `/data/tvshows` volume mount to fix library path mismatch |

### audiobookshelf

| property | value |
|----------|-------|
| **image** | `ghcr.io/advplyr/audiobookshelf:latest` |
| **container** | audiobookshelf |
| **host port** | 8081 |
| **tsdproxy.name** | `books` (LOCKED) |
| **network** | media-network |
| **purpose** | audiobook and podcast server with progress tracking |
| **config path** | `/mnt/BIG/filme/configs/audiobookshelf` |

---

## download clients

### transmission

| property | value |
|----------|-------|
| **image** | `lscr.io/linuxserver/transmission:4.0.5` (⚠️ PINNED — do not upgrade) |
| **container** | transmission |
| **host port** | 9091 (via gluetun), 51413 tcp+udp (via gluetun) |
| **tsdproxy.name** | `transmission` (LOCKED) |
| **network** | service:gluetun |
| **purpose** | torrent client — FileList whitelist requires version 4.0.5 |
| **mods** | flood UI, env-var-settings |
| **data path** | `/mnt/BIG/filme/transmission` (completed, incomplete, watch subdirs) |
| **⚠️ warning** | transmission 4.0.6+ is NOT on the FileList whitelist — do not upgrade |

### metube

| property | value |
|----------|-------|
| **image** | `ghcr.io/alexta69/metube:latest` |
| **container** | metube |
| **host port** | 8383 |
| **internal port** | 8081 |
| **tsdproxy.name** | `metube` (LOCKED) |
| **network** | media-network |
| **purpose** | youtube video/audio downloader web UI |

### jdownloader

| property | value |
|----------|-------|
| **image** | `jlesage/jdownloader-2:latest` |
| **container** | jdownloader |
| **host port** | 5800 (via gluetun) |
| **tsdproxy.name** | `jdown` (LOCKED) |
| **network** | service:gluetun |
| **purpose** | direct download manager with browser-based UI |

### spotdl

| property | value |
|----------|-------|
| **image** | `spotdl/spotify-downloader:latest` |
| **container** | spotdl |
| **host port** | 8800 |
| **tsdproxy.name** | `spotdl` (LOCKED) |
| **network** | media-network |
| **purpose** | spotify playlist/track downloader — web UI, saves as MP3 |
| **command** | `web --host 0.0.0.0 --port 8800 --web-use-output-dir --keep-alive --format mp3` |

---

## ARR stack — media automation

all ARR services route through gluetun VPN (network_mode: service:gluetun). unpackerr is the exception — it connects to the ARR APIs via the gluetun container's internal address.

### prowlarr

| property | value |
|----------|-------|
| **image** | `lscr.io/linuxserver/prowlarr:latest` |
| **container** | prowlarr |
| **host port** | 9696 (via gluetun) |
| **tsdproxy.name** | `prowlarr` (LOCKED) |
| **purpose** | indexer manager — provides search results to sonarr, radarr, lidarr, readarr |

### sonarr

| property | value |
|----------|-------|
| **image** | `lscr.io/linuxserver/sonarr:latest` |
| **container** | sonarr |
| **host port** | 8989 (via gluetun) |
| **tsdproxy.name** | `sonarr` (LOCKED) |
| **purpose** | TV show automation — monitors, downloads, and organizes episodes |
| **media path** | `/mnt/BIG/filme/seriale` → `/tv` |

### radarr

| property | value |
|----------|-------|
| **image** | `lscr.io/linuxserver/radarr:latest` |
| **container** | radarr |
| **host port** | 7878 (via gluetun) |
| **tsdproxy.name** | `radarr` (LOCKED) |
| **purpose** | movie automation — monitors, downloads, and organizes films |
| **media path** | `/mnt/BIG/filme/filme` → `/movies` |

### lidarr

| property | value |
|----------|-------|
| **image** | `lscr.io/linuxserver/lidarr:latest` |
| **container** | lidarr |
| **host port** | 8686 (via gluetun) |
| **tsdproxy.name** | `lidarr` (LOCKED) |
| **purpose** | music automation — monitors, downloads, and organizes albums |
| **media path** | `/mnt/BIG/filme/music` → `/music` |

### readarr

| property | value |
|----------|-------|
| **image** | `linuxserver/readarr:0.4.19-nightly` |
| **container** | readarr |
| **host port** | 8787 (via gluetun) |
| **tsdproxy.name** | `readarr` (LOCKED) |
| **purpose** | ebook automation — monitors, downloads, and organizes books |
| **media path** | `/mnt/BIG/filme/books` → `/books` |
| **note** | image pinned to `0.4.19-nightly` — fixed in v94 |

### bazarr

| property | value |
|----------|-------|
| **image** | `lscr.io/linuxserver/bazarr:latest` |
| **container** | bazarr |
| **host port** | 6767 (via gluetun) |
| **tsdproxy.name** | `bazarr` (LOCKED) |
| **purpose** | subtitle automation — downloads subtitles for sonarr and radarr media |
| **media paths** | movies (`/mnt/BIG/filme/filme`), TV (`/mnt/BIG/filme/seriale`) |

### unpackerr

| property | value |
|----------|-------|
| **image** | `golift/unpackerr:latest` |
| **container** | unpackerr |
| **tsdproxy.enable** | false |
| **network** | media-network |
| **purpose** | automatically extracts downloaded archives for sonarr, radarr, lidarr, readarr |
| **ARR connections** | connects to ARR APIs via `http://gluetun:<port>` |
| **API keys** | `${SONARR_API_KEY}`, `${RADARR_API_KEY}`, `${LIDARR_API_KEY}`, `${READARR_API_KEY}` |

---

## collaboration

### hedgedoc

| property | value |
|----------|-------|
| **image** | `quay.io/hedgedoc/hedgedoc:latest` |
| **container** | hedgedoc |
| **host port** | 3000 |
| **tsdproxy.name** | `pad` (LOCKED) |
| **network** | media-network |
| **purpose** | collaborative markdown editor with real-time editing |
| **database** | hedgedoc (on shared postgres) |
| **depends on** | postgres |
| **healthcheck** | image built-in Node.js check (v94 — curl/wget not available) |

### vaultwarden

| property | value |
|----------|-------|
| **image** | `vaultwarden/server:latest` |
| **container** | vaultwarden |
| **host port** | 8484 |
| **tsdproxy.name** | `vault` (LOCKED) |
| **network** | media-network |
| **purpose** | bitwarden-compatible password manager |
| **data path** | `/mnt/BIG/filme/configs/vaultwarden` |
| **healthcheck** | curl http://localhost:80/alive |
| **note** | migrated from amy to bender in v92 |

---

## utilities

### syncthing

| property | value |
|----------|-------|
| **image** | `syncthing/syncthing:latest` |
| **container** | syncthing |
| **network** | host |
| **tsdproxy.name** | `sync` (LOCKED) |
| **tsdproxy.container_port** | 8384 |
| **purpose** | peer-to-peer file synchronization across devices |
| **data path** | `/mnt/BIG/filme/syncthing` (single volume — config + data together) |
| **healthcheck** | curl http://127.0.0.1:8384/rest/noauth/health |
| **note** | v83 reverted to official syncthing image with correct volume structure |

---

## monitoring

### beszel-agent

| property | value |
|----------|-------|
| **image** | `henrygd/beszel-agent:latest` |
| **container** | beszel-agent |
| **network** | host |
| **tsdproxy.enable** | false |
| **purpose** | reports system metrics (CPU, memory, disk, network) to beszel hub on amy |
| **authentication** | `${BESZEL_KEY}` |

### cadvisor

| property | value |
|----------|-------|
| **image** | `gcr.io/cadvisor/cadvisor:latest` |
| **container** | cadvisor |
| **host port** | 9099 |
| **internal port** | 8080 |
| **tsdproxy.name** | `bender-cadvisor` (LOCKED) |
| **network** | media-network |
| **purpose** | container resource metrics — scraped by prometheus on HA VM for grafana dashboards |
| **resource flags** | `--housekeeping_interval=30s`, `--docker_only=true`, `--disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl` |

---

## commented services

these services are commented out in the compose file but preserved for future use:

### qbittorrent (v103 — disabled)

disabled after repeated system crashes on the HP MicroServer Gen8. aggressive I/O patterns during torrent hash checking overwhelmed ZFS. do not re-enable without testing on different hardware.

### playwright-chrome (disabled)

reserved for future ARR stack CAPTCHA solving or browser automation. not currently needed — flaresolverr handles cloudflare challenges.

### watchtower (disabled — on amy)

not present on bender's compose file. amy has watchtower commented out as emergency fallback.

---

## port reference

### direct host ports (media-network)

| port | service | internal port |
|------|---------|---------------|
| 53/tcp+udp | pihole | 53 |
| 2283 | immich_server | 2283 |
| 2375 | dockerproxy | 2375 |
| 3000 | hedgedoc | 3000 |
| 5432 | postgres | 5432 |
| 8053 | pihole web | 80 |
| 8081 | audiobookshelf | 80 |
| 8083 | trivy | 8080 |
| 8085 | tsdproxy | 8080 |
| 8096 | jellyfin | 8096 |
| 8191 | flaresolverr | 8191 |
| 8383 | metube | 8081 |
| 8484 | vaultwarden | 80 |
| 8800 | spotdl | 8800 |
| 9099 | cadvisor | 8080 |
| 9999 | dockwatch | 80 |

### gluetun-exposed ports

| port | service | internal port |
|------|---------|---------------|
| 5800 | jdownloader | 5800 |
| 6767 | bazarr | 6767 |
| 7878 | radarr | 7878 |
| 8686 | lidarr | 8686 |
| 8787 | readarr | 8787 |
| 8989 | sonarr | 8989 |
| 9091 | transmission | 9091 |
| 9696 | prowlarr | 9696 |
| 51413/tcp+udp | transmission peer | 51413 |

---

## tailscale URL reference

all services with `tsdproxy.enable: "true"` are accessible via tailscale:

| tsdproxy.name | URL | service |
|---------------|-----|---------|
| bender-proxy | https://bender-proxy.bunny-enigmatic.ts.net | tsdproxy dashboard |
| bender-dockwatch | https://bender-dockwatch.bunny-enigmatic.ts.net | dockwatch |
| pihole-bender | https://pihole-bender.bunny-enigmatic.ts.net | pihole admin |
| photo | https://photo.bunny-enigmatic.ts.net | immich |
| media | https://media.bunny-enigmatic.ts.net | jellyfin |
| books | https://books.bunny-enigmatic.ts.net | audiobookshelf |
| transmission | https://transmission.bunny-enigmatic.ts.net | transmission |
| metube | https://metube.bunny-enigmatic.ts.net | metube |
| jdown | https://jdown.bunny-enigmatic.ts.net | jdownloader |
| spotdl | https://spotdl.bunny-enigmatic.ts.net | spotdl |
| prowlarr | https://prowlarr.bunny-enigmatic.ts.net | prowlarr |
| sonarr | https://sonarr.bunny-enigmatic.ts.net | sonarr |
| radarr | https://radarr.bunny-enigmatic.ts.net | radarr |
| lidarr | https://lidarr.bunny-enigmatic.ts.net | lidarr |
| readarr | https://readarr.bunny-enigmatic.ts.net | readarr |
| bazarr | https://bazarr.bunny-enigmatic.ts.net | bazarr |
| pad | https://pad.bunny-enigmatic.ts.net | hedgedoc |
| vault | https://vault.bunny-enigmatic.ts.net | vaultwarden |
| sync | https://sync.bunny-enigmatic.ts.net | syncthing |
| bender-cadvisor | https://bender-cadvisor.bunny-enigmatic.ts.net | cadvisor |

---

## service dependencies

### startup order

```
postgres (healthcheck: pg_isready)
├── immich_server
├── hedgedoc
└── postgres-backup

immich_redis (healthcheck: redis-cli ping)
└── immich_server

gluetun (healthcheck: wget ipinfo.io)
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
| nebula-sync | pihole on amy (as replica target) |
| beszel-agent | beszel hub on amy (metrics collection) |

| amy service | depends on (bender) |
|------------|---------------------|
| homepage | dockerproxy on bender (container status widget) |
| pihole-dns-update.sh | docker API on bender (label scanning) |

---

*previous: [01-ARCHITECTURE.md](./01-ARCHITECTURE.md)*
*next: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
