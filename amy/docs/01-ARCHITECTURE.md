# amy infrastructure architecture documentation

## utilities & monitoring server

**document version:** 2.0  
**infrastructure version:** 98  
**last updated:** february 8, 2026  
**host:** intel core i3-2310m, 16gb ram  
**ip address:** 192.168.21.130

---

## table of contents

1. [executive summary](#executive-summary)
2. [role in infrastructure](#role-in-infrastructure)
3. [hardware specifications](#hardware-specifications)
4. [network configuration](#network-configuration)
5. [design philosophy](#design-philosophy)
6. [technology stack](#technology-stack)
7. [integration with bender](#integration-with-bender)

---

## executive summary

amy serves as the **utilities and monitoring host** in the two-host infrastructure. while bender handles media services and primary storage, amy provides:

- **notification services** (ntfy) for the entire infrastructure
- **monitoring and observability** (beszel, cadvisor, netalertx, telegraf)
- **DNS high availability** (secondary pihole with keepalived)
- **productivity tools** (mealie, lubelogger, stirling-pdf, etc.)
- **databases** (postgresql for atuin, miniflux, spendspentspent, mealie, stirling)

### key characteristics

| characteristic | implementation |
|----------------|----------------|
| **role** | utilities, monitoring, notifications |
| **hardware** | intel i3-2310m, 16gb ram |
| **storage** | local ssd + nfs from bender |
| **docker path** | `/docker-compose/` |
| **data path** | `/docker/` |
| **update schedule** | wednesday 04:30 |
| **compose version** | v98 |
| **container count** | 29 |
| **critical services** | 7 (postgres, ntfy, beszel, pihole, keepalived, spendspentspent, diun) |

---

## role in infrastructure

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              infrastructure overview                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────┐              ┌─────────────────────────┐       │
│  │   bender (TrueNAS)      │              │      amy (intel i3)     │       │
│  │   192.168.21.121        │              │      192.168.21.130     │       │
│  │   ─────────────────     │              │      ─────────────────  │       │
│  │   • media services      │              │      • notifications    │       │
│  │   • downloads (arr)     │◄────────────►│      • monitoring       │       │
│  │   • photo management    │     nfs      │      • DNS backup       │       │
│  │   • primary storage     │              │      • productivity     │       │
│  │   • DNS primary         │              │      • finance tracking  │       │
│  │   • vaultwarden         │              │      • SNMP monitoring   │       │
│  └─────────────────────────┘              └─────────────────────────┘       │
│              │                                        │                     │
│              └────────────────┬───────────────────────┘                     │
│                               │                                             │
│                        ┌──────▼───────┐                                     │
│                        │   VIP DNS    │                                     │
│                        │192.168.21.100│                                     │
│                        └──────────────┘                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### why amy exists

1. **failure isolation**: if bender goes down for maintenance, critical services (DNS, notifications, monitoring) continue on amy

2. **external monitoring**: amy can monitor bender's health from outside — if bender's monitoring fails, amy can still alert

3. **resource optimization**: lightweight services don't need TrueNAS's resources; they run fine on older hardware

4. **TrueNAS upgrade safety**: services on amy are unaffected by TrueNAS upgrades

### critical services on amy

amy hosts 7 critical services that receive special handling during updates:

| service | why critical |
|---------|--------------|
| **postgres** | database for 5 applications (atuin, miniflux, sss, mealie, stirling) |
| **ntfy** | notification hub for entire infrastructure |
| **beszel** | monitoring hub — if down, no visibility |
| **pihole** | DNS — network-wide impact if fails |
| **keepalived** | DNS failover — HA depends on it |
| **spendspentspent** | financial data — data integrity critical |
| **diun** | update notifications — security visibility |

---

## hardware specifications

### current hardware

| component | specification |
|-----------|---------------|
| **cpu** | intel core i3-2310m (2 cores, 4 threads, 2.1ghz) |
| **ram** | 16gb ddr3 |
| **storage** | 256gb ssd (system + docker) |
| **network** | 1gbe |
| **os** | debian |

### resource allocation

| resource | allocated | typical usage |
|----------|-----------|---------------|
| **cpu** | 4 threads | 10-30% average |
| **ram** | 16gb | 8-12gb used |
| **disk** | 256gb | ~50gb used |
| **network** | 1gbps | minimal |

### limitations

- **no gpu**: ml workloads run on bender
- **older cpu**: not suitable for heavy transcoding
- **single disk**: no raid redundancy (backups critical)

---

## network configuration

### ip addressing

| interface | ip address | purpose |
|-----------|------------|---------|
| **lan** | 192.168.21.130 | primary lan |
| **vip** | 192.168.21.100 | shared DNS (keepalived) |
| **tailscale** | 100.x.x.x | remote access |

### DNS configuration

amy runs as DNS backup:
- **primary**: bender (192.168.21.121)
- **backup**: amy (192.168.21.130)
- **vip**: 192.168.21.100 (clients point here)

all services on utility-network use `dns: 192.168.21.100` (keepalived VIP) for local DNS resolution.

### port mappings (key services)

| service | port | protocol |
|---------|------|----------|
| pihole DNS | 53 | tcp/udp |
| pihole web | 8053 | http |
| ntfy | 8888 | http |
| postgresql | 5432 | tcp |
| beszel | 8090 | http |
| cadvisor | 9099 | http |
| trivy | 8083 | http |
| stirling-pdf | 8080 | http |
| miniflux | 8385 | http |
| mealie | 8456 | http |
| homepage | 3003 | http |

---

## design philosophy

### guiding principles

1. **stability over features**: amy prioritizes uptime over latest versions
2. **resource efficiency**: maximize utility from limited hardware
3. **failure isolation**: amy's failure shouldn't affect bender and vice versa
4. **security first**: scan before deploy, no blind updates

### service placement criteria

services are placed on amy if they:
- are lightweight (low cpu/ram requirements)
- benefit from separation from media services
- provide infrastructure-wide functionality
- need to survive bender maintenance

### what doesn't belong on amy

- media transcoding (cpu-intensive)
- large file storage (limited disk)
- ml/ai workloads (no gpu, weak cpu)
- high-bandwidth services (1gbe limit)

---

## technology stack

### container runtime

| component | version | notes |
|-----------|---------|-------|
| **docker** | latest | native docker on debian |
| **docker compose** | v5.x | single compose file |
| **network driver** | bridge | utility-network |

### key technologies

| technology | purpose | why chosen |
|------------|---------|------------|
| **postgresql 17** | database | modern, reliable, shared instance |
| **valkey** | cache | redis-compatible, open source |
| **tailscale** | remote access | zero-config vpn |
| **tsdproxy** | service proxy | automatic tailscale integration |
| **trivy** | security scanning | cve detection before updates |
| **diun** | update notifications | image update awareness |
| **telegraf** | SNMP monitoring | cisco switch & brother printer metrics |

### service categories

| category | services | count |
|----------|----------|-------|
| **infrastructure** | tsdproxy, postgres, postgres-backup, valkey, pihole, keepalived | 6 |
| **monitoring** | beszel, beszel-agent, cadvisor, netalertx, telegraf, dozzle, dockwatch | 7 |
| **notifications** | ntfy | 1 |
| **productivity** | homepage, miniflux, mealie, it-tools, stirling-pdf, wallos, argus, filebrowser, atuin | 9 |
| **finance & automation** | spendspentspent, lubelogger, limdius, playwright-chrome | 4 |
| **updates** | diun, trivy | 2 |
| **total** | | **29** |

---

## integration with bender

### services that connect to amy

| bender service | connects to | purpose |
|----------------|-------------|---------|
| **diun** | ntfy (amy) | send update notifications |
| **all services** | pihole vip | DNS resolution |
| **homepage** | dockerproxy (bender) | container status |

### services that connect to bender

| amy service | connects to | purpose |
|-------------|-------------|---------|
| **homepage** | dockerproxy (bender:2375) | monitor bender containers |
| **beszel** | beszel-agent (bender) | system metrics |

### shared configuration

both hosts use synchronized configurations for:

- **pihole blocklists**: synced via nebula-sync (bender → amy)
- **keepalived vip**: coordinated vrrp with health checks
- **tsdproxy**: same tailscale tailnet for service access
- **timezone**: America/Toronto on both hosts
- **dns anchor**: all services use 192.168.21.100 (keepalived VIP)

---

## directory structure overview

```
/docker-compose/                    # docker compose configuration
├── docker-compose.yaml             # main compose file (v98)
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
└── reports/                        # generated reports
    └── weekly-reports/

/docker/                            # container data (persistent)
├── tsdproxy/                       # tailscale proxy
├── dockwatch/                      # container management
├── pihole/                         # DNS server
├── ntfy/                           # notification server
├── stirling/                       # pdf tools
├── homepage/                       # dashboard
├── mealie/                         # recipe manager
├── argus/                          # release monitor
├── lubelogger/                     # vehicle tracker
├── spendspentspent/                # expense tracker
├── limdius/                        # car listing monitor
├── beszel/                         # monitoring
├── netalertx/                      # network monitoring
├── filebrowser/                    # file manager
├── wallos/                         # subscription tracker
├── valkey/                         # cache
├── diun/                           # update notifier
├── trivy/                          # vulnerability scanner
├── keepalived/                     # HA configuration
├── postgres-backup/                # database backups
└── backups/                        # backup storage
    └── postgres/                   # database backups

/portainer/                         # legacy path (still in use)
├── postgresql/                     # postgresql data
│   └── data/                       # actual database files
└── telegraf/                       # telegraf configuration
    └── config/
        └── telegraf.conf           # SNMP monitoring config
```

---

*next: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
