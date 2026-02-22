# amy directory structure

## complete file system layout

**document version:** 3.0
**infrastructure version:** 99
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [docker-compose directory](#docker-compose-directory)
3. [container data — /docker/](#container-data--docker)
4. [legacy paths — /portainer/](#legacy-paths--portainer)
5. [backup data](#backup-data)
6. [volume mount reference](#volume-mount-reference)
7. [network mode reference](#network-mode-reference)
8. [path conventions](#path-conventions)

---

## overview

amy uses two base paths for container data:

| path | purpose | origin |
|------|---------|--------|
| `/docker-compose/` | compose file, .env, scripts, configs | current deployment |
| `/docker/` | per-service container data | current deployment |
| `/portainer/` | postgresql data, telegraf config | legacy from original portainer deployment |

the `/portainer/` paths are historical — the postgresql database was originally created there and moving it would require a full database migration. telegraf's config also lives there from its original standalone deployment before being consolidated into the main docker-compose.yaml in v98.

---

## docker-compose directory

```
/docker-compose/
├── docker-compose.yaml                 # v99 — main compose file (29 services)
├── .env                                # environment variables
├── scripts/
│   ├── secure-container-update.sh      # v1.2 — automated update orchestration
│   ├── health-checks.sh               # v1.0 — health check suite
│   └── rollback.sh                     # v1.0 — rollback helper
└── configs/
    ├── keepalived/
    │   └── keepalived.conf             # VRRP backup config (enp4s0, priority 100)
    ├── telegraf/
    │   └── telegraf.conf               # SNMP monitoring config (cisco + brother)
    └── secure-update/                  # created at runtime by update script
        ├── critical-containers.json
        ├── retry-queue.json
        ├── logs/
        └── scan-reports/
```

note: unlike bender (where scripts must be copied to `/tmp/` due to TrueNAS restrictions), amy can execute scripts directly from `/docker-compose/scripts/`.

---

## container data — /docker/

```
/docker/
├── argus/                      # release monitoring data
├── beszel/
│   └── data/                   # monitoring hub database
├── diun/
│   └── data/                   # image update tracker state
├── dockwatch/                  # container management config
├── filebrowser/
│   ├── database/               # filebrowser sqlite database
│   └── config/                 # filebrowser settings
├── homepage/
│   ├── config/                 # homepage dashboard config
│   └── images/                 # custom dashboard images
├── keepalived/                 # keepalived config (directory mount)
│   └── keepalived.conf
├── lubelogger/
│   ├── config/                 # app configuration
│   ├── data/                   # vehicle data
│   ├── temp/                   # temporary files
│   ├── log/                    # application logs
│   ├── keys/                   # data protection keys
│   └── documents/              # uploaded documents
├── mealie/                     # recipe data
├── netalertx/
│   └── data/                   # network scan database
├── ntfy/
│   ├── cache/                  # notification cache
│   └── etc/                    # ntfy server config
├── pihole/
│   ├── etc-pihole/             # pihole config (synced from bender via nebula-sync)
│   └── etc-dnsmasq.d/         # dnsmasq config
├── postgres-backup/            # daily postgresql backups
├── spendspentspent/
│   ├── app-files/              # application files
│   ├── files/                  # user uploaded files
│   └── config/                 # app configuration
├── stirling/
│   ├── trainingData/           # OCR tessdata
│   ├── configs/                # stirling settings
│   └── logs/                   # application logs
├── tsdproxy/
│   ├── data/                   # tailscale state
│   └── config/                 # tsdproxy config
├── trivy/
│   └── cache/                  # vulnerability database cache
├── valkey/                     # redis-compatible key-value data
└── wallos/
    └── db/                     # subscription tracker sqlite database
```

---

## legacy paths — /portainer/

```
/portainer/
├── postgresql/
│   └── data/                   # CRITICAL — all application databases
│                               # databases: atuin, miniflux, sss, mealie, stirling
│                               # consumer: postgres (/var/lib/postgresql/data)
└── telegraf/
    └── config/
        └── telegraf.conf       # SNMP monitoring config
                                # consumer: telegraf (/etc/telegraf/telegraf.conf:ro)
```

> **CRITICAL:** `/portainer/postgresql/data/` contains all of amy's application databases. this is the most critical data on amy. it is backed up daily by postgres-backup.

### why legacy paths exist

the postgresql data directory was created at `/portainer/postgresql/data/` during the original portainer-based deployment. changing it to `/docker/postgres/data/` would require stopping all dependent services, moving the data, and updating the volume mount — with risk of data loss. the current path works correctly and is documented here for clarity.

telegraf was originally deployed as a standalone compose file at `/portainer/telegraf/docker-compose.yml` before being consolidated into the main docker-compose.yaml in v98. the config file remains at its original location.

---

## backup data

```
/docker/postgres-backup/            # automated daily backups
├── daily/                          # daily backups (7 day retention)
├── weekly/                         # weekly backups (4 week retention)
├── monthly/                        # monthly backups (6 month retention)
└── last/                           # latest backup per database

/docker/backups/                    # manual backups (created by scripts)
└── postgres/
    └── pre-upgrade/                # pre-upgrade dumps from secure-container-update.sh
```

databases backed up: atuin, miniflux, sss, mealie, stirling.

---

## volume mount reference

### bridge network services (utility-network)

| container | host path | container path | mode |
|-----------|-----------|---------------|------|
| tsdproxy | /var/run/docker.sock | /var/run/docker.sock | rw |
| tsdproxy | /docker/tsdproxy/data | /data | rw |
| tsdproxy | /docker/tsdproxy/config | /config | rw |
| dockwatch | /docker/dockwatch | /config | rw |
| dockwatch | /var/run/docker.sock | /var/run/docker.sock | rw |
| dozzle | /var/run/docker.sock | /var/run/docker.sock | ro |
| pihole | /docker/pihole/etc-pihole | /etc/pihole | rw |
| pihole | /docker/pihole/etc-dnsmasq.d | /etc/dnsmasq.d | rw |
| postgres | /portainer/postgresql/data | /var/lib/postgresql/data | rw |
| postgres-backup | /docker/postgres-backup | /backups | rw |
| valkey | /docker/valkey | /data | rw |
| ntfy | /docker/ntfy/cache | /var/cache/ntfy | rw |
| ntfy | /docker/ntfy/etc | /etc/ntfy | rw |
| stirling | /docker/stirling/trainingData | /usr/share/tessdata | rw |
| stirling | /docker/stirling/configs | /configs | rw |
| stirling | /docker/stirling/logs | /logs | rw |
| homepage | /docker/homepage/config | /app/config | rw |
| homepage | /docker/homepage/images | /app/public/images | rw |
| homepage | /var/run/docker.sock | /var/run/docker.sock | ro |
| miniflux | (none) | | |
| it-tools | (none) | | |
| filebrowser | /docker/filebrowser/database | /database | rw |
| filebrowser | /docker/filebrowser/config | /config | rw |
| filebrowser | /docker | /srv/docker | rw |
| filebrowser | /portainer | /srv/portainer | rw |
| wallos | /docker/wallos/db | /var/www/html/db | rw |
| mealie | /docker/mealie | /app/data | rw |
| argus | /docker/argus | /app/data | rw |
| lubelogger | /docker/lubelogger/config | /App/config | rw |
| lubelogger | /docker/lubelogger/data | /App/data | rw |
| lubelogger | /docker/lubelogger/temp | /App/wwwroot/temp | rw |
| lubelogger | /docker/lubelogger/log | /App/log | rw |
| lubelogger | /docker/lubelogger/keys | /root/.aspnet/DataProtection-Keys | rw |
| lubelogger | /docker/lubelogger/documents | /App/wwwroot/documents | rw |
| spendspentspent | /etc/localtime | /etc/localtime | ro |
| spendspentspent | /docker/spendspentspent/app-files | /app-files | rw |
| spendspentspent | /docker/spendspentspent/files | /files | rw |
| spendspentspent | /docker/spendspentspent/config | /config | rw |
| limdius | /docker/limdius | /app | rw |
| beszel | /docker/beszel/data | /beszel_data | rw |
| cadvisor | / | /rootfs | ro |
| cadvisor | /var/run | /var/run | ro |
| cadvisor | /sys | /sys | ro |
| cadvisor | /var/lib/docker/ | /var/lib/docker | ro |
| diun | /docker/diun/data | /data | rw |
| diun | /var/run/docker.sock | /var/run/docker.sock | ro |
| trivy | /docker/trivy/cache | /tmp/trivy | rw |
| trivy | /var/run/docker.sock | /var/run/docker.sock | ro |
| playwright-chrome | (none) | | |

### host network services

| container | host path | container path | mode |
|-----------|-----------|---------------|------|
| keepalived | /docker/keepalived | /container/service/keepalived/assets | rw |
| beszel-agent | /var/run/docker.sock | /var/run/docker.sock | ro |
| netalertx | /docker/netalertx/data | /data | rw |
| telegraf | /portainer/telegraf/config/telegraf.conf | /etc/telegraf/telegraf.conf | ro |

### services with no volumes

miniflux, it-tools, atuin, playwright-chrome — no persistent volumes (miniflux and atuin store data in postgres).

---

## network mode reference

| mode | services |
|------|----------|
| bridge (utility-network) | tsdproxy, dockwatch, dozzle, pihole, postgres, postgres-backup, valkey, ntfy, stirling, homepage, atuin, miniflux, it-tools, filebrowser, wallos, mealie, argus, lubelogger, spendspentspent, limdius, playwright-chrome, beszel, cadvisor, diun, trivy |
| host | keepalived, beszel-agent, netalertx, telegraf |

---

## path conventions

| convention | example |
|------------|---------|
| compose and scripts under `/docker-compose/` | `/docker-compose/docker-compose.yaml` |
| container data under `/docker/<service>/` | `/docker/ntfy/cache/` |
| legacy postgresql data at `/portainer/` | `/portainer/postgresql/data/` |
| legacy telegraf config at `/portainer/` | `/portainer/telegraf/config/telegraf.conf` |
| backups under `/docker/postgres-backup/` | `/docker/postgres-backup/daily/` |
| configs for repo under `/docker-compose/configs/` | `/docker-compose/configs/keepalived/` |

---

*previous: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
*next: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
