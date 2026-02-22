# amy architecture

## infrastructure design and system overview

**document version:** 3.0
**infrastructure version:** 99
**last updated:** february 2026

---

## table of contents

1. [executive summary](#executive-summary)
2. [hardware specifications](#hardware-specifications)
3. [network configuration](#network-configuration)
4. [service architecture](#service-architecture)
5. [storage architecture](#storage-architecture)
6. [monitoring pipeline](#monitoring-pipeline)
7. [high availability](#high-availability)
8. [integration with bender](#integration-with-bender)
9. [technology stack](#technology-stack)

---

## executive summary

amy is the secondary host in a two-host home lab infrastructure. it runs on a repurposed Intel i3-2310M laptop with 16 GB RAM and provides utilities, monitoring, notifications, and DNS backup. amy complements bender (the primary host on TrueNAS Scale) by handling lightweight services that don't require ZFS storage.

as of v99, amy runs 29 active containers organized into infrastructure, DNS/HA, databases, notifications, productivity, finance, automation, monitoring, and update categories.

---

## hardware specifications

| component | specification |
|-----------|--------------|
| **CPU** | Intel Core i3-2310M (2 cores, 4 threads, 2.1 GHz) |
| **RAM** | 16 GB DDR3 |
| **storage** | single SSD |
| **network** | enp4s0 (ethernet) |
| **OS** | Debian 13 |
| **IP** | 192.168.21.130 |

### advantages over bender

- **no ZFS overhead**: simple filesystem means no I/O saturation risk
- **direct script execution**: no TrueNAS restrictions — scripts run directly from their paths
- **independent updates**: amy's debian can be upgraded without affecting bender's TrueNAS

---

## network configuration

### interfaces

| interface | type | ip address | purpose |
|-----------|------|------------|---------|
| enp4s0 | ethernet | 192.168.21.130 | primary network (all services) |
| tailscale | overlay | dynamic | remote access via tsdproxy |

### DNS

| setting | value |
|---------|-------|
| pihole VIP | 192.168.21.100 (keepalived VRRP) |
| upstream DNS | 9.9.9.9, 1.1.1.1 |
| DNSSEC | enabled |
| reverse DNS | enabled (192.168.21.0/24 → 192.168.21.1) |

all services on the `utility-network` bridge use the DNS anchor `192.168.21.100` (pihole VIP) via the `x-dns` YAML anchor. exceptions are pihole (it IS the DNS server), keepalived, beszel-agent, netalertx, and telegraf (all use host networking).

### docker networks

| network | driver | purpose |
|---------|--------|---------|
| utility-network | bridge | all bridge-mode services (with DNS anchor) |
| host | host | keepalived, beszel-agent, netalertx, telegraf |

### port allocation summary

| range | services |
|-------|----------|
| 53 | pihole DNS |
| 3003 | homepage |
| 3100 | playwright-chrome |
| 5050 | limdius |
| 5432 | postgresql |
| 6379 | valkey |
| 8053 | pihole web |
| 8080 | stirling |
| 8082 | filebrowser |
| 8083 | trivy |
| 8085 | tsdproxy |
| 8090 | beszel |
| 8181 | it-tools |
| 8182 | dozzle |
| 8283 | wallos |
| 8282 | argus |
| 8385 | miniflux |
| 8456 | mealie |
| 8777 | atuin |
| 8888 | ntfy |
| 8989 | lubelogger |
| 9021 | spendspentspent |
| 9099 | cadvisor |
| 9999 | dockwatch |
| 20211 | netalertx |

---

## service architecture

### service categories (29 active containers)

| category | count | services |
|----------|-------|----------|
| **infrastructure** | 3 | tsdproxy, dockwatch, dozzle |
| **DNS & HA** | 2 | pihole, keepalived |
| **databases** | 3 | postgres, postgres-backup, valkey |
| **notifications** | 1 | ntfy |
| **productivity** | 10 | stirling, homepage, atuin, miniflux, it-tools, filebrowser, wallos, mealie, argus, lubelogger |
| **finance & automation** | 3 | spendspentspent, limdius, playwright-chrome |
| **monitoring** | 5 | beszel, beszel-agent, cadvisor, netalertx, telegraf |
| **updates** | 2 | diun, trivy |
| **total** | **29** | |

### network modes

| mode | count | services |
|------|-------|----------|
| bridge (utility-network) | 25 | most services |
| host | 4 | keepalived, beszel-agent, netalertx, telegraf |

---

## storage architecture

amy uses two storage paths — `/docker/` for most container data and `/portainer/` for legacy paths from the original portainer deployment:

| path | purpose |
|------|---------|
| `/docker-compose/` | compose file, .env, scripts, configs |
| `/docker/` | per-service container data |
| `/portainer/postgresql/data/` | postgresql data (legacy path) |
| `/portainer/telegraf/config/` | telegraf configuration (legacy path) |

### critical data paths

| path | criticality | backup method |
|------|-------------|---------------|
| `/portainer/postgresql/data/` | **CRITICAL** — all app databases | postgres-backup (daily) |
| `/docker/beszel/data/` | **HIGH** — monitoring history | manual |
| `/docker/ntfy/` | **MEDIUM** — notification cache | manual |

---

## monitoring pipeline

amy runs three monitoring systems:

### cadvisor → prometheus → grafana

```
amy cadvisor (:9099)
   |
   v
prometheus (:9090, HA VM 192.168.21.220)
   |
   v
grafana (HA add-on, "amy docker" dashboard)
```

the grafana dashboard uses `instance` variable set to Constant type with value `192.168.21.130:9099`.

cadvisor runs with resource-saving flags (97% CPU reduction, 85% memory reduction):

- `--docker_only=true`
- `--housekeeping_interval=30s`
- `--disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl`

### telegraf → influxdb → grafana

```
telegraf (host network, SNMP polling)
   |
   +-- cisco 3750X switch (192.168.21.5:161, community "futurama")
   +-- brother MFC-L3710CW printer (192.168.21.10:161, community "public")
   |
   v
influxdb (:8086, HA VM 192.168.21.220, database "homeassistant")
   |
   v
grafana (HA add-on, switch + printer dashboards)
```

telegraf uses a starlark processor to parse Brother's proprietary hex-encoded page counts (brInfoCounter) and drum percentages (brInfoMaintenance) from SNMP OIDs.

### beszel

beszel hub runs on amy and collects system metrics from beszel-agents on both amy and bender. provides CPU, memory, disk, and network monitoring with a web UI at port 8090.

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

keepalived uses unicast mode with explicit peer addresses (192.168.21.121 ↔ 192.168.21.130). when bender's pihole health check fails 3 consecutive times, the VIP migrates to amy within ~5 seconds. when bender recovers, the VIP returns automatically due to its higher priority (200 vs 100).

nebula-sync on bender replicates pihole configuration to amy hourly with `FULL_SYNC=true` and `RUN_GRAVITY=true`.

note: amy's keepalived uses `osixia/keepalived:latest` (not pinned), while bender uses `osixia/keepalived:2.0.20` (pinned). the keepalived config file is mounted from `/docker/keepalived/` as a directory (not a single file like bender's read-only mount).

---

## integration with bender

### amy → bender dependencies

| amy service | depends on (bender) | purpose |
|------------|---------------------|---------|
| homepage | dockerproxy on bender (:2375) | container status widget |
| pihole | nebula-sync on bender | receives replicated DNS config |

### bender → amy dependencies

| bender service | depends on (amy) | purpose |
|---------------|------------------|---------|
| diun | ntfy | update notifications |
| secure-container-update.sh | ntfy | update/rollback notifications |
| nebula-sync | pihole on amy | DNS replication target |
| beszel-agent | beszel hub on amy | system metrics collection |
| pihole-dns-update.sh | docker API on amy (via SSH) | scan amy containers for DNS labels |

### SSH access

bender connects to amy via SSH as user `kube` (docker group member) for the pihole-dns-update.sh script. this uses an ed25519 key without passphrase for automated access.

---

## technology stack

| layer | technology |
|-------|------------|
| **host OS** | Debian 13 |
| **container runtime** | Docker + Docker Compose |
| **storage** | SSD (single disk) |
| **networking** | bridge, host |
| **DNS** | pihole v6 (DNSSEC enabled) |
| **HA** | keepalived (VRRP unicast, BACKUP role) |
| **remote access** | Tailscale via tsdproxy |
| **monitoring** | cadvisor → prometheus → grafana, telegraf → influxdb → grafana, beszel |
| **updates** | diun (notifications) + trivy (scanning) + custom script |
| **notifications** | ntfy (local) |
| **backup** | postgres-backup-local (daily) |

---

*next: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
