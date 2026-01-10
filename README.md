# futurama docker infrastructure

## home lab container infrastructure

two-host docker infrastructure for media services, utilities, and home automation.

---

## network architecture

```
                            ┌─────────────────────────────────────┐
                            │           lan network               │
                            │         192.168.21.0/24             │
                            └──────────────┬──────────────────────┘
                                           │
            ┌──────────────────────────────┼──────────────────────────────┐
            │                              │                              │
            ▼                              ▼                              ▼
   ┌─────────────────┐          ┌─────────────────┐           ┌─────────────────┐
   │     bender      │          │   pihole vip    │           │      amy        │
   │  192.168.21.121 │          │ 192.168.21.100  │           │ 192.168.21.130  │
   │   TrueNAS Scale │          │   (keepalived)  │           │  Intel i3-2310M │
   └────────┬────────┘          └────────┬────────┘           └────────┬────────┘
            │                            │                             │
            │         ┌──────────────────┴──────────────────┐          │
            │         │                                     │          │
            │         ▼                                     ▼          │
            │  ┌─────────────┐                       ┌─────────────┐   │
            │  │   pihole    │◄─── vrrp failover ───►│   pihole    │   │
            │  │  (master)   │      priority 150     │  (backup)   │   │
            │  │  port 8053  │      priority 100     │  port 8053  │   │
            │  └─────────────┘                       └─────────────┘   │
            │         │                                     │          │
            └─────────┴─────────────────────────────────────┴──────────┘
```

### keepalived dns failover

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           keepalived vrrp                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   normal operation:                                                         │
│   ┌─────────────┐         ┌─────────────┐         ┌─────────────┐          │
│   │   client    │────────►│  vip .100   │────────►│   bender    │          │
│   │  dns query  │         │  (master)   │         │   pihole    │          │
│   └─────────────┘         └─────────────┘         └─────────────┘          │
│                                                                             │
│   failover (bender pihole down):                                            │
│   ┌─────────────┐         ┌─────────────┐         ┌─────────────┐          │
│   │   client    │────────►│  vip .100   │────────►│     amy     │          │
│   │  dns query  │         │  (backup)   │         │   pihole    │          │
│   └─────────────┘         └─────────────┘         └─────────────┘          │
│                                                                             │
│   health check: wget to pihole admin (port 8053)                            │
│   failover time: ~5 seconds                                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## services architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              bender (TrueNAS Scale)                         │
│                                192.168.21.121                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ media services                                                       │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐            │   │
│  │  │  immich  │  │ jellyfin │  │  metube  │  │ hedgedoc │            │   │
│  │  │  :2283   │  │  :8080   │  │  :8383   │  │  :8000   │            │   │
│  │  └────┬─────┘  └──────────┘  └──────────┘  └────┬─────┘            │   │
│  │       │                                         │                   │   │
│  │       └──────────────┬──────────────────────────┘                   │   │
│  │                      ▼                                              │   │
│  │               ┌─────────────┐                                       │   │
│  │               │  postgresql │ (vectorchord)                         │   │
│  │               │    :5432    │                                       │   │
│  │               └─────────────┘                                       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ download services (arr stack)                                        │   │
│  │  ┌────────────┐  ┌────────┐  ┌────────┐  ┌──────────┐  ┌─────────┐ │   │
│  │  │transmission│  │ sonarr │  │ radarr │  │ prowlarr │  │  bazarr │ │   │
│  │  │   :9091    │  │ :8989  │  │ :7878  │  │  :9696   │  │  :6767  │ │   │
│  │  │  (vpn)     │  └───┬────┘  └───┬────┘  └────┬─────┘  └─────────┘ │   │
│  │  └──────┬─────┘      │           │            │                     │   │
│  │         │            └───────────┴────────────┘                     │   │
│  │         │                        │                                  │   │
│  │         └────────────────────────┘                                  │   │
│  │                      ▼                                              │   │
│  │         ┌────────────────────────┐                                  │   │
│  │         │  /mnt/BIG/filme/       │                                  │   │
│  │         │  (ZFS storage)         │                                  │   │
│  │         └────────────────────────┘                                  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ infrastructure                                                       │   │
│  │  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────┐           │   │
│  │  │ tsdproxy │  │  pihole  │  │keepalived │  │   diun   │           │   │
│  │  │  :8085   │  │  :8053   │  │  (master) │  │ (weekly) │           │   │
│  │  └──────────┘  └──────────┘  └───────────┘  └──────────┘           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ nfs + tailscale
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                amy (ubuntu)                                 │
│                               192.168.21.130                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ monitoring & notifications                                           │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────┐           │   │
│  │  │   ntfy   │  │  beszel  │  │ cadvisor │  │ netalertx │           │   │
│  │  │   :8080  │  │  :8090   │  │  :8081   │  │   :20211  │           │   │
│  │  └────┬─────┘  └──────────┘  └──────────┘  └───────────┘           │   │
│  │       │                                                             │   │
│  │       │◄──────── notifications from bender (diun, updates)          │   │
│  └───────┴─────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ productivity                                                         │   │
│  │  ┌───────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐           │   │
│  │  │vaultwarden│  │ miniflux │  │  mealie  │  │ homepage │           │   │
│  │  │   :8081   │  │  :8082   │  │  :9925   │  │  :3000   │           │   │
│  │  └───────────┘  └────┬─────┘  └──────────┘  └────┬─────┘           │   │
│  │                      │                           │                  │   │
│  │                      │    ┌──────────────────────┘                  │   │
│  │                      ▼    ▼                                         │   │
│  │               ┌─────────────┐                                       │   │
│  │               │  postgresql │ (atuin, miniflux, sss)                │   │
│  │               │    :5432    │                                       │   │
│  │               └─────────────┘                                       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ infrastructure                                                       │   │
│  │  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────┐           │   │
│  │  │ tsdproxy │  │  pihole  │  │keepalived │  │   diun   │           │   │
│  │  │  :8085   │  │  :8053   │  │  (backup) │  │ (weekly) │           │   │
│  │  └──────────┘  └──────────┘  └───────────┘  └──────────┘           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

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
| **pihole dns** | 192.168.21.100 | bender (priority 150) | amy (priority 100) |

