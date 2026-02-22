# bender services catalog

## complete service reference

**document version:** 3.0
**infrastructure version:** 109
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
11. [text-to-speech](#text-to-speech)
12. [utilities](#utilities)
13. [monitoring](#monitoring)
14. [commented and profiles services](#commented-and-profiles-services)
15. [port reference](#port-reference)
16. [tailscale URL reference](#tailscale-url-reference)
17. [service dependencies](#service-dependencies)

---

## services overview

bender runs 36 active services. 24 use the bridge network (media-network), 3 use host networking, 8 route through gluetun's VPN tunnel, and 1 uses docker.sock only (autoheal).

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
| text-to-speech | 2 | edge-tts, tts-pipeline |
| monitoring | 2 | beszel-agent, cadvisor |
| updates | 2 | diun, trivy |
| support | 1 | flaresolverr |
| **total** | **36** | |

---

## infrastructure services

### tsdproxy

| setting | value |
|---------|-------|
| image | `almeidapaulopt/tsdproxy:latest` |
| container | tsdproxy |
| port | 8085:8080 |
| network | media-network |
| tsdproxy.name | `bender-proxy` (LOCKED) |
| purpose | tailscale reverse proxy — provides `*.bunny-enigmatic.ts.net` URLs for all tsdproxy-enabled services |

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
| purpose | read-only docker socket proxy for homepage on amy — DO NOT REMOVE |

### autoheal (v106)

| setting | value |
|---------|-------|
| image | `willfarrell/autoheal:latest` |
| container | autoheal |
| port | none |
| network | none (docker.sock only) |
| tsdproxy | disabled |
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
| server country | Romania (`${GLUETUN_SERVER_COUNTRY}`) |
| DOT | off (plain DNS) |
| healthcheck | `wget http://1.1.1.1/cdn-cgi/trace` — IP-based, avoids DNS (v106) |

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

---

## DNS and high availability

### pihole

| setting | value |
|---------|-------|
| image | `pihole/pihole:latest` |
| container | pihole |
| ports | 53:53 (TCP+UDP), 8053:80 |
| network | media-network (no DNS anchor — it IS the DNS) |
| tsdproxy.name | `pihole-bender` (LOCKED) |
| upstream DNS | 1.1.1.1, 8.8.8.8 |
| healthcheck | `dig +norecurse +retry=0 @127.0.0.1 pi.hole` |

### keepalived

| setting | value |
|---------|-------|
| image | `osixia/keepalived:2.0.20` (pinned) |
| container | keepalived |
| network | host |
| interface | bond0 |
| role | MASTER (priority 200) |
| VIP | 192.168.21.100 |
| VRRP ID | 53 |
| mode | unicast (peer: 192.168.21.130) |
| health check | wget pihole admin (:8053) every 2s |
| purpose | pihole DNS failover with amy |

### nebula-sync

| setting | value |
|---------|-------|
| image | `ghcr.io/lovelaze/nebula-sync:latest` |
| container | nebula-sync |
| network | media-network |
| tsdproxy | disabled |
| schedule | hourly (`0 * * * *`) |
| healthcheck | disabled (minimal container has no binaries) |
| purpose | replicates pihole config from bender to amy (FULL_SYNC + RUN_GRAVITY) |

---

## databases and cache

### postgres

| setting | value |
|---------|-------|
| image | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` |
| container | postgres |
| port | 5432:5432 |
| network | media-network |
| databases | immich, hedgedoc |
| data path | `/mnt/BIG/filme/immich/postgresql` (CRITICAL) |
| init scripts | `/mnt/BIG/filme/configs/postgres/init` (read-only) |
| healthcheck | `pg_isready -U postgres -d immich` |
| extensions | vchord.so, vectors.so (shared_preload_libraries) |
| tuning | max_wal_size=2GB, shared_buffers=512MB, wal_compression=on |

### postgres-backup

| setting | value |
|---------|-------|
| image | `prodrigestivill/postgres-backup-local:latest` |
| container | postgres-backup |
| network | media-network |
| databases backed up | immich, hedgedoc |
| schedule | daily |
| retention | 7 days, 4 weeks, 6 months |
| backup path | `/mnt/BIG/filme/backups/postgres` |
| healthcheck | curl http://localhost:8080 |
| depends on | postgres |

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
| depends on | postgres, immich_redis |

### immich_machine_learning

| setting | value |
|---------|-------|
| image | `ghcr.io/immich-app/immich-machine-learning:release` |
| container | immich_machine_learning |
| network | media-network |
| cache path | `/mnt/BIG/filme/immich/ml-cache` |
| healthcheck | python3 HTTP GET to localhost:3003/ping (v104) |

---

## media servers

### jellyfin

| setting | value |
|---------|-------|
| image | `lscr.io/linuxserver/jellyfin:latest` (v96: corrected) |
| container | jellyfin |
| port | 8096:8096 |
| network | media-network |
| tsdproxy.name | `media` (LOCKED) |
| libraries | movies (`/data/movies`), tvshows (`/data/tvshows`), music (`/data/music`) |
| GPU | disabled (HP BIOS limitation — commented out for future use) |

### audiobookshelf

| setting | value |
|---------|-------|
| image | `ghcr.io/advplyr/audiobookshelf:latest` |
| container | audiobookshelf |
| port | 8081:80 |
| network | media-network |
| tsdproxy.name | `books` (LOCKED) |
| libraries | audiobooks, podcasts, metadata |
| integration | tts-pipeline outputs to `/audiobooks/cărți/` for automatic pickup |

---

## download clients

### transmission (v108: custom build)

| setting | value |
|---------|-------|
| build | `/mnt/BIG/filme/configs/transmission/Dockerfile` |
| base image | `lscr.io/linuxserver/transmission:4.0.5` (PINNED — FileList whitelist) |
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

**DO NOT UPGRADE** past 4.0.5 — FileList whitelist requirement.

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

## ARR stack — media automation

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
| database | postgres (hedgedoc DB) |
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

### syncthing

| setting | value |
|---------|-------|
| image | `syncthing/syncthing:latest` |
| container | syncthing |
| network | host |
| tsdproxy.name | `sync` (LOCKED) |
| tsdproxy.container_port | 8384 |
| data path | `/mnt/BIG/filme/syncthing` |
| healthcheck | curl 127.0.0.1:8384/rest/noauth/health |

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

### tts-pipeline (v108, v109)

| setting | value |
|---------|-------|
| build | `/mnt/BIG/filme/configs/tts-pipeline/Dockerfile` |
| container | tts-pipeline |
| port | 5051:5051 |
| network | media-network |
| tsdproxy.name | `tts` (LOCKED) |
| resource limits | 4 GB memory, 0.6 CPU |
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

## utilities

### syncthing

documented under [collaboration](#collaboration) above (uses host networking for peer discovery).

---

## monitoring

### beszel-agent

| setting | value |
|---------|-------|
| image | `henrygd/beszel-agent:latest` |
| container | beszel-agent |
| network | host |
| tsdproxy | disabled |
| purpose | reports system metrics to beszel hub on amy |

### cadvisor (v105)

| setting | value |
|---------|-------|
| image | `gcr.io/cadvisor/cadvisor:latest` |
| container | cadvisor |
| port | 9099:8080 |
| network | media-network |
| tsdproxy.name | `bender-cadvisor` (LOCKED) |
| flags | `--docker_only`, `--housekeeping_interval=30s`, disabled unused metrics |
| purpose | container resource metrics → prometheus → grafana |

---

## commented and profiles services

### qbittorrent (commented — v103)

removed in v103 after causing repeated system crashes due to ZFS I/O patterns on HP MicroServer Gen8. kept commented for potential future use.

### playwright-chrome (commented)

kept for future ARR stack browser automation. not currently needed.

### epub2tts-edge (profiles: tools — v108)

on-demand manual EPUB/TXT → M4B converter. not part of the regular active stack. run with:

```bash
docker compose run --rm epub2tts-edge
```

---

## port reference

### direct ports (host:container)

| host port | container port | service |
|-----------|---------------|---------|
| 53 | 53 | pihole (TCP+UDP) |
| 2283 | 2283 | immich_server |
| 2375 | 2375 | dockerproxy |
| 3000 | 3000 | hedgedoc |
| 5050 | 5050 | edge-tts |
| 5051 | 5051 | tts-pipeline |
| 5432 | 5432 | postgres |
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

all services with `tsdproxy.enable: "true"` are accessible via tailscale:

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
| sync | https://sync.bunny-enigmatic.ts.net | syncthing |
| prowlarr | https://prowlarr.bunny-enigmatic.ts.net | prowlarr |
| sonarr | https://sonarr.bunny-enigmatic.ts.net | sonarr |
| radarr | https://radarr.bunny-enigmatic.ts.net | radarr |
| lidarr | https://lidarr.bunny-enigmatic.ts.net | lidarr |
| readarr | https://readarr.bunny-enigmatic.ts.net | readarr |
| bazarr | https://bazarr.bunny-enigmatic.ts.net | bazarr |
| tts | https://tts.bunny-enigmatic.ts.net | tts-pipeline |
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
| nebula-sync | pihole on amy (as replica target) |
| beszel-agent | beszel hub on amy (metrics collection) |
| pihole-dns-update.sh | docker API on amy via SSH (label scanning) |

| amy service | depends on (bender) |
|------------|---------------------|
| homepage | dockerproxy on bender (:2375) |
| pihole-dns-update.sh | tsdproxy labels on bender |

---

*previous: [01-ARCHITECTURE.md](./01-ARCHITECTURE.md)*
*next: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
