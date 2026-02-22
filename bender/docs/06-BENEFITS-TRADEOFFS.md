# bender benefits and tradeoffs

## design decisions analysis

**document version:** 3.0
**infrastructure version:** 109
**last updated:** february 2026

---

## table of contents

1. [two-host architecture](#two-host-architecture)
2. [single compose file per host](#single-compose-file-per-host)
3. [shared postgresql](#shared-postgresql)
4. [security-first container updates](#security-first-container-updates)
5. [keepalived for DNS failover](#keepalived-for-dns-failover)
6. [centralized VPN with gluetun](#centralized-vpn-with-gluetun)
7. [autoheal for VPN recovery](#autoheal-for-vpn-recovery)
8. [transmission configuration choices](#transmission-configuration-choices)
9. [cloud TTS vs local TTS](#cloud-tts-vs-local-tts)
10. [pre-baked Flood UI for transmission](#pre-baked-flood-ui-for-transmission)
11. [cadvisor resource optimization](#cadvisor-resource-optimization)
12. [pihole v6 TOML-based DNS](#pihole-v6-toml-based-dns)
13. [tailscale via tsdproxy](#tailscale-via-tsdproxy)
14. [ZFS on HP MicroServer Gen8](#zfs-on-hp-microserver-gen8)

---

## two-host architecture

### decision

split infrastructure across two physical hosts: bender (TrueNAS Scale, media/downloads) and amy (Debian, utilities/monitoring).

### benefits

- **failure isolation**: a TrueNAS upgrade or crash does not take down notifications, monitoring, or DNS backup
- **resource separation**: heavy media processing (immich ML, transmission I/O) doesn't compete with lightweight utilities
- **independent updates**: each host can be updated on different schedules (bender saturday, amy wednesday)
- **ZFS independence**: amy runs on a simple ext4/btrfs disk — not affected by ZFS pool issues

### tradeoffs

- **cross-host dependencies**: some services depend on the other host (diun → ntfy, homepage → dockerproxy, nebula-sync → amy pihole)
- **two compose files to maintain**: changes sometimes need to be synchronized
- **network latency**: cross-host communication adds ~0.1ms (negligible on LAN)

### alternatives considered

- **single host**: simpler but no failure isolation. a TrueNAS upgrade takes everything down
- **kubernetes**: overkill for 65 containers across 2 hosts. docker compose is sufficient

---

## single compose file per host

### decision

one docker-compose.yaml per host rather than multiple compose files or docker stacks.

### benefits

- **tsdproxy compatibility**: tsdproxy requires all containers in the same compose project to manage tailscale proxies
- **simpler management**: `docker compose up -d` deploys everything. no orchestration between multiple files
- **atomic operations**: `docker compose down` stops everything cleanly
- **single .env file**: all configuration in one place per host

### tradeoffs

- **large file**: bender's v109 docker-compose.yaml is ~800 lines with 36 services
- **all-or-nothing restarts**: `docker compose up -d` touches all services (though Docker only recreates changed ones)
- **version tracking**: the file header changelog grows with every change

---

## shared postgresql

### decision

one postgresql instance per host, shared by multiple applications.

### benefits

- **RAM savings**: ~400 MB saved vs running separate postgres instances per app
- **centralized backup**: postgres-backup backs up all databases in one container
- **simplified management**: one database server to monitor, tune, and upgrade

### tradeoffs

- **single point of failure**: if postgres crashes, all dependent services go down (immich, hedgedoc on bender; atuin, miniflux, spendspentspent, mealie, stirling on amy)
- **upgrade risk**: postgres upgrades affect all applications simultaneously
- **mixed extensions**: bender's postgres uses the immich-specific vectorchord image, which may not be optimal for hedgedoc

### mitigation

- postgres is classified as a **critical service** in the update system
- pre-upgrade backups are mandatory before any postgres update
- health checks verify all databases are accessible after updates
- automatic rollback if any dependent service fails post-update

---

## security-first container updates

### decision

scan every container image with trivy before deployment. block containers with CRITICAL or HIGH vulnerabilities.

### benefits

- **no vulnerable containers deployed**: zero-tolerance policy for critical CVEs
- **automatic retry**: blocked containers are retried daily when patches become available
- **audit trail**: trivy scan reports retained for 180 days
- **rollback safety**: image backups (3 versions) enable instant rollback

### tradeoffs

- **delayed updates**: a container with upstream vulnerabilities may be blocked for days until patched
- **trivy false positives**: occasionally blocks updates due to disputed CVEs
- **scan time**: trivy scans can take 5–15 minutes per image, extending the update window
- **build containers excluded**: transmission, tts-pipeline, epub2tts-edge use `build:` and cannot be auto-scanned by the pipeline

### mitigation

- daily retry ensures blocked containers are eventually updated
- manual override available via `secure-container-update.sh scan <container>`
- build containers are manually rebuilt and can be scanned separately with `trivy image`

---

## keepalived for DNS failover

### decision

use keepalived VRRP to provide a floating VIP (192.168.21.100) for pihole DNS, with automatic failover between bender (master, priority 200) and amy (backup, priority 100).

### benefits

- **zero-downtime DNS**: clients always query the VIP, never a specific host
- **automatic failover**: ~5 seconds to migrate VIP when pihole fails health check
- **no client reconfiguration**: router DHCP points to VIP, not individual hosts
- **unicast mode**: avoids multicast issues on some network configurations

### tradeoffs

- **split-brain risk**: if network partitions, both hosts may claim the VIP (mitigated by unicast with explicit peers)
- **configuration sync**: pihole configs must be synchronized separately (nebula-sync handles this hourly)
- **bond0 vs enp4s0**: bender uses a bonded interface (bond0) while amy uses a physical NIC (enp4s0) — configs are not identical

### history

- initially deployed with multicast VRRP, priority 150/100, interface enp4s0 on bender
- migrated to unicast mode with explicit peer addresses for reliability
- bender interface changed to bond0 when NIC bonding was configured
- bender priority increased to 200 (from 150) to ensure it always wins master election when available

---

## centralized VPN with gluetun

### decision

route all download and ARR services through a single gluetun container running Surfshark OpenVPN, rather than per-container VPN configurations.

### benefits

- **single tunnel**: one VPN connection serves 9 containers (transmission + 7 ARR + jdownloader)
- **centralized management**: VPN credentials and server selection in one place
- **port exposure**: all VPN-routed ports defined on gluetun, not spread across containers
- **health monitoring**: single healthcheck determines VPN status for all dependent services

### tradeoffs

- **single point of failure**: if gluetun fails, all download/ARR services lose connectivity
- **no per-service VPN selection**: all services use the same server country
- **port conflicts**: all services must use unique ports since they share gluetun's network namespace

### mitigation

- autoheal auto-restarts gluetun on stale VPN sessions (v106)
- IP-based healthcheck avoids DNS resolution failures in BusyBox

### VPN type history

| version | type | outcome |
|---------|------|---------|
| v97–v98 | WireGuard | initial deployment, worked initially |
| v104 | OpenVPN | switched after WireGuard blocked outbound peer connections on all Surfshark servers |

---

## autoheal for VPN recovery

### decision

deploy autoheal to auto-restart gluetun when Docker reports it as unhealthy, rather than relying on manual intervention or Docker's restart policy.

### benefits

- **automatic recovery**: stale VPN sessions are detected and restarted within ~4 minutes (3 min healthcheck failure + 60s autoheal interval)
- **targeted**: only restarts containers with `autoheal: "true"` label, not everything
- **silent operation**: no ntfy notifications for routine VPN reconnects (only for update rollbacks)

### tradeoffs

- **restart loops**: if gluetun is fundamentally broken (credentials expired, server down), autoheal will restart it repeatedly
- **brief outages**: all VPN-dependent services lose connectivity during the restart (~30 seconds)

### why not Docker restart policy alone

Docker's `restart: unless-stopped` only restarts containers that exit (crash). gluetun with a stale VPN session stays running (exit code 0) but with no actual connectivity. the healthcheck + autoheal combination detects this "running but broken" state.

---

## transmission configuration choices

### decision

pin transmission to 4.0.5 with a custom Docker image, conservative queue limits, and pre-baked Flood UI.

### FileList whitelist requirement

transmission 4.0.6+ is NOT on the FileList private tracker whitelist. upgrading would result in immediate ban. the version is pinned in the Dockerfile `FROM` line.

### queue and I/O limits (v107)

after an incident where 812 active torrents caused ZFS I/O saturation and system freezes:

| setting | value | reasoning |
|---------|-------|-----------|
| download queue | 10 | limits concurrent download I/O |
| seed queue | 50 | allows seeding ratio compliance without I/O storms |
| stalled minutes | 1 | quickly frees queue slots for stuck torrents |
| cache | 64 MB | batches small writes into larger ZFS transactions |
| peer limit global | 300 | reduces connection overhead |
| peer limit per torrent | 30 | prevents single-torrent I/O dominance |

### qBittorrent evaluation (v102–v103)

qBittorrent was tested in v102 but caused repeated system crashes. its aggressive hash-checking I/O pattern is incompatible with ZFS on the HP MicroServer Gen8's 4-disk array. reverted in v103.

---

## cloud TTS vs local TTS

### decision

use Microsoft Edge's free cloud-based neural TTS (via edge-tts) rather than local TTS engines like Piper or Coqui.

### benefits

- **no GPU required**: the HP MicroServer Gen8 has no usable GPU (iGPU disabled by HP BIOS)
- **superior quality**: Microsoft's neural voices are significantly better than CPU-only local alternatives
- **zero cost**: edge-tts uses the same free API as Microsoft Edge browser's read-aloud feature
- **no model storage**: no need to download and store multi-GB voice models
- **multiple languages**: Romanian and English voices available without separate model downloads

### tradeoffs

- **internet dependency**: TTS fails if internet is down (not a concern for a home lab with stable internet)
- **Microsoft dependency**: the free API could be discontinued or rate-limited
- **no offline capability**: cannot generate audiobooks during internet outages
- **privacy**: text content is sent to Microsoft's servers for synthesis

### alternatives evaluated

| engine | quality (CPU-only) | resource usage | offline | cost |
|--------|--------------------|---------------|---------|------|
| edge-tts | excellent | minimal (API calls) | no | free |
| Piper | good | moderate CPU | yes | free |
| Coqui | fair on CPU | high CPU, needs GPU for quality | yes | free |

---

## pre-baked Flood UI for transmission

### decision

build a custom transmission Docker image with Flood UI pre-installed, rather than using linuxserver's DOCKER_MODS mechanism.

### benefits

- **faster restarts**: Flood UI is already in the image, no download on every container start
- **reliability**: no dependency on external mod download during startup
- **reproducibility**: the exact UI version is baked into the image via Dockerfile

### tradeoffs

- **manual rebuilds**: updating the base transmission image or Flood UI requires `docker compose build --no-cache transmission`
- **excluded from auto-updates**: the secure-container-update pipeline cannot auto-update build-based containers
- **build context required**: the Dockerfile and supporting files must exist at `/mnt/BIG/filme/configs/transmission/`

### previous approach

before v108, transmission used `DOCKER_MODS=linuxserver/mods:transmission-floodui` which downloaded the Flood UI on every container restart. this added 30–60 seconds to every restart and occasionally failed due to network issues.

---

## cadvisor resource optimization

### decision

deploy cadvisor with aggressive resource-saving flags that disable unused metric categories.

### results (measured during v105 deployment)

| metric | before optimization | after optimization | reduction |
|--------|--------------------|--------------------|-----------|
| CPU usage | 9.90% | 0.32% | 97% |
| memory usage | 118 MiB | 18 MiB | 85% |

### flags used

- `--docker_only=true` — skips host-level cgroups, only monitors Docker containers
- `--housekeeping_interval=30s` — reduces internal polling (default 1s)
- `--disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl` — disables metrics not needed for container monitoring

the remaining metrics (CPU, memory, network) are sufficient for the grafana dashboards.

---

## pihole v6 TOML-based DNS

### decision

use pihole v6's `pihole.toml` hosts array for automatic DNS population rather than the traditional `custom.list` file or the API.

### benefits

- **automatic**: pihole-dns-update.sh scans container labels every 5 minutes
- **cross-host**: scans both bender (local) and amy (via SSH) containers
- **change detection**: only updates and restarts pihole when entries actually change (md5 hash comparison)
- **replication**: nebula-sync automatically copies the configuration to amy

### tradeoffs

- **pihole restart required**: every DNS change requires a pihole container restart (~2 seconds)
- **5-minute delay**: new containers won't have DNS for up to 5 minutes
- **SSH dependency**: amy entries require SSH access from bender to amy

### approaches that failed

| approach | why it failed |
|----------|---------------|
| custom.list | pihole v6 ignores custom.list — moved to TOML configuration |
| pihole API | pihole v6 local DNS API endpoints not available at the time of implementation |
| direct pihole.toml edit without state file | caused unnecessary restarts on every cron run |

---

## tailscale via tsdproxy

### decision

use tsdproxy to provide tailscale URLs for all services, rather than running tailscale directly or using a traditional reverse proxy.

### benefits

- **automatic HTTPS**: every service with `tsdproxy.enable: "true"` gets a `*.bunny-enigmatic.ts.net` URL with valid TLS
- **no port forwarding**: no ports exposed to the internet
- **zero configuration**: adding a new service only requires adding tsdproxy labels
- **dashboard**: tsdproxy provides a web UI listing all proxied services

### tradeoffs

- **tailscale dependency**: remote access requires tailscale to be running
- **LAN access separate**: local access uses `*.home.arpa` names (pihole DNS), not tailscale URLs
- **single compose project**: tsdproxy requires all services in the same docker compose project

---

## ZFS on HP MicroServer Gen8

### decision

use TrueNAS Scale with ZFS for all storage, despite the limited hardware.

### benefits

- **data integrity**: ZFS checksums detect and prevent silent data corruption
- **snapshots**: point-in-time recovery for media libraries
- **compression**: transparent compression saves disk space
- **ECC RAM**: the MicroServer's ECC DDR3 prevents memory-induced data corruption

### tradeoffs

- **I/O limitations**: the 4-disk array can be overwhelmed by aggressive random I/O
- **no GPU**: HP BIOS disables the Xeon's iGPU, preventing hardware transcoding
- **intel_iommu issues**: DMAR faults from HP iLO required setting intel_iommu=off (v107)
- **script execution restrictions**: TrueNAS prevents executing scripts from /mnt paths

### mitigations

- transmission queue limits and cache settings (v107)
- qBittorrent abandoned after testing (incompatible I/O pattern)
- scripts copied to /tmp before execution
- cadvisor resource limits to reduce monitoring overhead

---

*previous: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
*next: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
