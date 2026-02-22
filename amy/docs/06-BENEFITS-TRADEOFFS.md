# amy benefits and tradeoffs

## design decisions analysis

**document version:** 3.0
**infrastructure version:** 99
**last updated:** february 2026

---

## table of contents

1. [amy's role in the two-host architecture](#amys-role-in-the-two-host-architecture)
2. [debian vs TrueNAS](#debian-vs-truenas)
3. [shared postgresql](#shared-postgresql)
4. [keepalived BACKUP role](#keepalived-backup-role)
5. [local ntfy](#local-ntfy)
6. [telegraf for SNMP monitoring](#telegraf-for-snmp-monitoring)
7. [cadvisor resource optimization](#cadvisor-resource-optimization)
8. [legacy portainer paths](#legacy-portainer-paths)
9. [valkey instead of redis](#valkey-instead-of-redis)
10. [python-based limdius](#python-based-limdius)

---

## amy's role in the two-host architecture

### decision

amy handles lightweight utilities, monitoring, and notifications while bender handles media and downloads.

### benefits

- **failure isolation**: amy stays running when bender is down for TrueNAS upgrades or ZFS issues
- **DNS continuity**: pihole on amy takes over via keepalived when bender is unavailable
- **notification independence**: ntfy on amy can still receive notifications even if bender is completely down
- **monitoring continuity**: beszel hub on amy continues collecting metrics from amy itself during bender outages

### tradeoffs

- **limited hardware**: the i3-2310M is significantly less powerful than bender's Xeon E3-1265L V2
- **no ZFS**: single SSD with no data redundancy (mitigated by daily postgres backups)
- **cross-host dependencies**: homepage needs bender's dockerproxy, beszel-agent on bender needs amy's beszel hub

---

## debian vs TrueNAS

### decision

run amy on stock Debian 13 rather than TrueNAS Scale.

### benefits

- **direct script execution**: no TrueNAS `/mnt` execution restrictions — scripts run from their actual paths
- **simpler storage**: single SSD, no ZFS pool management overhead
- **standard package management**: `apt` for system updates, no TrueNAS middleware layer
- **lighter resource usage**: no ZFS ARC cache consuming RAM

### tradeoffs

- **no ZFS protection**: single SSD means no checksumming, no redundancy, no snapshots
- **manual Docker installation**: Docker isn't pre-installed like on TrueNAS Scale
- **no web UI for system management**: server management via SSH only (no TrueNAS dashboard)

---

## shared postgresql

### decision

one postgres:17-alpine instance shared by atuin, miniflux, spendspentspent, mealie, and stirling.

### benefits

- **RAM savings**: ~400 MB saved vs running 5 separate postgres instances
- **centralized backup**: postgres-backup backs up all 5 databases in one container
- **simplified management**: one database to monitor and upgrade
- **version consistency**: all apps use the same postgres 17 release

### tradeoffs

- **single point of failure**: if postgres crashes, 5 services go down simultaneously
- **upgrade risk**: postgres 17 → 18 upgrade affects all applications at once
- **mixed workloads**: atuin (append-heavy shell history) and mealie (recipe CRUD) have different I/O patterns

### mitigation

- postgres is classified as critical in the update system (4 critical services total on amy)
- pre-upgrade backups mandatory before any postgres update
- health checks verify all 5 databases are accessible after updates
- automatic rollback if any dependent service fails

---

## keepalived BACKUP role

### decision

amy runs keepalived as BACKUP (priority 100) while bender runs as MASTER (priority 200).

### benefits

- **automatic failover**: if bender's pihole fails, amy takes the VIP within ~5 seconds
- **automatic recovery**: when bender recovers, the VIP returns automatically (higher priority wins)
- **no manual intervention**: the entire failover/recovery cycle is automated

### tradeoffs

- **amy's pihole may have stale config**: nebula-sync runs hourly, so amy's pihole could be up to 1 hour behind bender's after a config change
- **different upstream DNS**: bender uses 1.1.1.1 + 8.8.8.8 while amy uses 9.9.9.9 + 1.1.1.1 — clients may see different DNS behavior during failover
- **keepalived image not pinned**: amy uses `osixia/keepalived:latest` while bender uses `:2.0.20` — a breaking update could affect amy's keepalived

### configuration differences from bender

| setting | bender | amy |
|---------|--------|-----|
| role | MASTER | BACKUP |
| interface | bond0 | enp4s0 |
| priority | 200 | 100 |
| image | osixia/keepalived:2.0.20 (pinned) | osixia/keepalived:latest |
| volume mount | single file (read-only) | directory mount |
| KEEPALIVED_INTERFACE env | set in compose | not set (uses config file) |
| --copy-service flag | yes | no |

---

## local ntfy

### decision

run ntfy on amy rather than using a cloud notification service.

### benefits

- **works without internet**: notifications still flow during internet outages (both hosts are on LAN)
- **no external dependency**: no reliance on pushover, discord, or other cloud services
- **privacy**: notification content stays on the local network
- **used by both hosts**: bender's diun and secure-container-update.sh send notifications to amy's ntfy

### tradeoffs

- **single point of failure**: if amy is down, both hosts lose notifications
- **no mobile push without tailscale**: ntfy mobile app needs tailscale or internet exposure to receive notifications remotely
- **LAN-only by default**: remote notification access requires tailscale URL (https://ntfy.bunny-enigmatic.ts.net)

---

## telegraf for SNMP monitoring

### decision

use telegraf on amy to monitor the Cisco 3750X switch and Brother printer via SNMP, rather than monitoring from Home Assistant directly.

### benefits

- **SNMP expertise**: telegraf's SNMP input plugin handles table walks, OID translation, and retry logic
- **custom processing**: starlark processor parses Brother's proprietary hex-encoded page counts and drum percentages
- **decoupled from HA**: if Home Assistant restarts, telegraf continues collecting data — no gaps in metrics
- **host networking**: telegraf runs with network_mode: host for reliable SNMP access

### tradeoffs

- **extra hop**: data flows telegraf → influxdb → grafana instead of directly into Home Assistant
- **influxdb dependency**: requires influxdb on the HA VM (192.168.21.220)
- **legacy config path**: telegraf config lives at `/portainer/telegraf/config/` (historical)

### consolidation history

telegraf was originally deployed as a standalone docker-compose at `/portainer/telegraf/docker-compose.yml`. in v98, it was consolidated into amy's main docker-compose.yaml to simplify management while keeping the config at its original path.

---

## cadvisor resource optimization

### decision

deploy cadvisor with aggressive resource-saving flags, matching bender's configuration.

### results (measured during v98 deployment)

| metric | before optimization | after optimization | reduction |
|--------|--------------------|--------------------|-----------|
| CPU usage | 9.90% | 0.32% | 97% |
| memory usage | 118 MiB | 18 MiB | 85% |

### flags used

- `--docker_only=true` — skips host-level metrics
- `--housekeeping_interval=30s` — reduces internal polling
- `--disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl`

particularly important on amy given the limited i3-2310M CPU — every percent of saved CPU matters.

---

## legacy portainer paths

### decision

keep postgresql data at `/portainer/postgresql/data/` and telegraf config at `/portainer/telegraf/config/` rather than migrating to `/docker/` paths.

### benefits

- **zero migration risk**: no chance of data loss from moving the database
- **no downtime**: migration would require stopping all dependent services
- **works correctly**: the path doesn't affect functionality

### tradeoffs

- **inconsistent naming**: most services use `/docker/<service>/` but postgres and telegraf use `/portainer/`
- **confusion potential**: new operators might look in `/docker/postgres/` and not find data
- **documentation overhead**: must document the legacy paths clearly

### when to migrate

migration would be justified if: the `/portainer/` partition runs out of space, or if a major postgres version upgrade already requires data recreation. until then, the current paths are correct and stable.

---

## valkey instead of redis

### decision

use valkey (redis-compatible fork) instead of redis for amy's key-value caching needs.

### benefits

- **open source**: valkey is a truly open-source redis fork (BSD license) after Redis Ltd changed redis's license
- **drop-in compatible**: all redis clients and commands work with valkey
- **active development**: maintained by the Linux Foundation with broad industry support

### tradeoffs

- **less battle-tested**: valkey is newer than redis, though based on the same codebase
- **currently unused**: no service on amy explicitly depends on valkey yet (it's available for future use)

note: bender uses redis:7-alpine for immich_redis because immich specifically requires redis. amy uses valkey because there's no specific redis requirement.

---

## python-based limdius

### decision

run limdius using a `python:3.11-slim` base image with runtime dependency installation via `pip install` in the command.

### benefits

- **simple deployment**: no custom Dockerfile needed — just mount the Python script and let the command install dependencies
- **easy updates**: modify `/docker/limdius/limdius.py` directly, restart the container

### tradeoffs

- **slow startup**: `pip install` runs on every container start (~15–30 seconds)
- **internet dependency at startup**: if pypi.org is unreachable, the container fails to start
- **no dependency pinning**: `pip install requests flask playwright` always gets latest versions

### potential improvement

if startup time becomes an issue, a custom Dockerfile with pre-installed dependencies (similar to bender's transmission build) would eliminate the pip install delay. currently not worth the maintenance overhead for a lightweight service.

---

*previous: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
*next: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
