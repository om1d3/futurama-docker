# futurama docker infrastructure

## home lab container infrastructure

two-host docker infrastructure for media services, utilities, and home automation.

---

## network architecture

```
                                             LAN network
                                           192.168.21.0/24
                                                  |
                         +------------------------+------------------------+
                         |                        |                        |
                         v                        v                        v
                +------------------+    +------------------+    +------------------+
                |     bender       |    |   pihole VIP     |    |       amy        |
                |  192.168.21.121  |    |  192.168.21.100  |    |  192.168.21.130  |
                |  TrueNAS Scale   |    |   (keepalived)   |    |  Intel i3-2310M  |
                +--------+---------+    +--------+---------+    +--------+---------+
                         |                       |                       |
                         |          +------------+------------+          |
                         |          |                         |          |
                         |          v                         v          |
                         |   +------------+           +------------+     |
                         |   |   pihole   |<---VRRP-->|   pihole   |     |
                         |   |  (master)  |  failover |  (backup)  |     |
                         |   | priority150|           | priority100|     |
                         |   |  port 8053 |           |  port 8053 |     |
                         |   +------------+           +------------+     |
                         |          |                         |          |
                         +----------+-------------------------+----------+
```

### keepalived DNS failover

```
                +-----------------------------------------------------------------------+
                |                         keepalived VRRP                               |
                +-----------------------------------------------------------------------+
                |                                                                       |
                |  normal operation:                                                    |
                |  +----------+       +------------+       +------------------+         |
                |  |  client  |------>|  VIP .100  |------>| bender pihole    |         |
                |  | DNS query|       |  (master)  |       | (serves request) |         |
                |  +----------+       +------------+       +------------------+         |
                |                                                                       |
                |  failover (bender pihole down):                                       |
                |  +----------+       +------------+       +------------------+         |
                |  |  client  |------>|  VIP .100  |------>| amy pihole       |         |
                |  | DNS query|       |  (backup)  |       | (serves request) |         |
                |  +----------+       +------------+       +------------------+         |
                |                                                                       |
                |  health check: wget to pihole admin (port 8053)                       |
                |  failover time: ~5 seconds                                            |
                |                                                                       |
                +-----------------------------------------------------------------------+
```

---

## services architecture

```
                +-----------------------------------------------------------------------+
                |                    bender (TrueNAS Scale) 192.168.21.121              |
                +-----------------------------------------------------------------------+
                |                                                                       |
                |  +-----------------------------+  +-----------------------------+     |
                |  | media services              |  | download services           |     |
                |  | +---------+ +---------+     |  | +-------------+ +---------+ |     |
                |  | | immich  | |jellyfin |     |  | |transmission | | sonarr  | |     |
                |  | | :2283   | | :8080   |     |  | |    :9091    | | :8989   | |     |
                |  | +---------+ +---------+     |  | |    (vpn)    | +---------+ |     |
                |  | +---------+ +---------+     |  | +-------------+ +---------+ |     |
                |  | | metube  | |hedgedoc |     |  | | prowlarr    | | radarr  | |     |
                |  | | :8383   | | :8000   |     |  | |    :9696    | | :7878   | |     |
                |  | +---------+ +---------+     |  | +-------------+ +---------+ |     |
                |  +-------------+---------------+  +-----------------------------+     |
                |                |                                                      |
                |                v                                                      |
                |  +---------------------------+                                        |
                |  | postgresql (vectorchord)  |                                        |
                |  | :5432 [immich, hedgedoc]  |                                        |
                |  +---------------------------+                                        |
                |                                                                       |
                |  +---------------------------------------------------------------+    |
                |  | infrastructure                                                |    |
                |  | +---------+ +---------+ +-----------+ +------+ +------------+ |    |
                |  | |tsdproxy | | pihole  | |keepalived | | diun | |   trivy    | |    |
                |  | | :8085   | | :8053   | | (master)  | |weekly| |   :8082    | |    |
                |  | +---------+ +---------+ +-----------+ +------+ +------------+ |    |
                |  +---------------------------------------------------------------+    |
                |                                                                       |
                +-----------------------------------------------------------------------+
                                                   |
                                                   | nfs + tailscale
                                                   v
                +-----------------------------------------------------------------------+
                |                      amy (Debian) 192.168.21.130                      |
                +-----------------------------------------------------------------------+
                |                                                                       |
                |  +-------------------------------+  +-----------------------------+   |
                |  | monitoring & notifications    |  | productivity                |   |
                |  | +---------+ +---------+       |  | +-----------+ +-----------+ |   |
                |  | |  ntfy   | | beszel  |       |  | |vaultwarden| | miniflux  | |   |
                |  | | :8080   | | :8090   |       |  | |   :8081   | |   :8082   | |   |
                |  | +---------+ +---------+       |  | +-----------+ +-----------+ |   |
                |  | +---------+ +-----------+     |  | +-----------+ +-----------+ |   |
                |  | |cadvisor | | netalertx |     |  | |  mealie   | | homepage  | |   |
                |  | | :8081   | |  :20211   |     |  | |   :9925   | |   :3000   | |   |
                |  | +---------+ +-----------+     |  | +-----------+ +-----------+ |   |
                |  +-------------------------------+  +-------------+---------------+   |
                |                                                   |                   |
                |                                                   v                   |
                |                                     +---------------------------+     |
                |                                     | postgresql                |     |
                |                                     | :5432 [atuin,miniflux,sss]|     |
                |                                     +---------------------------+     |
                |                                                                       |
                |  +---------------------------------------------------------------+    |
                |  | infrastructure                                                |    |
                |  | +---------+ +---------+ +-----------+ +------+ +------------+ |    |
                |  | |tsdproxy | | pihole  | |keepalived | | diun | |   trivy    | |    |
                |  | | :8085   | | :8053   | | (backup)  | |weekly| |   :8082    | |    |
                |  | +---------+ +---------+ +-----------+ +------+ +------------+ |    |
                |  +---------------------------------------------------------------+    |
                |                                                                       |
                +-----------------------------------------------------------------------+
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
| **pihole DNS** | 192.168.21.100 | bender (priority 150) | amy (priority 100) |

---

## repository structure

```
                .
                ├── README.md
                ├── docs/
                │   └── PIHOLE-DNS-AUTO-POPULATION.md
                ├── bender/
                │   ├── .env.template
                │   ├── .env.gpg
                │   ├── docker-compose.yaml
                │   ├── configs/keepalived/keepalived.conf
                │   ├── docs/
                │   └── scripts/
                │       └── pihole-dns-update.sh
                └── amy/
                    ├── .env.template
                    ├── docker-compose.yaml
                    ├── configs/keepalived/keepalived.conf
                    ├── docs/
                    └── scripts/
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

