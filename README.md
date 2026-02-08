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
                |  | media services              |  | download services (via VPN) |     |
                |  | +---------+ +---------+     |  | +-------------+ +---------+ |     |
                |  | | immich  | |jellyfin |     |  | |transmission | | sonarr  | |     |
                |  | | :2283   | | :8096   |     |  | |    :9091    | | :8989   | |     |
                |  | +---------+ +---------+     |  | |  (gluetun)  | +---------+ |     |
                |  | +---------+ +---------+     |  | +-------------+ +---------+ |     |
                |  | |audio    | | metube  |     |  | | prowlarr    | | radarr  | |     |
                |  | |bookshelf| | :8383   |     |  | |    :9696    | | :7878   | |     |
                |  | | :8081   | +---------+     |  | +-------------+ +---------+ |     |
                |  | +---------+ +---------+     |  | +---------+ +-------------+ |     |
                |  | | spotdl  | |jdownldr |     |  | | lidarr  | |   readarr  | |      |
                |  | | :8800   | | :5800   |     |  | | :8686   | |    :8787   | |      |
                |  | +---------+ +---------+     |  | +---------+ +-------------+ |     |
                |  +-----------------------------+  | +---------+ +-------------+ |     |
                |                                   | | bazarr  | |  unpackerr  | |     |
                |  +-----------------------------+  | | :6767   | | (no port)   | |     |
                |  | collaboration               |  | +---------+ +-------------+ |     |
                |  | +---------+ +-----------+   |  +-----------------------------+     |
                |  | |hedgedoc | |vaultwarden|   |                                      |
                |  | | :3000   | |   :8484   |   |                                      |
                |  | +---------+ +-----------+   |                                      |
                |  +-----------------------------+                                      |
                |                                                                       |
                |  +---------------------------+                                        |
                |  | postgresql (vectorchord)  |                                        |
                |  | :5432 [immich, hedgedoc]  |                                        |
                |  +---------------------------+                                        |
                |                                                                       |
                |  +---------------------------------------------------------------+    |
                |  | infrastructure                                                |    |
                |  | +---------+ +---------+ +-----------+ +------+ +------------+ |    |
                |  | |tsdproxy | | pihole  | |keepalived | | diun | |   trivy    | |    |
                |  | | :8085   | | :8053   | | (master)  | |daily | |   :8083    | |    |
                |  | +---------+ +---------+ +-----------+ +------+ +------------+ |    |
                |  | +---------+ +-----------+ +-----------+ +------------------+  |    |
                |  | |cadvisor | |nebula-sync| |flaresolvrr| |  beszel-agent    |  |    |
                |  | | :9099   | | (hourly)  | |   :8191   | |  (host network)  |  |    |
                |  | +---------+ +-----------+ +-----------+ +------------------+  |    |
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
                |  | |  ntfy   | | beszel  |       |  | |  stirling | | miniflux  | |   |
                |  | | :8888   | | :8090   |       |  | |   :8080   | |   :8385   | |   |
                |  | +---------+ +---------+       |  | +-----------+ +-----------+ |   |
                |  | +---------+ +-----------+     |  | +-----------+ +-----------+ |   |
                |  | |cadvisor | | netalertx |     |  | |  mealie   | | homepage  | |   |
                |  | | :9099   | |  :20211   |     |  | |   :8456   | |   :3003   | |   |
                |  | +---------+ +-----------+     |  | +-----------+ +-----------+ |   |
                |  | +---------+ +-----------+     |  | +-----------+ +-----------+ |   |
                |  | |telegraf | |  dozzle   |     |  | |  it-tools | |   atuin   | |   |
                |  | | (host)  | |  :8182    |     |  | |   :8181   | |   :8777   | |   |
                |  | +---------+ +-----------+     |  | +-----------+ +-----------+ |   |
                |  +-------------------------------+  | +-----------+ +-----------+ |   |
                |                                     | |filebrowser| |   wallos  | |   |
                |  +-------------------------------+  | |   :8082   | |   :8283   | |   |
                |  | finance & automation          |  | +-----------+ +-----------+ |   |
                |  | +----------+ +-----------+    |  | +-----------+ +-----------+ |   |
                |  | |  money   | |  limdius  |    |  | |   argus   | | lubelogger| |   |
                |  | |  :9021   | |  :5050    |    |  | |   :8282   | |   :8989   | |   |
                |  | +----------+ +-----------+    |  | +-----------+ +-----------+ |   |
                |  +-------------------------------+  +-----------------------------+   |
                |                                                                       |
                |  +-------------------------------+  +---------------------------+     |
                |  | postgres-backup               |  | postgresql                |     |
                |  | [atuin,miniflux,sss,          |<-| :5432 [atuin,miniflux,sss,|     |
                |  |   mealie,stirling]            |  |      mealie,stirling]     |     |
                |  +-------------------------------+  +---------------------------+     |
                |                                                                       |
                |  +---------------------------------------------------------------+    |
                |  | infrastructure                                                |    |
                |  | +---------+ +---------+ +-----------+ +------+ +------------+ |    |
                |  | |tsdproxy | | pihole  | |keepalived | | diun | |   trivy    | |    |
                |  | | :8085   | | :8053   | | (backup)  | |weekly| |   :8083    | |    |
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
| **bender** | TrueNAS Scale (HP MicroServer Gen8, Xeon E3-1265L V2) | 192.168.21.121 | media services, downloads, primary storage |
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
                    ├── configs/
                    │   ├── keepalived/keepalived.conf
                    │   └── telegraf/telegraf.conf
                    ├── docs/
                    └── scripts/
