# amy directory structure

## complete file system layout

**document version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

---

## table of contents

1. [overview](#overview)
2. [docker-compose directory](#docker-compose-directory)
3. [service data – /docker](#service-data--docker)
4. [legacy paths – /portainer](#legacy-paths--portainer)
5. [bender replica](#bender-replica)
6. [volume mount reference](#volume-mount-reference)
7. [network mode reference](#network-mode-reference)
8. [path conventions](#path-conventions)

---

## overview

amy's layout is flat and plain-Linux: no ZFS, no noexec, no execution workarounds. three roots matter:

| path | purpose |
|------|---------|
| `/docker-compose/` | compose file, .env, scripts |
| `/docker/` | per-service data and config volumes |
| `/portainer/` | **legacy** – two canonical stragglers (postgres data, telegraf config) |

---

## docker-compose directory

```
/docker-compose/
├── docker-compose.yaml             # 20260810.2 – 31 defined, 25 running
├── .env                            # 16 variables (see 05); git copy is .env.gpg
└── scripts/
    ├── secure-container-update.sh  # v1.2 – update orchestration
    ├── health-checks.sh            # v1.0
    └── rollback.sh                 # v1.0
```

scripts execute directly (`./script.sh` or via crontab) – no bash-prefix ritual, no UI cron. root's crontab is the scheduler and, unlike TrueNAS, Debian does not eat it on upgrade. <!-- VERIFY: capture crontab -l into this doc at next revision -->

state directories for the update system (critical-containers.json, retry-queue.json, logs, scan-reports) live under the script's configured state path. <!-- VERIFY: exact path – bender keeps them under docker-compose/configs/secure-update/; confirm amy's equivalent -->

---

## service data – /docker

```
/docker/
├── argus/                  # config.yml + data
├── backups/
│   └── bender-replica/     # bender's nightly rsync target (see below)
├── beszel/data/            # hub state
├── diun/data/
├── dockwatch/
├── filebrowser/{database,config}
├── homepage/{config,images}
├── keepalived/keepalived.conf   # BACKUP config – VRRP password INLINE (keep out of git)
├── lubelogger/{config,data,temp,log,keys,documents}
├── mealie/                 # app data (db is in postgres)
├── ntfy/{cache,etc}
├── oxidized/               # config + router.db (contains the GitHub PAT – never commit)
├── pihole/{etc-pihole,etc-dnsmasq.d}   # overwritten hourly by nebula-sync from bender
├── postgres-backup/        # daily dumps: atuin, miniflux, sss, mealie, stirling
├── spendspentspent/{app-files,files,config}
├── stirling/{trainingData,configs,logs}
├── tax/html/               # static tax calculator site (nginx, ro)
├── trivy/cache/
├── tsdproxy/{data,config}  # tailscale state
├── valkey/
└── wallos/db/
```

---

## legacy paths – /portainer

```
/portainer/
├── postgresql/data/        # CRITICAL – the LIVE postgres data directory
│                           # (v94 restored this path; moving it buys nothing)
└── telegraf/config/telegraf.conf   # canonical telegraf config (v98 kept the path)
```

these predate the single-compose consolidation. they are **canonical**, not garbage – the v94 incident (a "clean" /docker/postgres/data path that orphaned the real databases) is the standing warning against tidying them casually. any future migration is a deliberate, dump-restore-verify operation.

---

## bender replica

```
/docker/backups/bender-replica/
├── configs/                # every bender service config (vaultwarden, forgejo, pihole, …)
├── backups/postgres/       # bender's five-database dumps
└── docker-compose/         # bender's compose, .env, and all six scripts
```

written nightly at 03:30 by bender-replicate.sh over SSH (kube-owned destination), 7-day retention managed from the bender side. amy's responsibilities: keep `kube`'s SSH trust for bender's root key, keep disk space available, be up at 03:30. **this directory contains bender's secrets (.env)** – amy's disk hygiene now matters to bender's security posture.

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
| oxidized | /docker/oxidized | /home/oxidized/.config/oxidized | rw |
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
| homepage | /docker/homepage | /app/config | rw |
| homepage | /docker/homepage/images | /app/public/images | rw |
| homepage | /var/run/docker.sock | /var/run/docker.sock | ro |
| miniflux | (none – db in postgres) | | |
| it-tools | (none) | | |
| filebrowser | /docker/filebrowser/database | /database | rw |
| filebrowser | /docker/filebrowser/config | /config | rw |
| filebrowser | /docker | /srv/docker | rw |
| filebrowser | /portainer | /srv/portainer | rw |
| wallos | /docker/wallos/db | /var/www/html/db | rw |
| mealie | /docker/mealie | /app/data | rw |
| argus | /docker/argus/config.yml | /app/config.yml | rw |
| argus | /docker/argus | /app/data | rw |
| lubelogger | /docker/lubelogger/* | /App/* (+ keys, documents) | rw |
| spendspentspent | /etc/localtime | /etc/localtime | ro |
| spendspentspent | /docker/spendspentspent/{app-files,files,config} | /app-files, /files, /config | rw |
| tax-calculator | /docker/tax/html | /usr/share/nginx/html | ro |
| limdius | /docker/limdius | /app | rw |
| playwright-chrome | (none) | | |
| beszel | /docker/beszel/data | /beszel_data | rw |
| cadvisor | /, /var/run, /sys, /var/lib/docker/ | /rootfs, /var/run, /sys, /var/lib/docker | ro |
| diun | /docker/diun/data | /data | rw |
| diun | /var/run/docker.sock | /var/run/docker.sock | ro |
| trivy | /docker/trivy/cache | /tmp/trivy | rw |
| trivy | /var/run/docker.sock | /var/run/docker.sock | ro |
| atuin | (none – db in postgres) | | |

### host network services

| container | host path | container path | mode |
|-----------|-----------|---------------|------|
| keepalived | /docker/keepalived/keepalived.conf | /etc/keepalived/keepalived.conf | rw mount of a file |
| beszel-agent | /var/run/docker.sock | /var/run/docker.sock | ro |
| netalertx | /docker/netalertx/data | /data | rw |
| telegraf | /portainer/telegraf/config/telegraf.conf | /etc/telegraf/telegraf.conf | ro |

---

## network mode reference

| mode | services |
|------|----------|
| bridge (utility-network) | tsdproxy, dockwatch, dozzle, oxidized, pihole, postgres, postgres-backup, valkey, ntfy, stirling, homepage, atuin, miniflux, it-tools, filebrowser, wallos, mealie, argus, lubelogger, spendspentspent, tax-calculator, limdius, playwright-chrome, beszel, cadvisor, diun, trivy |
| host | keepalived, beszel-agent, netalertx, telegraf |

---

## path conventions

| convention | example |
|------------|---------|
| service data under `/docker/<service>/` | `/docker/ntfy/` |
| compose + scripts under `/docker-compose/` | `/docker-compose/scripts/rollback.sh` |
| legacy `/portainer` paths are canonical until deliberately migrated | postgres data, telegraf config |
| bender's replica under `/docker/backups/bender-replica/` | owned by kube |
| secrets never in git-tracked config files | keepalived.conf auth_pass, oxidized PAT |


---

## decoy and out-of-tree paths

three paths on amy are not what they appear to be. each cost real
diagnostic time.

### /portainer/tsdproxy – DECOY

a leftover from amy's Portainer era. it contains a plausible
`config/tsdproxy.yaml` and a `data/` directory, and **nothing reads
either**. the live path is `/docker/tsdproxy/`.

confirm which file a container actually reads before editing it:

```bash
docker inspect tsdproxy --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
```

on 2026-08-08 a Tailscale key rotation was applied to the decoy. the
symptom was tsdproxy names failing while the config looked correct.

### /portainer/postgresql/data – LIVE, and canonical

not a decoy. this is amy's real postgres data directory, mounted by the
postgres container. the v94 fix restored this path after a move to
`/docker/postgres` lost access to the databases. **do not "tidy" it.**

### /portainer/telegraf/config/telegraf.conf – LIVE, outside /docker

telegraf's SNMP configuration for nod and the Brother printer. it holds
community strings. because it sits outside `/docker`, it was in no backup
scope until the git manifest added it on 2026-08-10.

### /docker/homepage vs /docker/homepage/config

the authored dashboard files live in `/docker/homepage`:
`services.yaml`, `bookmarks.yaml`, `widgets.yaml`, `docker.yaml`,
`proxmox.yaml`, `custom.css`, `custom.js`.

the `config/` subdirectory held only `kubernetes.yaml` and `settings.yaml`,
which homepage generated itself. the mount pointed there until 20260810,
so homepage rendered an empty dashboard.

---

## authored code held in mounts

two containers run code from a host mount rather than from their image.
both are authored and both belong in a backup scope.

| path | consumed by | note |
|------|-------------|------|
| /docker/limdius/limdius.py | limdius | the container pip-installs its dependencies at every start, then runs this file |
| /docker/tax/html/ | tax-calculator | a static site served read-only by nginx:alpine |

---

*previous: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
*next: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
