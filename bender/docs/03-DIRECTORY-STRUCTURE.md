# bender directory structure

## complete file system layout

**document version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

---

## table of contents

1. [overview](#overview)
2. [docker-compose directory](#docker-compose-directory)
3. [container configurations – configs/](#container-configurations--configs)
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
| `/mnt/BIG/filme/docker-compose/` | compose file, .env, scripts, secure-update state |
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

the naming convention (`/mnt/BIG/filme/filme/` for movies) is historical – `filme` is the Romanian word for "films/movies". the outer `filme` is the ZFS dataset name, the inner `filme` is the movie library directory.

**nothing operational lives under `/root` or the OS filesystem.** TrueNAS upgrades wipe or reset those locations (the HeavyScript loss is the standing precedent). every script, config, and state file belongs on the pool.

---

## docker-compose directory

```
/mnt/BIG/filme/docker-compose/
├── docker-compose.yaml             # 20260809 – main compose file (42 defined, 41 active)
├── .env                            # environment variables (31 active variables, 16 secrets)
├── scripts/
│   ├── secure-container-update.sh  # v1.3 – update orchestration (postgres + gluetun critical)
│   ├── secure-container-update.sh-v1.2.backup
│   ├── secure-container-update.sh.v1.1.backup
│   ├── health-checks.sh            # v1.2 – post-update health verification
│   ├── rollback.sh                 # v1.1 – rollback helper
│   ├── pihole-dns-update.sh        # v3.2 – DNS auto-population (hourly cron)
│   ├── smart-test.sh               # v1.1 – middleware-free SMART testing + alerting
│   └── bender-replicate.sh         # v1.0 – nightly critical-data replication to amy
├── configs/secure-update/
│   ├── critical-containers.json    # critical service definitions (postgres, gluetun)
│   ├── critical-containers_v1.2.json  # pre-v1.3 version (versioned-backup convention)
│   ├── retry-queue.json            # containers blocked by vulnerability scans
│   ├── logs/                       # daily update + replicate- + smart- logs (180-day retention)
│   ├── scan-reports/               # trivy JSON reports by date (180-day retention)
│   └── smart-state/                # SMART baselines keyed by model_serial
└── reports/weekly-reports/         # markdown update summaries (180-day retention)
```

superseded script versions are kept beside the live script with a versioned suffix rather than `.bak` – the same convention applies to rewritten config JSONs (`critical-containers_v1.2.json`).

> **known wart – dual configs trees:** a second, near-empty configs tree exists at `/mnt/BIG/filme/docker-compose/configs/` (diun, jellyfin-themerr, secure-update, trivy remnants). **canonical for service configs is `/mnt/BIG/filme/configs/`**; the secure-update state tree is canonical under `docker-compose/configs/secure-update/`. cleanup is deferred until after the K8s migration – do not "tidy" it mid-flight.

> **note:** the pool is mounted noexec – scripts under `/mnt/` cannot be executed directly. every invocation, scheduled or manual, uses the `bash /mnt/BIG/filme/docker-compose/scripts/<script>.sh` form. the legacy pattern of copying scripts to `/tmp/` before execution was retired in 2026-07; if you find it in a cron entry or muscle memory, replace it.

all six scripts are scheduled through TrueNAS UI cron jobs (System → Advanced → Cron Jobs) – UI-defined jobs survive TrueNAS upgrades; `crontab -e` entries do not. see [07-MAINTENANCE.md](./07-MAINTENANCE.md) for the full seven-job table.

---

## container configurations – configs/

```
/mnt/BIG/filme/configs/
├── audiobookshelf/             # audiobookshelf config
├── baikal/                     # v110: CalDAV/CardDAV server
│   ├── config/                 # baikal configuration
│   └── data/                   # baikal Specific/ data
├── bazarr/                     # subtitle manager config
├── diun/                       # image update notifier data
├── dockwatch/                  # container management config
├── epub2tts-edge/              # v108: epub2tts-edge build context
│   ├── Dockerfile
│   └── patch_epub2tts.py
├── forgejo/                    # v115: git forge data (repos + config; chown 1000:1000)
├── gluetun/                    # VPN client state
├── hedgedoc/
│   └── uploads/                # hedgedoc uploaded files
├── jdownloader/                # jdownloader config
├── jellyfin/                   # media server config + cache
├── keepalived/
│   └── keepalived.conf         # VRRP master config (ens1f0, priority 200, VIP 10.30.0.2)
├── lidarr/                     # music automation config
├── pihole/
│   ├── etc-pihole/             # pihole config (pihole.toml + .dns-state)
│   └── etc-dnsmasq.d/          # dnsmasq config
├── postgres/
│   └── init/                   # init scripts (read-only mount)
├── prowlarr/                   # indexer manager config
├── radarr/                     # movie automation config
├── readarr/                    # ebook automation config
├── sonarr/                     # tv automation config
├── transmission/               # v108: custom build context
│   ├── Dockerfile              # pre-baked Flood UI build (base pinned 4.0.5)
│   └── ...                     # transmission config files
├── trivy/                      # vulnerability scanner cache
├── tsdproxy/
│   ├── data/tailscale/         # tailscale state
│   └── config/                 # tsdproxy config
├── audiobook-foundry/          # 20260729: git checkout, replaces tts-pipeline
├── tts-pipeline/               # RETIRED 20260729 – archive after first good conversion
├── influxdb/ -> NOT here       # 20260807: data lives at /mnt/BIG/filme/influxdb
├── meshcentral/                # 20260729: meshcentral-data holds AMT credentials
│   ├── Dockerfile              # Flask web UI + pipeline.sh
│   ├── pipeline.sh             # filesystem watcher script
│   ├── preprocess.py           # input preprocessing
│   ├── patch_epub2tts.py       # epub2tts patching
│   ├── webapp.py               # v109: Flask web interface
│   └── start.sh                # v109: entrypoint (starts both watcher + web)
├── vaultwarden/                # password manager data
└── vikunja/                    # v111: task management
    └── files/                  # vikunja file attachments (chown 1000)
```

---

## build contexts

three containers use `build:` directives instead of pre-built images. their Dockerfiles and supporting files live under `/mnt/BIG/filme/configs/`:

| container | build context | key files |
|-----------|--------------|-----------|
| transmission | `/mnt/BIG/filme/configs/transmission/` | Dockerfile (base: lscr.io/linuxserver/transmission:4.0.5, adds Flood UI) |
| audiobook-foundry | `/mnt/BIG/filme/configs/audiobook-foundry/` | Dockerfile, pipeline.sh, webapp.py, start.sh, preprocess.py, patch_epub2tts.py. this is a git checkout of a public repository. |
| epub2tts-edge | `/mnt/BIG/filme/configs/epub2tts-edge/` | Dockerfile, patch_epub2tts.py (profiles: tools, on-demand only) |

the build context moved in 20260729. it is now `configs/audiobook-foundry/`, a git checkout rather than a loose directory. so `git log` answers which version is deployed. `configs/tts-pipeline/` is retired and should be archived after the first successful conversion on the new image.

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
├── postgresql/                     # CRITICAL – shared database (5 tenants)
│                                   # consumer: postgres (/var/lib/postgresql/data)
├── redis/                          # redis persistent data
│                                   # consumer: immich_redis (/data)
└── ml-cache/                       # machine learning model cache
                                    # consumer: immich_machine_learning (/cache)
```

> **CRITICAL:** `/mnt/BIG/filme/immich/postgresql` is the shared postgres data directory carrying **all five** tenant databases: immich (photo metadata), hedgedoc, baikal, vikunja, and forgejo. the path name is historical – it long ago outgrew "immich only". it is the most critical data on bender: backed up daily by postgres-backup, dumped pre-upgrade by the update system, and its dumps replicated nightly to amy.

---

## text-to-speech data

```
/mnt/BIG/filme/tts/
└── input/                          # TTS input directories (v109)
    ├── ro-emil/                    # → ro-RO-EmilNeural (Romanian male)
    ├── ro-alina/                   # → ro-RO-AlinaNeural (Romanian female)
    ├── en-ryan/                    # → en-GB-RyanNeural (British male)
    └── en-sonia/                   # → en-GB-SoniaNeural (British female)
                                    # consumers: lrrr (/input), epub2tts-edge (/input)

/mnt/BIG/filme/audiobookshelf/
├── audiobooks/                     # audiobook library
│   └── cărți/                      # TTS output goes here for automatic pickup
│                                   # consumers: audiobookshelf (/audiobooks), lrrr (/audiobooks),
│                                   #            epub2tts-edge (/audiobooks)
├── podcasts/                       # podcast library
│                                   # consumer: audiobookshelf (/podcasts)
└── metadata/                       # audiobookshelf metadata
                                    # consumer: audiobookshelf (/metadata)
```

lrrr watches all 4 input directories and auto-selects the voice based on which directory the file is placed in. output M4B files go to `/audiobooks/cărți/` where audiobookshelf picks them up automatically.

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
└── postgres/                       # postgresql backups (all 5 databases)
    ├── pre-upgrade/                # pre-upgrade dumps (created by secure-container-update.sh)
    └── ...                         # daily/weekly/monthly from postgres-backup container
                                    # consumer: postgres-backup (/backups)
```

retention policy: 7 daily, 4 weekly, 6 monthly backups.

### off-host replica (amy)

bender-replicate.sh rsyncs the critical trees to amy nightly at 03:30:

```
amy:/docker/backups/bender-replica/
├── configs/                        # everything under /mnt/BIG/filme/configs/
├── backups/postgres/               # the database dumps above
└── docker-compose/                 # compose, .env, scripts, secure-update state
```

7-day retention on amy; regenerable bulk (media libraries, downloads, ML caches) is excluded. the replica intentionally includes the replication script itself – the backup system backs up its own code.

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
| baikal | configs/baikal/config | /var/www/baikal/config | rw |
| baikal | configs/baikal/data | /var/www/baikal/Specific | rw |
| vikunja | configs/vikunja/files | /app/vikunja/files | rw |
| forgejo | configs/forgejo | /data | rw |
| unpackerr | transmission | /downloads | rw |
| flaresolverr | (none) | | |
| edge-tts | (none) | | |
| audiobook-foundry | tts/input | /input | rw |
| audiobook-foundry | audiobookshelf/audiobooks | /audiobooks | rw |
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

nebula-sync, flaresolverr, edge-tts – no persistent volumes.

### tools-profile services

| container | host path | container path | mode |
|-----------|-----------|---------------|------|
| epub2tts-edge | audiobookshelf/audiobooks | /audiobooks | rw |
| epub2tts-edge | tts/input | /input | rw |

---

## network mode reference

| mode | services |
|------|----------|
| bridge (media-network) | tsdproxy, dockwatch, dockerproxy, diun, trivy, meshcentral, gluetun, pihole, nebula-sync, postgres, postgres-backup, immich_redis, influxdb, immich_server, immich_machine_learning, jellyfin, audiobookshelf, metube, spotdl, hedgedoc, vaultwarden, baikal, vikunja, forgejo, unpackerr, flaresolverr, edge-tts, audiobook-foundry, cadvisor, epub2tts-edge (profiles: tools) |
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
| build contexts go under `configs/<service>/` | `/mnt/BIG/filme/configs/audiobook-foundry/` (a git checkout since 20260729) |
| backup data goes under `backups/` | `/mnt/BIG/filme/backups/postgres/` |
| scripts + operational state under `docker-compose/` | `/mnt/BIG/filme/docker-compose/scripts/`, `.../configs/secure-update/` |
| nothing under /root or the OS filesystem | TrueNAS upgrades reset those locations |

---

## TrueNAS-specific notes

### script execution (noexec pool)

TrueNAS mounts the pool noexec – scripts under `/mnt/` cannot be executed directly. the `bash <path>` invocation form is used everywhere (cron and manual):

```bash
# example: run health checks
bash /mnt/BIG/filme/docker-compose/scripts/health-checks.sh postgres

# example: manual rollback listing
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh list jellyfin
```

the `chmod +x` on scripts is convention, not function – noexec makes the execute bit inert. the historical copy-to-/tmp pattern is retired; it added failure modes (partial copies, stale /tmp versions) for no benefit.

### cron persistence

only TrueNAS **UI-defined** cron jobs (System → Advanced → Cron Jobs) survive upgrades. root's `crontab -e` was silently emptied by an upgrade (discovered 2026-07); all seven schedules now live in the UI. after every TrueNAS upgrade, verify the seven jobs against the table in [07-MAINTENANCE.md](./07-MAINTENANCE.md).

### apt / developer mode

TrueNAS blocks apt by default (symlinks to `pkg_mgmt_disabled`). it was unlocked via `install-dev-tools`, with the Debian **bookworm** repository added (25.10.x is bookworm-based). an idempotent Pre Init script (timeout 900) re-applies developer mode and the repo after upgrades. if apt fails with a policy error after an upgrade, run the post-init script manually and retry.

### ZFS considerations

- **snapshots**: ZFS snapshots provide point-in-time recovery for the entire `/mnt/BIG/filme/` dataset. this is the recommended backup strategy for media libraries
- **I/O patterns**: aggressive random I/O (qBittorrent hash checking v102, unconstrained immich ML v112) can overwhelm ZFS on the 4-disk array. transmission and immich run with conservative limits
- **pool monitoring**: `zpool status BIG`; disk health via smart-test.sh (see [07-MAINTENANCE.md](./07-MAINTENANCE.md))
- **intel_iommu**: set to `off` in the MicroSD GRUB config to prevent DMAR faults from escalating I/O stalls into hard freezes (v107). the MicroSD is a single point of failure – imaging a spare is backlog 04-A

---

*previous: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
*next: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
