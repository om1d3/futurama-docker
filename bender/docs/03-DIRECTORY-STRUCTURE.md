# bender directory structure

## complete file system layout

**document version:** 3.0
**infrastructure version:** 109
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [docker-compose directory](#docker-compose-directory)
3. [container configurations — configs/](#container-configurations--configs)
4. [build contexts](#build-contexts)
5. [media libraries](#media-libraries)
6. [immich data](#immich-data)
7. [text-to-speech data](#text-to-speech-data)
8. [download data](#download-data)
9. [backup data](#backup-data)
10. [volume mount reference](#volume-mount-reference)
11. [network mode reference](#network-mode-reference)
12. [path conventions](#path-conventions)
13. [TrueNAS-specific notes](#truenas-specific-notes)

---

## overview

all of bender's container data lives under a single ZFS path: `/mnt/BIG/filme/`. this is the root of the ZFS pool `BIG`, dataset `filme`.

| path | purpose |
|------|---------|
| `/mnt/BIG/filme/docker-compose/` | compose file, .env, scripts |
| `/mnt/BIG/filme/configs/` | per-service configuration volumes |
| `/mnt/BIG/filme/immich/` | immich photos, database, redis, ML cache |
| `/mnt/BIG/filme/filme/` | movie library |
| `/mnt/BIG/filme/seriale/` | TV show library |
| `/mnt/BIG/filme/music/` | music library |
| `/mnt/BIG/filme/books/` | ebook library |
| `/mnt/BIG/filme/audiobookshelf/` | audiobooks, podcasts, metadata |
| `/mnt/BIG/filme/tts/` | TTS input directories (4 voice folders) |
| `/mnt/BIG/filme/transmission/` | torrent downloads |
| `/mnt/BIG/filme/backups/` | database backups |
| `/mnt/BIG/filme/syncthing/` | syncthing data + config |
| `/mnt/BIG/filme/metube/` | youtube downloads |
| `/mnt/BIG/filme/jdownloader/` | jdownloader output |
| `/mnt/BIG/filme/spotdl/` | spotify downloads |

the naming convention (`/mnt/BIG/filme/filme/` for movies) is historical — `filme` is the Romanian word for "films/movies". the outer `filme` is the ZFS dataset name, the inner `filme` is the movie library directory.

---

## docker-compose directory

```
/mnt/BIG/filme/docker-compose/
├── docker-compose.yaml             # v109 — main compose file (36 services)
├── .env                            # environment variables (28 variables)
└── scripts/
    ├── secure-container-update.sh  # v1.2 — automated update orchestration
    ├── health-checks.sh            # v1.2 — post-update health verification
    ├── rollback.sh                 # v1.1 — rollback helper
    └── pihole-dns-update.sh        # v3.0 — reference copy (executable at /root/)
```

> **note:** on TrueNAS, scripts under `/mnt/` cannot be executed directly due to filesystem restrictions. the secure-container-update.sh cron job copies the script to `/tmp/` before execution. the pihole-dns-update.sh executable lives at `/root/pihole-dns-update.sh`.

---

## container configurations — configs/

```
/mnt/BIG/filme/configs/
├── audiobookshelf/             # audiobookshelf config
├── bazarr/                     # subtitle manager config
├── diun/                       # image update notifier data
├── dockwatch/                  # container management config
├── epub2tts-edge/              # v108: epub2tts-edge build context
│   └── Dockerfile
├── gluetun/                    # VPN client state
├── hedgedoc/
│   └── uploads/                # hedgedoc uploaded files
├── jdownloader/                # jdownloader config
├── jellyfin/                   # media server config + cache
├── keepalived/
│   └── keepalived.conf         # VRRP master config (bond0, priority 200)
├── lidarr/                     # music automation config
├── pihole/
│   ├── etc-pihole/             # pihole config (includes pihole.toml)
│   └── etc-dnsmasq.d/         # dnsmasq config
├── postgres/
│   └── init/                   # init scripts (read-only mount)
├── prowlarr/                   # indexer manager config
├── radarr/                     # movie automation config
├── readarr/                    # ebook automation config
├── sonarr/                     # tv automation config
├── transmission/               # v108: custom build context
│   ├── Dockerfile              # pre-baked Flood UI build
│   └── ...                     # transmission config files
├── trivy/                      # vulnerability scanner cache
├── tsdproxy/
│   ├── data/tailscale/         # tailscale state
│   └── config/                 # tsdproxy config
├── tts-pipeline/               # v108: tts-pipeline build context
│   ├── Dockerfile              # Flask web UI + pipeline.sh
│   ├── pipeline.sh             # filesystem watcher script
│   ├── webapp.py               # v109: Flask web interface
│   └── start.sh                # v109: entrypoint (starts both watcher + web)
└── vaultwarden/                # password manager data
```

---

## build contexts

three containers use `build:` directives instead of pre-built images. their Dockerfiles and supporting files live under `/mnt/BIG/filme/configs/`:

| container | build context | key files |
|-----------|--------------|-----------|
| transmission | `/mnt/BIG/filme/configs/transmission/` | Dockerfile (base: lscr.io/linuxserver/transmission:4.0.5, adds Flood UI) |
| tts-pipeline | `/mnt/BIG/filme/configs/tts-pipeline/` | Dockerfile, pipeline.sh, webapp.py, start.sh |
| epub2tts-edge | `/mnt/BIG/filme/configs/epub2tts-edge/` | Dockerfile (profiles: tools, on-demand only) |

to rebuild after changes:

```bash
cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache <service_name>
docker compose up -d <service_name>
```

---

## media libraries

```
/mnt/BIG/filme/filme/               # movie library
                                    # consumers: jellyfin (/data/movies), radarr (/movies), bazarr (/movies)

/mnt/BIG/filme/seriale/             # TV show library
                                    # consumers: jellyfin (/data/tvshows), sonarr (/tv), bazarr (/tv)

/mnt/BIG/filme/music/               # music library
                                    # consumers: jellyfin (/data/music), lidarr (/music)

/mnt/BIG/filme/books/               # ebook library
                                    # consumers: readarr (/books)
```

---

## immich data

```
/mnt/BIG/filme/immich/
├── photos/                         # original uploaded photos
│                                   # consumer: immich_server (/usr/src/app/upload)
├── postgresql/                     # CRITICAL — immich database
│                                   # consumer: postgres (/var/lib/postgresql/data)
├── redis/                          # redis persistent data
│                                   # consumer: immich_redis (/data)
└── ml-cache/                       # machine learning model cache
                                    # consumer: immich_machine_learning (/cache)
```

> **CRITICAL:** `/mnt/BIG/filme/immich/postgresql` contains the actual immich database with all photo metadata. this path is the most critical data on bender. it is backed up daily by postgres-backup and receives pre-upgrade dumps before any postgres updates.

---

## text-to-speech data

```
/mnt/BIG/filme/tts/
└── input/                          # TTS input directories (v109)
    ├── ro-emil/                    # → ro-RO-EmilNeural (Romanian male)
    ├── ro-alina/                   # → ro-RO-AlinaNeural (Romanian female)
    ├── en-ryan/                    # → en-GB-RyanNeural (British male)
    └── en-sonia/                   # → en-GB-SoniaNeural (British female)
                                    # consumer: tts-pipeline (/input)

/mnt/BIG/filme/audiobookshelf/
├── audiobooks/                     # audiobook library
│   └── cărți/                      # TTS output goes here for automatic pickup
│                                   # consumers: audiobookshelf (/audiobooks), tts-pipeline (/audiobooks)
├── podcasts/                       # podcast library
│                                   # consumer: audiobookshelf (/podcasts)
└── metadata/                       # audiobookshelf metadata
                                    # consumer: audiobookshelf (/metadata)
```

the tts-pipeline watches all 4 input directories and auto-selects the voice based on which directory the file is placed in. output M4B files go to `/audiobooks/cărți/` where audiobookshelf picks them up automatically.

---

## download data

```
/mnt/BIG/filme/transmission/
├── completed/                      # finished downloads
├── incomplete/                     # in-progress downloads
├── watch/                          # torrent file watch directory
└── config/
    └── transmission-home/          # transmission config (/config mount)
                                    # consumers: transmission (/data), sonarr (/downloads),
                                    #            radarr (/downloads), lidarr (/downloads),
                                    #            readarr (/downloads), unpackerr (/downloads)

/mnt/BIG/filme/metube/              # youtube downloads
                                    # consumer: metube (/downloads)

/mnt/BIG/filme/jdownloader/         # jdownloader output
                                    # consumer: jdownloader (/output)

/mnt/BIG/filme/spotdl/              # spotify downloads
                                    # consumer: spotdl (/music)
```

---

## backup data

```
/mnt/BIG/filme/backups/
└── postgres/                       # postgresql backups
    ├── pre-upgrade/                # pre-upgrade dumps (created by secure-container-update.sh)
    └── ...                         # daily/weekly/monthly from postgres-backup container
                                    # consumer: postgres-backup (/backups)
```

retention policy: 7 daily, 4 weekly, 6 monthly backups.

---

## volume mount reference

### bridge network services (media-network)

| container | host path | container path | mode |
|-----------|-----------|---------------|------|
| tsdproxy | /var/run/docker.sock | /var/run/docker.sock | rw |
| tsdproxy | configs/tsdproxy/data/tailscale | /data | rw |
| tsdproxy | configs/tsdproxy/config | /config | rw |
| dockwatch | configs/dockwatch | /config | rw |
| dockwatch | /var/run/docker.sock | /var/run/docker.sock | rw |
| dockerproxy | /var/run/docker.sock | /var/run/docker.sock | ro |
| diun | configs/diun | /data | rw |
| diun | /var/run/docker.sock | /var/run/docker.sock | ro |
| trivy | configs/trivy | /root/.cache/trivy | rw |
| trivy | /var/run/docker.sock | /var/run/docker.sock | ro |
| gluetun | configs/gluetun | /gluetun | rw |
| pihole | configs/pihole/etc-pihole | /etc/pihole | rw |
| pihole | configs/pihole/etc-dnsmasq.d | /etc/dnsmasq.d | rw |
| postgres | immich/postgresql | /var/lib/postgresql/data | rw |
| postgres | configs/postgres/init | /docker-entrypoint-initdb.d | ro |
| postgres-backup | backups/postgres | /backups | rw |
| immich_redis | immich/redis | /data | rw |
| immich_server | immich/photos | /usr/src/app/upload | rw |
| immich_machine_learning | immich/ml-cache | /cache | rw |
| jellyfin | configs/jellyfin | /config | rw |
| jellyfin | filme | /data/movies | rw |
| jellyfin | seriale | /data/tvshows | rw |
| jellyfin | music | /data/music | rw |
| audiobookshelf | configs/audiobookshelf | /config | rw |
| audiobookshelf | audiobookshelf/audiobooks | /audiobooks | rw |
| audiobookshelf | audiobookshelf/podcasts | /podcasts | rw |
| audiobookshelf | audiobookshelf/metadata | /metadata | rw |
| metube | metube | /downloads | rw |
| spotdl | spotdl | /music | rw |
| hedgedoc | configs/hedgedoc/uploads | /hedgedoc/public/uploads | rw |
| vaultwarden | configs/vaultwarden | /data | rw |
| unpackerr | transmission | /downloads | rw |
| flaresolverr | (none) | | |
| edge-tts | (none) | | |
| tts-pipeline | tts/input | /input | rw |
| tts-pipeline | audiobookshelf/audiobooks | /audiobooks | rw |
| cadvisor | / | /rootfs | ro |
| cadvisor | /var/run | /var/run | ro |
| cadvisor | /sys | /sys | ro |
| cadvisor | /var/lib/docker/ | /var/lib/docker | ro |

### gluetun network services (service:gluetun)

| container | host path | container path | mode |
|-----------|-----------|---------------|------|
| transmission | transmission/config/transmission-home | /config | rw |
| transmission | transmission | /data | rw |
| jdownloader | configs/jdownloader | /config | rw |
| jdownloader | jdownloader | /output | rw |
| prowlarr | configs/prowlarr | /config | rw |
| sonarr | configs/sonarr | /config | rw |
| sonarr | seriale | /tv | rw |
| sonarr | transmission | /downloads | rw |
| radarr | configs/radarr | /config | rw |
| radarr | filme | /movies | rw |
| radarr | transmission | /downloads | rw |
| lidarr | configs/lidarr | /config | rw |
| lidarr | music | /music | rw |
| lidarr | transmission | /downloads | rw |
| readarr | configs/readarr | /config | rw |
| readarr | books | /books | rw |
| readarr | transmission | /downloads | rw |
| bazarr | configs/bazarr | /config | rw |
| bazarr | filme | /movies | rw |
| bazarr | seriale | /tv | rw |

### host network services

| container | host path | container path | mode |
|-----------|-----------|---------------|------|
| keepalived | configs/keepalived/keepalived.conf | /container/service/keepalived/assets/keepalived.conf | ro |
| syncthing | syncthing | /var/syncthing | rw |
| beszel-agent | /var/run/docker.sock | /var/run/docker.sock | ro |

### standalone services

| container | host path | container path | mode |
|-----------|-----------|---------------|------|
| autoheal | /var/run/docker.sock | /var/run/docker.sock | rw |

### services with no volumes

nebula-sync, flaresolverr, edge-tts — no persistent volumes.

---

## network mode reference

| mode | services |
|------|----------|
| bridge (media-network) | tsdproxy, dockwatch, dockerproxy, diun, trivy, gluetun, pihole, nebula-sync, postgres, postgres-backup, immich_redis, immich_server, immich_machine_learning, jellyfin, audiobookshelf, metube, spotdl, hedgedoc, vaultwarden, unpackerr, flaresolverr, edge-tts, tts-pipeline, cadvisor |
| host | keepalived, syncthing, beszel-agent |
| service:gluetun | transmission, jdownloader, prowlarr, sonarr, radarr, lidarr, readarr, bazarr |
| standalone | autoheal |

---

## path conventions

| convention | example |
|------------|---------|
| all host paths are relative to `/mnt/BIG/filme/` | `configs/jellyfin` → `/mnt/BIG/filme/configs/jellyfin` |
| config volumes go under `configs/<service>/` | `/mnt/BIG/filme/configs/sonarr` |
| data volumes have their own top-level directories | `/mnt/BIG/filme/filme/`, `/mnt/BIG/filme/music/` |
| build contexts go under `configs/<service>/` | `/mnt/BIG/filme/configs/tts-pipeline/` |
| backup data goes under `backups/` | `/mnt/BIG/filme/backups/postgres/` |

---

## TrueNAS-specific notes

### script execution

TrueNAS does not allow executing scripts from `/mnt/` paths. workarounds:

- **secure-container-update.sh**: cron copies to `/tmp/` before execution
- **pihole-dns-update.sh**: executable copy lives at `/root/pihole-dns-update.sh`
- **health-checks.sh and rollback.sh**: copy to `/tmp/` for manual use

```bash
# example: run health checks
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/
bash /tmp/health-checks.sh postgres
rm /tmp/health-checks.sh
```

### ZFS considerations

- **snapshots**: ZFS snapshots provide point-in-time recovery for the entire `/mnt/BIG/filme/` dataset. this is the recommended backup strategy for media libraries
- **I/O patterns**: aggressive random I/O (such as qBittorrent hash checking) can overwhelm ZFS on the HP MicroServer Gen8. transmission with conservative settings is used instead (v107)
- **pool monitoring**: monitor ZFS pool health with `zpool status BIG`
- **intel_iommu**: set to `off` in GRUB to prevent DMAR faults from escalating I/O stalls into hard freezes (v107)

---

*previous: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
*next: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
