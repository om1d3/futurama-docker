# bender architecture

## infrastructure design and system overview

**document version:** 2.0
**infrastructure version:** 105
**last updated:** february 2026

---

## table of contents

1. [executive summary](#executive-summary)
2. [hardware specifications](#hardware-specifications)
3. [network configuration](#network-configuration)
4. [service architecture](#service-architecture)
5. [storage architecture](#storage-architecture)
6. [VPN architecture](#vpn-architecture)
7. [monitoring pipeline](#monitoring-pipeline)
8. [high availability](#high-availability)
9. [integration with amy](#integration-with-amy)
10. [technology stack](#technology-stack)

---

## executive summary

bender is the primary host in a two-host home lab infrastructure. it runs on TrueNAS Scale on an HP MicroServer Gen8 and is responsible for media services, download automation, photo management, and primary DNS. it serves as the storage backend for the infrastructure, with amy (the secondary host) providing utilities, monitoring, and notifications.

| property | value |
|----------|-------|
| **hostname** | bender |
| **operating system** | TrueNAS Scale (debian-based) |
| **ip address** | 192.168.21.121 |
| **compose version** | 105 |
| **active services** | 33 |
| **network** | media-network (bridge) |
| **VPN** | surfshark via gluetun (OpenVPN) |
| **role** | media, downloads, photos, primary DNS, primary storage |

---

## hardware specifications

| component | specification |
|-----------|--------------|
| **chassis** | HP MicroServer Gen8 |
| **CPU** | Intel Xeon E3-1265L V2 (4 cores, 8 threads, 2.5 GHz) |
| **RAM** | 16 GB ECC |
| **iGPU** | Intel HD Graphics P4000 (disabled in HP BIOS — no modded BIOS available) |
| **storage** | ZFS pool on multiple drives (pool name: BIG) |
| **network** | gigabit ethernet (interface: enp4s0) |

### hardware limitations

- **no GPU acceleration**: the iGPU is disabled by HP's BIOS with no workaround. jellyfin transcoding is CPU-only (software encoding with libx264)
- **modest CPU**: the xeon E3-1265L V2 handles the workload adequately but is not suitable for heavy simultaneous transcoding
- **ZFS I/O patterns**: qBittorrent was found to cause system crashes due to aggressive I/O patterns overwhelming ZFS (v103). transmission with pinned version 4.0.5 is used instead

---

## network configuration

### ip addresses

| host/service | ip address | purpose |
|-------------|------------|---------|
| **bender** | 192.168.21.121 | primary host |
| **amy** | 192.168.21.130 | secondary host |
| **keepalived VIP** | 192.168.21.100 | floating DNS VIP (bender = master) |
| **home assistant VM** | 192.168.21.220 | grafana, prometheus, influxdb |
| **cisco 3750x switch** | 192.168.21.5 | network switch (monitored via SNMP from amy) |
| **router** | 192.168.21.1 | default gateway |

### docker networking

| network | driver | purpose |
|---------|--------|---------|
| **media-network** | bridge | all bridge-networked services |

all bridge-networked services use a DNS anchor pointing to `192.168.21.100` (keepalived VIP):

```yaml
x-dns-config: &default-dns
  dns:
    - 192.168.21.100
```

services that use `network_mode: host` do not use the anchor — they inherit the host's DNS configuration. services using `network_mode: "service:gluetun"` route through gluetun's network stack and DNS.

### port allocation

bender uses a large number of ports due to the media stack. gluetun exposes ports for all VPN-routed services.

| port range | purpose |
|------------|---------|
| 53 | pihole DNS |
| 2283 | immich |
| 2375 | dockerproxy (for homepage on amy) |
| 3000 | hedgedoc |
| 5432 | postgresql |
| 5800 | jdownloader (via gluetun) |
| 6767 | bazarr (via gluetun) |
| 7878 | radarr (via gluetun) |
| 8053 | pihole web UI |
| 8081 | audiobookshelf |
| 8083 | trivy |
| 8085 | tsdproxy dashboard |
| 8096 | jellyfin |
| 8191 | flaresolverr |
| 8383 | metube |
| 8484 | vaultwarden |
| 8686 | lidarr (via gluetun) |
| 8787 | readarr (via gluetun) |
| 8800 | spotdl |
| 8989 | sonarr (via gluetun) |
| 9091 | transmission (via gluetun) |
| 9099 | cadvisor |
| 9696 | prowlarr (via gluetun) |
| 9999 | dockwatch |
| 51413 | transmission peer port (via gluetun, TCP+UDP) |

---

## service architecture

### service categories

bender's 33 active services are organized into functional groups:

#### infrastructure (5 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| tsdproxy | almeidapaulopt/tsdproxy | tailscale reverse proxy | media-network |
| dockwatch | ghcr.io/notifiarr/dockwatch | container management UI | media-network |
| dockerproxy | ghcr.io/tecnativa/docker-socket-proxy | docker socket proxy for amy's homepage | media-network |
| diun | crazymax/diun | image update notifications | media-network |
| trivy | aquasec/trivy | vulnerability scanner | media-network |

#### VPN (1 service)

| service | image | purpose | network |
|---------|-------|---------|---------|
| gluetun | qmcgaw/gluetun | surfshark OpenVPN tunnel | media-network |

#### DNS and high availability (3 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| pihole | pihole/pihole | primary DNS with ad-blocking | media-network |
| keepalived | osixia/keepalived:2.0.20 | VIP failover (master, priority 150) | host |
| nebula-sync | ghcr.io/lovelaze/nebula-sync | pihole config sync to amy (hourly) | media-network |

#### databases and cache (4 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| postgres | ghcr.io/immich-app/postgres:14-vectorchord0.4.3 | postgresql with vector extensions (immich, hedgedoc) | media-network |
| postgres-backup | prodrigestivill/postgres-backup-local | daily database backups | media-network |
| immich_redis | redis:7-alpine | redis cache for immich | media-network |
| flaresolverr | ghcr.io/flaresolverr/flaresolverr | CAPTCHA solver for prowlarr | media-network |

#### photo management (2 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| immich_server | ghcr.io/immich-app/immich-server:release | photo/video management | media-network |
| immich_machine_learning | ghcr.io/immich-app/immich-machine-learning:release | ML-based face/object recognition | media-network |

#### media servers (2 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| jellyfin | lscr.io/linuxserver/jellyfin | media server (movies, TV, music) | media-network |
| audiobookshelf | ghcr.io/advplyr/audiobookshelf | audiobook and podcast server | media-network |

#### download clients (4 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| transmission | lscr.io/linuxserver/transmission:4.0.5 | torrent client (pinned — FileList whitelist) | gluetun |
| metube | ghcr.io/alexta69/metube | youtube downloader | media-network |
| jdownloader | jlesage/jdownloader-2 | direct download manager | gluetun |
| spotdl | spotdl/spotify-downloader | spotify music downloader | media-network |

#### ARR stack — media automation (7 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| prowlarr | lscr.io/linuxserver/prowlarr | indexer manager | gluetun |
| sonarr | lscr.io/linuxserver/sonarr | TV show automation | gluetun |
| radarr | lscr.io/linuxserver/radarr | movie automation | gluetun |
| lidarr | lscr.io/linuxserver/lidarr | music automation | gluetun |
| readarr | linuxserver/readarr:0.4.19-nightly | ebook automation | gluetun |
| bazarr | lscr.io/linuxserver/bazarr | subtitle automation | gluetun |
| unpackerr | golift/unpackerr | automatic archive extraction | media-network |

#### collaboration (2 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| hedgedoc | quay.io/hedgedoc/hedgedoc | collaborative markdown editor | media-network |
| vaultwarden | vaultwarden/server | password manager (moved from amy in v92) | media-network |

#### utilities (1 service)

| service | image | purpose | network |
|---------|-------|---------|---------|
| syncthing | syncthing/syncthing | file synchronization | host |

#### monitoring (2 services)

| service | image | purpose | network |
|---------|-------|---------|---------|
| beszel-agent | henrygd/beszel-agent | system metrics agent → beszel hub on amy | host |
| cadvisor | gcr.io/cadvisor/cadvisor | container resource metrics → prometheus | media-network |

### network mode summary

| network mode | services | reason |
|-------------|----------|--------|
| **media-network (bridge)** | 22 services | standard container isolation with DNS anchor |
| **host** | keepalived, syncthing, beszel-agent | need direct host network access |
| **service:gluetun** | transmission, jdownloader, prowlarr, sonarr, radarr, lidarr, readarr, bazarr | route through VPN tunnel |

---

## storage architecture

### ZFS pool

bender's primary storage is a ZFS pool named `BIG`, mounted at `/mnt/BIG/`. all container data, media files, and configurations live under `/mnt/BIG/filme/`.

### directory layout

| path | purpose |
|------|---------|
| `/mnt/BIG/filme/docker-compose/` | compose file, .env, scripts |
| `/mnt/BIG/filme/configs/` | container configuration volumes |
| `/mnt/BIG/filme/immich/` | immich photos, postgresql, redis, ML cache |
| `/mnt/BIG/filme/filme/` | movie library |
| `/mnt/BIG/filme/seriale/` | TV show library |
| `/mnt/BIG/filme/music/` | music library |
| `/mnt/BIG/filme/books/` | ebook library |
| `/mnt/BIG/filme/transmission/` | torrent downloads (completed, incomplete, watch) |
| `/mnt/BIG/filme/backups/postgres/` | daily postgresql backups |

### NFS exports

bender exports storage to amy via NFS. amy mounts bender's paths under `/portainer/jellyfin/filme_bender/`:

| bender path | amy mount point |
|-------------|----------------|
| `/mnt/BIG/filme/` | `/portainer/jellyfin/filme_bender/` |

this allows amy's filebrowser to browse bender's media files, and was the original data path before services were split across hosts.

---

## VPN architecture

### gluetun (surfshark OpenVPN)

all download and indexer services route through a centralized VPN tunnel provided by gluetun.

```
┌────────────────────────────────────────────────────┐
│                    gluetun                          │
│              (surfshark OpenVPN)                    │
│                                                    │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────┐  │
│  │ transmission │  │  prowlarr   │  │  sonarr   │  │
│  │ (4.0.5)     │  │             │  │           │  │
│  └─────────────┘  └─────────────┘  └───────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────┐  │
│  │   radarr    │  │   lidarr    │  │  readarr  │  │
│  └─────────────┘  └─────────────┘  └───────────┘  │
│  ┌─────────────┐  ┌─────────────┐                  │
│  │   bazarr    │  │ jdownloader │                  │
│  └─────────────┘  └─────────────┘                  │
│                                                    │
│  ports exposed: 9091, 51413, 9696, 8989,           │
│                 7878, 8686, 8787, 6767, 5800       │
└────────────────────────────────────────────────────┘
```

### VPN history

| version | change | reason |
|---------|--------|--------|
| v97 | added gluetun with OpenVPN | centralized VPN for ARR stack |
| v98 | switched to WireGuard | better performance |
| v104 | switched back to OpenVPN | WireGuard blocked outbound peer connections |

### transmission pinning

transmission is pinned to version **4.0.5** — do not upgrade. version 4.0.6+ is not on the FileList client whitelist. this is enforced by the explicit image tag `lscr.io/linuxserver/transmission:4.0.5` rather than `:latest`.

### qBittorrent note

qBittorrent was tested in v102 but caused repeated system crashes on the HP MicroServer Gen8 due to aggressive I/O patterns overwhelming ZFS. it is commented out in the compose file with a warning. do not re-enable without testing on different hardware.

---

## monitoring pipeline

bender participates in a multi-host monitoring pipeline:

```
bender (192.168.21.121)          amy (192.168.21.130)
┌──────────────┐                 ┌──────────────┐
│   cadvisor   │                 │   cadvisor   │
│  :9099/tcp   │                 │  :9099/tcp   │
└──────┬───────┘                 └──────┬───────┘
       │                                │
       └──────────┐    ┌────────────────┘
                  ▼    ▼
          HA VM (192.168.21.220)
          ┌──────────────┐
          │  prometheus  │
          │  :9090/tcp   │
          │              │
          │  scrape_configs:
          │  - 192.168.21.130:9099
          │  - 192.168.21.121:9099
          └──────┬───────┘
                 │
                 ▼
          ┌──────────────┐
          │   grafana    │
          │  (HA add-on) │
          │              │
          │  dashboards: │
          │  - amy docker│
          │  - bender    │
          │    docker    │
          └──────────────┘
```

additionally, amy's telegraf monitors bender's network infrastructure (cisco switch) via SNMP, feeding data to influxdb on the HA VM for separate grafana dashboards.

### cadvisor resource optimization

cadvisor runs with resource-saving flags to minimize overhead:

| metric | before flags | after flags |
|--------|-------------|-------------|
| CPU | 9.90% | 0.32% |
| memory | 118 MiB | 18 MiB |

flags: `--housekeeping_interval=30s`, `--docker_only=true`, `--disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl`

---

## high availability

### pihole DNS failover

| property | bender (master) | amy (backup) |
|----------|----------------|--------------|
| **keepalived role** | MASTER | BACKUP |
| **keepalived priority** | 150 | 100 |
| **keepalived interface** | enp4s0 | (host default) |
| **VIP** | 192.168.21.100 | 192.168.21.100 |
| **pihole port** | 8053 | 8053 |
| **DNS port** | 53 | 53 |

under normal operation, bender holds the VIP (192.168.21.100). if bender's pihole fails or bender goes offline, keepalived on amy detects the failure and claims the VIP within seconds. nebula-sync keeps pihole configuration synchronized from bender to amy hourly.

### pihole healthcheck

bender's pihole uses a `dig` healthcheck:

```yaml
healthcheck:
  test: ["CMD", "dig", "+norecurse", "+retry=0", "@127.0.0.1", "pi.hole"]
```

if this check fails, keepalived's VRRP health script detects the failure and releases the VIP to amy.

---

## integration with amy

### services on bender that connect to amy

| bender service | connects to | purpose |
|---------------|-------------|---------|
| diun | ntfy on amy (`${NTFY_ADDRESS}`) | send image update notifications |
| nebula-sync | pihole on amy (192.168.21.130:8053) | replicate pihole configuration |
| secure-container-update.sh | ntfy on amy (`${NTFY_ADDRESS}`) | send update/rollback notifications |
| beszel-agent | beszel hub on amy (port 45876) | report system metrics |

### services on amy that connect to bender

| amy service | connects to | purpose |
|------------|-------------|---------|
| homepage | dockerproxy on bender (192.168.21.121:2375) | display bender container status |
| pihole-dns-update.sh (cron) | docker API on bender | scan tsdproxy labels for DNS entries |
| beszel hub | beszel-agent on bender | collect system metrics |

### shared configuration

| item | must match on both hosts |
|------|--------------------------|
| keepalived password | `KEEPALIVED_PASSWORD` in both .env files |
| keepalived VIP | `192.168.21.100` in both keepalived configs |
| pihole password | `PIHOLE_PASSWORD` in both .env files (for nebula-sync) |
| tsdproxy tailnet | same tailscale tailnet (bunny-enigmatic) |
| DNS anchor | `192.168.21.100` in both compose files |

---

## technology stack

| layer | technology | purpose |
|-------|-----------|---------|
| **host OS** | TrueNAS Scale | ZFS storage, container runtime |
| **container runtime** | docker + docker compose | service orchestration |
| **reverse proxy** | tsdproxy | tailscale-based HTTPS access |
| **VPN** | gluetun + surfshark (OpenVPN) | download traffic encryption |
| **database** | postgresql 14 (vectorchord) | immich + hedgedoc data |
| **cache** | redis 7 | immich session/job cache |
| **DNS** | pihole + keepalived | ad-blocking with HA failover |
| **config sync** | nebula-sync | pihole replication to amy |
| **media server** | jellyfin | movies, TV shows, music |
| **photo management** | immich | photo/video with ML classification |
| **download automation** | transmission + ARR stack | automated media acquisition |
| **monitoring** | cadvisor + prometheus + grafana | container resource metrics |
| **notifications** | ntfy (on amy) | all infrastructure alerts |
| **security** | trivy + diun | vulnerability scanning + image monitoring |
| **file sync** | syncthing | cross-device file synchronization |
| **backup** | postgres-backup-local | daily automated database backups |

---

*next: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
