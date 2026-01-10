# amy directory structure

## file system layout and storage configuration

**document version:** 1.0  
**infrastructure version:** 85  
**last updated:** january 10, 2026

---

## table of contents

1. [overview](#overview)
2. [docker compose directory](#docker-compose-directory)
3. [container data directory](#container-data-directory)
4. [backup directory](#backup-directory)
5. [permissions](#permissions)
6. [comparison with bender](#comparison-with-bender)

---

## overview

amy uses a simpler directory structure than bender, with all container data stored locally on the ssd.

### key paths

| path | purpose |
|------|---------|
| `/docker-compose/` | docker compose configuration, scripts |
| `/docker/` | container persistent data |
| `/docker/backups/` | postgresql backups |

### storage architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        amy storage                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    local ssd (256gb)                     │    │
│  │  ┌─────────────────┐  ┌─────────────────────────────┐   │    │
│  │  │ /docker-compose │  │         /docker             │   │    │
│  │  │                 │  │                             │   │    │
│  │  │ • docker-compose│  │ • postgresql data           │   │    │
│  │  │ • .env          │  │ • service configs           │   │    │
│  │  │ • scripts/      │  │ • persistent volumes        │   │    │
│  │  │ • configs/      │  │ • backups/                  │   │    │
│  │  └─────────────────┘  └─────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## docker compose directory

### structure

```
/docker-compose/
├── docker-compose.yaml          # main compose file (v85)
├── .env                         # environment variables (secrets)
├── scripts/
│   ├── secure-container-update.sh
│   ├── health-checks.sh
│   └── rollback.sh
├── configs/
│   └── secure-update/
│       ├── critical-containers.json
│       ├── retry-queue.json
│       ├── logs/
│       │   └── *.log
│       └── scan-reports/
│           └── *.json
└── reports/
    └── weekly-reports/
        └── *.md
```

### file descriptions

| file | purpose |
|------|---------|
| `docker-compose.yaml` | main service definitions (v85, ~800 lines) |
| `.env` | environment variables and secrets |
| `scripts/secure-container-update.sh` | weekly update orchestration |
| `scripts/health-checks.sh` | service health verification |
| `scripts/rollback.sh` | manual rollback helper |
| `configs/secure-update/critical-containers.json` | list of critical services |
| `configs/secure-update/retry-queue.json` | failed updates awaiting retry |

---

## container data directory

### structure

```
/docker/
├── postgresql/
│   └── data/                    # postgres data directory
├── ntfy/
│   ├── cache/                   # attachment cache
│   └── etc/                     # configuration
├── pihole/
│   ├── etc-pihole/              # pihole config
│   └── etc-dnsmasq.d/           # dnsmasq config
├── keepalived/
│   └── keepalived.conf          # vrrp configuration
├── vaultwarden/
│   └── data/                    # vault data
├── beszel/
│   └── data/                    # monitoring data
├── tsdproxy/
│   ├── data/                    # tailscale state
│   └── config/                  # tsdproxy config
├── dockwatch/
├── valkey/
│   └── data/                    # cache data
├── stirling-pdf/
│   ├── training/
│   └── configs/
├── homepage/
│   └── config/                  # dashboard config
├── atuin/
│   └── config/
├── filebrowser/
│   └── database.db
├── mealie/
│   └── data/
├── argus/
├── lubelogger/
│   ├── config/
│   ├── data/
│   ├── documents/
│   ├── images/
│   ├── temp/
│   ├── log/
│   └── keys/
├── spendspentspent/
│   ├── app-files/
│   └── files/
├── limdius/
├── netalertx/
│   ├── config/
│   ├── db/
│   └── logs/
├── diun/
│   ├── data/                    # diun database
│   └── config/                  # diun config
├── trivy/
│   └── cache/                   # vulnerability db cache
└── backups/
    └── postgres/
        ├── daily/               # daily backups
        ├── weekly/              # weekly backups
        └── monthly/             # monthly backups
```

### service data locations

| service | data path | size estimate |
|---------|-----------|---------------|
| postgresql | `/docker/postgresql/data/` | 500mb - 2gb |
| vaultwarden | `/docker/vaultwarden/` | 50-200mb |
| pihole | `/docker/pihole/` | 100-500mb |
| beszel | `/docker/beszel/data/` | 100-500mb |
| mealie | `/docker/mealie/` | 100mb-1gb |
| backups | `/docker/backups/postgres/` | 1-5gb |

---

## backup directory

### postgresql backup structure

```
/docker/backups/
└── postgres/
    ├── daily/
    │   ├── atuin-20260110.sql.gz
    │   ├── miniflux-20260110.sql.gz
    │   └── sss-20260110.sql.gz
    ├── weekly/
    │   ├── atuin-20260106.sql.gz
    │   ├── miniflux-20260106.sql.gz
    │   └── sss-20260106.sql.gz
    └── monthly/
        ├── atuin-20260101.sql.gz
        ├── miniflux-20260101.sql.gz
        └── sss-20260101.sql.gz
```

### backup retention

| type | retention | count |
|------|-----------|-------|
| daily | 7 days | ~21 files |
| weekly | 4 weeks | ~12 files |
| monthly | 6 months | ~18 files |

### manual backup location

```
/docker/backups/postgres/manual/
```

for ad-hoc backups before major changes.

---

## permissions

### ownership

| path | owner | group | permissions |
|------|-------|-------|-------------|
| `/docker-compose/` | root | root | 755 |
| `/docker-compose/.env` | root | root | 600 |
| `/docker-compose/scripts/` | root | root | 755 |
| `/docker/` | 1000 | 1000 | 755 |
| `/docker/postgresql/` | 1000 | 1000 | 700 |

### setting permissions

```bash
# docker-compose directory
chown -R root:root /docker-compose/
chmod 755 /docker-compose/
chmod 600 /docker-compose/.env
chmod 755 /docker-compose/scripts/*.sh

# container data directory
chown -R 1000:1000 /docker/
chmod 755 /docker/
chmod 700 /docker/postgresql/data/
```

---

## comparison with bender

### key differences

| aspect | amy | bender |
|--------|-----|--------|
| **base path** | `/docker-compose/` | `/mnt/BIG/filme/docker-compose/` |
| **data path** | `/docker/` | `/mnt/BIG/filme/` |
| **storage type** | local ssd | zfs pool |
| **script execution** | direct | requires /tmp copy |
| **nfs mounts** | none | exports to amy |
| **backup storage** | local | local + nfs |

### path mapping

| purpose | amy | bender |
|---------|-----|--------|
| compose file | `/docker-compose/docker-compose.yaml` | `/mnt/BIG/filme/docker-compose/docker-compose.yaml` |
| environment | `/docker-compose/.env` | `/mnt/BIG/filme/docker-compose/.env` |
| scripts | `/docker-compose/scripts/` | `/mnt/BIG/filme/docker-compose/scripts/` |
| postgres data | `/docker/postgresql/` | `/mnt/BIG/filme/immich/postgresql/` |
| backups | `/docker/backups/postgres/` | `/mnt/BIG/filme/backups/postgres/` |

### TrueNAS vs ubuntu

1. **TrueNAS vs ubuntu**: bender runs on TrueNAS with zfs pools, requiring paths under `/mnt/`. amy runs standard ubuntu with simpler paths.

2. **script execution**: TrueNAS restricts script execution on mounted filesystems, requiring copy-to-tmp workarounds. amy can execute scripts directly.

3. **storage scale**: bender handles large media files (tbs), while amy's data is primarily small configuration and database files.

---

## directory creation

### initial setup commands

```bash
# create base directories
mkdir -p /docker-compose/{scripts,configs/secure-update/{logs,scan-reports},reports/weekly-reports}
mkdir -p /docker/{postgresql/{data,init},ntfy/{cache,etc},pihole/{etc-pihole,etc-dnsmasq.d}}
mkdir -p /docker/{keepalived,vaultwarden,beszel/data,tsdproxy/{data,config},dockwatch}
mkdir -p /docker/{valkey,stirling-pdf/{training,configs},homepage,atuin,filebrowser}
mkdir -p /docker/{mealie,argus,lubelogger/{config,data,documents,images,temp,log,keys}}
mkdir -p /docker/{spendspentspent/{app-files,files},limdius,netalertx/{config,db,logs}}
mkdir -p /docker/{diun/{data,config},trivy/cache,backups/postgres/{daily,weekly,monthly,manual}}

# set ownership
chown -R 1000:1000 /docker/
chown -R root:root /docker-compose/

# initialize configuration files
echo '["postgres", "ntfy", "beszel", "pihole", "keepalived", "vaultwarden", "spendspentspent", "diun"]' > /docker-compose/configs/secure-update/critical-containers.json
echo '{"containers": []}' > /docker-compose/configs/secure-update/retry-queue.json
```

---

*previous: [02-SERVICES-CATALOG.md](./02-SERVICES-CATALOG.md)*  
*next: [04-SECURE-UPDATES.md](./04-SECURE-UPDATES.md)*
