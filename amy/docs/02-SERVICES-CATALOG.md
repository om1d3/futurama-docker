# amy services catalog

## complete service reference

**document version:** 2.0  
**infrastructure version:** 98  
**last updated:** february 8, 2026

---

## table of contents

1. [services overview](#services-overview)
2. [infrastructure services](#infrastructure-services)
3. [monitoring services](#monitoring-services)
4. [notification services](#notification-services)
5. [productivity services](#productivity-services)
6. [finance & automation services](#finance--automation-services)
7. [update services](#update-services)
8. [port reference](#port-reference)
9. [tsdproxy urls](#tsdproxy-urls)

---

## services overview

### service count by category

| category | count | services |
|----------|-------|----------|
| **infrastructure** | 6 | tsdproxy, postgres, postgres-backup, valkey, pihole, keepalived |
| **monitoring** | 7 | beszel, beszel-agent, cadvisor, netalertx, telegraf, dozzle, dockwatch |
| **notifications** | 1 | ntfy |
| **productivity** | 9 | homepage, miniflux, mealie, it-tools, stirling-pdf, wallos, argus, filebrowser, atuin |
| **finance & automation** | 4 | spendspentspent, lubelogger, limdius, playwright-chrome |
| **updates** | 2 | diun, trivy |
| **total** | **29** | |

### critical services

these services receive special handling during updates:

| service | criticality | reason |
|---------|-------------|--------|
| postgres | critical | database for atuin, miniflux, sss, mealie, stirling |
| ntfy | critical | notification hub for entire infrastructure |
| beszel | critical | monitoring hub for entire infrastructure |
| pihole | critical | DNS (HA with bender via keepalived) |
| keepalived | critical | DNS failover / VIP management |
| spendspentspent | critical | financial tracking |
| diun | critical | update notifications for entire infrastructure |

---

## infrastructure services

### tsdproxy

| property | value |
|----------|-------|
| **image** | `almeidapaulopt/tsdproxy:latest` |
| **port** | 8085:8080 |
| **tsdproxy name** | amy-proxy |
| **purpose** | tailscale proxy for all services |
| **data path** | `/docker/tsdproxy/` |

### postgres

| property | value |
|----------|-------|
| **image** | `postgres:17-alpine` |
| **port** | 5432:5432 |
| **tsdproxy name** | (disabled) |
| **purpose** | shared database for 5 applications |
| **data path** | `/portainer/postgresql/data/` |
| **databases** | atuin, miniflux, sss, mealie, stirling |
| **healthcheck** | `pg_isready -U postgres` |

### postgres-backup

| property | value |
|----------|-------|
| **image** | `prodrigestivill/postgres-backup-local:17` |
| **tsdproxy name** | (disabled) |
| **purpose** | automated postgresql backups |
| **schedule** | daily |
| **databases** | atuin, miniflux, sss, mealie, stirling |
| **backup path** | `/docker/postgres-backup/` |
| **retention** | 7 daily, 4 weekly, 6 monthly |

### valkey

| property | value |
|----------|-------|
| **image** | `valkey/valkey:8-alpine` |
| **port** | 6379:6379 |
| **tsdproxy name** | (disabled) |
| **purpose** | redis-compatible cache |
| **data path** | `/docker/valkey/` |

### pihole

| property | value |
|----------|-------|
| **image** | `pihole/pihole:latest` |
| **ports** | 53:53 (DNS), 8053:80 (web) |
| **tsdproxy name** | pihole-amy |
| **purpose** | secondary DNS server (backup) |
| **data path** | `/docker/pihole/` |
| **vip** | 192.168.21.100 (shared with bender) |
| **note** | does NOT use default-dns (it IS the DNS server) |

### keepalived

| property | value |
|----------|-------|
| **image** | `osixia/keepalived:latest` |
| **network** | host |
| **tsdproxy name** | (disabled) |
| **purpose** | VRRP for DNS failover |
| **config path** | `/docker/keepalived/` |
| **state** | BACKUP (priority 100) |

---

## monitoring services

### beszel

| property | value |
|----------|-------|
| **image** | `henrygd/beszel:latest` |
| **port** | 8090:8090 |
| **tsdproxy name** | beszel |
| **purpose** | monitoring hub for entire infrastructure |
| **data path** | `/docker/beszel/data/` |

### beszel-agent

| property | value |
|----------|-------|
| **image** | `henrygd/beszel-agent:latest` |
| **network** | host |
| **tsdproxy name** | (disabled) |
| **purpose** | local system metrics collector |

### cadvisor

| property | value |
|----------|-------|
| **image** | `gcr.io/cadvisor/cadvisor:latest` |
| **port** | 9099:8080 |
| **tsdproxy name** | cadvisor |
| **purpose** | container resource metrics (CPU, memory, I/O) |
| **flags** | `--housekeeping_interval=30s --docker_only=true --disable_metrics=percpu,sched,tcp,udp,disk,diskIO,hugetlb,referenced_memory,cpu_topology,resctrl` |
| **note** | scraped by Prometheus on Home Assistant VM (192.168.21.220:9090) for Grafana dashboards |

### netalertx

| property | value |
|----------|-------|
| **image** | `jokobsk/netalertx:latest` |
| **port** | 20211 (host network) |
| **tsdproxy name** | netalertx |
| **purpose** | network device monitoring |
| **data path** | `/docker/netalertx/data/` |
| **capabilities** | NET_RAW, NET_ADMIN, NET_BIND_SERVICE |

### telegraf

| property | value |
|----------|-------|
| **image** | `telegraf:latest` |
| **network** | host |
| **tsdproxy name** | (disabled) |
| **purpose** | SNMP monitoring (Cisco 3750X switch + Brother MFC-L3710CW printer) |
| **config path** | `/portainer/telegraf/config/telegraf.conf` |
| **output** | InfluxDB on Home Assistant VM (192.168.21.220:8086) |
| **note** | consolidated into main docker-compose in v98 (previously separate stack) |

### dozzle

| property | value |
|----------|-------|
| **image** | `amir20/dozzle:latest` |
| **port** | 8182:8080 |
| **tsdproxy name** | logs |
| **purpose** | real-time container log viewer |

### dockwatch

| property | value |
|----------|-------|
| **image** | `ghcr.io/notifiarr/dockwatch:main` |
| **port** | 9999:80 |
| **tsdproxy name** | amy-dockwatch |
| **purpose** | container management UI |

---

## notification services

### ntfy

| property | value |
|----------|-------|
| **image** | `binwiederhier/ntfy:latest` |
| **port** | 8888:80 |
| **tsdproxy name** | ntfy |
| **purpose** | push notifications for entire infrastructure |
| **data path** | `/docker/ntfy/` |

---

## productivity services

### stirling-pdf

| property | value |
|----------|-------|
| **image** | `stirlingtools/stirling-pdf:latest` |
| **port** | 8080:8080 |
| **tsdproxy name** | pdf |
| **purpose** | PDF manipulation tools |
| **data path** | `/docker/stirling/` |
| **note** | SYSTEM_MAXDPI=1200 (added in v97) |

### homepage

| property | value |
|----------|-------|
| **image** | `ghcr.io/gethomepage/homepage:latest` |
| **port** | 3003:3000 |
| **tsdproxy name** | home |
| **purpose** | service dashboard |
| **data path** | `/docker/homepage/` |

### miniflux

| property | value |
|----------|-------|
| **image** | `miniflux/miniflux:latest` |
| **port** | 8385:8080 |
| **tsdproxy name** | rss |
| **purpose** | RSS feed reader |
| **database** | postgres (miniflux db) |

### mealie

| property | value |
|----------|-------|
| **image** | `ghcr.io/mealie-recipes/mealie:latest` |
| **port** | 8456:9000 |
| **tsdproxy name** | mealie |
| **purpose** | recipe manager |
| **database** | postgres (mealie db) |
| **data path** | `/docker/mealie/` |

### it-tools

| property | value |
|----------|-------|
| **image** | `corentinth/it-tools:latest` |
| **port** | 8181:80 |
| **tsdproxy name** | it-tools |
| **purpose** | developer utilities collection |

### wallos

| property | value |
|----------|-------|
| **image** | `bellamy/wallos:latest` |
| **port** | 8283:80 |
| **tsdproxy name** | wallos |
| **purpose** | subscription tracker |
| **data path** | `/docker/wallos/db/` |

### argus

| property | value |
|----------|-------|
| **image** | `releaseargus/argus:latest` |
| **port** | 8282:8080 |
| **tsdproxy name** | argus |
| **purpose** | release monitor |
| **data path** | `/docker/argus/` |

### filebrowser

| property | value |
|----------|-------|
| **image** | `filebrowser/filebrowser:latest` |
| **port** | 8082:80 |
| **tsdproxy name** | files |
| **purpose** | web-based file manager |
| **data path** | `/docker/filebrowser/` |
| **mounts** | `/docker:/srv/docker`, `/portainer:/srv/portainer` |

### atuin

| property | value |
|----------|-------|
| **image** | `ghcr.io/atuinsh/atuin:latest` |
| **port** | 8777:8888 |
| **tsdproxy name** | atuin |
| **purpose** | shell history sync |
| **database** | postgres (atuin db) |

---

## finance & automation services

### spendspentspent

| property | value |
|----------|-------|
| **image** | `gonzague/spendspentspent:latest` |
| **port** | 9021:9001 |
| **tsdproxy name** | money |
| **purpose** | expense tracker |
| **database** | postgres (sss db) |
| **data path** | `/docker/spendspentspent/` |
| **volumes** | app-files, files, config |

### lubelogger

| property | value |
|----------|-------|
| **image** | `ghcr.io/hargata/lubelogger:latest` |
| **port** | 8989:8080 |
| **tsdproxy name** | lube |
| **purpose** | vehicle maintenance tracker |
| **data path** | `/docker/lubelogger/` |

### limdius

| property | value |
|----------|-------|
| **image** | `python:3.11-slim` |
| **port** | 5050:5050 |
| **tsdproxy name** | limdius |
| **purpose** | car listing monitor |
| **data path** | `/docker/limdius/` |
| **depends on** | playwright-chrome |

### playwright-chrome

| property | value |
|----------|-------|
| **image** | `browserless/chrome:latest` |
| **port** | 3100:3000 |
| **tsdproxy name** | (disabled) |
| **purpose** | headless browser for limdius and spendspentspent |

---

## update services

### diun

| property | value |
|----------|-------|
| **image** | `crazymax/diun:latest` |
| **tsdproxy name** | (disabled) |
| **purpose** | docker image update notifier |
| **schedule** | wednesday 04:00 (`0 4 * * 3`) |
| **data path** | `/docker/diun/data/` |
| **notifications** | ntfy (`http://ntfy:80`) |

### trivy

| property | value |
|----------|-------|
| **image** | `aquasec/trivy:latest` |
| **port** | 8083:4954 |
| **tsdproxy name** | (disabled) |
| **purpose** | vulnerability scanner |
| **data path** | `/docker/trivy/cache/` |

---

## port reference

### complete port mapping

| port | service | protocol |
|------|---------|----------|
| 53 | pihole (DNS) | tcp/udp |
| 3003 | homepage | http |
| 3100 | playwright-chrome | http |
| 5050 | limdius | http |
| 5432 | postgres | tcp |
| 6379 | valkey | tcp |
| 8053 | pihole (web) | http |
| 8080 | stirling-pdf | http |
| 8082 | filebrowser | http |
| 8083 | trivy | http |
| 8085 | tsdproxy | http |
| 8090 | beszel | http |
| 8181 | it-tools | http |
| 8182 | dozzle | http |
| 8282 | argus | http |
| 8283 | wallos | http |
| 8385 | miniflux | http |
| 8456 | mealie | http |
| 8777 | atuin | http |
| 8888 | ntfy | http |
| 8989 | lubelogger | http |
| 9021 | spendspentspent | http |
| 9099 | cadvisor | http |
| 9999 | dockwatch | http |
| 20211 | netalertx | http |

---

## tsdproxy urls

### service access via tailscale

| tsdproxy name | service | LAN url | tailscale url |
|---------------|---------|---------|---------------|
| amy-proxy | tsdproxy dashboard | http://amy-proxy.home.arpa:8085 | https://amy-proxy.bunny-enigmatic.ts.net |
| amy-dockwatch | dockwatch | http://amy-dockwatch.home.arpa:9999 | https://amy-dockwatch.bunny-enigmatic.ts.net |
| pihole-amy | pihole | http://pihole-amy.home.arpa:8053 | https://pihole-amy.bunny-enigmatic.ts.net |
| ntfy | ntfy | http://ntfy.home.arpa:8888 | https://ntfy.bunny-enigmatic.ts.net |
| home | homepage | http://home.home.arpa:3003 | https://home.bunny-enigmatic.ts.net |
| rss | miniflux | http://rss.home.arpa:8385 | https://rss.bunny-enigmatic.ts.net |
| pdf | stirling-pdf | http://pdf.home.arpa:8080 | https://pdf.bunny-enigmatic.ts.net |
| it-tools | it-tools | http://it-tools.home.arpa:8181 | https://it-tools.bunny-enigmatic.ts.net |
| files | filebrowser | http://files.home.arpa:8082 | https://files.bunny-enigmatic.ts.net |
| wallos | wallos | http://wallos.home.arpa:8283 | https://wallos.bunny-enigmatic.ts.net |
| atuin | atuin | http://atuin.home.arpa:8777 | https://atuin.bunny-enigmatic.ts.net |
| mealie | mealie | http://mealie.home.arpa:8456 | https://mealie.bunny-enigmatic.ts.net |
| argus | argus | http://argus.home.arpa:8282 | https://argus.bunny-enigmatic.ts.net |
| lube | lubelogger | http://lube.home.arpa:8989 | https://lube.bunny-enigmatic.ts.net |
| money | spendspentspent | http://money.home.arpa:9021 | https://money.bunny-enigmatic.ts.net |
| limdius | limdius | http://limdius.home.arpa:5050 | https://limdius.bunny-enigmatic.ts.net |
| logs | dozzle | http://logs.home.arpa:8182 | https://logs.bunny-enigmatic.ts.net |
| beszel | beszel | http://beszel.home.arpa:8090 | https://beszel.bunny-enigmatic.ts.net |
| cadvisor | cadvisor | http://cadvisor.home.arpa:9099 | https://cadvisor.bunny-enigmatic.ts.net |
| netalertx | netalertx | http://netalertx.home.arpa:20211 | https://netalertx.bunny-enigmatic.ts.net |

---

*previous: [01-ARCHITECTURE.md](./01-ARCHITECTURE.md)*  
*next: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
