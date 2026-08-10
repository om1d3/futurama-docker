# bender architecture

## infrastructure design and system overview

**document version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

---

## table of contents

1. [executive summary](#executive-summary)
2. [hardware specifications](#hardware-specifications)
3. [network configuration](#network-configuration)
4. [service architecture](#service-architecture)
5. [storage architecture](#storage-architecture)
6. [VPN architecture](#vpn-architecture)
7. [text-to-speech architecture](#text-to-speech-architecture)
8. [git forge architecture](#git-forge-architecture)
9. [replication architecture](#replication-architecture)
10. [SMART monitoring architecture](#smart-monitoring-architecture)
11. [self-healing architecture](#self-healing-architecture)
12. [monitoring pipeline](#monitoring-pipeline)
13. [high availability](#high-availability)
14. [integration with amy](#integration-with-amy)
15. [technology stack](#technology-stack)

---

## executive summary

bender is the primary host in a two-host home lab infrastructure. it runs on TrueNAS Scale on an HP MicroServer Gen8 and is responsible for media services, download automation, photo management, text-to-speech audiobook generation, calendar/contacts, task management, git hosting for infrastructure-as-code, and primary DNS. it serves as the storage backend for the infrastructure, with amy (the secondary host) providing utilities, monitoring, and notifications.

as of 20260809, bender defines 42 services and runs 41. epub2tts-edge sits behind `profiles: tools` and runs on demand only. the categories are media, downloads, collaboration, calendar, tasks, git forge, text-to-speech, time-series, remote management, databases, DNS/HA, infrastructure, monitoring, and updates. three containers use `build:` directives instead of pre-built images: transmission, audiobook-foundry, and epub2tts-edge.

two subsystems added since v109 make bender self-sufficient where TrueNAS middleware proved unreliable: nightly critical-data replication to amy (bender-replicate.sh) and middleware-independent SMART disk testing with state-diff alerting (smart-test.sh), replacing the SMART scheduling UI removed in TrueNAS 25.10.

---

## hardware specifications

| component | specification |
|-----------|--------------|
| **model** | HP ProLiant MicroServer Gen8 |
| **CPU** | Intel Xeon E3-1265L V2 (4 cores, 8 threads, 2.5 GHz) |
| **RAM** | 16 GB ECC DDR3 |
| **iGPU** | disabled by HP BIOS (no hardware transcoding) |
| **storage** | ZFS pool `BIG` – 4x HDD; MicroSD boot device |
| **network** | ens1f0 (10G NIC, primary interface) |
| **OS** | TrueNAS Scale (25.10.x, Debian bookworm base) |
| **IP** | 10.30.0.12 |
| **iLO** | 10.30.0.13 (remote BIOS/console access) |

### known hardware limitations

- **no GPU acceleration**: HP BIOS disables the Xeon's integrated GPU. jellyfin transcoding is software-only. GPU passthrough is commented out in docker-compose.yaml for future use
- **ZFS I/O sensitivity**: aggressive random I/O (hash checking, many concurrent torrents, unconstrained immich ML) can overwhelm the 4-disk array. transmission runs with queue limits (10 download, 50 seed), 64 MB write cache, and peer limits (300 global, 30 per torrent); immich runs with memory/CPU caps and job concurrency 1 (v112)
- **intel_iommu**: set to `off` in the MicroSD GRUB config (v107). HP iLO DMAR interrupt faults escalated ZFS I/O stalls into hard freezes when `intel_iommu=on` was active
- **noexec pool**: scripts under `/mnt/` cannot be executed directly. all scheduled and manual script invocations use the `bash /mnt/...` form instead of direct execution (the legacy copy-to-/tmp pattern was retired in 2026-07)
- **apt locked by default**: TrueNAS blocks apt; developer mode was unlocked via `install-dev-tools` with the Debian bookworm repository added. an idempotent Pre Init script re-applies this after every TrueNAS upgrade
- **MicroSD single point of failure**: the boot device (including the GRUB `intel_iommu=off` setting) has no redundancy. imaging a spare card is backlog item 04-A
- **legacy NIC hazard**: the onboard eno1 was found physically connected to a mislabeled switch port and silently carrying (and dropping) production traffic. the switch port was shut down; ens1f0 is the sole production interface. if bender ever loses connectivity after cabling work, verify the default route is on ens1f0 first

---

## network configuration

### interfaces

| interface | type | ip address | purpose |
|-----------|------|------------|---------|
| ens1f0 | 10G NIC | 10.30.0.12 | primary network (all services, keepalived VRRP) |
| eno1 | onboard 1G | unconfigured | disconnected – switch port administratively down |
| tailscale | overlay | dynamic | remote access via tsdproxy |

### DNS

| setting | value |
|---------|-------|
| pihole VIP | 10.30.0.2 (keepalived VRRP) |
| upstream DNS | 1.1.1.1, 8.8.8.8 |
| local domain | `home.arpa` |
| auto-population | pihole-dns-update.sh v3.2 (hourly, hash-guarded) |

all services on the `media-network` bridge use the DNS anchor `10.30.0.2` (pihole VIP) via the `x-dns-config` YAML anchor. exceptions are pihole itself (it IS the DNS server), keepalived, syncthing, and beszel-agent (all use host networking), and autoheal (docker.sock only, no network).

the DNS scraper runs hourly rather than every 5 minutes (the v3.0 cadence): it is hash-guarded, so 23 of 24 runs are no-ops, and new tsdproxy names resolve within the hour or immediately after a manual `bash /mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh`.

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
| 2222 | forgejo git SSH |
| 2283 | immich |
| 2375 | dockerproxy |
| 3000 | hedgedoc |
| 3030 | forgejo HTTP |
| 3456 | vikunja |
| 5050 | edge-tts |
| 5051 | audiobook-foundry (TTS pipeline) |
| 8086 | influxdb (time-series, no tsdproxy) |
| 8584 | meshcentral (HTTP redirect) |
| 8585 | meshcentral (web and KVM) |
| 5432 | postgresql |
| 5800 | jdownloader (via gluetun) |
| 6767 | bazarr (via gluetun) |
| 7878 | radarr (via gluetun) |
| 8001 | baikal |
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

### service categories (41 active containers, 42 defined)

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
| **calendar & contacts** | 1 | baikal |
| **task management** | 1 | vikunja |
| **git forge** | 1 | forgejo |
| **text-to-speech** | 2 | edge-tts, audiobook-foundry |
| **time-series** | 1 | influxdb |
| **remote management** | 1 | meshcentral |
| **monitoring** | 2 | beszel-agent, cadvisor |
| **updates** | 2 | diun, trivy |
| **support** | 1 | flaresolverr |
| **total active** | **39** | |

additionally, 3 services are commented out or use profiles: qbittorrent (commented, incompatible with ZFS I/O), playwright-chrome (commented, future use), epub2tts-edge (profiles: tools, on-demand only).

### network modes

| mode | count | services |
|------|-------|----------|
| bridge (media-network) | 27 | most services |
| host | 3 | keepalived, syncthing, beszel-agent |
| service:gluetun | 8 | transmission, jdownloader, prowlarr, sonarr, radarr, lidarr, readarr, bazarr |
| none (standalone) | 1 | autoheal (docker.sock only) |

### build-based containers

three containers use `build:` instead of `image:`. these require `docker compose build` for updates rather than `docker compose pull`:

| container | build context | reason |
|-----------|--------------|--------|
| transmission | `/mnt/BIG/filme/configs/transmission` | pre-baked Flood UI (eliminates linuxserver mod download on every restart); base image pinned 4.0.5 |
| audiobook-foundry | `/mnt/BIG/filme/configs/audiobook-foundry` | custom Flask web UI plus pipeline.sh for automated audiobook conversion. lineage: tts-pipeline (v108) to lrrr (v113) to audiobook-foundry (20260729). the build context is now a git checkout of a public repository, so `git log` answers what is deployed. |
| epub2tts-edge | `/mnt/BIG/filme/configs/epub2tts-edge` | custom EPUB/TXT → M4B converter (profiles: tools, on-demand only) |

---

## storage architecture

### ZFS layout

all data lives under `/mnt/BIG/filme/` on ZFS pool `BIG`:

| path | purpose | consumers |
|------|---------|-----------|
| `/mnt/BIG/filme/docker-compose/` | compose file, .env, scripts, secure-update state | docker compose, all cron jobs |
| `/mnt/BIG/filme/configs/` | per-service config volumes | all services |
| `/mnt/BIG/filme/immich/` | photos, database, redis, ML cache | immich stack, postgres |
| `/mnt/BIG/filme/filme/` | movie library | jellyfin, radarr, bazarr |
| `/mnt/BIG/filme/seriale/` | TV show library | jellyfin, sonarr, bazarr |
| `/mnt/BIG/filme/music/` | music library | jellyfin, lidarr |
| `/mnt/BIG/filme/books/` | ebook library | readarr |
| `/mnt/BIG/filme/transmission/` | torrent downloads | transmission, ARR apps, unpackerr |
| `/mnt/BIG/filme/audiobookshelf/` | audiobooks, podcasts, metadata | audiobookshelf, audiobook-foundry, epub2tts-edge |
| `/mnt/BIG/filme/tts/` | TTS input directories (4 voice folders) | audiobook-foundry, epub2tts-edge |
| `/mnt/BIG/filme/influxdb/` | InfluxDB 1.x time-series data | influxdb |
| `/mnt/BIG/filme/backups/` | database backups | postgres-backup, update-script pre-upgrade dumps |
| `/mnt/BIG/filme/syncthing/` | syncthing data + config | syncthing |

the naming convention (`/mnt/BIG/filme/filme/` for movies) is historical – `filme` is the Romanian word for "films/movies". the outer `filme` is the ZFS dataset name, the inner `filme` is the movie library directory.

### critical data paths

| path | criticality | backup method |
|------|-------------|---------------|
| `/mnt/BIG/filme/immich/postgresql` | **CRITICAL** – immich photo metadata + hedgedoc, baikal, vikunja, forgejo databases | postgres-backup (daily dumps of all five databases) + pre-upgrade dumps + nightly dump replication to amy |
| `/mnt/BIG/filme/immich/photos` | **HIGH** – original photos | ZFS snapshots |
| `/mnt/BIG/filme/configs/vaultwarden` | **HIGH** – password vault | ZFS snapshots + nightly replication to amy |
| `/mnt/BIG/filme/configs/forgejo` | **HIGH** – git repositories (futurama-terraform IaC) | postgres dump (metadata) + nightly replication to amy (repo data) |
| `/mnt/BIG/filme/docker-compose/` | **HIGH** – compose, .env, all operational scripts | nightly replication to amy + futurama-docker git repo (compose + .env.gpg) |

note that the single shared postgres instance now carries **five** tenant databases (immich, hedgedoc, baikal, vikunja, forgejo), which concentrates criticality on `/mnt/BIG/filme/immich/postgresql` – the path name is historical; it long ago outgrew "immich only".

---

## VPN architecture

all download and ARR services route through a single gluetun container running Surfshark OpenVPN:

```
internet
   │
   ▼
gluetun (Surfshark OpenVPN, Romania)
   │
   ├── transmission (:9091, :51413)
   ├── jdownloader (:5800)
   ├── prowlarr (:9696)
   ├── sonarr (:8989)
   ├── radarr (:7878)
   ├── lidarr (:8686)
   ├── readarr (:8787)
   └── bazarr (:6767)
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

### gluetun as a critical update target

since secure-container-update.sh v1.3, gluetun is classified as a **critical service** in the update pipeline. updating gluetun destroys the network namespace that its eight dependents share, so the pipeline recreates all eight in a defined order after a gluetun update instead of leaving them attached to a dead namespace. see [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md).

---

## text-to-speech architecture

added in v108 and v109, renamed to lrrr in v113, then to audiobook-foundry in 20260729. the TTS subsystem converts PDF and EPUB files into M4B audiobooks using Microsoft Edge's free cloud-based neural voices:

```
input files (PDF/EPUB/TXT)
   │
   ▼
audiobook-foundry (Flask web UI :5051 + filesystem watcher)
   │
   ├── /input/ro-emil/   → ro-RO-EmilNeural (Romanian male)
   ├── /input/ro-alina/  → ro-RO-AlinaNeural (Romanian female)
   ├── /input/en-ryan/   → en-GB-RyanNeural (British male)
   ├── /input/en-sonia/  → en-GB-SoniaNeural (British female)
   │
   ▼
edge-tts API (:5050, OpenAI-compatible)
   │
   ▼
audiobookshelf library (/audiobooks/cărți/)
```

notifications are sent via ntfy on amy when a conversion completes or fails. audiobook-foundry publishes to the `tts-pipeline` topic at `http://10.30.0.11:8888/tts-pipeline`. the topic name predates both renames and was deliberately kept, so notification history stays continuous.

the web interface on port 5051 allows file upload and URL pasting. the pipeline.sh watcher monitors all 4 voice directories and auto-selects the voice based on which directory contains the input file. output goes directly into audiobookshelf's library for automatic pickup.

epub2tts-edge is available as an on-demand tool (`docker compose run --rm epub2tts-edge`) via the `profiles: tools` mechanism.

### design decision: cloud TTS vs local

edge-tts was chosen over local alternatives (Piper, Coqui) because the HP MicroServer Gen8 has no GPU and limited CPU. Microsoft Edge's neural voices provide significantly better quality than CPU-only local TTS, and the service is free with no API key required.

---

## git forge architecture

added in v115, forgejo hosts the `futurama-terraform` infrastructure-as-code repository (and future repos) locally:

| aspect | value |
|--------|-------|
| image | `codeberg.org/forgejo/forgejo:15` (v15 LTS, supported to 2027-07) |
| HTTP | 3030:3000 – `http://git.home.arpa:3030/` |
| git SSH | 2222:22 – `ssh://git@git.home.arpa:2222/` |
| database | dedicated `forgejo` user and database in shared postgres |
| registration | disabled (single-user instance; admin created on first launch) |
| tailscale | `git` → https://git.bunny-enigmatic.ts.net |

### design decision: source of truth off the cluster

forgejo lives on bender **permanently**, not on the planned futurama Kubernetes cluster, for the same reason the Garage state backend does: the source of truth for the cluster must not live on the cluster it defines. if the cluster is down, its definition must still be readable and editable.

### design decision: dedicated database user

forgejo is the exception to the superuser-sharing pattern used by immich, hedgedoc, baikal, and vikunja (which all connect as `postgres`). forgejo connects as its own `forgejo` user owning the `forgejo` database. this was a deliberate first step toward per-tenant users; new services should follow the forgejo pattern rather than the legacy one.

### upgrade policy

the rolling `:15` tag delivers minor/patch updates only. major upgrades (→16) are a manual, deliberate operation per Forgejo policy: read the release notes, change the image tag explicitly, never let the auto-updater cross a major boundary.

---

## replication architecture

bender-replicate.sh (added 2026-07) copies bender's critical, non-regenerable data to amy nightly:

```
bender (03:30 daily, TrueNAS UI cron)
   │
   │  rsync over SSH (root@bender → kube@10.30.0.11)
   ▼
amy: /docker/backups/bender-replica/
   ├── configs/            (all service configs incl. vaultwarden, forgejo)
   ├── backups/postgres/   (the daily dumps of all five databases)
   └── docker-compose/     (compose, .env, scripts – the system replicates its own code)
```

| aspect | value |
|--------|-------|
| schedule | daily 03:30 (after amy's 02:00 sss rsync, before the 04:30 update windows) |
| retention | 7 days |
| exclusions | regenerable bulk (media libraries, download data, ML caches) |
| transport | rsync over SSH; bender root's key trusts kube@amy (shared with the DNS scraper) |
| notifications | ntfy on completion/failure |

this is a disaster-recovery replica, not an archive: it answers "bender's boot device or pool died – restore configs, secrets, and database dumps from amy". media libraries are covered separately by ZFS snapshots and are considered regenerable.

**scheduling rule:** the weekly update scan (saturday 04:30) and the replication run must never execute simultaneously on the Gen8 – the schedules are offset by design (03:30 vs 04:30); do not move either without preserving the gap.

---

## SMART monitoring architecture

TrueNAS 25.10 removed the SMART scheduling UI and auto-converted existing schedules into `midclt call disk.smart_test` cron entries whose API signature then drifted and broke. smart-test.sh (v1.1) replaces the whole mechanism, talking to smartctl directly so no TrueNAS release can silently break it:

| mode | schedule | behavior |
|------|----------|----------|
| `short` | weekly, monday 05:00 | starts SHORT self-test on all eligible disks; skips disks with a test already in progress (never force-aborts) |
| `long` | monthly, 1st 05:00 | starts LONG (extended) self-test on all eligible disks |
| `report` | daily 18:00 | reads health + critical attributes, compares to saved state, pushes ntfy ONLY on degradation or FAILED health |
| `status` | manual | human-readable table to stdout |

eligible disks are whole disks (sd*/nvme*) that answer smartctl; the MicroSD boot device (mmcblk) is skipped automatically. watched attributes: 5 Reallocated_Sector_Ct, 187 Reported_Uncorrect, 197 Current_Pending_Sector, 198 Offline_Uncorrectable, 199 UDMA_CRC_Error_Count (warn only). baselines live in `configs/secure-update/smart-state/` keyed by model_serial, so they survive device-letter shuffles; after replacing a disk, the next report run creates its baseline automatically.

v1.1 fixed two v1.0 defects discovered live: in-progress test detection missed one drive family's reporting format, and smartctl's bitmask exit codes were misclassified as failures instead of skips.

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

### immich resource containment (v112)

unconstrained immich ML workers caused an OOM during bulk photo uploads: load average hit 10.96 on the 4-core CPU and ZFS `txg_sync` stalled for over 120 seconds. containment since v112:

| container | mem_limit | cpus | additional |
|-----------|-----------|------|------------|
| immich_server | 2G | 2.0 | – |
| immich_machine_learning | 3G | 1.5 | all job concurrency set to 1 in Admin UI → Settings → Job Settings |

the Admin UI concurrency setting lives in the immich database, not the compose file – after a database restore, re-verify it.

---

## monitoring pipeline

```
bender cadvisor (:9099)
   │
   ▼
prometheus (:9090, Home Assistant VM 10.30.0.41)
   │
   ▼
grafana (HA add-on, 2 dashboards)
```

cadvisor runs with resource-saving flags that reduced CPU usage by 97% (9.90% → 0.32%) and memory by 85% (118 MiB → 18 MiB):

- `--docker_only=true` – skips host-level metrics
- `--housekeeping_interval=30s` – reduces polling frequency
- `--disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl`

the grafana dashboard for bender uses an `instance` variable set to Constant type with value `10.30.0.12:9099` (amy's dashboard: `10.30.0.11:9099`). after the v113 subnet migration, any prometheus scrape config still targeting `192.168.21.x` addresses returns nothing – if a dashboard goes empty, check the scrape targets on the HA VM first.

beszel-agent provides additional system-level monitoring (CPU, memory, disk, network) to the beszel hub running on amy (10.30.0.11:8090).

---

## high availability

### pihole DNS failover

| setting | bender (MASTER) | amy (BACKUP) |
|---------|-----------------|--------------|
| VIP | 10.30.0.2 | 10.30.0.2 |
| interface | ens1f0 | enp4s0 (per amy's keepalived.conf; no rename ever recorded) |
| priority | 200 | 100 |
| VRRP ID | 53 | 53 |
| mode | unicast (peer 10.30.0.11) | unicast (peer 10.30.0.12) |
| health check | wget pihole admin (:8053) every 2s | wget pihole admin (:8053) every 2s |
| failover time | ~5 seconds | ~5 seconds |

keepalived uses unicast mode with explicit peer addresses rather than multicast. the health check script runs every 2 seconds with a weight of -150 – if pihole fails 3 consecutive checks, the priority drops below amy's 100 and the VIP migrates. the v113 migration moved bender's keepalived interface from enp4s0 to ens1f0 (the 10G NIC) and the VIP from 192.168.21.100 to 10.30.0.2; amy's keepalived.conf peer address was updated to 10.30.0.12 in the same change.

nebula-sync replicates pihole configuration from bender (PRIMARY http://10.30.0.12:8053) to amy (REPLICAS http://10.30.0.11:8053) hourly with `FULL_SYNC=true` and `RUN_GRAVITY=true`.

---

## integration with amy

### bender → amy dependencies

| bender service | depends on (amy) | purpose |
|---------------|------------------|---------|
| diun | ntfy (10.30.0.11:8888) | update notifications |
| secure-container-update.sh | ntfy | update/rollback notifications |
| smart-test.sh | ntfy | disk degradation alerts |
| bender-replicate.sh | SSH (kube@10.30.0.11) + /docker/backups/bender-replica | nightly critical-data replica |
| nebula-sync | pihole on amy (10.30.0.11:8053) | DNS replication target |
| beszel-agent | beszel hub on amy (10.30.0.11:8090) | system metrics collection |
| pihole-dns-update.sh | docker API on amy (via SSH, kube@10.30.0.11) | scan amy containers for DNS labels |
| audiobook-foundry | ntfy (10.30.0.11:8888/tts-pipeline) | conversion notifications |
| influxdb | none | Home Assistant writes to it; nothing on bender consumes it |
| meshcentral | AMT on 10.50.0.0/16 | needs the fry pass rule for TCP 16992-16995 and 5900 |

### amy → bender dependencies

| amy service | depends on (bender) | purpose |
|------------|---------------------|---------|
| homepage | dockerproxy on bender (10.30.0.12:2375) | container status widget |
| pihole (amy) | nebula-sync push from bender | receives full pihole config hourly |

note the asymmetry: notifications and monitoring live on amy so that a bender outage (TrueNAS upgrade, pool issue) does not silence the alerts about that very outage.

---

## technology stack

| layer | technology |
|-------|------------|
| **host OS** | TrueNAS Scale (Debian bookworm base, developer mode enabled via post-init script) |
| **container runtime** | Docker + Docker Compose |
| **storage** | ZFS (pool BIG) |
| **networking** | bridge, host, gluetun VPN tunnel; 10G via ens1f0 |
| **DNS** | pihole v6 (TOML config), auto-populated hourly |
| **HA** | keepalived (VRRP unicast, VIP 10.30.0.2) |
| **remote access** | Tailscale via tsdproxy |
| **git forge** | Forgejo 15 LTS (IaC source of truth) |
| **monitoring** | cadvisor → prometheus → grafana, beszel |
| **disk health** | smart-test.sh (direct smartctl, state-diff alerting) |
| **updates** | diun (notifications) + trivy (scanning) + secure-container-update.sh v1.3 |
| **notifications** | ntfy (on amy) |
| **VPN** | Surfshark via gluetun (OpenVPN) |
| **TTS** | Microsoft Edge neural voices via edge-tts |
| **backup** | postgres-backup-local (daily, 5 databases), ZFS snapshots, nightly replication to amy |

---

*next: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
