# futurama docker infrastructure

## home lab container infrastructure

two-host docker infrastructure for media services, utilities, and home automation.

---

## quick links

| host | documentation | docker compose | scripts |
|------|---------------|----------------|---------|
| **bender** | [docs](bender/docs/) | [docker-compose.yaml](bender/docker-compose.yaml) | [scripts](bender/scripts/) |
| **amy** | [docs](amy/docs/) | [docker-compose.yaml](amy/docker-compose.yaml) | [scripts](amy/scripts/) |

---

## infrastructure overview

### host roles

| host | hardware | ip address | role |
|------|----------|------------|------|
| **bender** | TrueNAS Scale | 192.168.21.121 | media services, downloads, primary storage |
| **amy** | Intel i3-2310M, 16GB | 192.168.21.130 | utilities, monitoring, notifications |

### shared services

| service | vip | primary | backup |
|---------|-----|---------|--------|
| **pihole dns** | 192.168.21.100 | bender | amy |

---

## repository structure

```
.
├── README.md                    # this file
├── bender/                      # TrueNAS Scale host
│   ├── .env.template            # environment variables template
│   ├── .env.gpg                 # encrypted production secrets
│   ├── .env.gpg.README          # gpg decryption instructions
│   ├── docker-compose.yaml      # main compose file (v86)
│   ├── configs/
│   │   └── keepalived/
│   │       └── keepalived.conf  # pihole ha (master)
│   ├── docs/
│   │   ├── 01-ARCHITECTURE.md
│   │   ├── 02-SERVICES-CATALOG.md
│   │   ├── 03-DIRECTORY-STRUCTURE.md
│   │   ├── 04-SECURE-UPDATES.md
│   │   ├── 05-ENV-REFERENCE.md
│   │   ├── 06-BENEFITS-TRADEOFFS.md
│   │   ├── 07-MAINTENANCE.md
│   │   └── 08-TROUBLESHOOTING.md
│   └── scripts/
│       ├── secure-container-update.sh
│       ├── health-checks.sh
│       └── rollback.sh
└── amy/                         # ubuntu utilities host
    ├── .env.template            # environment variables template
    ├── docker-compose.yaml      # main compose file (v85)
    ├── configs/
    │   └── keepalived/
    │       └── keepalived.conf  # pihole ha (backup)
    ├── docs/
    │   ├── 01-ARCHITECTURE.md
    │   ├── 02-SERVICES-CATALOG.md
    │   ├── 03-DIRECTORY-STRUCTURE.md
    │   ├── 04-SECURE-UPDATES.md
    │   ├── 05-ENV-REFERENCE.md
    │   ├── 06-BENEFITS-TRADEOFFS.md
    │   ├── 07-MAINTENANCE.md
    │   └── 08-TROUBLESHOOTING.md
    └── scripts/
        ├── secure-container-update.sh
        ├── health-checks.sh
        └── rollback.sh
```

---

## services summary

### bender services (21 containers)

| category | services |
|----------|----------|
| **media** | immich, jellyfin, metube |
| **downloads** | transmission, sonarr, radarr, prowlarr, bazarr, unpackerr |
| **infrastructure** | postgresql, tsdproxy, pihole, keepalived |
| **utilities** | syncthing, hedgedoc, dozzle, dockwatch |
| **updates** | diun, trivy |

### amy services (27 containers)

| category | services |
|----------|----------|
| **infrastructure** | postgresql, tsdproxy, pihole, keepalived, ntfy |
| **monitoring** | beszel, beszel-agent, cadvisor, netalertx |
| **productivity** | vaultwarden, miniflux, mealie, homepage, it-tools |
| **utilities** | atuin, filebrowser, stirling-pdf, lubelogger |
| **finance** | spendspentspent |
| **updates** | diun, trivy |

---

## quick start

### new deployment

1. **clone repository**
   ```bash
   git clone <repo-url>
   cd futurama-docker
   ```

2. **create environment files**
   ```bash
   # for bender
   cp bender/.env.template bender/.env
   nano bender/.env  # fill in secrets

   # for amy
   cp amy/.env.template amy/.env
   nano amy/.env  # fill in secrets
   ```

3. **deploy to hosts**
   ```bash
   # copy to bender
   scp bender/docker-compose.yaml bender/.env root@192.168.21.121:/mnt/BIG/filme/docker-compose/

   # copy to amy
   scp amy/docker-compose.yaml amy/.env root@192.168.21.130:/docker-compose/
   ```

4. **start services**
   ```bash
   # on bender
   cd /mnt/BIG/filme/docker-compose
   docker compose up -d

   # on amy
   cd /docker-compose
   docker compose up -d
   ```

### existing deployment

see host-specific documentation:
- [bender maintenance](bender/docs/07-MAINTENANCE.md)
- [amy maintenance](amy/docs/07-MAINTENANCE.md)

---

## documentation index

### bender documentation

| document | description |
|----------|-------------|
| [01-ARCHITECTURE.md](bender/docs/01-ARCHITECTURE.md) | system design and infrastructure overview |
| [02-SERVICES-CATALOG.md](bender/docs/02-SERVICES-CATALOG.md) | complete service reference with ports |
| [03-DIRECTORY-STRUCTURE.md](bender/docs/03-DIRECTORY-STRUCTURE.md) | file system layout and paths |
| [04-SECURE-UPDATES.md](bender/docs/04-SECURE-UPDATES.md) | container update system |
| [05-ENV-REFERENCE.md](bender/docs/05-ENV-REFERENCE.md) | environment variables reference |
| [06-BENEFITS-TRADEOFFS.md](bender/docs/06-BENEFITS-TRADEOFFS.md) | design decisions analysis |
| [07-MAINTENANCE.md](bender/docs/07-MAINTENANCE.md) | operational procedures |
| [08-TROUBLESHOOTING.md](bender/docs/08-TROUBLESHOOTING.md) | problem resolution guide |

