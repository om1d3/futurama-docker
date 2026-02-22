# amy services catalog

## complete service reference

**document version:** 3.0
**infrastructure version:** 99
**last updated:** february 2026

---

## table of contents

1. [services overview](#services-overview)
2. [infrastructure services](#infrastructure-services)
3. [DNS and high availability](#dns-and-high-availability)
4. [databases](#databases)
5. [notifications](#notifications)
6. [productivity](#productivity)
7. [finance and automation](#finance-and-automation)
8. [monitoring](#monitoring)
9. [update and security tools](#update-and-security-tools)
10. [commented services](#commented-services)
11. [port reference](#port-reference)
12. [tailscale URL reference](#tailscale-url-reference)
13. [service dependencies](#service-dependencies)

---

## services overview

amy runs 29 active containers. 25 use the bridge network (utility-network) and 4 use host networking.

| category | count | services |
|----------|-------|----------|
| infrastructure | 3 | tsdproxy, dockwatch, dozzle |
| DNS & HA | 2 | pihole, keepalived |
| databases | 3 | postgres, postgres-backup, valkey |
| notifications | 1 | ntfy |
| productivity | 10 | stirling, homepage, atuin, miniflux, it-tools, filebrowser, wallos, mealie, argus, lubelogger |
| finance & automation | 3 | spendspentspent, limdius, playwright-chrome |
| monitoring | 5 | beszel, beszel-agent, cadvisor, netalertx, telegraf |
| updates | 2 | diun, trivy |
| **total** | **29** | |

---

## infrastructure services

### tsdproxy

| setting | value |
|---------|-------|
| image | `almeidapaulopt/tsdproxy:latest` |
| container | tsdproxy |
| port | 8085:8080 |
| network | utility-network |
| tsdproxy.name | `amy-proxy` (LOCKED) |
| purpose | tailscale reverse proxy for all tsdproxy-enabled services |

### dockwatch

| setting | value |
|---------|-------|
| image | `ghcr.io/notifiarr/dockwatch:main` |
| container | dockwatch |
| port | 9999:80 |
| network | utility-network |
| tsdproxy.name | `amy-dockwatch` (LOCKED) |
| purpose | container management web UI |

### dozzle

| setting | value |
|---------|-------|
| image | `amir20/dozzle:latest` |
| container | dozzle |
| port | 8182:8080 |
| network | utility-network |
| tsdproxy.name | `logs` (LOCKED) |
| purpose | real-time docker log viewer |

---

## DNS and high availability

### pihole

| setting | value |
|---------|-------|
| image | `pihole/pihole:latest` |
| container | pihole |
| ports | 53:53 (TCP+UDP), 8053:80 |
| network | utility-network (no DNS anchor — it IS the DNS) |
| tsdproxy.name | `pihole-amy` (LOCKED) |
| upstream DNS | 9.9.9.9, 1.1.1.1 |
| DNSSEC | enabled |
| reverse DNS | enabled (192.168.21.0/24 → 192.168.21.1) |

### keepalived

| setting | value |
|---------|-------|
| image | `osixia/keepalived:latest` (not pinned) |
| container | keepalived |
| network | host |
| interface | enp4s0 |
| role | BACKUP (priority 100) |
| VIP | 192.168.21.100 |
| VRRP ID | 53 |
| mode | unicast (peer: 192.168.21.121) |
| health check | wget pihole admin (:8053) every 2s |
| volume mount | `/docker/keepalived` → `/container/service/keepalived/assets` (directory mount) |

note: bender's keepalived uses a pinned image (2.0.20) and a single-file read-only mount. amy uses `:latest` and a directory mount. both configurations work correctly for VRRP failover.

---

## databases

### postgres

| setting | value |
|---------|-------|
| image | `postgres:17-alpine` |
| container | postgres |
| port | 5432:5432 |
| network | utility-network |
| databases | atuin, miniflux, sss, mealie, stirling |
| data path | `/portainer/postgresql/data` (legacy path) |
| healthcheck | `pg_isready -U postgres` |

note: the data path is `/portainer/postgresql/data` rather than `/docker/postgres/data` because the database was originally created under portainer. changing the path would require a database migration.

### postgres-backup

| setting | value |
|---------|-------|
| image | `prodrigestivill/postgres-backup-local:17` (pinned to match postgres) |
| container | postgres-backup |
| network | utility-network |
| databases backed up | atuin, miniflux, sss, mealie, stirling |
| schedule | daily |
| retention | 7 days, 4 weeks, 6 months |
| backup path | `/docker/postgres-backup` |
| depends on | postgres (healthy) |

### valkey

| setting | value |
|---------|-------|
| image | `valkey/valkey:8-alpine` |
| container | valkey |
| port | 6379:6379 |
| network | utility-network |
| purpose | redis-compatible key-value store (available for services that need caching) |

---

## notifications

### ntfy

| setting | value |
|---------|-------|
| image | `binwiederhier/ntfy:latest` |
| container | ntfy |
| port | 8888:80 |
| network | utility-network |
| tsdproxy.name | `ntfy` (LOCKED) |
| command | `serve` |
| purpose | push notification server — used by diun on both hosts and secure-container-update.sh on bender |

---

## productivity

### stirling-pdf

| setting | value |
|---------|-------|
| image | `stirlingtools/stirling-pdf:latest` (v96: corrected) |
| container | stirling |
| port | 8080:8080 |
| network | utility-network |
| tsdproxy.name | `pdf` (LOCKED) |
| SYSTEM_MAXDPI | 1200 (v97: fixes DPI limit error) |

### homepage

| setting | value |
|---------|-------|
| image | `ghcr.io/gethomepage/homepage:latest` |
| container | homepage |
| port | 3003:3000 |
| network | utility-network |
| tsdproxy.name | `home` (LOCKED) |
| docker socket | mounted read-only for local container status |
| cross-host | connects to bender's dockerproxy (:2375) for bender container status |

### atuin (v99: command fix)

| setting | value |
|---------|-------|
| image | `ghcr.io/atuinsh/atuin:latest` |
| container | atuin |
| port | 8777:8888 |
| network | utility-network |
| tsdproxy.name | `atuin` (LOCKED) |
| command | `start` (v99: changed from `server start` — upstream binary changed to atuin-server) |
| database | postgres (atuin DB) |
| depends on | postgres (healthy) |

### miniflux

| setting | value |
|---------|-------|
| image | `miniflux/miniflux:latest` |
| container | miniflux |
| port | 8385:8080 |
| network | utility-network |
| tsdproxy.name | `rss` (LOCKED) |
| database | postgres (miniflux DB) |
| depends on | postgres (healthy) |

### it-tools

| setting | value |
|---------|-------|
| image | `corentinth/it-tools:latest` |
| container | it-tools |
| port | 8181:80 |
| network | utility-network |
| tsdproxy.name | `it-tools` (LOCKED) |

### filebrowser

| setting | value |
|---------|-------|
| image | `filebrowser/filebrowser:latest` |
| container | filebrowser |
| port | 8082:80 |
| network | utility-network |
| tsdproxy.name | `files` (LOCKED) |
| browsable paths | /docker, /portainer |

### wallos

| setting | value |
|---------|-------|
| image | `bellamy/wallos:latest` |
| container | wallos |
| port | 8283:80 |
| network | utility-network |
| tsdproxy.name | `wallos` (LOCKED) |
| purpose | subscription tracker |

### mealie

| setting | value |
|---------|-------|
| image | `ghcr.io/mealie-recipes/mealie:latest` (v96: corrected) |
| container | mealie |
| port | 8456:9000 |
| network | utility-network |
| tsdproxy.name | `mealie` (LOCKED) |
| database | postgres (mealie DB) |
| depends on | postgres (healthy) |

### argus

| setting | value |
|---------|-------|
| image | `releaseargus/argus:latest` (v85.3: corrected) |
| container | argus |
| port | 8282:8080 |
| network | utility-network |
| tsdproxy.name | `argus` (LOCKED) |
| purpose | release monitoring for software updates |

### lubelogger

| setting | value |
|---------|-------|
| image | `ghcr.io/hargata/lubelogger:latest` |
| container | lubelogger |
| port | 8989:8080 |
| network | utility-network |
| tsdproxy.name | `lube` (LOCKED) |
| purpose | vehicle maintenance tracker |

---

## finance and automation

### spendspentspent

| setting | value |
|---------|-------|
| image | `gonzague/spendspentspent:latest` |
| container | spendspentspent |
| port | 9021:9001 |
| network | utility-network |
| tsdproxy.name | `money` (LOCKED) |
| database | postgres (sss DB) |
| browser | playwright-chrome (for bank scraping) |
| depends on | postgres (healthy) |

### limdius

| setting | value |
|---------|-------|
| image | `python:3.11-slim` (v85.3: corrected) |
| container | limdius |
| port | 5050:5050 |
| network | utility-network |
| tsdproxy.name | `limdius` (LOCKED) |
| command | installs dependencies at startup (`pip install requests flask playwright`) then runs `/app/limdius.py` |

### playwright-chrome

| setting | value |
|---------|-------|
| image | `browserless/chrome:latest` |
| container | playwright-chrome |
| port | 3100:3000 |
| network | utility-network |
| tsdproxy | disabled |
| purpose | headless chrome for spendspentspent bank scraping and limdius automation |

---

## monitoring

### beszel

| setting | value |
|---------|-------|
| image | `henrygd/beszel:latest` |
| container | beszel |
| port | 8090:8090 |
| network | utility-network |
| tsdproxy.name | `beszel` (LOCKED) |
| purpose | system monitoring hub — collects metrics from agents on amy and bender |

### beszel-agent

| setting | value |
|---------|-------|
| image | `henrygd/beszel-agent:latest` |
| container | beszel-agent |
| network | host |
| port | 45876 (host) |
| tsdproxy | disabled |
| purpose | reports amy's system metrics to local beszel hub |

### cadvisor

| setting | value |
|---------|-------|
| image | `gcr.io/cadvisor/cadvisor:latest` |
| container | cadvisor |
| port | 9099:8080 |
| network | utility-network |
| tsdproxy.name | `cadvisor` (LOCKED) |
| flags | `--docker_only`, `--housekeeping_interval=30s`, disabled unused metrics |
| purpose | container resource metrics → prometheus → grafana |

### netalertx

| setting | value |
|---------|-------|
| image | `jokobsk/netalertx:latest` |
| container | netalertx |
| network | host |
| port | 20211 (host) |
| tsdproxy.name | `netalertx` (LOCKED) |
| capabilities | NET_RAW, NET_ADMIN, NET_BIND_SERVICE |
| purpose | network device discovery and alerting |

### telegraf

| setting | value |
|---------|-------|
| image | `telegraf:latest` |
| container | telegraf |
| network | host |
| tsdproxy | disabled |
| config | `/portainer/telegraf/config/telegraf.conf` (read-only mount) |
| targets | cisco 3750X switch (192.168.21.5), brother MFC-L3710CW printer (192.168.21.10) |
| output | influxdb on HA VM (192.168.21.220:8086) |

---

## update and security tools

### diun

| setting | value |
|---------|-------|
| image | `crazymax/diun:latest` |
| container | diun |
| network | utility-network |
| tsdproxy | disabled |
| command | `serve` |
| schedule | wednesday 04:00 (`0 4 * * 3`) |
| notifications | ntfy (local, `http://ntfy:80`) |
| topic | `${DIUN_NTFY_TOPIC}` (container-updates-amy) |

### trivy

| setting | value |
|---------|-------|
| image | `aquasec/trivy:latest` |
| container | trivy |
| port | 8083:4954 |
| network | utility-network |
| tsdproxy | disabled |
| command | `server --listen 0.0.0.0:4954` |
| purpose | container vulnerability scanner (server mode for secure-container-update.sh) |

---

## commented services

### watchtower (commented — kept as fallback)

watchtower is commented out but kept in the compose file as a fallback update mechanism. the secure-container-update.sh system replaced it with trivy-scanned updates.

---

## port reference

| host port | container port | service |
|-----------|---------------|---------|
| 53 | 53 | pihole (TCP+UDP) |
| 3003 | 3000 | homepage |
| 3100 | 3000 | playwright-chrome |
| 5050 | 5050 | limdius |
| 5432 | 5432 | postgres |
| 6379 | 6379 | valkey |
| 8053 | 80 | pihole web |
| 8080 | 8080 | stirling |
| 8082 | 80 | filebrowser |
| 8083 | 4954 | trivy |
| 8085 | 8080 | tsdproxy |
| 8090 | 8090 | beszel |
| 8181 | 80 | it-tools |
| 8182 | 8080 | dozzle |
| 8283 | 80 | wallos |
| 8282 | 8080 | argus |
| 8385 | 8080 | miniflux |
| 8456 | 9000 | mealie |
| 8777 | 8888 | atuin |
| 8888 | 80 | ntfy |
| 8989 | 8080 | lubelogger |
| 9021 | 9001 | spendspentspent |
| 9099 | 8080 | cadvisor |
| 9999 | 80 | dockwatch |

host-network services (no port mapping — bind directly):

| port | service |
|------|---------|
| 20211 | netalertx |
| 45876 | beszel-agent |
| telegraf SNMP | telegraf (outbound only) |

---

## tailscale URL reference

| tsdproxy.name | URL | service |
|---------------|-----|---------|
| amy-proxy | https://amy-proxy.bunny-enigmatic.ts.net | tsdproxy |
| amy-dockwatch | https://amy-dockwatch.bunny-enigmatic.ts.net | dockwatch |
| logs | https://logs.bunny-enigmatic.ts.net | dozzle |
| pihole-amy | https://pihole-amy.bunny-enigmatic.ts.net | pihole |
| ntfy | https://ntfy.bunny-enigmatic.ts.net | ntfy |
| pdf | https://pdf.bunny-enigmatic.ts.net | stirling |
| home | https://home.bunny-enigmatic.ts.net | homepage |
| atuin | https://atuin.bunny-enigmatic.ts.net | atuin |
| rss | https://rss.bunny-enigmatic.ts.net | miniflux |
| it-tools | https://it-tools.bunny-enigmatic.ts.net | it-tools |
| files | https://files.bunny-enigmatic.ts.net | filebrowser |
| wallos | https://wallos.bunny-enigmatic.ts.net | wallos |
| mealie | https://mealie.bunny-enigmatic.ts.net | mealie |
| argus | https://argus.bunny-enigmatic.ts.net | argus |
| lube | https://lube.bunny-enigmatic.ts.net | lubelogger |
| money | https://money.bunny-enigmatic.ts.net | spendspentspent |
| limdius | https://limdius.bunny-enigmatic.ts.net | limdius |
| beszel | https://beszel.bunny-enigmatic.ts.net | beszel |
| cadvisor | https://cadvisor.bunny-enigmatic.ts.net | cadvisor |
| netalertx | https://netalertx.bunny-enigmatic.ts.net | netalertx |

---

## service dependencies

### startup order

```
postgres (healthcheck: pg_isready)
├── atuin
├── miniflux
├── spendspentspent
├── mealie
└── postgres-backup
```

### cross-host dependencies

| amy service | depends on (bender) |
|------------|---------------------|
| homepage | dockerproxy on bender (:2375) |
| pihole | nebula-sync on bender (config replication) |

| bender service | depends on (amy) |
|---------------|------------------|
| diun | ntfy (for notifications) |
| secure-container-update.sh | ntfy (for notifications) |
| nebula-sync | pihole on amy (as replica target) |
| beszel-agent | beszel hub on amy (metrics collection) |
| pihole-dns-update.sh | docker API on amy via SSH (label scanning) |

---

*previous: [01-ARCHITECTURE.md](./01-ARCHITECTURE.md)*
*next: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