```

---

## services summary

### bender services (33 containers)

| category | services |
|----------|----------|
| **media** | immich_server, immich_machine_learning, immich_redis, jellyfin, audiobookshelf, metube, spotdl |
| **downloads** | gluetun (VPN), transmission, sonarr, radarr, prowlarr, bazarr, lidarr, readarr, unpackerr, jdownloader, flaresolverr |
| **collaboration** | hedgedoc, vaultwarden, syncthing |
| **databases** | postgresql, postgres-backup |
| **dns & ha** | pihole, keepalived, nebula-sync |
| **infrastructure** | tsdproxy, dockwatch, dockerproxy |
| **monitoring** | beszel-agent, cadvisor |
| **updates** | diun, trivy |

### amy services (29 containers)

| category | services |
|----------|----------|
| **monitoring** | ntfy, beszel, beszel-agent, cadvisor, netalertx, telegraf, dozzle |
| **productivity** | stirling-pdf, miniflux, mealie, homepage, it-tools, atuin, filebrowser, wallos, argus |
| **finance & automation** | spendspentspent, lubelogger, limdius, playwright-chrome |
| **databases** | postgresql, postgres-backup, valkey |
| **dns & ha** | pihole, keepalived |
| **infrastructure** | tsdproxy, dockwatch |
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
| photo.home.arpa | ntfy.home.arpa |
| media.home.arpa | vault.home.arpa |
| books.home.arpa | beszel.home.arpa |
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
| **gluetun VPN** | centralized VPN for all download services |

---

## service urls

### bender services (192.168.21.121)

| service | tsdproxy name | LAN url | tailscale url |
|---------|---------------|---------|---------------|
| immich | photo | http://photo.home.arpa:2283 | https://photo.bunny-enigmatic.ts.net |
| jellyfin | media | http://media.home.arpa:8096 | https://media.bunny-enigmatic.ts.net |
| audiobookshelf | books | http://books.home.arpa:8081 | https://books.bunny-enigmatic.ts.net |
| transmission | transmission | http://transmission.home.arpa:9091 | https://transmission.bunny-enigmatic.ts.net |
| hedgedoc | pad | http://pad.home.arpa:3000 | https://pad.bunny-enigmatic.ts.net |
| vaultwarden | vault | http://vault.home.arpa:8484 | https://vault.bunny-enigmatic.ts.net |
| syncthing | sync | http://sync.home.arpa:8384 | https://sync.bunny-enigmatic.ts.net |
| metube | metube | http://metube.home.arpa:8383 | https://metube.bunny-enigmatic.ts.net |
| jdownloader | jdown | http://jdown.home.arpa:5800 | https://jdown.bunny-enigmatic.ts.net |
| spotdl | spotdl | http://spotdl.home.arpa:8800 | https://spotdl.bunny-enigmatic.ts.net |
| prowlarr | prowlarr | http://prowlarr.home.arpa:9696 | https://prowlarr.bunny-enigmatic.ts.net |
| sonarr | sonarr | http://sonarr.home.arpa:8989 | https://sonarr.bunny-enigmatic.ts.net |
| radarr | radarr | http://radarr.home.arpa:7878 | https://radarr.bunny-enigmatic.ts.net |
| lidarr | lidarr | http://lidarr.home.arpa:8686 | https://lidarr.bunny-enigmatic.ts.net |
| readarr | readarr | http://readarr.home.arpa:8787 | https://readarr.bunny-enigmatic.ts.net |
| bazarr | bazarr | http://bazarr.home.arpa:6767 | https://bazarr.bunny-enigmatic.ts.net |
| pihole | pihole-bender | http://pihole-bender.home.arpa:8053 | https://pihole-bender.bunny-enigmatic.ts.net |
| cadvisor | bender-cadvisor | http://bender-cadvisor.home.arpa:9099 | https://bender-cadvisor.bunny-enigmatic.ts.net |
| dockwatch | bender-dockwatch | http://bender-dockwatch.home.arpa:9999 | https://bender-dockwatch.bunny-enigmatic.ts.net |

### amy services (192.168.21.130)

| service | tsdproxy name | LAN url | tailscale url |
|---------|---------------|---------|---------------|
| ntfy | ntfy | http://ntfy.home.arpa:8888 | https://ntfy.bunny-enigmatic.ts.net |
| beszel | beszel | http://beszel.home.arpa:8090 | https://beszel.bunny-enigmatic.ts.net |
| stirling-pdf | pdf | http://pdf.home.arpa:8080 | https://pdf.bunny-enigmatic.ts.net |
| homepage | home | http://home.home.arpa:3003 | https://home.bunny-enigmatic.ts.net |
| miniflux | rss | http://rss.home.arpa:8385 | https://rss.bunny-enigmatic.ts.net |
| mealie | mealie | http://mealie.home.arpa:8456 | https://mealie.bunny-enigmatic.ts.net |
| atuin | atuin | http://atuin.home.arpa:8777 | https://atuin.bunny-enigmatic.ts.net |
| it-tools | it-tools | http://it-tools.home.arpa:8181 | https://it-tools.bunny-enigmatic.ts.net |
| filebrowser | files | http://files.home.arpa:8082 | https://files.bunny-enigmatic.ts.net |
| wallos | wallos | http://wallos.home.arpa:8283 | https://wallos.bunny-enigmatic.ts.net |
| argus | argus | http://argus.home.arpa:8282 | https://argus.bunny-enigmatic.ts.net |
| lubelogger | lube | http://lube.home.arpa:8989 | https://lube.bunny-enigmatic.ts.net |
| spendspentspent | money | http://money.home.arpa:9021 | https://money.bunny-enigmatic.ts.net |
| limdius | limdius | http://limdius.home.arpa:5050 | https://limdius.bunny-enigmatic.ts.net |
| cadvisor | cadvisor | http://cadvisor.home.arpa:9099 | https://cadvisor.bunny-enigmatic.ts.net |
| netalertx | netalertx | http://netalertx.home.arpa:20211 | https://netalertx.bunny-enigmatic.ts.net |
| dozzle | logs | http://logs.home.arpa:8182 | https://logs.bunny-enigmatic.ts.net |
| pihole | pihole-amy | http://pihole-amy.home.arpa:8053 | https://pihole-amy.bunny-enigmatic.ts.net |
| dockwatch | amy-dockwatch | http://amy-dockwatch.home.arpa:9999 | https://amy-dockwatch.bunny-enigmatic.ts.net |

---

## license

private infrastructure documentation.
