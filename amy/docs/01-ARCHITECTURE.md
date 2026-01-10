# amy infrastructure architecture documentation

## utilities & monitoring server

**document version:** 1.0  
**infrastructure version:** 85  
**last updated:** january 10, 2026  
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
- **monitoring and observability** (beszel, cadvisor, netalertx)
- **dns high availability** (secondary pihole with keepalived)
- **productivity tools** (vaultwarden, mealie, lubelogger, etc.)
- **lightweight databases** (postgresql for atuin, miniflux, spendspentspent)

### key characteristics

| characteristic | implementation |
|----------------|----------------|
| **role** | utilities, monitoring, notifications |
| **hardware** | intel i3-2310m, 16gb ram |
| **storage** | local ssd + nfs from bender |
| **docker path** | `/docker-compose/` |
| **data path** | `/docker/` |
| **update schedule** | wednesday 04:30 |
| **critical services** | 8 (postgres, ntfy, beszel, pihole, keepalived, vaultwarden, spendspentspent, diun) |

---

## role in infrastructure

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              infrastructure overview                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────┐              ┌─────────────────────────┐       │
│  │   bender (TrueNAS)      │              │      amy (intel i3)     │       │
│  │   192.168.21.121        │              │      192.168.21.130     │       │
│  │   ─────────────────     │              │      ─────────────────  │       │
│  │   • media services      │              │      • notifications    │       │
│  │   • downloads (arr)     │◄────────────►│      • monitoring       │       │
│  │   • photo management    │     nfs      │      • dns backup       │       │
│  │   • primary storage     │              │      • productivity     │       │
│  │   • dns primary         │              │      • password mgmt    │       │
│  └─────────────────────────┘              └─────────────────────────┘       │
│              │                                        │                      │
│              └────────────────┬───────────────────────┘                      │
│                               │                                              │
│                        ┌──────▼──────┐                                      │
│                        │   vip dns   │                                      │
│                        │192.168.21.100│                                      │
│                        └─────────────┘                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### why amy exists

1. **failure isolation**: if bender goes down for maintenance, critical services (dns, notifications, monitoring) continue on amy

2. **external monitoring**: amy can monitor bender's health from outside - if bender's monitoring fails, amy can still alert

3. **resource optimization**: lightweight services don't need TrueNAS's resources; they run fine on older hardware

4. **TrueNAS upgrade safety**: services on amy are unaffected by TrueNAS upgrades

### critical services on amy

amy hosts 8 critical services that receive special handling during updates:

| service | why critical |
|---------|--------------|
| **postgres** | database for 3 applications (atuin, miniflux, sss) |
| **ntfy** | notification hub for entire infrastructure |
| **beszel** | monitoring hub - if down, no visibility |
| **pihole** | dns - network-wide impact if fails |
| **keepalived** | dns failover - ha depends on it |
| **vaultwarden** | password manager - security critical |
| **spendspentspent** | financial data - data integrity critical |
| **diun** | update notifications - security visibility |

---

## hardware specifications

### current hardware

| component | specification |
|-----------|---------------|
| **cpu** | intel core i3-2310m (2 cores, 4 threads, 2.1ghz) |
| **ram** | 16gb ddr3 |
| **storage** | 256gb ssd (system + docker) |
| **network** | 1gbe (enp4s0) |
| **os** | ubuntu server 22.04 lts |

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
| **enp4s0** | 192.168.21.130 | primary lan |
| **vip** | 192.168.21.100 | shared dns (keepalived) |
| **tailscale** | 100.x.x.x | remote access |

### dns configuration

amy runs as dns backup:
- **primary**: bender (192.168.21.121)
- **backup**: amy (192.168.21.130)
- **vip**: 192.168.21.100 (clients point here)

### port mappings (key services)

| service | port | protocol |
|---------|------|----------|
| pihole dns | 53 | tcp/udp |
| pihole web | 8053 | http |
| ntfy | 8888 | http |
| postgresql | 5432 | tcp |
| beszel | 8090 | http |
| trivy | 8083 | http |

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
| **docker** | latest | native docker on ubuntu |
| **docker compose** | v2.x | single compose file |
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

### service categories

| category | services | count |
|----------|----------|-------|
| **infrastructure** | tsdproxy, postgres, valkey, pihole, keepalived | 5 |
| **monitoring** | beszel, beszel-agent, cadvisor, netalertx, dozzle, dockwatch | 6 |
| **notifications** | ntfy | 1 |
| **productivity** | homepage, vaultwarden, miniflux, mealie, it-tools, stirling-pdf | 6 |
| **utilities** | atuin, filebrowser, lubelogger, spendspentspent, limdius | 5 |
| **updates** | diun, trivy, postgres-backup | 3 |
| **support** | playwright-chrome | 1 |

---

## integration with bender

### services that connect to amy

| bender service | connects to | purpose |
|----------------|-------------|---------|
| **diun** | ntfy (amy) | send update notifications |
| **watchtower** | ntfy (amy) | send update notifications |
| **all services** | pihole vip | dns resolution |
| **homepage** | dockerproxy (bender) | container status |

### services that connect to bender

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
/docker-compose/                    # docker compose configuration
├── docker-compose.yaml             # main compose file (v85)
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
├── postgresql/                     # postgresql data
├── ntfy/                           # notification server
├── pihole/                         # dns server
├── vaultwarden/                    # password manager
├── beszel/                         # monitoring
├── backups/                        # backup storage
│   └── postgres/                   # database backups
└── [other services]/               # service-specific data
```

---

*next: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
