# amy architecture

## infrastructure design and system overview

**document version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

---

## table of contents

1. [executive summary](#executive-summary)
2. [hardware specifications](#hardware-specifications)
3. [network configuration](#network-configuration)
4. [service architecture](#service-architecture)
5. [storage architecture](#storage-architecture)
6. [notification hub](#notification-hub)
7. [network configuration backup](#network-configuration-backup)
8. [replica hosting](#replica-hosting)
9. [monitoring pipeline](#monitoring-pipeline)
10. [high availability](#high-availability)
11. [integration with bender](#integration-with-bender)
12. [technology stack](#technology-stack)

---

## executive summary

amy is the secondary host in the two-host home lab. it runs on a repurposed Intel i3-2310M laptop with 16 GB RAM and provides utilities, monitoring, notifications, DNS backup, network-config backup, and disaster-recovery storage for bender. amy complements bender by handling lightweight services that don't require ZFS storage – and by being the host that stays up (and keeps alerting) when bender is upgrading or broken.

as of 20260810.2, amy defines 31 services and runs 25. six are deliberately parked with `profiles: ["parked"]` and do not start by default: limdius, lubelogger, playwright-chrome, spendspentspent, tax-calculator, wallos. the categories are infrastructure, network-config backup, DNS/HA, databases, notifications, productivity, finance, automation, monitoring, and updates. one container (watchtower) is kept commented as a fallback.

three roles have grown since v99: amy became the **replica target** for bender's nightly critical-data copy (`/docker/backups/bender-replica`), gained **oxidized** for hourly Cisco switch-config backup to GitHub (v102), and its tsdproxy was hardened against post-reboot auth failures (v101, v104).

---

## hardware specifications

| component | specification |
|-----------|--------------|
| **platform** | repurposed laptop |
| **CPU** | Intel Core i3-2310M (2 cores, 4 threads, 2.1 GHz) |
| **RAM** | 16 GB DDR3 |
| **storage** | single SSD |
| **network** | enp4s0 (ethernet) |
| **OS** | Debian |
| **IP** | 10.30.0.11 |

### advantages over bender

- **no ZFS overhead**: simple filesystem, no I/O saturation risk
- **direct script execution**: no TrueNAS restrictions – scripts run directly from their paths, cron is plain crontab
- **independent updates**: Debian upgrades don't touch bender's TrueNAS

### limitations

- **single SSD**: no redundancy. amy's own data is postgres-dumped daily, but the SSD also carries bender's replica – a bender-and-amy simultaneous disk loss is the residual uncovered scenario (mitigated by the git repo + off-site copies)
- **modest CPU**: 2 cores/4 threads pins the service mix to lightweight utilities; playwright-chrome is the heaviest tenant

---

## network configuration

### interfaces

| interface | type | ip address | purpose |
|-----------|------|------------|---------|
| enp4s0 | 1G ethernet | 10.30.0.11 | primary network (all services, keepalived VRRP) |
| tailscale | overlay | dynamic | remote access via tsdproxy |

### DNS

| setting | value |
|---------|-------|
| pihole VIP | 10.30.0.2 (keepalived VRRP – amy is BACKUP) |
| amy pihole upstream | 9.9.9.9, 1.1.1.1 – DNSSEC enabled |
| reverse lookups | REV_SERVER → 10.30.0.1 (fry), domain `lan`, CIDR 10.30.0.0/24 |
| local domain | `home.arpa` (entries pushed from bender via nebula-sync) |

all services on the `utility-network` bridge use the DNS anchor `10.30.0.2` via the `x-dns` YAML anchor. exceptions: pihole (it IS the DNS), and the host-network services (keepalived, beszel-agent, netalertx, telegraf).

note the deliberate upstream asymmetry with bender (bender: 1.1.1.1/8.8.8.8, no DNSSEC flag; amy: quad9 + DNSSEC) – a failover to amy also changes upstream behavior slightly.

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
| 5432 | postgres |
| 6379 | valkey |
| 8080 | stirling |
| 8082 | filebrowser |
| 8083 | trivy |
| 8085 | tsdproxy |
| 8053 | pihole web |
| 8090 | beszel hub |
| 8181 | it-tools |
| 8182 | dozzle |
| 8282 | argus |
| 8283 | wallos |
| 8385 | miniflux |
| 8456 | mealie |
| 8484 | tax-calculator |
| 8777 | atuin |
| 8888 | ntfy |
| 8889 | oxidized REST |
| 8989 | lubelogger |
| 9021 | spendspentspent |
| 9099 | cadvisor |
| 9999 | dockwatch |
| 20211 | netalertx (host) |
| 45876 | beszel-agent (host) |

(amy's 8484 is tax-calculator and 8989 is lubelogger – same numbers serve vaultwarden and sonarr on bender; ports are per-host.)

---

## service architecture

### service categories (31 active containers)

| category | count | services |
|----------|-------|----------|
| **infrastructure** | 3 | tsdproxy, dockwatch, dozzle |
| **network config backup** | 1 | oxidized |
| **DNS & HA** | 2 | pihole, keepalived |
| **databases & cache** | 3 | postgres, postgres-backup, valkey |
| **notifications** | 1 | ntfy |
| **productivity** | 9 | stirling, homepage, atuin, miniflux, it-tools, filebrowser, wallos, mealie, lubelogger |
| **release tracking** | 1 | argus |
| **finance** | 2 | spendspentspent, tax-calculator |
| **automation & support** | 2 | limdius, playwright-chrome |
| **monitoring** | 5 | beszel, beszel-agent, cadvisor, netalertx, telegraf |
| **updates** | 2 | diun, trivy |
| **total active** | **31** | |

plus watchtower, commented out as an emergency fallback updater.

### network modes

| mode | count | services |
|------|-------|----------|
| bridge (utility-network) | 27 | most services |
| host | 4 | keepalived, beszel-agent, netalertx, telegraf |

---

## storage architecture

everything lives on the single SSD:

| path | purpose |
|------|---------|
| `/docker-compose/` | compose file, .env, scripts |
| `/docker/<service>/` | per-service data and config volumes |
| `/docker/postgres-backup/` | daily dumps of the five databases |
| `/docker/backups/bender-replica/` | bender's nightly replica (configs + dumps + compose tree) |
| `/portainer/postgresql/data` | **legacy path** – the live postgres data directory (v94 restored this path) |
| `/portainer/telegraf/config/` | **legacy path** – telegraf.conf (v98 consolidation kept the path) |

the two `/portainer` paths are pre-consolidation debt: they predate the single-compose migration and were kept because moving a live postgres data directory buys nothing. treat them as canonical until a deliberate migration; do not "tidy" them.

### critical data paths

| path | criticality | backup method |
|------|-------------|---------------|
| `/portainer/postgresql/data` | **CRITICAL** – atuin, miniflux, sss, mealie, stirling databases | postgres-backup daily (7d/4w/6m retention) |
| `/docker/backups/bender-replica` | **HIGH** – bender's disaster-recovery copy | is itself the backup; 7-day rotation from bender |
| `/docker/ntfy`, `/docker/beszel` | medium – notification + monitoring state | file-level, replaceable |

---

## notification hub

amy is the notification center for the entire infrastructure – deliberately placed on the host that is NOT being upgraded on saturdays:

```
producers                                consumers
bender diun ─────────────┐
bender update script ────┤
bender smart-test ───────┼──► ntfy (amy :8888) ──► phone / browser
bender replicate ────────┤
bender lrrr (TTS) ───────┤
amy diun ────────────────┘   (amy's own diun posts via http://ntfy:80 in-network)
```

if amy is down, alerts are down – which is why amy's own update day (wednesday) is offset from bender's (saturday), and why amy's stack is kept small and boring.

---

## network configuration backup

oxidized (v102) backs up nod's (Cisco Catalyst 3750X) running config hourly to the private GitHub repo om1d3/nod-config:

| aspect | value |
|--------|-------|
| image | oxidized/oxidized:0.36.0 (pinned 20260810 – 0.37.0 is broken) |
| schedule | hourly (CONFIG_RELOAD_INTERVAL=3600) |
| config | /docker/oxidized/config |
| device list | /docker/oxidized/router.db |
| REST API | http://10.30.0.11:8889 |
| credential | GitHub PAT (amy-oxidized) – has an expiry; rotation is an operational task |

this closes the loop on infrastructure sources of truth: compose in futurama-docker, IaC in forgejo on bender, switch config in nod-config.

---

## replica hosting

amy receives bender's nightly (03:30) rsync of non-regenerable data into `/docker/backups/bender-replica/`:

- `configs/` – every bender service config (vaultwarden, forgejo repos, pihole, …)
- `backups/postgres/` – bender's five-database dumps
- `docker-compose/` – bender's compose, .env, and all six scripts

7-day retention, kube-owned destination, SSH trust from bender's root key. amy's duty is passive: keep the SSH trust valid, keep disk space available, and stay up at 03:30. capacity check belongs in amy's weekly routine (see 07).

---

## monitoring pipeline

```
bender cadvisor (10.30.0.12:9099) ─┐
amy cadvisor  (10.30.0.11:9099) ───┼─► prometheus (10.30.0.41:9090, HA VM) ─► grafana (2 dashboards)
```

amy's cadvisor runs the same resource-saving flags as bender's (docker_only, 30s housekeeping, disabled unused metrics). grafana's amy dashboard uses an `instance` variable of Constant type, value `10.30.0.11:9099`.

beszel (hub, :8090) collects system metrics from both hosts' beszel-agents. netalertx watches the LAN for new/changed devices (host network, port 20211). telegraf (host network) polls nod and the Brother MFC-L3710CW printer via SNMP. <!-- VERIFY: telegraf output destination (prometheus? influx?) – read /portainer/telegraf/config/telegraf.conf -->

---

## high availability

### pihole DNS failover (amy = BACKUP)

| setting | value |
|---------|-------|
| VIP | 10.30.0.2 |
| interface | enp4s0 |
| role | BACKUP (priority 100) |
| VRRP ID | 53, unicast |
| peers | src 10.30.0.11 → peer 10.30.0.12 |
| health check | wget pihole admin (127.0.0.1:8053) every 2s, weight -150 |

amy claims the VIP within ~5 seconds of bender's pihole failing three consecutive checks, and cedes it when bender (priority 200) recovers. pihole config flows one way: bender → amy, hourly, via nebula-sync (FULL_SYNC + RUN_GRAVITY) – never edit amy's pihole directly; changes will be overwritten within the hour.

note: amy's keepalived mounts its config directly to `/etc/keepalived/keepalived.conf` with the VRRP password inline, unlike bender's env-injected osixia `--copy-service` pattern. the two hosts run different keepalived versions by different mechanisms, and that is deliberate. amy runs 2.3.4, pinned by digest since 20260810.2. bender runs 2.0.20. VRRP is a protocol, so the two interoperate. a 20260810 attempt to pin amy to the 2.0.20 tag failed and caused a restart loop, because 2.0.20 reads `/usr/local/etc/keepalived/keepalived.conf` and therefore ignored amy's mount. version parity would require changing amy's mount path as well. the inline-password conf mount remains the standing hygiene item – see 06.

---

## integration with bender

### amy → bender dependencies

| amy service | depends on (bender) | purpose |
|------------|---------------------|---------|
| homepage | dockerproxy (10.30.0.12:2375) | bender container status widget |
| pihole | nebula-sync push from bender | receives full pihole config hourly |

### bender → amy dependencies

| bender service | depends on (amy) | purpose |
|---------------|------------------|---------|
| diun / update script / smart-test / lrrr | ntfy (:8888) | all notifications |
| bender-replicate.sh | SSH + /docker/backups/bender-replica | nightly replica |
| nebula-sync | pihole (:8053) | DNS replication target |
| beszel-agent | beszel hub (:8090) | metrics collection |
| pihole-dns-update.sh | docker API via SSH (kube@10.30.0.11) | scans amy tsdproxy labels for DNS |

---

## technology stack

| layer | technology |
|-------|------------|
| **host OS** | Debian |
| **container runtime** | Docker + Docker Compose |
| **storage** | single SSD, plain Linux filesystem |
| **DNS** | pihole v6 (BACKUP role), DNSSEC, quad9 upstream |
| **HA** | keepalived (VRRP unicast BACKUP, VIP 10.30.0.2) |
| **remote access** | Tailscale via tsdproxy |
| **notifications** | ntfy (the infrastructure's hub) |
| **monitoring** | beszel hub, cadvisor → prometheus → grafana, netalertx, telegraf/SNMP |
| **network config backup** | oxidized → GitHub (om1d3/nod-config) |
| **updates** | diun (wed 04:00) + trivy (:4954 internal) + secure-container-update.sh v1.2 |
| **backup** | postgres-backup-local (daily, 5 databases); hosts bender's replica |

---

*next: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
