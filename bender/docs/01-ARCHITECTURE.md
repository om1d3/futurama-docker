# bender architecture

## infrastructure design and system overview

**document version:** 3.0
**infrastructure version:** 109
**last updated:** february 2026

---

## table of contents

1. [executive summary](#executive-summary)
2. [hardware specifications](#hardware-specifications)
3. [network configuration](#network-configuration)
4. [service architecture](#service-architecture)
5. [storage architecture](#storage-architecture)
6. [VPN architecture](#vpn-architecture)
7. [text-to-speech architecture](#text-to-speech-architecture)
8. [self-healing architecture](#self-healing-architecture)
9. [monitoring pipeline](#monitoring-pipeline)
10. [high availability](#high-availability)
11. [integration with amy](#integration-with-amy)
12. [technology stack](#technology-stack)

---

## executive summary

bender is the primary host in a two-host home lab infrastructure. it runs on TrueNAS Scale on an HP MicroServer Gen8 and is responsible for media services, download automation, photo management, text-to-speech audiobook generation, and primary DNS. it serves as the storage backend for the infrastructure, with amy (the secondary host) providing utilities, monitoring, and notifications.

as of v109, bender runs 36 active containers organized into media, downloads, collaboration, text-to-speech, databases, DNS/HA, infrastructure, monitoring, and update categories. three additional containers use `build:` directives (transmission, tts-pipeline, epub2tts-edge) instead of pre-built images.

---

## hardware specifications

| component | specification |
|-----------|--------------|
| **model** | HP ProLiant MicroServer Gen8 |
| **CPU** | Intel Xeon E3-1265L V2 (4 cores, 8 threads, 2.5 GHz) |
| **RAM** | 16 GB ECC DDR3 |
| **iGPU** | disabled by HP BIOS (no hardware transcoding) |
| **storage** | ZFS pool `BIG` — 4x HDD |
| **network** | bond0 (bonded NIC interface) |
| **OS** | TrueNAS Scale |
| **IP** | 192.168.21.121 |
| **management** | HP iLO (remote BIOS/console access) |

### known hardware limitations

- **no GPU acceleration**: HP BIOS disables the Xeon's integrated GPU. jellyfin transcoding is software-only. GPU passthrough is commented out in docker-compose.yaml for future use
- **ZFS I/O sensitivity**: aggressive random I/O (hash checking, many concurrent torrents) can overwhelm the 4-disk array. transmission is configured with queue limits (10 download, 50 seed), 64 MB write cache, and peer limits (300 global, 30 per torrent) to mitigate this
- **intel_iommu**: set to `off` in GRUB (v107). HP iLO DMAR interrupt faults escalated ZFS I/O stalls into hard freezes when `intel_iommu=on` was active
- **TrueNAS script execution**: scripts under `/mnt/` cannot be executed directly. the cron system copies scripts to `/tmp/` before execution

---

## network configuration

### interfaces

| interface | type | ip address | purpose |
|-----------|------|------------|---------|
| bond0 | bonded NIC | 192.168.21.121 | primary network (all services) |
| tailscale | overlay | dynamic | remote access via tsdproxy |

### DNS

| setting | value |
|---------|-------|
| pihole VIP | 192.168.21.100 (keepalived VRRP) |
| upstream DNS | 1.1.1.1, 8.8.8.8 |
| local domain | `home.arpa` |
| auto-population | pihole-dns-update.sh (every 5 min) |

all services on the `media-network` bridge use the DNS anchor `192.168.21.100` (pihole VIP) via the `x-dns-config` YAML anchor. exceptions are pihole itself (it IS the DNS server), keepalived, syncthing, and beszel-agent (all use host networking).

### docker networks

| network | driver | purpose |
|---------|--------|---------|
| media-network | bridge | all bridge-mode services (with DNS anchor) |
| host | host | keepalived, syncthing, beszel-agent |
| service:gluetun | container | transmission, jdownloader, prowlarr, sonarr, radarr, lidarr, readarr, bazarr |

### port allocation summary

bender uses ports across several ranges. see [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md) for the complete port reference.

| range | services |
|-------|----------|
| 53 | pihole DNS |
| 2283 | immich |
| 2375 | dockerproxy |
| 3000 | hedgedoc |
| 5050 | edge-tts |
| 5051 | tts-pipeline |
| 5432 | postgresql |
| 5800 | jdownloader (via gluetun) |
| 6767 | bazarr (via gluetun) |
| 7878 | radarr (via gluetun) |
| 8053 | pihole web |
| 8081 | audiobookshelf |
| 8083 | trivy |
| 8085 | tsdproxy |
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
| 51413 | transmission peer (TCP+UDP via gluetun) |

---

## service architecture

### service categories (36 active containers)

| category | count | services |
|----------|-------|----------|
| **infrastructure** | 4 | tsdproxy, dockwatch, dockerproxy, autoheal |
| **VPN** | 1 | gluetun |
| **DNS & HA** | 3 | pihole, keepalived, nebula-sync |
| **databases & cache** | 3 | postgres, postgres-backup, immich_redis |
| **photo management** | 2 | immich_server, immich_machine_learning |
| **media servers** | 2 | jellyfin, audiobookshelf |
| **download clients** | 4 | transmission, metube, jdownloader, spotdl |
| **ARR stack** | 7 | prowlarr, sonarr, radarr, lidarr, readarr, bazarr, unpackerr |
| **collaboration** | 3 | hedgedoc, vaultwarden, syncthing |
| **text-to-speech** | 2 | edge-tts, tts-pipeline |
| **monitoring** | 2 | beszel-agent, cadvisor |
| **updates** | 2 | diun, trivy |
| **support** | 1 | flaresolverr |
| **total active** | **36** | |

additionally, 3 services are commented out or use profiles: qbittorrent (commented, incompatible with ZFS I/O), playwright-chrome (commented, future use), epub2tts-edge (profiles: tools, on-demand only).

### network modes

| mode | count | services |
|------|-------|----------|
| bridge (media-network) | 24 | most services |
| host | 3 | keepalived, syncthing, beszel-agent |
| service:gluetun | 8 | transmission, jdownloader, prowlarr, sonarr, radarr, lidarr, readarr, bazarr |
| none (standalone) | 1 | autoheal (docker.sock only) |

### build-based containers

three containers use `build:` instead of `image:`. these require `docker compose build` for updates rather than `docker compose pull`:

| container | build context | reason |
|-----------|--------------|--------|
| transmission | `/mnt/BIG/filme/configs/transmission` | pre-baked Flood UI (eliminates linuxserver mod download on every restart) |
| tts-pipeline | `/mnt/BIG/filme/configs/tts-pipeline` | custom Flask web UI + pipeline.sh for automated audiobook conversion |
| epub2tts-edge | `/mnt/BIG/filme/configs/epub2tts-edge` | custom EPUB/TXT → M4B converter (profiles: tools, on-demand only) |

---

## storage architecture

### ZFS layout

all data lives under `/mnt/BIG/filme/` on ZFS pool `BIG`:

| path | purpose | consumers |
|------|---------|-----------|
| `/mnt/BIG/filme/docker-compose/` | compose file, .env, scripts | docker compose |
| `/mnt/BIG/filme/configs/` | per-service config volumes | all services |
| `/mnt/BIG/filme/immich/` | photos, database, redis, ML cache | immich stack, postgres |
| `/mnt/BIG/filme/filme/` | movie library | jellyfin, radarr, bazarr |
| `/mnt/BIG/filme/seriale/` | TV show library | jellyfin, sonarr, bazarr |
| `/mnt/BIG/filme/music/` | music library | jellyfin, lidarr |
| `/mnt/BIG/filme/books/` | ebook library | readarr |
| `/mnt/BIG/filme/transmission/` | torrent downloads | transmission, sonarr, radarr, lidarr, readarr, unpackerr |
| `/mnt/BIG/filme/audiobookshelf/` | audiobooks, podcasts, metadata | audiobookshelf, tts-pipeline |
| `/mnt/BIG/filme/tts/` | TTS input directories (4 voice folders) | tts-pipeline |
| `/mnt/BIG/filme/backups/` | database backups | postgres-backup |
| `/mnt/BIG/filme/syncthing/` | syncthing data + config | syncthing |

the naming convention (`/mnt/BIG/filme/filme/` for movies) is historical — `filme` is the Romanian word for "films/movies". the outer `filme` is the ZFS dataset name, the inner `filme` is the movie library directory.

### critical data paths

| path | criticality | backup method |
|------|-------------|---------------|
| `/mnt/BIG/filme/immich/postgresql` | **CRITICAL** — immich photo metadata | postgres-backup (daily) + pre-upgrade dumps |
| `/mnt/BIG/filme/immich/photos` | **HIGH** — original photos | ZFS snapshots |
| `/mnt/BIG/filme/configs/vaultwarden` | **HIGH** — password vault | ZFS snapshots |

---

## VPN architecture

all download and ARR services route through a single gluetun container running Surfshark OpenVPN:

```
internet
   |
   v
gluetun (Surfshark OpenVPN, Romania)
   |
   +-- transmission (:9091, :51413)
   +-- jdownloader (:5800)
   +-- prowlarr (:9696)
   +-- sonarr (:8989)
   +-- radarr (:7878)
   +-- lidarr (:8686)
   +-- readarr (:8787)
   +-- bazarr (:6767)
```

### VPN history

| version | type | reason for change |
|---------|------|-------------------|
| v97 | WireGuard | initial gluetun deployment |
| v98 | WireGuard | confirmed working |
| v104 | OpenVPN | WireGuard blocked outbound peer connections on all Surfshark servers |

### VPN healthcheck and recovery

the gluetun healthcheck uses an IP-based HTTP test (v106) that avoids DNS resolution:

```
wget → http://1.1.1.1/cdn-cgi/trace → grep 'warp='
```

if the healthcheck fails 3 consecutive times (3 minutes), Docker marks gluetun as unhealthy. autoheal detects this and restarts gluetun within 60 seconds. this handles stale VPN sessions that would otherwise silently block all download traffic.

---

## text-to-speech architecture

added in v108–v109, the TTS subsystem converts PDF/EPUB files into M4B audiobooks using Microsoft Edge's free cloud-based neural voices:

```
input files (PDF/EPUB/TXT)
   |
   v
tts-pipeline (Flask web UI :5051 + filesystem watcher)
   |
   +-- /input/ro-emil/   → ro-RO-EmilNeural (Romanian male)
   +-- /input/ro-alina/  → ro-RO-AlinaNeural (Romanian female)
   +-- /input/en-ryan/   → en-GB-RyanNeural (British male)
   +-- /input/en-sonia/  → en-GB-SoniaNeural (British female)
   |
   v
edge-tts API (:5050, OpenAI-compatible)
   |
   v
audiobookshelf library (/audiobooks/cărți/)
```

the web interface on port 5051 allows file upload and URL pasting. the pipeline.sh watcher monitors all 4 voice directories and auto-selects the voice based on which directory contains the input file. output goes directly into audiobookshelf's library for automatic pickup.

epub2tts-edge is available as an on-demand tool (`docker compose run epub2tts-edge`) for manual conversions via the `profiles: tools` mechanism.

### design decision: cloud TTS vs local

edge-tts was chosen over local alternatives (Piper, Coqui) because the HP MicroServer Gen8 has no GPU and limited CPU. Microsoft Edge's neural voices provide significantly better quality than CPU-only local TTS, and the service is free with no API key required.

---

## self-healing architecture

### autoheal pattern (v106)

autoheal monitors containers with the `autoheal: "true"` label and restarts them when Docker reports them as unhealthy:

```
gluetun healthcheck fails 3x (3 min)
   → Docker marks unhealthy
   → autoheal detects within 60s
   → autoheal restarts gluetun
   → gluetun reconnects to Surfshark
   → healthcheck passes
   → all VPN-dependent services resume
```

currently only gluetun uses the autoheal label. the pattern can be extended to other services by adding `autoheal: "true"` to their labels.

### transmission resilience (v107)

transmission is configured with conservative limits to prevent ZFS I/O saturation:

| setting | value | purpose |
|---------|-------|---------|
| download queue | 10 concurrent | prevents I/O stampede |
| seed queue | 50 concurrent | limits active seeding |
| stalled minutes | 1 | quickly detects stuck torrents |
| cache | 64 MB | batches writes to ZFS |
| peer limit global | 300 | limits connection overhead |
| peer limit per torrent | 30 | limits per-torrent I/O |

---

## monitoring pipeline

```
bender cadvisor (:9099)
   |
   v
prometheus (:9090, HA VM 192.168.21.220)
   |
   v
grafana (HA add-on, 2 dashboards)
```

cadvisor runs with resource-saving flags that reduced CPU usage by 97% (9.90% → 0.32%) and memory by 85% (118 MiB → 18 MiB):

- `--docker_only=true` — skips host-level metrics
- `--housekeeping_interval=30s` — reduces polling frequency
- `--disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl`

the grafana dashboard for bender uses `instance` variable set to Constant type with value `192.168.21.121:9099`.

beszel-agent provides additional system-level monitoring (CPU, memory, disk, network) to the beszel hub running on amy.

---

## high availability

### pihole DNS failover

| setting | bender (MASTER) | amy (BACKUP) |
|---------|-----------------|--------------|
| VIP | 192.168.21.100 | 192.168.21.100 |
| interface | bond0 | enp4s0 |
| priority | 200 | 100 |
| VRRP ID | 53 | 53 |
| mode | unicast | unicast |
| health check | wget pihole admin (:8053) | wget pihole admin (:8053) |
| failover time | ~5 seconds | ~5 seconds |

keepalived uses unicast mode with explicit peer addresses (192.168.21.121 ↔ 192.168.21.130) rather than multicast. the health check script runs every 2 seconds with a weight of -150 — if pihole fails 3 consecutive checks, the priority drops below amy's 100 and the VIP migrates.

nebula-sync replicates pihole configuration from bender to amy hourly with `FULL_SYNC=true` and `RUN_GRAVITY=true`.

---

## integration with amy

### bender → amy dependencies

| bender service | depends on (amy) | purpose |
|---------------|------------------|---------|
| diun | ntfy | update notifications |
| secure-container-update.sh | ntfy | update/rollback notifications |
| nebula-sync | pihole on amy | DNS replication target |
| beszel-agent | beszel hub on amy | system metrics collection |
| pihole-dns-update.sh | docker API on amy (via SSH) | scan amy containers for DNS labels |

### amy → bender dependencies

| amy service | depends on (bender) | purpose |
|------------|---------------------|---------|
| homepage | dockerproxy on bender (:2375) | container status widget |
| pihole-dns-update.sh | tsdproxy labels on bender | DNS auto-population source |

---

## technology stack

| layer | technology |
|-------|------------|
| **host OS** | TrueNAS Scale (Debian-based) |
| **container runtime** | Docker + Docker Compose |
| **storage** | ZFS (pool BIG) |
| **networking** | bridge, host, gluetun VPN tunnel |
| **DNS** | pihole v6 (TOML config) |
| **HA** | keepalived (VRRP unicast) |
| **remote access** | Tailscale via tsdproxy |
| **monitoring** | cadvisor → prometheus → grafana, beszel |
| **updates** | diun (notifications) + trivy (scanning) + custom script |
| **notifications** | ntfy (on amy) |
| **VPN** | Surfshark via gluetun (OpenVPN) |
| **TTS** | Microsoft Edge neural voices via edge-tts |
| **backup** | postgres-backup-local (daily), ZFS snapshots |

---

*next: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