```bash
# clone
git clone git@github.com:om1d3/futurama-docker.git
cd futurama-docker

# configure
cp bender/.env.template bender/.env && nano bender/.env
cp amy/.env.template amy/.env && nano amy/.env

# deploy to bender
scp bender/docker-compose.yaml bender/.env root@192.168.21.121:/mnt/BIG/filme/docker-compose/

# deploy to amy
scp amy/docker-compose.yaml amy/.env root@192.168.21.130:/docker-compose/

# start services
ssh root@192.168.21.121 'cd /mnt/BIG/filme/docker-compose && docker compose up -d'
ssh root@192.168.21.130 'cd /docker-compose && docker compose up -d'
```

---

## documentation

### shared documentation

| document | description |
|----------|-------------|
| [PIHOLE-DNS-AUTO-POPULATION.md](docs/PIHOLE-DNS-AUTO-POPULATION.md) | automatic DNS record population for docker services |

### host-specific documentation

| bender | amy |
|--------|-----|
| [01-ARCHITECTURE.md](bender/docs/01-ARCHITECTURE.md) | [01-ARCHITECTURE.md](amy/docs/01-ARCHITECTURE.md) |
| [02-SERVICES-CATALOG.md](bender/docs/02-SERVICES-CATALOG.md) | [02-SERVICES-CATALOG.md](amy/docs/02-SERVICES-CATALOG.md) |
| [03-DIRECTORY-STRUCTURE.md](bender/docs/03-DIRECTORY-STRUCTURE.md) | [03-DIRECTORY-STRUCTURE.md](amy/docs/03-DIRECTORY-STRUCTURE.md) |
| [04-SECURE-UPDATES.md](bender/docs/04-SECURE-UPDATES.md) | [04-SECURE-UPDATES.md](amy/docs/04-SECURE-UPDATES.md) |
| [05-ENV-REFERENCE.md](bender/docs/05-ENV-REFERENCE.md) | [05-ENV-REFERENCE.md](amy/docs/05-ENV-REFERENCE.md) |
| [06-BENEFITS-TRADEOFFS.md](bender/docs/06-BENEFITS-TRADEOFFS.md) | [06-BENEFITS-TRADEOFFS.md](amy/docs/06-BENEFITS-TRADEOFFS.md) |
| [07-MAINTENANCE.md](bender/docs/07-MAINTENANCE.md) | [07-MAINTENANCE.md](amy/docs/07-MAINTENANCE.md) |
| [08-TROUBLESHOOTING.md](bender/docs/08-TROUBLESHOOTING.md) | [08-TROUBLESHOOTING.md](amy/docs/08-TROUBLESHOOTING.md) |

---

## automatic DNS resolution

all services with `tsdproxy.enable: "true"` labels automatically get DNS entries in pi-hole. a cron job on bender scans running containers every 5 minutes and updates pi-hole's configuration.

| feature | value |
|---------|-------|
| **domain suffix** | `home.arpa` |
| **scan interval** | every 5 minutes |
| **replication** | nebula-sync to amy (hourly) |
| **script location** | `/root/pihole-dns-update.sh` on bender |

### example DNS names

| bender services | amy services |
|-----------------|--------------|
| books.home.arpa | ntfy.home.arpa |
| media.home.arpa | vault.home.arpa |
| photo.home.arpa | beszel.home.arpa |
| pad.home.arpa | home.home.arpa |
| sync.home.arpa | mealie.home.arpa |
| transmission.home.arpa | rss.home.arpa |

see [PIHOLE-DNS-AUTO-POPULATION.md](docs/PIHOLE-DNS-AUTO-POPULATION.md) for implementation details.

---

## key design decisions

| decision | rationale |
|----------|-----------|
| **two-host split** | failure isolation, TrueNAS upgrade immunity |
| **pihole HA** | zero-downtime DNS with keepalived VRRP |
| **automatic DNS** | containers get `*.home.arpa` entries automatically |
| **local ntfy** | notifications work without internet |
| **security-first updates** | trivy scanning before deployment |
| **shared postgresql per host** | ram efficiency, centralized backup |

---

## tailscale urls

| service | url |
|---------|-----|
| immich | https://immich.bunny-enigmatic.ts.net |
| jellyfin | https://jellyfin.bunny-enigmatic.ts.net |
| transmission | https://transmission.bunny-enigmatic.ts.net |
| homepage | https://homepage.bunny-enigmatic.ts.net |
| vaultwarden | https://vaultwarden.bunny-enigmatic.ts.net |
| miniflux | https://miniflux.bunny-enigmatic.ts.net |
| beszel | https://beszel.bunny-enigmatic.ts.net |

---

## license

private infrastructure documentation.