### amy documentation

| document | description |
|----------|-------------|
| [01-ARCHITECTURE.md](amy/docs/01-ARCHITECTURE.md) | system design and infrastructure overview |
| [02-SERVICES-CATALOG.md](amy/docs/02-SERVICES-CATALOG.md) | complete service reference with ports |
| [03-DIRECTORY-STRUCTURE.md](amy/docs/03-DIRECTORY-STRUCTURE.md) | file system layout and paths |
| [04-SECURE-UPDATES.md](amy/docs/04-SECURE-UPDATES.md) | container update system |
| [05-ENV-REFERENCE.md](amy/docs/05-ENV-REFERENCE.md) | environment variables reference |
| [06-BENEFITS-TRADEOFFS.md](amy/docs/06-BENEFITS-TRADEOFFS.md) | design decisions analysis |
| [07-MAINTENANCE.md](amy/docs/07-MAINTENANCE.md) | operational procedures |
| [08-TROUBLESHOOTING.md](amy/docs/08-TROUBLESHOOTING.md) | problem resolution guide |

---

## common commands

### status check

```bash
# bender
ssh root@192.168.21.121 'cd /mnt/BIG/filme/docker-compose && docker compose ps'

# amy
ssh root@192.168.21.130 'cd /docker-compose && docker compose ps'
```

### health checks

```bash
# bender
ssh root@192.168.21.121 '/mnt/BIG/filme/docker-compose/scripts/health-checks.sh all'

# amy
ssh root@192.168.21.130 '/docker-compose/scripts/health-checks.sh all'
```

### view logs

```bash
# bender
ssh root@192.168.21.121 'docker logs -f <service_name>'

# amy
ssh root@192.168.21.130 'docker logs -f <service_name>'
```

### update status

```bash
# bender (requires /tmp copy due to TrueNAS restrictions)
ssh root@192.168.21.121 'cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh status && rm /tmp/secure-container-update.sh'

# amy
ssh root@192.168.21.130 '/docker-compose/scripts/secure-container-update.sh status'
```

---

## update schedule

| host | day | time | description |
|------|-----|------|-------------|
| **amy** | wednesday | 04:30 | weekly container updates |
| **bender** | saturday | 04:30 | weekly container updates |
| **both** | daily | 04:30 | retry failed updates |

updates are staggered to prevent simultaneous failures across both hosts.

---

## key design decisions

| decision | rationale |
|----------|-----------|
| **two-host split** | failure isolation, TrueNAS upgrade immunity |
| **pihole ha** | zero-downtime dns with keepalived |
| **local ntfy** | notifications work without internet |
| **security-first updates** | trivy scanning before deployment |
| **shared postgresql** | ram efficiency on each host |

for detailed analysis, see:
- [bender benefits & trade-offs](bender/docs/06-BENEFITS-TRADEOFFS.md)
- [amy benefits & trade-offs](amy/docs/06-BENEFITS-TRADEOFFS.md)

---

## service urls (tailscale)

### media & downloads (bender)
- immich: https://photos.bunny-enigmatic.ts.net
- jellyfin: https://jelly.bunny-enigmatic.ts.net
- transmission: https://torrent.bunny-enigmatic.ts.net

### utilities (amy)
- homepage: https://home.bunny-enigmatic.ts.net
- vaultwarden: https://vault.bunny-enigmatic.ts.net
- miniflux: https://rss.bunny-enigmatic.ts.net
- ntfy: https://ntfy.bunny-enigmatic.ts.net

### monitoring
- beszel: https://beszel.bunny-enigmatic.ts.net
- dozzle (logs): https://logs.bunny-enigmatic.ts.net

for complete service urls, see:
- [bender services catalog](bender/docs/02-SERVICES-CATALOG.md)
- [amy services catalog](amy/docs/02-SERVICES-CATALOG.md)

---

## backup strategy

| data | location | backup method | retention |
|------|----------|---------------|-----------|
| **bender postgresql** | `/mnt/BIG/filme/backups/postgres` | daily automated | 7d/4w/6m |
| **amy postgresql** | `/docker/backups/postgres` | daily automated | 7d/4w/6m |
| **configuration** | this repository | git | unlimited |
| **secrets** | `*.env.gpg` files | gpg encrypted | with repo |

---

## emergency contacts

| issue | first response |
|-------|---------------|
| **dns failure** | check pihole on both hosts, verify vip |
| **database issues** | check postgresql logs, restore from backup |
| **update failures** | check `/configs/secure-update/logs/` |
| **service down** | check `docker compose ps`, restart service |

---

## version history

| date | bender | amy | changes |
|------|--------|-----|---------|
| 2026-01-10 | v86 | v85 | secure update system, full documentation |
| 2026-01-09 | v84 | v83 | vectorchord migration, diun+trivy |
| 2026-01-07 | v80 | v81 | pihole ha with keepalived |

---

## license

private infrastructure documentation. not for public distribution.
