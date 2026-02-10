# amy directory structure

## complete file system layout

**document version:** 2.0
**infrastructure version:** 98
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [docker-compose directory](#docker-compose-directory)
3. [container data — /docker/](#container-data--docker)
4. [legacy paths — /portainer/](#legacy-paths--portainer)
5. [volume mount reference](#volume-mount-reference)
6. [network mode reference](#network-mode-reference)
7. [path conventions](#path-conventions)

---

## overview

amy uses two primary data locations for container storage:

| path | purpose | notes |
|------|---------|-------|
| `/docker-compose/` | compose files, .env, scripts | working directory for `docker compose` commands |
| `/docker/` | container persistent data | main data path for most services |
| `/portainer/` | legacy data paths | postgres and telegraf data (historical, do not move) |

the split between `/docker/` and `/portainer/` is historical — postgres and telegraf data existed under `/portainer/` before the main compose file was consolidated. moving these would require database migration and downtime, so the paths are preserved as-is.

---

## docker-compose directory

```
/docker-compose/
├── docker-compose.yaml          # v98 — main compose file (31 services)
├── .env                         # environment variables (16 variables)
└── scripts/
    ├── secure-container-update.sh   # automated update orchestration
    ├── health-checks.sh             # post-update health verification
    └── rollback.sh                  # rollback helper
```

---

## container data — /docker/

this is the primary data directory for amy's containers. each service gets its own subdirectory.

```
/docker/
├── beszel/
│   └── data/                    # beszel hub database and state
├── diun/
│   └── data/                    # image update tracking database
├── dockwatch/                   # dockwatch configuration
├── dozzle/                      # (no persistent data — reads docker.sock only)
├── filebrowser/
│   ├── database/                # filebrowser sqlite database
│   └── config/                  # filebrowser settings
├── homepage/
│   ├── config/                  # homepage dashboard configuration (services.yaml, etc.)
│   └── images/                  # custom dashboard images
├── keepalived/                  # keepalived vrrp configuration
├── lubelogger/
│   ├── config/                  # application configuration
│   ├── data/                    # vehicle and maintenance records
│   ├── temp/                    # temporary upload files
│   ├── log/                     # application logs
│   ├── keys/                    # ASP.NET data protection keys
│   └── documents/               # uploaded documents
├── limdius/                     # limdius application code and data
├── mealie/                      # mealie recipe data (/app/data)
├── netalertx/
│   └── data/                    # network device scan database
├── ntfy/
│   ├── cache/                   # notification message cache
│   └── etc/                     # ntfy server configuration
├── pihole/
│   ├── etc-pihole/              # pihole configuration and database
│   └── etc-dnsmasq.d/          # dnsmasq overrides
├── postgres-backup/             # daily postgresql backup files
├── spendspentspent/
│   ├── app-files/               # application runtime files
│   ├── files/                   # uploaded receipt files
│   └── config/                  # application configuration
├── stirling/
│   ├── trainingData/            # tessdata OCR language files
│   ├── configs/                 # stirling-pdf settings
│   └── logs/                    # application logs
├── trivy/
│   └── cache/                   # vulnerability database cache
├── tsdproxy/
│   ├── data/                    # tailscale state and certificates
│   └── config/                  # tsdproxy configuration
├── valkey/                      # valkey (redis-compatible) append-only data
└── wallos/
    └── db/                      # wallos sqlite subscription database
```

---

## legacy paths — /portainer/

these paths predate the consolidated docker-compose setup. they contain production data and must not be relocated without a planned migration.

```
/portainer/
├── postgresql/
│   └── data/                    # postgresql 17 data directory
│                                # databases: atuin, miniflux, sss, mealie, stirling
│                                # ⚠️ DO NOT MOVE — actively used by postgres container
└── telegraf/
    └── config/
        └── telegraf.conf        # telegraf SNMP configuration (read-only mount)
                                 # monitors: cisco 3750x switch, brother mfc-l3710cw printer
                                 # ⚠️ DO NOT MOVE — referenced by telegraf container
```

### why these paths exist

when amy was initially set up, services were managed through portainer stacks. the postgres database and telegraf configuration were created under `/portainer/`. when the infrastructure was consolidated into a single docker-compose file (v94+), these paths were preserved to avoid data loss and downtime.

---

## volume mount reference

### services with bridge network (utility-network)

| service | container path | host path | mode |
|---------|---------------|-----------|------|
| tsdproxy | /data | /docker/tsdproxy/data | rw |
| tsdproxy | /config | /docker/tsdproxy/config | rw |
| dockwatch | /config | /docker/dockwatch | rw |
| dozzle | /var/run/docker.sock | /var/run/docker.sock | ro |
| pihole | /etc/pihole | /docker/pihole/etc-pihole | rw |
| pihole | /etc/dnsmasq.d | /docker/pihole/etc-dnsmasq.d | rw |
| postgres | /var/lib/postgresql/data | /portainer/postgresql/data | rw |
| postgres-backup | /backups | /docker/postgres-backup | rw |
| valkey | /data | /docker/valkey | rw |
| ntfy | /var/cache/ntfy | /docker/ntfy/cache | rw |
| ntfy | /etc/ntfy | /docker/ntfy/etc | rw |
| stirling | /usr/share/tessdata | /docker/stirling/trainingData | rw |
| stirling | /configs | /docker/stirling/configs | rw |
| stirling | /logs | /docker/stirling/logs | rw |
| homepage | /app/config | /docker/homepage/config | rw |
| homepage | /app/public/images | /docker/homepage/images | rw |
| homepage | /var/run/docker.sock | /var/run/docker.sock | ro |
| filebrowser | /database | /docker/filebrowser/database | rw |
| filebrowser | /config | /docker/filebrowser/config | rw |
| filebrowser | /srv/docker | /docker | rw |
| filebrowser | /srv/portainer | /portainer | rw |
| wallos | /var/www/html/db | /docker/wallos/db | rw |
| mealie | /app/data | /docker/mealie | rw |
| argus | /app/data | /docker/argus | rw |
| lubelogger | /App/config | /docker/lubelogger/config | rw |
| lubelogger | /App/data | /docker/lubelogger/data | rw |
| lubelogger | /App/wwwroot/temp | /docker/lubelogger/temp | rw |
| lubelogger | /App/log | /docker/lubelogger/log | rw |
| lubelogger | /root/.aspnet/DataProtection-Keys | /docker/lubelogger/keys | rw |
| lubelogger | /App/wwwroot/documents | /docker/lubelogger/documents | rw |
| spendspentspent | /app-files | /docker/spendspentspent/app-files | rw |
| spendspentspent | /files | /docker/spendspentspent/files | rw |
| spendspentspent | /config | /docker/spendspentspent/config | rw |
| spendspentspent | /etc/localtime | /etc/localtime | ro |
| limdius | /app | /docker/limdius | rw |
| beszel | /beszel_data | /docker/beszel/data | rw |
| cadvisor | /rootfs | / | ro |
| cadvisor | /var/run | /var/run | ro |
| cadvisor | /sys | /sys | ro |
| cadvisor | /var/lib/docker | /var/lib/docker | ro |
| diun | /data | /docker/diun/data | rw |
| diun | /var/run/docker.sock | /var/run/docker.sock | ro |
| trivy | /tmp/trivy | /docker/trivy/cache | rw |
| trivy | /var/run/docker.sock | /var/run/docker.sock | ro |

### services with host network

| service | container path | host path | mode |
|---------|---------------|-----------|------|
| keepalived | /container/service/keepalived/assets | /docker/keepalived | rw |
| beszel-agent | /var/run/docker.sock | /var/run/docker.sock | ro |
| netalertx | /data | /docker/netalertx/data | rw |
| telegraf | /etc/telegraf/telegraf.conf | /portainer/telegraf/config/telegraf.conf | ro |

---

## network mode reference

most services use the `utility-network` bridge. some require host networking for their function:

| service | network mode | reason |
|---------|-------------|--------|
| keepalived | host | needs direct access to network interfaces for vrrp |
| beszel-agent | host | needs access to host metrics (cpu, memory, disk) |
| netalertx | host | needs arp scanning capability on the local network |
| telegraf | host | needs direct network access for SNMP polling |
| all others | utility-network (bridge) | standard container isolation with dns anchor |

the dns anchor (`x-dns: &default-dns`) points all bridge-networked services to `192.168.21.100` (keepalived vip), ensuring DNS resolution works through the pihole ha pair. host-networked services use the host's own DNS configuration.

---

## path conventions

### naming rules

- all container data lives under `/docker/<service-name>/`
- subdirectories match the container's internal mount purpose (e.g., `/config`, `/data`)
- legacy paths under `/portainer/` are frozen — no new services should use this location

### backup considerations

| path | backup method | frequency |
|------|--------------|-----------|
| `/docker-compose/` | git repository (futurama-docker) | on change |
| `/docker/postgres-backup/` | automated by postgres-backup container | daily |
| `/portainer/postgresql/data/` | backed up via postgres-backup container | daily |
| `/docker/` (all other) | manual or scheduled backup | as needed |
| `/portainer/telegraf/config/` | git repository (futurama-docker) | on change |

### disk usage notes

the largest consumers of disk space on amy are typically:
- `/portainer/postgresql/data/` — database files (atuin history can grow significantly)
- `/docker/trivy/cache/` — vulnerability database cache (can be safely cleared)
- `/docker/postgres-backup/` — retained backups (7 daily, 4 weekly, 6 monthly)
- `/docker/stirling/trainingData/` — OCR language files

---

*previous: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
*next: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
