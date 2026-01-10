# bender infrastructure architecture documentation

## media & downloads server (TrueNAS Scale)

**document version:** 1.0  
**infrastructure version:** 86  
**last updated:** january 10, 2026  
**host:** TrueNAS Scale  
**ip address:** 192.168.21.121

---

## table of contents

1. [executive summary](#executive-summary)
2. [role in infrastructure](#role-in-infrastructure)
3. [hardware specifications](#hardware-specifications)
4. [network configuration](#network-configuration)
5. [design philosophy](#design-philosophy)
6. [technology stack](#technology-stack)
7. [integration with amy](#integration-with-amy)

---

## executive summary

bender serves as the **primary storage and media services host** in the two-host infrastructure. running on TrueNAS Scale, it provides:

- **media management** (immich, jellyfin, metube)
- **download automation** (transmission, sonarr, radarr, prowlarr, bazarr)
- **primary storage** (ZFS pool at /mnt/BIG/)
- **DNS services** (primary pihole with keepalived failover)
- **shared database** (postgresql for immich, hedgedoc)

### key characteristics

| characteristic | implementation |
|----------------|----------------|
| **role** | primary storage & media services |
| **orchestration** | docker compose (single file) |
| **remote access** | tailscale mesh vpn with tsdproxy |
| **update strategy** | security-first with trivy scanning |
| **high availability** | keepalived vrrp for dns failover (master) |
| **notifications** | ntfy (via amy) for alerts |
| **monitoring** | beszel-agent reporting to amy |

---

## role in infrastructure

### two-host architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              bender (TrueNAS Scale)                         │
│                              192.168.21.121                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  role: primary storage and media services host                              │
│  hardware: TrueNAS Scale appliance                                          │
│  storage: /mnt/BIG/ (ZFS pool - primary data storage)                       │
│  docker path: /mnt/BIG/filme/docker-compose/                                │
│                                                                             │
│  services:                                                                  │
│  ├── media: immich, jellyfin, metube                                        │
│  ├── downloads: transmission, sonarr, radarr, prowlarr, bazarr              │
│  ├── sync: syncthing, nebula-sync                                           │
│  ├── productivity: hedgedoc                                                 │
│  ├── infrastructure: tsdproxy, pihole, keepalived, postgresql               │
│  └── updates: diun, trivy                                                   │
└─────────────────────────────────────────────────────────────────────────────┘
                             │
                             │ nfs export + tailscale
                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              amy (intel i3-2310m)                           │
│                              192.168.21.130                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  role: utilities and monitoring host                                        │
│  services: ntfy, beszel, homepage, vaultwarden, miniflux, mealie            │
└─────────────────────────────────────────────────────────────────────────────┘
```

### service distribution rationale

| category | bender (this host) | amy |
|----------|--------------------|-----|
| **storage-intensive** | ✅ immich, jellyfin | ❌ |
| **download services** | ✅ transmission, arr stack | ❌ |
| **cpu-intensive** | ✅ immich ml, transcoding | ❌ |
| **notifications** | ❌ | ✅ ntfy |
| **monitoring hub** | ❌ | ✅ beszel |
| **password management** | ❌ | ✅ vaultwarden |
| **dns (ha)** | ✅ primary pihole | ✅ backup pihole |

---

## hardware specifications

### TrueNAS Scale system

| component | specification |
|-----------|---------------|
| **os** | TrueNAS Scale 25.10.x |
| **storage** | ZFS pool "BIG" |
| **docker path** | /mnt/BIG/filme/docker-compose/ |
| **data path** | /mnt/BIG/filme/ |
| **config path** | /mnt/BIG/filme/configs/ |

### storage layout

```
/mnt/BIG/                           # ZFS pool root
└── filme/                          # main data directory
    ├── docker-compose/             # compose files & scripts
    │   ├── docker-compose.yaml     # main compose file (v86)
    │   ├── .env                    # environment variables
    │   ├── scripts/                # operational scripts
    │   └── configs/                # service configs
    ├── configs/                    # container config volumes
    │   ├── postgresql/
    │   ├── tsdproxy/
    │   ├── pihole/
    │   └── [service]/
    ├── filme/                      # movies
    ├── seriale/                    # tv shows
    ├── music/                      # music library
    ├── books/                      # ebooks & audiobooks
    ├── immich/                     # photo library
    │   └── postgresql/             # immich database
    ├── transmission/               # downloads
    └── syncthing/                  # sync data
```

---

## network configuration

### ip addressing

| interface | ip address | purpose |
|-----------|------------|---------|
| **lan** | 192.168.21.121 | primary interface |
| **vip** | 192.168.21.100 | pihole ha (shared with amy) |
| **docker network** | 172.21.0.0/24 | container network |

### port assignments

| port range | purpose |
|------------|---------|
| 8085 | tsdproxy web ui |
| 9091 | transmission |
| 8080 | jellyfin |
| 2283 | immich |
| 8053 | pihole dns |
| 8054 | pihole web ui |
| 8000 | hedgedoc |
| 8384 | syncthing |
| 8989 | sonarr |
| 7878 | radarr |
| 9696 | prowlarr |
| 6767 | bazarr |
| 8082 | trivy server |

### firewall considerations

bender operates on a trusted lan segment. all external access is through tailscale mesh vpn via tsdproxy.

---

## design philosophy

### why TrueNAS Scale for media services

| reason | benefit |
|--------|---------|
| **ZFS storage** | data integrity, snapshots, compression |
| **native docker** | survives TrueNAS upgrades |
| **enterprise hardware** | reliability for 24/7 operation |
| **nfs exports** | easy data sharing with amy |

### why single compose file

| reason | benefit |
|--------|---------|
| **tsdproxy compatibility** | single network for service discovery |
| **simplified management** | one `docker compose up -d` command |
| **atomic updates** | entire stack managed together |
| **shared networks** | inter-container communication |

### why postgresql on bender

| reason | benefit |
|--------|---------|
| **data locality** | database near storage-heavy services |
| **backup integration** | database alongside media backups |
| **performance** | no network latency for immich queries |

---

## technology stack

### container runtime

| component | version/image |
|-----------|---------------|
| **docker** | TrueNAS native |
| **compose** | v2.x (compose plugin) |

### key services

| service | image | purpose |
|---------|-------|---------|
| **postgresql** | ghcr.io/immich-app/postgres:14-vectorchord0.4.3 | shared database |
| **immich** | ghcr.io/immich-app/immich-server:latest | photo management |
| **jellyfin** | jellyfin/jellyfin:latest | media streaming |
| **transmission** | haugene/transmission-openvpn:latest | vpn-protected downloads |
| **tsdproxy** | almeidapaulopt/tsdproxy:latest | tailscale integration |
| **pihole** | pihole/pihole:latest | dns server |
| **keepalived** | osixia/keepalived:latest | vrrp failover |

### update system

| component | purpose |
|-----------|---------|
| **diun** | image update detection |
| **trivy** | vulnerability scanning |
| **secure-container-update.sh** | orchestrated updates |

---

## integration with amy

### services that connect to amy

| bender service | connects to | purpose |
|----------------|-------------|---------|
| **diun** | ntfy (amy) | send update notifications |
| **all services** | pihole vip | dns resolution |
| **secure-container-update.sh** | ntfy (amy) | update notifications |

### services that connect from amy

| amy service | connects to | purpose |
|-------------|-------------|---------|
| **homepage** | dockerproxy (bender:2375) | monitor bender containers |
| **beszel** | beszel-agent (bender) | system metrics |
| **nebula-sync** | pihole (bender) | config synchronization |

### shared configuration

both hosts use synchronized configurations for:

- **pihole blocklists**: synced via nebula-sync (bender → amy)
- **keepalived vip**: coordinated vrrp with health checks
- **tsdproxy**: same tailscale tailnet for service access
- **timezone**: America/Toronto on both hosts

---

## directory structure overview

```
/mnt/BIG/filme/docker-compose/      # docker compose configuration
├── docker-compose.yaml             # main compose file (v86)
├── .env                            # environment variables
├── scripts/                        # operational scripts
│   ├── secure-container-update.sh  # update orchestration
│   ├── health-checks.sh            # health verification
│   └── rollback.sh                 # rollback helper
├── configs/                        # service configurations
│   └── secure-update/              # update system state
│       ├── critical-containers.json
│       ├── retry-queue.json
│       ├── logs/
│       └── scan-reports/
└── backups/                        # backup storage
    └── postgres/                   # database backups

/mnt/BIG/filme/configs/             # container config volumes
├── postgresql/                     # database data
├── tsdproxy/                       # tailscale proxy
├── pihole/                         # dns server
├── immich/                         # photo management
├── jellyfin/                       # media server
├── transmission/                   # download client
├── sonarr/                         # tv automation
├── radarr/                         # movie automation
├── prowlarr/                       # indexer manager
├── bazarr/                         # subtitle manager
├── hedgedoc/                       # collaborative notes
└── keepalived/                     # ha configuration
```

---

*next: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
