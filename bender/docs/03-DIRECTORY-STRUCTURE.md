# bender directory structure

## file system layout and storage paths

**document version:** 1.0  
**infrastructure version:** 86  
**last updated:** january 10, 2026

---

## table of contents

1. [overview](#overview)
2. [ZFS pool structure](#zfs-pool-structure)
3. [docker compose directory](#docker-compose-directory)
4. [container config volumes](#container-config-volumes)
5. [media storage](#media-storage)
6. [nfs exports](#nfs-exports)
7. [permissions](#permissions)

---

## overview

bender uses TrueNAS Scale with a ZFS pool named "BIG" as the primary storage. all data, configuration, and docker compose files are stored under `/mnt/BIG/filme/`.

### key paths

| path | purpose |
|------|---------|
| `/mnt/BIG/` | ZFS pool root |
| `/mnt/BIG/filme/` | main data directory |
| `/mnt/BIG/filme/docker-compose/` | compose files, scripts, backups |
| `/mnt/BIG/filme/configs/` | container configuration volumes |

---

## ZFS pool structure

### complete directory tree

```
/mnt/BIG/                               # ZFS pool root
└── filme/                              # main data directory
    ├── docker-compose/                 # docker compose configuration
    │   ├── docker-compose.yaml         # main compose file (v86)
    │   ├── .env                        # environment variables
    │   ├── scripts/                    # operational scripts
    │   │   ├── secure-container-update.sh
    │   │   ├── health-checks.sh
    │   │   └── rollback.sh
    │   ├── configs/                    # update system state
    │   │   └── secure-update/
    │   │       ├── critical-containers.json
    │   │       ├── retry-queue.json
    │   │       ├── logs/
    │   │       └── scan-reports/
    │   └── backups/                    # database backups
    │       └── postgres/
    │           ├── daily/
    │           └── weekly/
    │
    ├── configs/                        # container config volumes
    │   ├── postgresql/
    │   │   └── init/                   # init scripts
    │   ├── tsdproxy/
    │   │   ├── config/
    │   │   └── data/tailscale/
    │   ├── pihole/
    │   │   ├── etc-pihole/
    │   │   └── etc-dnsmasq.d/
    │   ├── keepalived/
    │   │   └── keepalived.conf
    │   ├── jellyfin/
    │   │   ├── config/
    │   │   └── cache/
    │   ├── transmission/
    │   │   └── config/
    │   ├── sonarr/
    │   ├── radarr/
    │   ├── prowlarr/
    │   ├── bazarr/
    │   ├── lidarr/
    │   ├── readarr/
    │   ├── unpackerr/
    │   ├── hedgedoc/
    │   │   └── uploads/
    │   ├── metube/
    │   ├── diun/
    │   │   ├── data/
    │   │   └── config/
    │   ├── trivy/
    │   │   └── cache/
    │   ├── dockwatch/
    │   └── beszel-agent/
    │
    ├── immich/                         # immich data (special structure)
    │   ├── upload/                     # user uploads
    │   ├── library/                    # processed library
    │   ├── model-cache/                # ml model cache
    │   └── postgresql/                 # immich database
    │       └── data/
    │
    ├── filme/                          # movies
    ├── seriale/                        # tv shows
    ├── music/                          # music library
    ├── books/                          # ebooks & audiobooks
    │   ├── ebooks/
    │   └── audiobooks/
    ├── transmission/                   # downloads
    │   ├── completed/
    │   ├── incomplete/
    │   └── watch/
    ├── syncthing/                      # syncthing data + config
    ├── spotdl/                         # music downloads
    └── audiobookshelf/                 # audiobook library
        ├── config/
        └── metadata/
```

---

## docker compose directory

### location: /mnt/BIG/filme/docker-compose/

| file/directory | purpose |
|----------------|---------|
| `docker-compose.yaml` | main compose file (v86) |
| `.env` | environment variables with secrets |
| `scripts/` | operational scripts |
| `configs/secure-update/` | update system state files |
| `backups/postgres/` | postgresql backup storage |

### scripts directory

| script | version | purpose |
|--------|---------|---------|
| `secure-container-update.sh` | 1.2 | orchestrated container updates |
| `health-checks.sh` | 1.0 | service health verification |
| `rollback.sh` | 1.0 | manual rollback helper |

### update system state

```
configs/secure-update/
├── critical-containers.json    # containers requiring special handling
├── retry-queue.json           # failed updates pending retry
├── logs/                      # daily update logs
│   ├── 2026-01-10.log
│   └── ...
└── scan-reports/              # trivy vulnerability reports
    ├── postgres-2026-01-10.json
    └── ...
```

---

## container config volumes

### location: /mnt/BIG/filme/configs/

each container has its configuration stored in a dedicated subdirectory.

### infrastructure configs

| directory | container | contents |
|-----------|-----------|----------|
| `postgresql/` | postgres | database data, init scripts |
| `tsdproxy/` | tsdproxy | tailscale state, config |
| `pihole/` | pihole | dns config, blocklists |
| `keepalived/` | keepalived | vrrp configuration |

### media configs

| directory | container | contents |
|-----------|-----------|----------|
| `jellyfin/` | jellyfin | library metadata, cache |
| `metube/` | metube | download config |

### download configs

| directory | container | contents |
|-----------|-----------|----------|
| `transmission/` | transmission | client config, blocklists |
| `sonarr/` | sonarr | library, logs, config |
| `radarr/` | radarr | library, logs, config |
| `prowlarr/` | prowlarr | indexer config |
| `bazarr/` | bazarr | subtitle config |
| `lidarr/` | lidarr | library, logs, config |
| `readarr/` | readarr | library, logs, config |
| `unpackerr/` | unpackerr | extraction config |

### productivity configs

| directory | container | contents |
|-----------|-----------|----------|
| `hedgedoc/` | hedgedoc | uploads, config |
| `syncthing/` | syncthing | combined config + data |

### update configs

| directory | container | contents |
|-----------|-----------|----------|
| `diun/` | diun | state, notifications config |
| `trivy/` | trivy | vulnerability database cache |

---

## media storage

### location: /mnt/BIG/filme/

| directory | purpose | estimated size |
|-----------|---------|----------------|
| `filme/` | movies | ~500GB+ |
| `seriale/` | tv shows | ~1TB+ |
| `music/` | music library | ~100GB+ |
| `books/ebooks/` | ebooks | ~50GB+ |
| `books/audiobooks/` | audiobooks | ~200GB+ |
| `immich/` | photos & videos | variable |
| `transmission/` | active downloads | variable |

### immich storage structure

```
immich/
├── upload/                     # original uploads (preserve)
├── library/                    # processed files
├── model-cache/                # ml models (can regenerate)
└── postgresql/                 # database (critical - backup)
    └── data/
```

**critical:** the `immich/postgresql/` directory contains the actual database and must be backed up regularly.

---

## nfs exports

### exported to amy

bender exports the following paths via nfs to amy:

| export path | amy mount point | purpose |
|-------------|-----------------|---------|
| `/mnt/BIG/filme/` | `/portainer/jellyfin/filme_bender/` | media access |

### nfs configuration

```
/mnt/BIG/filme    192.168.21.130(rw,sync,no_subtree_check,no_root_squash)
```

### usage on amy

amy mounts bender's storage for:
- homepage media statistics
- backup verification
- cross-host file access

---

## permissions

### standard ownership

| path | owner | group | permissions |
|------|-------|-------|-------------|
| `/mnt/BIG/filme/` | 1000 (filme) | 1000 (filme) | 755 |
| `/mnt/BIG/filme/docker-compose/` | root | root | 755 |
| `/mnt/BIG/filme/docker-compose/.env` | root | root | 600 |
| `/mnt/BIG/filme/configs/` | 1000 | 1000 | 755 |
| `/mnt/BIG/filme/immich/postgresql/` | 70 (postgres) | 70 | 700 |

### container user mapping

| container | uid:gid | notes |
|-----------|---------|-------|
| most containers | 1000:1000 | standard puid/pgid |
| postgresql | 70:70 | postgres user |
| pihole | 999:999 | pihole user |
| transmission | 1000:1000 | via puid/pgid |

### fixing permissions

```bash
# fix general media permissions
chown -R 1000:1000 /mnt/BIG/filme/{filme,seriale,music,books}

# fix config permissions
chown -R 1000:1000 /mnt/BIG/filme/configs

# fix immich database permissions
chown -R 70:70 /mnt/BIG/filme/immich/postgresql

# fix .env permissions
chmod 600 /mnt/BIG/filme/docker-compose/.env
```

---

## backup considerations

### critical data (must backup)

| path | priority | frequency |
|------|----------|-----------|
| `/mnt/BIG/filme/docker-compose/.env` | critical | after changes |
| `/mnt/BIG/filme/docker-compose/docker-compose.yaml` | critical | after changes |
| `/mnt/BIG/filme/immich/postgresql/` | critical | daily |
| `/mnt/BIG/filme/configs/` | high | weekly |

### regeneratable (can skip backup)

| path | reason |
|------|--------|
| `immich/model-cache/` | downloaded on demand |
| `trivy/cache/` | vulnerability db auto-updates |
| `jellyfin/cache/` | regenerated from media |

---

*previous: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*  
*next: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
