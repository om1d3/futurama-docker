# bender directory structure

## complete file system layout

**document version:** 2.0
**infrastructure version:** 105
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [docker-compose directory](#docker-compose-directory)
3. [container configurations — configs/](#container-configurations--configs)
4. [media libraries](#media-libraries)
5. [immich data](#immich-data)
6. [download data](#download-data)
7. [backup data](#backup-data)
8. [volume mount reference](#volume-mount-reference)
9. [network mode reference](#network-mode-reference)
10. [path conventions](#path-conventions)
11. [TrueNAS-specific notes](#truenas-specific-notes)

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
| `/mnt/BIG/filme/transmission/` | torrent downloads |
| `/mnt/BIG/filme/backups/` | database backups |

the naming convention (`/mnt/BIG/filme/filme/` for movies) is historical — `filme` is the Romanian word for "films/movies". the outer `filme` is the ZFS dataset name, the inner `filme` is the movie library directory.

---

## docker-compose directory

```
/mnt/BIG/filme/docker-compose/
├── docker-compose.yaml             # v105 — main compose file (33 services)
├── .env                            # environment variables (28 variables)
└── scripts/
    ├── secure-container-update.sh  # automated update orchestration
    ├── health-checks.sh            # post-update health verification
    ├── rollback.sh                 # rollback helper
    └── pihole-dns-update.sh        # reference copy (executable at /root/)
```

> **note:** on TrueNAS, scripts under `/mnt/` cannot be executed directly due to filesystem restrictions. the secure-container-update.sh cron job copies the script to `/tmp/` before execution. the pihole-dns-update.sh executable lives at `/root/pihole-dns-update.sh`.

---

## container configurations — configs/

each service that needs persistent configuration gets a subdirectory under `/mnt/BIG/filme/configs/`:

```
/mnt/BIG/filme/configs/
├── audiobookshelf/          # audiobookshelf config, library database
├── bazarr/                  # bazarr settings, subtitle profiles
├── diun/                    # image update tracking database
├── dockwatch/               # dockwatch configuration
├── gluetun/                 # VPN connection state and wireguard keys
├── hedgedoc/
│   └── uploads/             # user-uploaded images and attachments
├── jdownloader/             # jdownloader settings, link grabber config
├── jellyfin/                # jellyfin server config, metadata cache, plugins
├── keepalived/
│   └── keepalived.conf      # VRRP configuration (read-only mount)
├── lidarr/                  # lidarr settings, music database
├── pihole/
│   ├── etc-pihole/          # pihole configuration, gravity database
│   └── etc-dnsmasq.d/       # dnsmasq overrides
├── postgres/
│   └── init/                # database initialization scripts (read-only)
├── prowlarr/                # prowlarr settings, indexer database
├── qbittorrent/             # qbittorrent config (commented service — preserved)
├── radarr/                  # radarr settings, movie database
├── readarr/                 # readarr settings, book database
├── sonarr/                  # sonarr settings, TV database
├── trivy/                   # vulnerability database cache
├── tsdproxy/
│   ├── data/
│   │   └── tailscale/       # tailscale node state and certificates
│   └── config/              # tsdproxy configuration
└── vaultwarden/             # vaultwarden data (sqlite database, attachments, keys)
```

---

## media libraries

these directories contain the actual media files served by jellyfin, audiobookshelf, and the ARR stack:

```
/mnt/BIG/filme/
├── filme/                   # movie library (1200+ films)
│                            # mounted as /data/movies in jellyfin
│                            # mounted as /movies in radarr, bazarr
│
├── seriale/                 # TV show library (180+ series)
│                            # mounted as /data/tvshows in jellyfin
│                            # mounted as /tv in sonarr, bazarr
│
├── music/                   # music library (240+ artists)
│                            # mounted as /data/music in jellyfin
│                            # mounted as /music in lidarr
│
├── books/                   # ebook library
│                            # mounted as /books in readarr
│
├── audiobookshelf/
│   ├── audiobooks/          # audiobook files
│   ├── podcasts/            # podcast episodes
│   └── metadata/            # audiobookshelf metadata cache
│
├── metube/                  # youtube downloads (metube output)
├── spotdl/                  # spotify downloads (spotdl output)
├── jdownloader/             # jdownloader output directory
│
└── syncthing/               # syncthing data + config (single volume)
```

### jellyfin volume mapping

| jellyfin internal path | host path | used by |
|-----------------------|-----------|---------|
| `/data/movies` | `/mnt/BIG/filme/filme` | movie library |
| `/data/tvshows` | `/mnt/BIG/filme/seriale` | TV show library (v105 fix) |
| `/data/music` | `/mnt/BIG/filme/music` | music library |
| `/config` | `/mnt/BIG/filme/configs/jellyfin` | server configuration |

> **note:** jellyfin's TV library was configured to use `/data/tvshows` internally. in v105, the volume mount was updated from `/data/tv` to `/data/tvshows` to match the library configuration, fixing "access denied" errors and missing metadata.

---

## immich data

immich stores its data separately from the configs directory due to the volume of photo/video files:

```
/mnt/BIG/filme/immich/
├── photos/                  # uploaded photos and videos (/usr/src/app/upload)
├── postgresql/              # ⚠️ CRITICAL — immich + hedgedoc database
│                            # contains vectorchord/pgvectors extensions
│                            # DO NOT MOVE — actively used by postgres container
├── redis/                   # redis persistence files
└── ml-cache/                # machine learning model cache
```

> **⚠️ CRITICAL:** the postgresql directory at `/mnt/BIG/filme/immich/postgresql` contains the production database for both immich and hedgedoc. this path is mounted directly as postgres's data directory. moving or corrupting this directory will result in total data loss for both services. always backup before any postgres operations.

---

## download data

```
/mnt/BIG/filme/transmission/
├── completed/               # finished downloads
├── incomplete/              # in-progress downloads
├── watch/                   # .torrent file watch directory
└── config/
    └── transmission-home/   # transmission configuration
```

the entire `/mnt/BIG/filme/transmission/` directory is mounted into transmission, sonarr, radarr, lidarr, readarr, and unpackerr so they can all access downloaded files for import and post-processing.

---

## backup data

```
/mnt/BIG/filme/backups/
└── postgres/                # automated daily postgresql backups
                             # databases: immich, hedgedoc
                             # retention: 7 daily, 4 weekly, 6 monthly
```

---

## volume mount reference

### services on media-network (bridge)

| service | container path | host path | mode |
|---------|---------------|-----------|------|
| tsdproxy | /data | /mnt/BIG/filme/configs/tsdproxy/data/tailscale | rw |
| tsdproxy | /config | /mnt/BIG/filme/configs/tsdproxy/config | rw |
| dockwatch | /config | /mnt/BIG/filme/configs/dockwatch | rw |
| dockerproxy | /var/run/docker.sock | /var/run/docker.sock | ro |
| diun | /data | /mnt/BIG/filme/configs/diun | rw |
| diun | /var/run/docker.sock | /var/run/docker.sock | ro |
| trivy | /root/.cache/trivy | /mnt/BIG/filme/configs/trivy | rw |
| trivy | /var/run/docker.sock | /var/run/docker.sock | ro |
| gluetun | /gluetun | /mnt/BIG/filme/configs/gluetun | rw |
| pihole | /etc/pihole | /mnt/BIG/filme/configs/pihole/etc-pihole | rw |
| pihole | /etc/dnsmasq.d | /mnt/BIG/filme/configs/pihole/etc-dnsmasq.d | rw |
| nebula-sync | (no volumes) | — | — |
| postgres | /var/lib/postgresql/data | /mnt/BIG/filme/immich/postgresql | rw |
| postgres | /docker-entrypoint-initdb.d | /mnt/BIG/filme/configs/postgres/init | ro |
| postgres-backup | /backups | /mnt/BIG/filme/backups/postgres | rw |
| immich_redis | /data | /mnt/BIG/filme/immich/redis | rw |
| immich_server | /usr/src/app/upload | /mnt/BIG/filme/immich/photos | rw |
| immich_machine_learning | /cache | /mnt/BIG/filme/immich/ml-cache | rw |
| jellyfin | /config | /mnt/BIG/filme/configs/jellyfin | rw |
| jellyfin | /data/movies | /mnt/BIG/filme/filme | rw |
| jellyfin | /data/tvshows | /mnt/BIG/filme/seriale | rw |
| jellyfin | /data/music | /mnt/BIG/filme/music | rw |
| audiobookshelf | /config | /mnt/BIG/filme/configs/audiobookshelf | rw |
| audiobookshelf | /audiobooks | /mnt/BIG/filme/audiobookshelf/audiobooks | rw |
| audiobookshelf | /podcasts | /mnt/BIG/filme/audiobookshelf/podcasts | rw |
| audiobookshelf | /metadata | /mnt/BIG/filme/audiobookshelf/metadata | rw |
| metube | /downloads | /mnt/BIG/filme/metube | rw |
| spotdl | /music | /mnt/BIG/filme/spotdl | rw |
| hedgedoc | /hedgedoc/public/uploads | /mnt/BIG/filme/configs/hedgedoc/uploads | rw |
| vaultwarden | /data | /mnt/BIG/filme/configs/vaultwarden | rw |
| unpackerr | /downloads | /mnt/BIG/filme/transmission | rw |
| flaresolverr | (no volumes) | — | — |
| cadvisor | /rootfs | / | ro |
| cadvisor | /var/run | /var/run | ro |
| cadvisor | /sys | /sys | ro |
| cadvisor | /var/lib/docker | /var/lib/docker | ro |

### services using gluetun network (no direct volumes to host ports)

| service | container path | host path | mode |
|---------|---------------|-----------|------|
| transmission | /config | /mnt/BIG/filme/transmission/config/transmission-home | rw |
| transmission | /data | /mnt/BIG/filme/transmission | rw |
| jdownloader | /config | /mnt/BIG/filme/configs/jdownloader | rw |
| jdownloader | /output | /mnt/BIG/filme/jdownloader | rw |
| prowlarr | /config | /mnt/BIG/filme/configs/prowlarr | rw |
| sonarr | /config | /mnt/BIG/filme/configs/sonarr | rw |
| sonarr | /tv | /mnt/BIG/filme/seriale | rw |
| sonarr | /downloads | /mnt/BIG/filme/transmission | rw |
| radarr | /config | /mnt/BIG/filme/configs/radarr | rw |
| radarr | /movies | /mnt/BIG/filme/filme | rw |
| radarr | /downloads | /mnt/BIG/filme/transmission | rw |
| lidarr | /config | /mnt/BIG/filme/configs/lidarr | rw |
| lidarr | /music | /mnt/BIG/filme/music | rw |
| lidarr | /downloads | /mnt/BIG/filme/transmission | rw |
| readarr | /config | /mnt/BIG/filme/configs/readarr | rw |
| readarr | /books | /mnt/BIG/filme/books | rw |
| readarr | /downloads | /mnt/BIG/filme/transmission | rw |
| bazarr | /config | /mnt/BIG/filme/configs/bazarr | rw |
| bazarr | /movies | /mnt/BIG/filme/filme | rw |
| bazarr | /tv | /mnt/BIG/filme/seriale | rw |

### services with host network

| service | container path | host path | mode |
|---------|---------------|-----------|------|
| keepalived | /container/service/keepalived/assets/keepalived.conf | /mnt/BIG/filme/configs/keepalived/keepalived.conf | ro |
| syncthing | /var/syncthing | /mnt/BIG/filme/syncthing | rw |
| beszel-agent | /var/run/docker.sock | /var/run/docker.sock | ro |

---

## network mode reference

| service | network mode | reason |
|---------|-------------|--------|
| keepalived | host | direct access to network interfaces for VRRP |
| syncthing | host | peer discovery and direct connections |
| beszel-agent | host | access to host system metrics |
| transmission | service:gluetun | VPN tunnel for torrent traffic |
| jdownloader | service:gluetun | VPN tunnel for direct downloads |
| prowlarr | service:gluetun | VPN tunnel for indexer queries |
| sonarr | service:gluetun | VPN tunnel for API traffic |
| radarr | service:gluetun | VPN tunnel for API traffic |
| lidarr | service:gluetun | VPN tunnel for API traffic |
| readarr | service:gluetun | VPN tunnel for API traffic |
| bazarr | service:gluetun | VPN tunnel for subtitle downloads |
| all others | media-network (bridge) | standard isolation with DNS anchor |

the DNS anchor (`x-dns-config: &default-dns`) points bridge-networked services to `192.168.21.100` (keepalived VIP). host-networked services use the host's DNS. gluetun-networked services use gluetun's DNS (configured with `DOT=off` for plain DNS).

---

## path conventions

### naming rules

- all container configurations live under `/mnt/BIG/filme/configs/<service-name>/`
- media libraries live directly under `/mnt/BIG/filme/` (filme, seriale, music, books)
- immich has its own directory `/mnt/BIG/filme/immich/` due to the volume of photo data
- download data lives under `/mnt/BIG/filme/transmission/` (shared across ARR stack)

### shared volume mounts

several host directories are mounted into multiple containers:

| host path | mounted by | purpose |
|-----------|-----------|---------|
| `/mnt/BIG/filme/filme` | jellyfin, radarr, bazarr | movie library |
| `/mnt/BIG/filme/seriale` | jellyfin, sonarr, bazarr | TV show library |
| `/mnt/BIG/filme/music` | jellyfin, lidarr | music library |
| `/mnt/BIG/filme/transmission` | transmission, sonarr, radarr, lidarr, readarr, unpackerr | download processing pipeline |
| `/var/run/docker.sock` | tsdproxy, dockwatch, dockerproxy, diun, trivy, beszel-agent | docker API access |

### backup considerations

| path | backup method | frequency |
|------|--------------|-----------|
| `/mnt/BIG/filme/docker-compose/` | git repository (futurama-docker) | on change |
| `/mnt/BIG/filme/backups/postgres/` | automated by postgres-backup container | daily |
| `/mnt/BIG/filme/immich/postgresql/` | backed up via postgres-backup container | daily |
| `/mnt/BIG/filme/immich/photos/` | ZFS snapshots recommended | as needed |
| `/mnt/BIG/filme/configs/` | manual or scheduled backup | as needed |
| media libraries (filme, seriale, music, books) | ZFS snapshots | as needed |

### disk usage notes

the largest consumers of disk space on bender are:
- `/mnt/BIG/filme/filme/` — movie library (largest by far)
- `/mnt/BIG/filme/seriale/` — TV show library
- `/mnt/BIG/filme/immich/photos/` — uploaded photos and videos
- `/mnt/BIG/filme/transmission/` — active and completed downloads
- `/mnt/BIG/filme/immich/ml-cache/` — ML model files (can be regenerated)
- `/mnt/BIG/filme/configs/trivy/` — vulnerability database cache (can be cleared)

---

## TrueNAS-specific notes

### script execution restriction

TrueNAS does not allow executing scripts from `/mnt/` paths. the cron job for secure-container-update.sh works around this:

```bash
# cron copies script to /tmp before execution
cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/
bash /tmp/secure-container-update.sh weekly
rm /tmp/secure-container-update.sh
```

the pihole-dns-update.sh script lives at `/root/pihole-dns-update.sh` for direct execution.

### ZFS considerations

- **snapshots**: ZFS snapshots provide point-in-time recovery for the entire `/mnt/BIG/filme/` dataset. this is the recommended backup strategy for media libraries
- **I/O patterns**: aggressive random I/O (such as qBittorrent hash checking) can overwhelm ZFS on the HP MicroServer Gen8. transmission with conservative settings is used instead
- **pool monitoring**: monitor ZFS pool health with `zpool status BIG`

---

*previous: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*
*next: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
