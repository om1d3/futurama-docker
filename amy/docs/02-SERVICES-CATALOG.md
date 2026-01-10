# amy services catalog

## complete service reference

**document version:** 1.0  
**infrastructure version:** 85  
**last updated:** january 10, 2026

---

## table of contents

1. [services overview](#services-overview)
2. [infrastructure services](#infrastructure-services)
3. [monitoring services](#monitoring-services)
4. [productivity services](#productivity-services)
5. [utility services](#utility-services)
6. [update services](#update-services)
7. [port reference](#port-reference)
8. [tsdproxy urls](#tsdproxy-urls)

---

## services overview

### service count by category

| category | count | services |
|----------|-------|----------|
| **infrastructure** | 5 | tsdproxy, postgres, valkey, pihole, keepalived |
| **monitoring** | 6 | beszel, beszel-agent, cadvisor, netalertx, dozzle, dockwatch |
| **notifications** | 1 | ntfy |
| **productivity** | 6 | homepage, vaultwarden, miniflux, mealie, it-tools, stirling-pdf |
| **utilities** | 5 | atuin, filebrowser, lubelogger, spendspentspent, limdius |
| **updates** | 3 | diun, trivy, postgres-backup |
| **support** | 1 | playwright-chrome |
| **total** | 27 | |

### critical services

these services receive special handling during updates:

| service | criticality | reason |
|---------|-------------|--------|
| postgres | critical | database for atuin, miniflux, sss |
| ntfy | critical | notification hub for entire infrastructure |
| beszel | critical | monitoring hub for entire infrastructure |
| pihole | critical | dns (ha with bender via keepalived) |
| keepalived | critical | dns failover / vip management |
| vaultwarden | critical | password manager |
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
| **purpose** | shared database for atuin, miniflux, sss |
| **data path** | `/docker/postgresql/` |
| **databases** | atuin, miniflux, sss |

### valkey

| property | value |
|----------|-------|
| **image** | `valkey/valkey:alpine` |
| **port** | 6379:6379 |
| **tsdproxy name** | (disabled) |
| **purpose** | redis-compatible cache |
| **data path** | `/docker/valkey/` |

### pihole

| property | value |
|----------|-------|
| **image** | `pihole/pihole:latest` |
| **ports** | 53:53 (dns), 8053:80 (web) |
| **tsdproxy name** | pihole-amy |
| **purpose** | secondary dns server (backup) |
| **data path** | `/docker/pihole/` |
| **vip** | 192.168.21.100 (shared with bender) |

### keepalived

| property | value |
|----------|-------|
| **image** | `osixia/keepalived:2.0.20` |
| **network** | host |
| **tsdproxy name** | (disabled) |
| **purpose** | vrrp for dns failover |
| **config path** | `/docker/keepalived/` |
| **state** | backup (priority 100) |

---

## monitoring services

### beszel

| property | value |
|----------|-------|
| **image** | `henrygd/beszel:latest` |
| **port** | 8090:8090 |
| **tsdproxy name** | beszel |
| **purpose** | monitoring hub |
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
| **purpose** | container resource metrics |

### netalertx

| property | value |
|----------|-------|
| **image** | `jokobsk/netalertx:latest` |
| **port** | 20211:20211 |
| **tsdproxy name** | netalertx |
| **purpose** | network device monitoring |
| **data path** | `/docker/netalertx/` |

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
| **image** | `ghcr.io/notifiarr/dockwatch:latest` |
| **port** | 9999:80 |
| **tsdproxy name** | amy-dockwatch |
| **purpose** | container management ui |

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

### homepage

| property | value |
|----------|-------|
| **image** | `ghcr.io/gethomepage/homepage:latest` |
| **port** | 3003:3000 |
| **tsdproxy name** | home |
| **purpose** | service dashboard |
| **data path** | `/docker/homepage/` |

### vaultwarden

| property | value |
|----------|-------|
| **image** | `vaultwarden/server:latest` |
| **port** | 8484:80 |
| **tsdproxy name** | vault |
| **purpose** | password manager |
| **data path** | `/docker/vaultwarden/` |

### miniflux

| property | value |
|----------|-------|
| **image** | `miniflux/miniflux:latest` |
| **port** | 8385:8080 |
| **tsdproxy name** | rss |
| **purpose** | rss feed reader |
| **database** | postgres (miniflux db) |

### mealie

| property | value |
|----------|-------|
| **image** | `ghcr.io/mealie-recipes/mealie:latest` |
| **port** | 8456:9000 |
| **tsdproxy name** | mealie |
| **purpose** | recipe manager |
| **data path** | `/docker/mealie/` |

### it-tools

| property | value |
|----------|-------|
| **image** | `corentinth/it-tools:latest` |
| **port** | 8181:80 |
| **tsdproxy name** | it-tools |
| **purpose** | developer utilities collection |

### stirling-pdf

| property | value |
|----------|-------|
| **image** | `frooodle/s-pdf:latest` |
| **port** | 8080:8080 |
| **tsdproxy name** | pdf |
| **purpose** | pdf manipulation tools |
| **data path** | `/docker/stirling-pdf/` |

---

## utility services

### atuin

| property | value |
|----------|-------|
| **image** | `ghcr.io/atuinsh/atuin:latest` |
| **port** | 8777:8888 |
| **tsdproxy name** | atuin |
| **purpose** | shell history sync |
| **database** | postgres (atuin db) |

### filebrowser

| property | value |
|----------|-------|
| **image** | `filebrowser/filebrowser:latest` |
| **port** | 8082:80 |
| **tsdproxy name** | files |
| **purpose** | web-based file manager |
| **data path** | `/docker/filebrowser/` |

### lubelogger

| property | value |
|----------|-------|
| **image** | `ghcr.io/hargata/lubelogger:latest` |
| **port** | 8989:8080 |
| **tsdproxy name** | lube |
| **purpose** | vehicle maintenance tracker |
| **data path** | `/docker/lubelogger/` |

### spendspentspent

| property | value |
|----------|-------|
| **image** | `ghcr.io/spendspentspent/spendspentspent:latest` |
| **port** | 9021:9001 |
| **tsdproxy name** | money |
| **purpose** | expense tracker |
| **database** | postgres (sss db) |

### limdius

| property | value |
|----------|-------|
| **image** | `ghcr.io/horia138/limdius:latest` |
| **port** | 5050:5050 |
| **tsdproxy name** | limdius |
| **purpose** | car listing monitor |
| **data path** | `/docker/limdius/` |

---

## update services

### diun

| property | value |
|----------|-------|
| **image** | `crazymax/diun:latest` |
| **tsdproxy name** | (disabled) |
| **purpose** | docker image update notifier |
| **schedule** | wednesday 04:30 (cron: `0 30 4 * * 3`) |
| **data path** | `/docker/diun/data/` |
| **config path** | `/docker/diun/config/` |
| **notifications** | ntfy (http://ntfy:80) |

### trivy

| property | value |
|----------|-------|
| **image** | `aquasec/trivy:latest` |
| **port** | 8083:8080 |
| **tsdproxy name** | (disabled) |
| **purpose** | vulnerability scanner |
| **data path** | `/docker/trivy/cache/` |

### postgres-backup

| property | value |
|----------|-------|
| **image** | `prodrigestivill/postgres-backup-local:latest` |
| **tsdproxy name** | (disabled) |
| **purpose** | automated postgresql backups |
| **schedule** | daily |
| **databases** | atuin, miniflux, sss |
| **backup path** | `/docker/backups/postgres/` |
| **retention** | 7 daily, 4 weekly, 6 monthly |

---

## support services

### playwright-chrome

| property | value |
|----------|-------|
| **image** | `browserless/chrome:latest` |
| **tsdproxy name** | (disabled) |
| **purpose** | headless browser for limdius |

---

## port reference

### complete port mapping

| port | service | protocol |
|------|---------|----------|
| 53 | pihole (dns) | tcp/udp |
| 3003 | homepage | http |
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
| 8385 | miniflux | http |
| 8456 | mealie | http |
| 8484 | vaultwarden | http |
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

| tsdproxy name | service | url |
|---------------|---------|-----|
| amy-proxy | tsdproxy dashboard | https://amy-proxy.bunny-enigmatic.ts.net |
| amy-dockwatch | dockwatch | https://amy-dockwatch.bunny-enigmatic.ts.net |
| pihole-amy | pihole | https://pihole-amy.bunny-enigmatic.ts.net |
| ntfy | ntfy | https://ntfy.bunny-enigmatic.ts.net |
| home | homepage | https://home.bunny-enigmatic.ts.net |
| vault | vaultwarden | https://vault.bunny-enigmatic.ts.net |
| rss | miniflux | https://rss.bunny-enigmatic.ts.net |
| pdf | stirling-pdf | https://pdf.bunny-enigmatic.ts.net |
| it-tools | it-tools | https://it-tools.bunny-enigmatic.ts.net |
| files | filebrowser | https://files.bunny-enigmatic.ts.net |
| atuin | atuin | https://atuin.bunny-enigmatic.ts.net |
| mealie | mealie | https://mealie.bunny-enigmatic.ts.net |
| lube | lubelogger | https://lube.bunny-enigmatic.ts.net |
| money | spendspentspent | https://money.bunny-enigmatic.ts.net |
| limdius | limdius | https://limdius.bunny-enigmatic.ts.net |
| logs | dozzle | https://logs.bunny-enigmatic.ts.net |
| beszel | beszel | https://beszel.bunny-enigmatic.ts.net |
| cadvisor | cadvisor | https://cadvisor.bunny-enigmatic.ts.net |
| netalertx | netalertx | https://netalertx.bunny-enigmatic.ts.net |

---

*previous: [01-ARCHITECTURE.md](./01-ARCHITECTURE.md)*  
*next: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
