# bender services catalog

## complete service reference

**document version:** 1.0  
**infrastructure version:** 86  
**last updated:** january 10, 2026

---

## table of contents

1. [services overview](#services-overview)
2. [infrastructure services](#infrastructure-services)
3. [media services](#media-services)
4. [download services](#download-services)
5. [productivity services](#productivity-services)
6. [update services](#update-services)
7. [service dependencies](#service-dependencies)
8. [port reference](#port-reference)
9. [tailscale urls](#tailscale-urls)

---

## services overview

### service count by category

| category | count | services |
|----------|-------|----------|
| **infrastructure** | 7 | tsdproxy, postgresql, pihole, keepalived, dockerproxy, postgres-backup, dockwatch |
| **media** | 4 | immich-server, immich-machine-learning, immich-redis, jellyfin |
| **downloads** | 8 | transmission, sonarr, radarr, prowlarr, bazarr, lidarr, readarr, unpackerr |
| **productivity** | 3 | hedgedoc, syncthing, metube |
| **updates** | 2 | diun, trivy |
| **total** | **24** | |

---

## infrastructure services

### tsdproxy

| property | value |
|----------|-------|
| **image** | almeidapaulopt/tsdproxy:latest |
| **container** | tsdproxy |
| **port** | 8085:8080 |
| **tailscale** | bender-proxy |
| **purpose** | tailscale integration for all services |

**configuration:**
- provides tailscale mesh access to all labeled services
- auto-discovers containers with `tsdproxy.enable: "true"` labels
- manages tailscale authentication and certificates

---

### postgresql

| property | value |
|----------|-------|
| **image** | ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0 |
| **container** | postgres |
| **port** | 5432:5432 |
| **databases** | immich, hedgedoc |
| **purpose** | shared database server |

**databases:**
- `immich` - photo management metadata
- `hedgedoc` - collaborative notes

**health check:**
```bash
pg_isready -U postgres
```

**backup:**
- daily backup via postgres-backup container
- 7-day retention in /mnt/BIG/filme/docker-compose/backups/postgres/

---

### pihole

| property | value |
|----------|-------|
| **image** | pihole/pihole:latest |
| **container** | pihole |
| **ports** | 8053:53/tcp, 8053:53/udp, 8054:80 |
| **tailscale** | bender-pihole |
| **purpose** | primary dns server with ad blocking |

**high availability:**
- master role in keepalived vrrp
- priority: 150 (higher than amy's 100)
- vip: 192.168.21.100

---

### keepalived

| property | value |
|----------|-------|
| **image** | osixia/keepalived:latest |
| **container** | keepalived |
| **network** | host mode |
| **purpose** | vrrp failover for pihole |

**configuration:**
- state: MASTER
- priority: 150
- virtual ip: 192.168.21.100
- health check: pihole web interface

---

### dockerproxy

| property | value |
|----------|-------|
| **image** | ghcr.io/tecnativa/docker-socket-proxy:latest |
| **container** | dockerproxy |
| **port** | 2375:2375 |
| **purpose** | secure docker api access for homepage on amy |

**security:**
- read-only access to docker socket
- containers, images, networks, volumes enabled
- services, tasks, nodes disabled

---

### postgres-backup

| property | value |
|----------|-------|
| **image** | prodrigestivill/postgres-backup-local:latest |
| **container** | postgres-backup |
| **schedule** | daily at 04:00 |
| **retention** | 7 days |
| **purpose** | automated postgresql backups |

**backup location:** /mnt/BIG/filme/docker-compose/backups/postgres/

---

### dockwatch

| property | value |
|----------|-------|
| **image** | ghcr.io/notifiarr/dockwatch:main |
| **container** | dockwatch |
| **port** | 9999:80 |
| **tailscale** | bender-dockwatch |
| **purpose** | container monitoring and management |

---

## media services

### immich-server

| property | value |
|----------|-------|
| **image** | ghcr.io/immich-app/immich-server:latest |
| **container** | immich_server |
| **port** | 2283:2283 |
| **tailscale** | immich |
| **purpose** | photo management server |

**dependencies:** postgresql, immich-redis, immich-machine-learning

**volumes:**
- /mnt/BIG/filme/immich/upload:/usr/src/app/upload
- /mnt/BIG/filme/immich/library:/usr/src/app/library

---

### immich-machine-learning

| property | value |
|----------|-------|
| **image** | ghcr.io/immich-app/immich-machine-learning:latest |
| **container** | immich_machine_learning |
| **purpose** | ai/ml processing for photo recognition |

**dependencies:** immich-server

---

### immich-redis

| property | value |
|----------|-------|
| **image** | redis:alpine |
| **container** | immich_redis |
| **purpose** | cache for immich |

---

### jellyfin

| property | value |
|----------|-------|
| **image** | jellyfin/jellyfin:latest |
| **container** | jellyfin |
| **port** | 8080:8096 |
| **tailscale** | jellyfin |
| **purpose** | media streaming server |

**volumes:**
- /mnt/BIG/filme/filme:/data/movies
- /mnt/BIG/filme/seriale:/data/tvshows
- /mnt/BIG/filme/music:/data/music

---

## download services

### transmission

| property | value |
|----------|-------|
| **image** | haugene/transmission-openvpn:latest |
| **container** | transmission |
| **port** | 9091:9091 |
| **tailscale** | transmission |
| **purpose** | vpn-protected torrent client |

**vpn configuration:**
- provider: surfshark
- kill switch enabled
- local network bypass: 192.168.21.0/24

---

### sonarr

| property | value |
|----------|-------|
| **image** | lscr.io/linuxserver/sonarr:latest |
| **container** | sonarr |
| **port** | 8989:8989 |
| **tailscale** | sonarr |
| **purpose** | tv show automation |

---

### radarr

| property | value |
|----------|-------|
| **image** | lscr.io/linuxserver/radarr:latest |
| **container** | radarr |
| **port** | 7878:7878 |
| **tailscale** | radarr |
| **purpose** | movie automation |

---

### prowlarr

| property | value |
|----------|-------|
| **image** | lscr.io/linuxserver/prowlarr:latest |
| **container** | prowlarr |
| **port** | 9696:9696 |
| **tailscale** | prowlarr |
| **purpose** | indexer manager for arr stack |

---

### bazarr

| property | value |
|----------|-------|
| **image** | lscr.io/linuxserver/bazarr:latest |
| **container** | bazarr |
| **port** | 6767:6767 |
| **tailscale** | bazarr |
| **purpose** | subtitle management |

---

### lidarr

| property | value |
|----------|-------|
| **image** | lscr.io/linuxserver/lidarr:latest |
| **container** | lidarr |
| **port** | 8686:8686 |
| **tailscale** | lidarr |
| **purpose** | music automation |

---

### readarr

| property | value |
|----------|-------|
| **image** | lscr.io/linuxserver/readarr:develop |
| **container** | readarr |
| **port** | 8787:8787 |
| **tailscale** | readarr |
| **purpose** | ebook automation |

---

### unpackerr

| property | value |
|----------|-------|
| **image** | golift/unpackerr:latest |
| **container** | unpackerr |
| **purpose** | automatic archive extraction for arr stack |

---

## productivity services

### hedgedoc

| property | value |
|----------|-------|
| **image** | quay.io/hedgedoc/hedgedoc:latest |
| **container** | hedgedoc |
| **port** | 8000:3000 |
| **tailscale** | pad |
| **purpose** | collaborative markdown notes |

**database:** postgresql (hedgedoc database)

---

### syncthing

| property | value |
|----------|-------|
| **image** | syncthing/syncthing:latest |
| **container** | syncthing |
| **ports** | 8384:8384, 22000:22000, 21027:21027/udp |
| **network** | host mode |
| **purpose** | file synchronization |

---

### metube

| property | value |
|----------|-------|
| **image** | ghcr.io/alexta69/metube:latest |
| **container** | metube |
| **port** | 8383:8081 |
| **tailscale** | metube |
| **purpose** | youtube video downloader |

---

## update services

### diun

| property | value |
|----------|-------|
| **image** | crazymax/diun:latest |
| **container** | diun |
| **schedule** | saturdays at 04:30 |
| **purpose** | docker image update notifications |

**notification:** ntfy via amy (http://192.168.21.130:8080/diun-bender)

---

### trivy

| property | value |
|----------|-------|
| **image** | aquasec/trivy:latest |
| **container** | trivy |
| **port** | 8082:8080 |
| **purpose** | container vulnerability scanning |

**mode:** server mode for secure-container-update.sh

---

## service dependencies

### dependency chain

```
postgresql
├── immich-server
│   ├── immich-machine-learning
│   └── immich-redis
├── hedgedoc
└── postgres-backup

tsdproxy
└── all services with tsdproxy.enable: "true"

pihole
└── keepalived (health check)

transmission
└── sonarr, radarr (download client)

prowlarr
├── sonarr (indexers)
├── radarr (indexers)
├── lidarr (indexers)
└── readarr (indexers)
```

### startup order

1. **tier 1 (no dependencies):** postgresql, pihole, tsdproxy, trivy
2. **tier 2 (database ready):** immich-redis, keepalived, diun
3. **tier 3 (services):** immich-server, hedgedoc, jellyfin, transmission
4. **tier 4 (dependent):** immich-machine-learning, arr stack, postgres-backup

---

## port reference

### complete port mapping

| port | service | protocol |
|------|---------|----------|
| 2283 | immich | http |
| 2375 | dockerproxy | tcp |
| 5432 | postgresql | tcp |
| 6767 | bazarr | http |
| 7878 | radarr | http |
| 8000 | hedgedoc | http |
| 8053 | pihole dns | tcp/udp |
| 8054 | pihole web | http |
| 8080 | jellyfin | http |
| 8082 | trivy | http |
| 8085 | tsdproxy | http |
| 8383 | metube | http |
| 8384 | syncthing | http |
| 8686 | lidarr | http |
| 8787 | readarr | http |
| 8989 | sonarr | http |
| 9091 | transmission | http |
| 9696 | prowlarr | http |
| 9999 | dockwatch | http |
| 21027 | syncthing discovery | udp |
| 22000 | syncthing transfer | tcp |

---

## tailscale urls

### service access via tailnet

| service | tailscale url |
|---------|---------------|
| immich | https://immich.bunny-enigmatic.ts.net |
| jellyfin | https://jellyfin.bunny-enigmatic.ts.net |
| transmission | https://transmission.bunny-enigmatic.ts.net |
| sonarr | https://sonarr.bunny-enigmatic.ts.net |
| radarr | https://radarr.bunny-enigmatic.ts.net |
| prowlarr | https://prowlarr.bunny-enigmatic.ts.net |
| bazarr | https://bazarr.bunny-enigmatic.ts.net |
| lidarr | https://lidarr.bunny-enigmatic.ts.net |
| readarr | https://readarr.bunny-enigmatic.ts.net |
| hedgedoc | https://pad.bunny-enigmatic.ts.net |
| metube | https://metube.bunny-enigmatic.ts.net |
| pihole | https://bender-pihole.bunny-enigmatic.ts.net |
| dockwatch | https://bender-dockwatch.bunny-enigmatic.ts.net |
| tsdproxy | https://bender-proxy.bunny-enigmatic.ts.net |

---

*previous: [01-ARCHITECTURE.md](./01-ARCHITECTURE.md)*  
*next: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