---

## repository structure

```
.
├── README.md                    # this file
├── bender/                      # TrueNAS Scale host
│   ├── .env.template            # environment variables template
│   ├── .env.gpg                 # encrypted production secrets
│   ├── docker-compose.yaml      # main compose file (v86)
│   ├── configs/
│   │   └── keepalived/
│   │       └── keepalived.conf  # pihole ha (master)
│   ├── docs/                    # 8 documentation files
│   └── scripts/                 # operational scripts
└── amy/                         # ubuntu utilities host
    ├── .env.template            # environment variables template
    ├── docker-compose.yaml      # main compose file (v85)
    ├── configs/
    │   └── keepalived/
    │       └── keepalived.conf  # pihole ha (backup)
    ├── docs/                    # 8 documentation files
    └── scripts/                 # operational scripts
```

---

## services summary

### bender services (24 containers)

| category | services |
|----------|----------|
| **media** | immich, jellyfin, metube |
| **downloads** | transmission, sonarr, radarr, prowlarr, bazarr, lidarr, readarr, unpackerr |
| **productivity** | hedgedoc, syncthing |
| **infrastructure** | postgresql, tsdproxy, pihole, keepalived, dockerproxy |
| **updates** | diun, trivy, dockwatch |

### amy services (27 containers)

| category | services |
|----------|----------|
| **monitoring** | ntfy, beszel, beszel-agent, cadvisor, netalertx |
| **productivity** | vaultwarden, miniflux, mealie, homepage, it-tools |
| **utilities** | atuin, filebrowser, stirling-pdf, lubelogger |
| **finance** | spendspentspent |
| **infrastructure** | postgresql, tsdproxy, pihole, keepalived |
| **updates** | diun, trivy |

---

## quick start

### new deployment

1. **clone repository**
   ```bash
   git clone git@github.com:om1d3/futurama-docker.git
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
   cd /mnt/BIG/filme/docker-compose && docker compose up -d

   # on amy
   cd /docker-compose && docker compose up -d
   ```

---

## documentation

### bender docs

| document | description |
|----------|-------------|
| [01-ARCHITECTURE.md](bender/docs/01-ARCHITECTURE.md) | system design overview |
| [02-SERVICES-CATALOG.md](bender/docs/02-SERVICES-CATALOG.md) | service reference with ports |
| [03-DIRECTORY-STRUCTURE.md](bender/docs/03-DIRECTORY-STRUCTURE.md) | file system layout |
| [04-SECURE-UPDATES.md](bender/docs/04-SECURE-UPDATES.md) | container update system |
| [05-ENV-REFERENCE.md](bender/docs/05-ENV-REFERENCE.md) | environment variables |
| [06-BENEFITS-TRADEOFFS.md](bender/docs/06-BENEFITS-TRADEOFFS.md) | design decisions |
| [07-MAINTENANCE.md](bender/docs/07-MAINTENANCE.md) | operational procedures |
| [08-TROUBLESHOOTING.md](bender/docs/08-TROUBLESHOOTING.md) | problem resolution |

### amy docs

| document | description |
|----------|-------------|
| [01-ARCHITECTURE.md](amy/docs/01-ARCHITECTURE.md) | system design overview |
| [02-SERVICES-CATALOG.md](amy/docs/02-SERVICES-CATALOG.md) | service reference with ports |
| [03-DIRECTORY-STRUCTURE.md](amy/docs/03-DIRECTORY-STRUCTURE.md) | file system layout |
| [04-SECURE-UPDATES.md](amy/docs/04-SECURE-UPDATES.md) | container update system |
| [05-ENV-REFERENCE.md](amy/docs/05-ENV-REFERENCE.md) | environment variables |
| [06-BENEFITS-TRADEOFFS.md](amy/docs/06-BENEFITS-TRADEOFFS.md) | design decisions |
| [07-MAINTENANCE.md](amy/docs/07-MAINTENANCE.md) | operational procedures |
| [08-TROUBLESHOOTING.md](amy/docs/08-TROUBLESHOOTING.md) | problem resolution |

---

## key design decisions

| decision | rationale |
|----------|-----------|
| **two-host split** | failure isolation, TrueNAS upgrade immunity |
| **pihole ha** | zero-downtime dns with keepalived vrrp |
| **local ntfy** | notifications work without internet |
| **security-first updates** | trivy scanning before deployment |
| **shared postgresql per host** | ram efficiency, centralized backup |

---

## tailscale urls

access via tailnet (bunny-enigmatic.ts.net):

| service | url |
|---------|-----|
| immich | https://immich.bunny-enigmatic.ts.net |
| jellyfin | https://jellyfin.bunny-enigmatic.ts.net |
| transmission | https://transmission.bunny-enigmatic.ts.net |
| homepage | https://homepage.bunny-enigmatic.ts.net |
| vaultwarden | https://vaultwarden.bunny-enigmatic.ts.net |
| miniflux | https://miniflux.bunny-enigmatic.ts.net |
| beszel | https://beszel.bunny-enigmatic.ts.net |

see service catalogs for complete url list.

---

## license

private infrastructure documentation.
