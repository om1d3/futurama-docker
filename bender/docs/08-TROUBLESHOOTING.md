# bender troubleshooting guide

## diagnostic procedures and common fixes

**document version:** 2.0
**infrastructure version:** 105
**last updated:** february 2026

---

## table of contents

1. [quick diagnostics](#quick-diagnostics)
2. [container issues](#container-issues)
3. [VPN and download issues](#vpn-and-download-issues)
4. [postgresql issues](#postgresql-issues)
5. [DNS and networking issues](#dns-and-networking-issues)
6. [immich issues](#immich-issues)
7. [jellyfin issues](#jellyfin-issues)
8. [ARR stack issues](#arr-stack-issues)
9. [update system issues](#update-system-issues)
10. [monitoring issues](#monitoring-issues)
11. [TrueNAS-specific issues](#truenas-specific-issues)
12. [historical fixes reference](#historical-fixes-reference)

---

## quick diagnostics

### first response checklist

```bash
cd /mnt/BIG/filme/docker-compose

# 1. how many containers are running vs expected?
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -c "Up"
# expected: 33 (all active services in v105)

# 2. which containers are NOT running?
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"

# 3. any containers restarting?
docker ps -a --format "{{.Names}}\t{{.Status}}" | grep -i "restarting"

# 4. any containers unhealthy?
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "unhealthy"

# 5. VPN connected?
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null | head -3

# 6. disk space ok?
df -h /mnt/BIG/

# 7. ZFS pool healthy?
zpool status BIG | head -10

# 8. system resources ok?
free -h && uptime
```

### health check suite

```bash
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/

# full check
bash /tmp/health-checks.sh all

# specific services
bash /tmp/health-checks.sh postgres
bash /tmp/health-checks.sh immich
bash /tmp/health-checks.sh vaultwarden

rm /tmp/health-checks.sh
```

---

## container issues

### container won't start

```bash
# check exit code and logs
docker inspect <container> --format '{{.State.ExitCode}}'
docker logs <container> --tail 50

# common exit codes:
# 1   — application error (check logs)
# 126 — permission denied on entrypoint
# 127 — entrypoint not found (wrong image?)
# 137 — OOM killed
# 139 — segfault
```

**fix — out of memory (exit 137):**

```bash
# check system memory
free -h

# check per-container memory usage
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}" | sort -k2 -h -r | head -10

# immich_machine_learning is typically the heaviest consumer
# if RAM is exhausted, consider restarting ML service
docker compose restart immich_machine_learning
```

### container in restart loop

```bash
# stop the loop
docker compose stop <container>

# check what's failing
docker logs <container> --tail 100

# common causes:
# - gluetun not ready (for VPN-routed services)
# - postgres not ready (for database-dependent services)
# - port conflict
# - volume mount path doesn't exist
```

**fix — gluetun not ready (VPN-routed services):**

```bash
# check gluetun first
docker compose ps gluetun
docker logs gluetun --tail 10

# if gluetun is healthy, restart the affected service
docker compose restart <service>

# if gluetun is down, restart it and wait
docker compose restart gluetun
sleep 30
docker compose restart <service>
```

### container shows "unhealthy"

```bash
# check what the healthcheck tests
docker inspect <container> --format '{{json .Config.Healthcheck}}' | jq .

# check healthcheck output
docker inspect <container> --format '{{json .State.Health}}' | jq '.Log[-3:]'
```

> **note on healthchecks:** several containers had healthcheck issues resolved in past versions — hedgedoc uses Node.js (not curl/wget), immich_machine_learning uses python3, nebula-sync has healthcheck disabled, tsdproxy on amy had wget removed. see the [historical fixes](#historical-fixes-reference) section.

---

## VPN and download issues

### gluetun won't connect

**symptoms:** gluetun logs show connection errors, VPN-routed services have no internet

```bash
# check gluetun logs
docker logs gluetun --tail 30

# check if VPN credentials are set
grep SURFSHARK /mnt/BIG/filme/docker-compose/.env

# verify /dev/net/tun exists
ls -la /dev/net/tun

# restart gluetun
docker compose restart gluetun
sleep 30
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null
```

**common gluetun errors:**

| error | cause | fix |
|-------|-------|-----|
| `AUTH: Received control message: AUTH_FAILED` | wrong OpenVPN credentials | update SURFSHARK_OPENVPN_USER and PASSWORD in .env |
| `TLS Error: TLS handshake failed` | server issue or network block | try different SERVER_COUNTRIES |
| `/dev/net/tun: no such file or directory` | TUN device not available | check TrueNAS docker settings |
| `DNS resolution failed` | DNS issue inside gluetun | verify DOT=off is set, restart gluetun |

### transmission can't connect to peers

**symptoms:** torrents show 0 peers, no upload/download

```bash
# verify VPN is connected
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null

# check transmission bind address
docker exec transmission env | grep BIND
# should show: TRANSMISSION_BIND_ADDRESS_IPV4=0.0.0.0

# check peer port (51413)
docker exec gluetun wget -qO- "https://am.i.mullvad.net/port/51413" 2>/dev/null
```

> **historical note:** WireGuard was abandoned in v104 because it blocked outbound peer connections on all surfshark servers. if peer connectivity breaks again, verify the VPN_TYPE is still `openvpn`.

### transmission version warning

```bash
# verify pinned version
docker inspect transmission --format '{{.Config.Image}}'
# MUST show: lscr.io/linuxserver/transmission:4.0.5

# if someone ran "docker compose pull transmission" — it should NOT upgrade
# because the tag is explicit (4.0.5), not :latest
```

> **critical:** transmission 4.0.6+ is NOT on the FileList client whitelist. if accidentally upgraded, rollback immediately.

### jdownloader not accessible

jdownloader runs through gluetun on port 5800:

```bash
# check jdownloader is running
docker ps | grep jdownloader

# check gluetun is healthy
docker logs gluetun --tail 5

# port 5800 is exposed through gluetun — verify
curl -s http://localhost:5800 | head -5
```

---

## postgresql issues

### postgres won't start

```bash
# check logs
docker logs postgres --tail 50

# check disk space
df -h /mnt/BIG/
du -sh /mnt/BIG/filme/immich/postgresql/

# check ZFS pool
zpool status BIG

# check permissions
ls -la /mnt/BIG/filme/immich/postgresql/

# check if shared_preload_libraries is the issue
docker logs postgres 2>&1 | grep -i "could not load\|shared_preload"
```

> **important:** bender's postgres requires `shared_preload_libraries=vchord.so,vectors.so`. if these extensions are missing from the image, postgres won't start. ensure the image is `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`.

### database connection refused

```bash
# verify postgres is running and healthy
docker compose ps postgres
docker exec postgres pg_isready -U postgres

# check from immich's perspective
docker logs immich_server --tail 20 2>&1 | grep -i "connect\|database\|error"

# check from hedgedoc's perspective
docker logs hedgedoc --tail 20 2>&1 | grep -i "connect\|database\|error"
```

**fix — postgres healthy but services can't connect:**

```bash
cd /mnt/BIG/filme/docker-compose

# restart dependent services
docker compose restart immich_server immich_machine_learning hedgedoc
```

### postgres-backup fails

```bash
# check logs
docker logs postgres-backup --tail 20

# verify databases exist
docker exec postgres psql -U postgres -l | grep -E "immich|hedgedoc"

# verify compose matches
grep POSTGRES_DB docker-compose.yaml
# should show: POSTGRES_DB=immich,hedgedoc
```

### immich database table queries

when debugging immich database issues, note that the `user` table requires quoting:

```bash
# correct (with quotes around "user")
docker exec postgres psql -U postgres -d immich -c 'SELECT COUNT(*) FROM "user";'

# incorrect (will fail with "syntax error")
docker exec postgres psql -U postgres -d immich -c 'SELECT COUNT(*) FROM user;'
```

---

## DNS and networking issues

### pihole not resolving

```bash
# test DNS
dig google.com @127.0.0.1
dig google.com @192.168.21.121
dig google.com @192.168.21.100  # VIP

# check pihole
docker compose ps pihole
docker logs pihole --tail 20

# restart pihole
docker compose restart pihole
```

### keepalived VIP issues

```bash
# check if bender holds the VIP (it should under normal operation)
ip addr show | grep 192.168.21.100

# if VIP is missing, check keepalived
docker logs keepalived --tail 20

# check keepalived config is mounted
docker inspect keepalived --format '{{json .Mounts}}' | jq '.[].Source'
# should include keepalived.conf

# restart keepalived
docker compose restart keepalived
```

### .home.arpa domains not resolving

```bash
# test a local domain
dig media.home.arpa @192.168.21.100

# check pihole.toml for DNS entries
docker exec pihole cat /etc/pihole/pihole.toml | grep -A50 "hosts ="

# check auto-population script last run
tail -5 /var/log/pihole-dns-export.log

# force DNS update
/root/pihole-dns-update.sh

# if entries are present but not resolving, restart pihole
docker compose restart pihole
```

### containers can't reach external services

```bash
# for bridge-networked services — check DNS anchor
docker inspect <container> --format '{{json .HostConfig.Dns}}'
# should show: ["192.168.21.100"]

# test from inside a container
docker exec <container> nslookup google.com 192.168.21.100

# for VPN-routed services — check gluetun
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null
```

---

## immich issues

### immich not loading / 502 error

```bash
# check all immich components
docker compose ps immich_server immich_machine_learning immich_redis postgres

# check immich server logs
docker logs immich_server --tail 30

# check ML service
docker logs immich_machine_learning --tail 20

# check redis
docker exec immich_redis redis-cli ping

# check postgres from immich
docker exec postgres psql -U postgres -d immich -c "SELECT 1;"

# restart immich stack
docker compose restart immich_redis immich_server immich_machine_learning
```

### immich ML service unhealthy

**symptoms:** `immich_machine_learning` shows "(unhealthy)"

```bash
# check healthcheck output
docker inspect immich_machine_learning --format '{{json .State.Health}}' | jq '.Log[-3:]'

# the healthcheck uses python3 (v104 fix — curl not available)
# verify the check works manually
docker exec immich_machine_learning python3 -c "
import http.client
c=http.client.HTTPConnection('localhost',3003)
c.request('GET','/ping')
r=c.getresponse()
print(f'Status: {r.status}')
"
```

### immich redis "RDB format version" error

this was fixed in v94 by upgrading from `redis:6.2-alpine` to `redis:7-alpine`. if the error reappears:

```bash
# verify redis image
docker inspect immich_redis --format '{{.Config.Image}}'
# should show: redis:7-alpine

# if wrong, check compose file and recreate
docker compose up -d --force-recreate immich_redis
```

### immich photos not appearing after upload

```bash
# check upload directory
ls -la /mnt/BIG/filme/immich/photos/ | tail -10

# check immich server logs for processing errors
docker logs immich_server --tail 50 2>&1 | grep -i "error\|upload\|process"

# check ML is processing
docker logs immich_machine_learning --tail 20
```

---

## jellyfin issues

### jellyfin library path errors

**symptoms:** logs show "Access to path /data/tvshows is denied" or missing metadata images

this was fixed in v105 by adding the `/data/tvshows` volume mount mapping to `/mnt/BIG/filme/seriale`.

```bash
# verify volume mounts
docker exec jellyfin ls -la /data/
# should show: movies, tvshows, music

# if /data/tvshows is missing, check compose file
grep tvshows docker-compose.yaml
```

### jellyfin transcoding failures

**symptoms:** FFmpeg exits with error codes (243, 254)

```bash
# check transcode cache
docker exec jellyfin ls -la /config/data/transcodes/ | head -10

# test FFmpeg manually
docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -version

# clear transcode cache
docker exec jellyfin rm -rf /config/data/transcodes/*
```

> **note:** bender has no GPU acceleration (HP BIOS disables iGPU). all transcoding is CPU-only with libx264. limit concurrent transcoding streams to 1-2 at 1080p.

### jellyfin wrong image

v96 corrected the image from `jellyfin/jellyfin:latest` to `lscr.io/linuxserver/jellyfin:latest`:

```bash
# verify correct image
docker inspect jellyfin --format '{{.Config.Image}}'
# should show: lscr.io/linuxserver/jellyfin:latest
```

---

## ARR stack issues

### ARR service can't reach indexers/trackers

all ARR services route through gluetun — if they can't reach external services, check the VPN first:

```bash
# check gluetun
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null

# check from inside an ARR container
docker exec sonarr wget -qO- http://ipinfo.io 2>/dev/null

# if gluetun is down, restart it
docker compose restart gluetun
sleep 30

# ARR services should auto-recover
```

### unpackerr not extracting downloads

```bash
# check unpackerr logs
docker logs unpackerr --tail 20

# verify API connectivity to ARR services (via gluetun internal network)
docker exec unpackerr wget -qO- http://gluetun:8989/api/v3/system/status?apikey=<SONARR_API_KEY> 2>/dev/null | head -5

# verify download directory is accessible
docker exec unpackerr ls -la /downloads/completed/
```

### flaresolverr not solving challenges

```bash
# check flaresolverr status
docker compose ps flaresolverr
docker logs flaresolverr --tail 20

# restart if needed
docker compose restart flaresolverr
```

### prowlarr indexer test failures

```bash
# check prowlarr can reach flaresolverr
docker exec prowlarr wget -qO- http://flaresolverr:8191 2>/dev/null | head -3

# note: prowlarr reaches flaresolverr via gluetun's network
# but flaresolverr is on media-network — they communicate via the docker DNS
```

> **note:** prowlarr uses `network_mode: service:gluetun` but connects to flaresolverr which is on media-network. docker's internal DNS resolution handles this cross-network communication.

---

## update system issues

### secure-container-update.sh not running

```bash
# check cron
crontab -l | grep secure-container

# expected:
# 30 4 * * 6 cp ... /tmp/ && bash /tmp/secure-container-update.sh weekly ...
# 30 4 * * 0-5 cp ... /tmp/ && bash /tmp/secure-container-update.sh retry ...

# check last execution
ls -la /mnt/BIG/filme/docker-compose/configs/secure-update/logs/ | tail -5
tail -20 /mnt/BIG/filme/docker-compose/configs/secure-update/logs/cron.log

# manual test run
cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && \
  bash /tmp/secure-container-update.sh weekly && \
  rm /tmp/secure-container-update.sh
```

### trivy scan failures

```bash
# check trivy
docker compose ps trivy
curl -s http://localhost:8083/healthz

# if unhealthy, clear cache and restart
docker compose stop trivy
rm -rf /mnt/BIG/filme/configs/trivy/*
docker compose start trivy
sleep 30
curl -s http://localhost:8083/healthz
```

### notifications not arriving

```bash
# bender sends to amy's ntfy — check connectivity
wget -qO- http://192.168.21.130:8888/ 2>/dev/null | head -3

# check NTFY_ADDRESS in .env
grep NTFY_ADDRESS /mnt/BIG/filme/docker-compose/.env

# test notification
curl -d "test from bender" http://192.168.21.130:8888/test-topic

# if amy's ntfy is down, notifications fail silently
# check logs instead: cat /mnt/BIG/filme/docker-compose/configs/secure-update/logs/<date>.log
```

### containers stuck in retry queue

```bash
# view queue
cat /mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json | jq .

# manually scan a blocked image
docker pull <image>
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --severity CRITICAL,HIGH <image>

# manual override (skip trivy, update directly)
docker compose pull <service>
docker compose up -d <service>

# clear from retry queue
nano /mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json
```

---

## monitoring issues

### cadvisor high resource usage

```bash
# check current usage
docker stats cadvisor --no-stream

# expected: <1% CPU, <20MB memory (with resource-saving flags)
# verify flags are applied
docker inspect cadvisor --format '{{json .Config.Cmd}}'

# if flags missing, recreate
docker compose up -d --force-recreate cadvisor
sleep 30
docker stats cadvisor --no-stream
```

### grafana dashboard shows no data

the pipeline is: cadvisor (bender:9099) → prometheus (HA VM 192.168.21.220:9090) → grafana

```bash
# 1. verify cadvisor metrics
curl -s http://localhost:9099/metrics | head -5

# 2. check prometheus config on HA VM (via web terminal)
# docker exec prometheus cat /etc/prometheus/prometheus.yml
# should list 192.168.21.121:9099 in scrape targets

# 3. if prometheus config lost (HA VM restart), recreate:
# docker exec prometheus sh -c 'cat > /etc/prometheus/prometheus.yml << EOF
# global:
#   scrape_interval: 1m
#   evaluation_interval: 15s
# alerting:
#   alertmanagers:
#     - static_configs:
#       - targets:
#         - 192.168.21.220:9093
# scrape_configs:
#   - job_name: cadvisor
#     static_configs:
#       - targets:
#         - 192.168.21.130:9099
#         - 192.168.21.121:9099
# EOF'
# docker exec prometheus kill -HUP 1
```

### grafana dashboard configuration

there are two separate grafana dashboards, one per host. each dashboard has its `instance` variable set to **Constant** type (not Query) to lock it to a specific host.

| dashboard | instance variable type | instance value |
|-----------|----------------------|----------------|
| **amy docker** | Constant | `192.168.21.130:9099` |
| **bender docker** | Constant | `192.168.21.121:9099` |

if a dashboard shows data from the wrong host or no data at all, verify the variable configuration:

1. open the dashboard in grafana
2. click **Edit** (top right)
3. click **Settings** → **Variables** tab
4. click on the **instance** variable
5. verify **Variable type** is set to `Constant`
6. verify the **Value** matches the correct host IP and port
7. click **Apply** → **Save dashboard**

> **note:** the dashboards were originally created with a Query-type `instance` variable that showed both hosts in a dropdown. they were changed to Constant type to create dedicated per-host dashboards. if you need to create a new dashboard for a host, duplicate an existing one (Edit → Settings → JSON Model → copy → import) and change the Constant value to the target host.

### beszel-agent not reporting

```bash
# check beszel-agent (host network)
docker ps | grep beszel-agent
docker logs beszel-agent --tail 20

# verify BESZEL_KEY is set
grep BESZEL_KEY /mnt/BIG/filme/docker-compose/.env

# restart agent
docker compose restart beszel-agent
```

---

## TrueNAS-specific issues

### script execution failures

**symptoms:** "permission denied" or "killed" when running scripts from /mnt/

```bash
# always copy to /tmp first
cp /mnt/BIG/filme/docker-compose/scripts/<script>.sh /tmp/
bash /tmp/<script>.sh <args>
rm /tmp/<script>.sh
```

> **never** try to execute scripts directly from `/mnt/BIG/` — TrueNAS will kill the process.

### cron jobs disappeared after TrueNAS upgrade

```bash
# check if crontab survived
crontab -l

# if empty, re-add the entries
crontab -e
```

add:

```
30 4 * * 6 cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh weekly && rm /tmp/secure-container-update.sh >> /mnt/BIG/filme/docker-compose/configs/secure-update/logs/cron.log 2>&1
30 4 * * 0-5 cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh retry && rm /tmp/secure-container-update.sh >> /mnt/BIG/filme/docker-compose/configs/secure-update/logs/cron.log 2>&1
*/5 * * * * /root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1
```

### docker not starting after TrueNAS upgrade

```bash
# check docker service
systemctl status docker

# if not running
systemctl start docker
systemctl enable docker

# verify compose file is intact
cat /mnt/BIG/filme/docker-compose/docker-compose.yaml | head -5

# bring up services
cd /mnt/BIG/filme/docker-compose
docker compose up -d
```

### ZFS pool degraded

```bash
# check pool status
zpool status BIG

# if degraded, check which disk failed
zpool status -v BIG

# ZFS pool recovery is beyond the scope of this document
# consult TrueNAS documentation for disk replacement procedures
```

---

## historical fixes reference

| version | service | issue | fix |
|---------|---------|-------|-----|
| v90.8 | nebula-sync | quote placement error | fixed PRIMARY/REPLICAS quoting |
| v92 | vaultwarden | migrated from amy | added to bender compose with ADMIN_TOKEN |
| v93 | all services | DNS not using pihole | added `x-dns-config` anchor with 192.168.21.100 |
| v94 | immich_redis | "Can't handle RDB format version 11" | upgraded from redis:6.2-alpine to redis:7-alpine |
| v94 | readarr | wrong image | fixed to `linuxserver/readarr:0.4.19-nightly` |
| v94 | spotdl | wrong image | fixed to `spotdl/spotify-downloader:latest` |
| v94 | hedgedoc | unhealthy (curl/wget not in image) | changed to Node.js-based healthcheck |
| v94 | immich_server | unauthorized healthcheck causing unhealthy | removed healthcheck (uses image built-in) |
| v96 | jellyfin | wrong image (`jellyfin/jellyfin`) | corrected to `lscr.io/linuxserver/jellyfin:latest` |
| v97 | ARR stack + transmission | no VPN tunnel | added gluetun with OpenVPN |
| v98 | gluetun | testing WireGuard | switched VPN_TYPE to wireguard |
| v99 | transmission | bind address and UI | added BIND_ADDRESS_IPV4, flood UI mod |
| v100 | postgres | backup compatibility | added shared_preload_libraries for vchord.so |
| v101 | multiple | v100 corrupted configuration | restored v96 base with approved v97-v100 changes |
| v102 | transmission | FileList whitelist | replaced with qBittorrent |
| v103 | qBittorrent | system crashes (ZFS I/O) | reverted to transmission 4.0.5, commented qBittorrent |
| v104 | gluetun | WireGuard blocked peers | switched back to OpenVPN |
| v104 | immich_machine_learning | unhealthy (curl not in image) | changed to python3 healthcheck |
| v104 | nebula-sync | unhealthy (no binaries) | disabled healthcheck |
| v105 | cadvisor | not present | added with resource-saving flags |
| v105 | jellyfin | /data/tvshows path missing | added volume mount for tvshows library |

---

*previous: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
*this is the last document in the bender documentation series*
