# bender benefits and tradeoffs

## design decisions analysis

**document version:** 2.0
**infrastructure version:** 105
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [centralized VPN with gluetun](#centralized-vpn-with-gluetun)
3. [OpenVPN over WireGuard](#openvpn-over-wireguard)
4. [transmission pinning](#transmission-pinning)
5. [immich-specific postgresql](#immich-specific-postgresql)
6. [single docker-compose file](#single-docker-compose-file)
7. [ZFS as container storage](#zfs-as-container-storage)
8. [pihole as master DNS](#pihole-as-master-dns)
9. [nebula-sync for pihole replication](#nebula-sync-for-pihole-replication)
10. [automatic DNS population](#automatic-dns-population)
11. [vaultwarden on bender](#vaultwarden-on-bender)
12. [cadvisor with resource limits](#cadvisor-with-resource-limits)
13. [no GPU acceleration](#no-gpu-acceleration)
14. [remote ntfy dependency](#remote-ntfy-dependency)
15. [TrueNAS as host OS](#truenas-as-host-os)

---

## overview

bender's architecture is shaped by its role as the primary media and storage host, the constraints of the HP MicroServer Gen8 hardware, and the requirements of TrueNAS Scale. this document explains the reasoning behind each design decision, what alternatives were tested, and what tradeoffs were accepted.

---

## centralized VPN with gluetun

### decision

route all download clients and ARR stack services through a single gluetun VPN container using `network_mode: "service:gluetun"`, rather than individual VPN connections per service.

### benefits

- **single VPN connection**: one OpenVPN tunnel serves 9 services (transmission, prowlarr, sonarr, radarr, lidarr, readarr, bazarr, jdownloader, and their peer traffic)
- **centralized port management**: all VPN-routed ports are defined in gluetun's `ports:` section — one place to manage
- **consistent IP**: all services share the same public VPN IP address, simplifying tracker and indexer configurations
- **easy VPN provider switching**: changing providers or protocols only requires modifying gluetun's environment variables

### tradeoffs

- **single point of failure**: if gluetun goes down, all 8 VPN-routed services lose network access simultaneously
- **shared bandwidth**: all download traffic competes for the same VPN tunnel bandwidth
- **complex port mapping**: gluetun must expose ports for every service behind it — the ports section is large (9 port mappings)
- **DNS dependency**: gluetun handles DNS for all its child services (`DOT=off` for plain DNS after troubleshooting)

### alternatives considered

- **per-service VPN**: each download client gets its own VPN container — maximum isolation but 8x the resource usage and 8 VPN connections
- **host-level VPN**: VPN on the TrueNAS host itself — affects all traffic including management, risky for remote access
- **no VPN**: direct connections — not acceptable for torrent traffic privacy

---

## OpenVPN over WireGuard

### decision

use OpenVPN instead of WireGuard for the surfshark VPN connection in gluetun (v104).

### benefits

- **peer connections work**: OpenVPN allows outbound torrent peer connections to establish properly
- **proven compatibility**: OpenVPN has broader compatibility with surfshark's infrastructure
- **stable operation**: no dropped connections or blocked traffic patterns observed

### tradeoffs

- **lower performance**: OpenVPN is slower than WireGuard (higher CPU usage, higher latency)
- **higher resource usage**: OpenVPN uses more CPU for encryption/decryption than WireGuard
- **more complex protocol**: OpenVPN is harder to debug than WireGuard's simpler implementation

### history

| version | protocol | result |
|---------|----------|--------|
| v97 | OpenVPN | worked initially |
| v98 | WireGuard | better performance but blocked outbound peer connections on all surfshark servers |
| v104 | OpenVPN | restored — stable, peer connections work |

WireGuard was abandoned because it blocked outbound peer connections, making transmission unable to seed or connect to peers. this appeared to be a surfshark-side issue with WireGuard NAT traversal.

---

## transmission pinning

### decision

pin transmission to version 4.0.5 (`lscr.io/linuxserver/transmission:4.0.5`) and never upgrade to 4.0.6+.

### benefits

- **FileList compatibility**: version 4.0.5 is on the FileList client whitelist — newer versions are not
- **proven stability**: 4.0.5 runs reliably on the HP MicroServer Gen8 with ZFS
- **flood UI mod**: the linuxserver transmission image supports the flood UI mod for a better web interface

### tradeoffs

- **no security updates**: pinned version will not receive security patches from upstream
- **no new features**: any improvements in 4.0.6+ are unavailable
- **manual monitoring required**: must watch for critical vulnerabilities in 4.0.5 that might require manual intervention

### alternatives tested

| client | version | result |
|--------|---------|--------|
| transmission | 4.0.5 | ✅ stable, FileList whitelisted |
| transmission | latest (4.0.6+) | ❌ not on FileList whitelist |
| qBittorrent | latest | ❌ caused repeated system crashes — aggressive I/O during hash checking overwhelmed ZFS on HP MicroServer Gen8 (v102→v103 revert) |

qBittorrent is preserved as a commented service in the compose file with a warning about the I/O issue.

---

## immich-specific postgresql

### decision

use the immich-provided postgresql image (`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`) with vector extensions, rather than standard postgresql.

### benefits

- **immich compatibility**: immich requires vectorchord and pgvectors extensions for ML-based smart search, face recognition, and CLIP embeddings
- **tested combination**: the immich team tests this specific image version with each immich release
- **shared instance**: hedgedoc also uses this postgres instance — it doesn't need the vector extensions but works fine with them present
- **tuned settings**: custom `shared_preload_libraries`, `max_wal_size=2GB`, `shared_buffers=512MB`, `wal_compression=on`

### tradeoffs

- **locked to postgresql 14**: the immich image is based on PostgreSQL 14 — cannot upgrade to 15 or 16 without immich's blessing
- **specialized image**: harder to find documentation compared to the official postgres images
- **extension dependencies**: if vectorchord or pgvectors have issues, debugging requires understanding the immich ecosystem
- **different from amy**: amy uses `postgres:17-alpine` — the two hosts are not interchangeable for database purposes

### alternatives considered

- **standard postgres + manual extensions**: install vectorchord/pgvectors manually — fragile and breaks on postgres upgrades
- **separate postgres per application**: one for immich, one for hedgedoc — wastes RAM on a 16GB system

---

## single docker-compose file

### decision

consolidate all 33 bender services into one `docker-compose.yaml` (v105).

### benefits

- **atomic operations**: `docker compose up -d` handles all services with correct ordering
- **shared networking**: all bridge services on `media-network` communicate by container name
- **single version history**: one changelog tracking all changes from v90.8 through v105
- **dependency management**: `depends_on` ensures postgres and gluetun start before their dependent services

### tradeoffs

- **large file**: v105 is ~700 lines with extensive comments and changelog
- **all-or-nothing risk**: a YAML syntax error in one service prevents all services from starting
- **TrueNAS update risk**: TrueNAS upgrades can potentially reset docker configuration — the compose file on ZFS is safe, but docker state may need rebuilding

### alternatives considered

- **portainer stacks**: the original approach — abandoned due to difficulty managing cross-service dependencies and networking
- **multiple compose files**: splitting into media.yaml, downloads.yaml, infrastructure.yaml — adds networking complexity with no clear benefit at this scale

---

## ZFS as container storage

### decision

run all container data on ZFS (pool `BIG`, dataset `filme`) rather than a separate ext4/btrfs partition.

### benefits

- **data integrity**: ZFS checksumming protects against bit rot on media files and database data
- **snapshots**: point-in-time recovery for the entire dataset without stopping services
- **compression**: transparent compression reduces disk usage for compressible data (configs, logs, databases)
- **unified management**: one storage pool for media, configs, databases, and downloads

### tradeoffs

- **I/O sensitivity**: ZFS can be overwhelmed by aggressive random I/O patterns (qBittorrent crash issue in v102-v103)
- **RAM usage**: ZFS ARC cache benefits from abundant RAM — 16GB is adequate but not generous for both ZFS and 33 containers
- **TrueNAS coupling**: ZFS pool management is handled by TrueNAS — manual ZFS commands may conflict with TrueNAS's expectations
- **script execution restriction**: TrueNAS prevents executing scripts from ZFS-mounted paths, requiring the `/tmp` copy workaround

---

## pihole as master DNS

### decision

run bender as the pihole MASTER (keepalived priority 150) with amy as BACKUP (priority 100).

### benefits

- **primary availability**: bender is the more stable host (TrueNAS with ECC RAM, UPS-protected)
- **local resolution**: bender's pihole handles DNS for most network clients by default
- **automatic failover**: if bender goes down, amy takes over the VIP within seconds

### tradeoffs

- **bender dependency**: under normal operation, all DNS queries go through bender — a bender network issue affects the entire home network
- **update window**: during bender's saturday update, DNS briefly shifts to amy (if keepalived detects the interruption)

### alternatives considered

- **amy as master**: possible but amy hardware is older (Intel i3 vs Xeon) and doesn't have ECC RAM
- **equal priority**: both at priority 100 — would cause unpredictable VIP assignment

---

## nebula-sync for pihole replication

### decision

use nebula-sync to replicate pihole configuration from bender (primary) to amy (replica) hourly.

### benefits

- **automatic**: no manual configuration needed when adding blocklists or changing settings on bender
- **full sync**: replicates blocklists, local DNS records, settings, and triggers gravity rebuild on amy
- **lightweight**: minimal container with no runtime dependencies

### tradeoffs

- **one-hour lag**: changes on bender take up to 60 minutes to propagate to amy
- **one-directional**: changes made directly on amy's pihole are overwritten on the next sync
- **healthcheck limitation**: nebula-sync's container is minimal — no binaries for healthchecks (healthcheck disabled in v104)

---

## automatic DNS population

### decision

run a cron script (`/root/pihole-dns-update.sh`) every 5 minutes to scan docker containers on both hosts and automatically create `.home.arpa` DNS entries in pihole.

### benefits

- **zero manual DNS management**: new services with `tsdproxy.enable: "true"` labels automatically get DNS entries
- **cross-host scanning**: the script SSHes to amy to scan its containers as well
- **change detection**: uses md5 hashing to only update pihole when entries actually change
- **pihole v6 compatible**: uses the `pihole.toml` `hosts = []` array (custom.list approach failed in pihole v6)

### tradeoffs

- **SSH dependency**: requires passwordless SSH from bender to amy (via `kube@192.168.21.130`)
- **5-minute delay**: new services take up to 5 minutes to get DNS entries
- **pihole restart**: updating DNS entries requires a pihole restart (brief DNS interruption)
- **not visible in UI**: entries in `pihole.toml` hosts array do not appear in pihole's web interface under "Local DNS"

### alternatives tested

| approach | result |
|----------|--------|
| `custom.list` file | ❌ pihole v6 does not read from custom.list for local DNS |
| pihole API (`/api/dns/local`) | ❌ endpoint returns 404 in pihole v6 |
| `pihole.toml` hosts array | ✅ works — entries loaded after pihole restart |

see [docs/PIHOLE-DNS-AUTO-POPULATION.md](../../docs/PIHOLE-DNS-AUTO-POPULATION.md) for full implementation details.

---

## vaultwarden on bender

### decision

migrate vaultwarden from amy to bender in v92.

### benefits

- **storage proximity**: vaultwarden data lives on ZFS with checksumming and snapshot capability
- **reduces amy load**: one fewer service on amy's more modest hardware
- **backup coverage**: bender's ZFS snapshots provide additional recovery options beyond vaultwarden's own backup mechanisms

### tradeoffs

- **bender dependency**: if bender is down, the password manager is unavailable (though browser extensions cache credentials locally)
- **shared failure domain**: vaultwarden now shares bender with all media services — a bender outage affects more services

### why it was moved

the migration was user-requested in conversation #39 (v92). no technical reason prevented it from staying on amy — the decision was based on preference for centralizing important data on the ZFS-backed host.

---

## cadvisor with resource limits

### decision

run cadvisor with resource-saving flags to minimize overhead on the HP MicroServer Gen8.

### benefits

- **97% CPU reduction**: from 9.90% to 0.32%
- **85% memory reduction**: from 118 MiB to 18 MiB
- **still provides needed metrics**: container CPU, memory, and network metrics for grafana dashboards

### tradeoffs

- **reduced granularity**: per-CPU, TCP/UDP, disk I/O, and other detailed metrics are disabled
- **30-second update interval**: slightly less responsive than default

### flags applied

```yaml
command:
  - --housekeeping_interval=30s
  - --docker_only=true
  - --disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl
```

---

## no GPU acceleration

### decision

accept CPU-only transcoding in jellyfin due to HP BIOS limitations.

### the constraint

the HP MicroServer Gen8's Intel Xeon E3-1265L V2 has an Intel HD Graphics P4000 iGPU, but HP's BIOS disables it with no modded BIOS available. the GPU device entries are commented out in the jellyfin service definition for future use.

### impact

- **software transcoding only**: jellyfin uses libx264 for transcoding, which is CPU-intensive
- **limited concurrent streams**: the Xeon E3-1265L V2 can handle 1-2 simultaneous transcodes at 1080p
- **direct play recommended**: clients that support direct play avoid transcoding entirely

### future option

if a modded BIOS becomes available or the server is replaced, GPU acceleration can be re-enabled by uncommenting the `devices` and `group_add` sections in the jellyfin service.

---

## remote ntfy dependency

### decision

send all notifications from bender to amy's ntfy instance (`${NTFY_ADDRESS}`) rather than running a local ntfy on bender.

### benefits

- **single notification hub**: all notifications from both hosts arrive at one place
- **no duplicate infrastructure**: one ntfy instance to maintain, not two
- **resource savings**: one fewer container on bender

### tradeoffs

- **amy dependency**: if amy is down, bender's notifications fail silently — update failures, vulnerability blocks, and rollbacks go unreported
- **network dependency**: requires network connectivity between bender and amy for notifications

### mitigations

- update logs are always written to `/mnt/BIG/filme/docker-compose/configs/secure-update/logs/` regardless of ntfy availability
- the retry queue persists failed updates independently of notification delivery

---

## TrueNAS as host OS

### decision

run bender on TrueNAS Scale rather than a standard linux distribution.

### benefits

- **ZFS management**: TrueNAS provides a web UI for ZFS pool management, snapshots, and scrubbing
- **NFS server**: built-in NFS export configuration for sharing media to amy
- **enterprise features**: ECC RAM support, SMART monitoring, alerting
- **docker support**: TrueNAS Scale is debian-based and supports docker natively

### tradeoffs

- **script execution restriction**: cannot execute scripts from `/mnt/` paths — requires `/tmp` copy workaround
- **upgrade risk**: TrueNAS major upgrades can reset container configurations or docker state
- **limited customization**: some linux-level changes may be overwritten by TrueNAS updates
- **docker compose version**: TrueNAS may ship an older docker compose version than desired
- **no systemd timers**: cron must be used instead of systemd timers for scheduling

### alternatives considered

- **debian/ubuntu server**: more control, standard docker experience, but loses TrueNAS's ZFS management UI and NFS ease
- **proxmox + VM**: could run TrueNAS in a VM for storage and a separate VM for docker — adds complexity and overhead on modest hardware
- **unraid**: alternative NAS OS with docker support — less mature ZFS support than TrueNAS

---

*previous: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
*next: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
