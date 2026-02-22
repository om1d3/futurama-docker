# bender troubleshooting guide

## diagnostic procedures and common fixes

**document version:** 3.0
**infrastructure version:** 109
**last updated:** february 2026

---

## table of contents

1. [quick diagnostics](#quick-diagnostics)
2. [container issues](#container-issues)
3. [VPN and download issues](#vpn-and-download-issues)
4. [autoheal issues](#autoheal-issues)
5. [postgresql issues](#postgresql-issues)
6. [DNS and networking issues](#dns-and-networking-issues)
7. [immich issues](#immich-issues)
8. [jellyfin issues](#jellyfin-issues)
9. [ARR stack issues](#arr-stack-issues)
10. [TTS pipeline issues](#tts-pipeline-issues)
11. [transmission issues](#transmission-issues)
12. [update system issues](#update-system-issues)
13. [monitoring issues](#monitoring-issues)
14. [TrueNAS-specific issues](#truenas-specific-issues)
15. [historical fixes reference](#historical-fixes-reference)

---

## quick diagnostics

### first response checklist

```bash
cd /mnt/BIG/filme/docker-compose

# 1. how many containers are running vs expected?
docker compose ps --format "{{.Names}}" | wc -l
# expected: 36 (all active services in v109)

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

# full postgresql check
bash /tmp/health-checks.sh postgres

# specific container
bash /tmp/health-checks.sh container jellyfin

# all containers
bash /tmp/health-checks.sh all

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
# 137 — killed by OOM or docker stop
# 139 — segfault
# 143 — SIGTERM (graceful stop)
```

### container keeps restarting

```bash
# check restart count
docker inspect <container> --format '{{.RestartCount}}'

# check if OOM killed
docker inspect <container> --format '{{.State.OOMKilled}}'

# check resource limits
docker stats --no-stream <container>

# check logs across restarts
docker logs <container> --tail 100 -t
```

### orphaned containers warning

if `docker compose up -d` shows orphan container warnings:

```bash
# list orphans
docker compose ps -a --format "{{.Names}}" | sort > /tmp/compose.txt
docker ps -a --format "{{.Names}}" | sort > /tmp/docker.txt
diff /tmp/compose.txt /tmp/docker.txt

# remove specific orphan
docker rm -f <orphan_name>

# remove all orphans
docker compose up -d --remove-orphans
```

---

## VPN and download issues

### gluetun won't connect

```bash
# check logs for connection errors
docker logs gluetun --tail 50

# common issues:
# "auth failed" → credentials expired, update SURFSHARK_OPENVPN_USER/PASSWORD in .env
# "connection refused" → Surfshark server down, try different country
# "tun device not available" → /dev/net/tun missing, check device mount

# verify credentials are loaded
docker exec gluetun env | grep -i openvpn

# try different server country
# edit .env: GLUETUN_SERVER_COUNTRY=Netherlands
docker compose up -d gluetun
```

### gluetun healthy but no internet in VPN containers

```bash
# test from inside gluetun
docker exec gluetun wget -qO- http://ipinfo.io

# test from transmission
docker exec transmission curl -s http://ipinfo.io 2>/dev/null || echo "no connectivity"

# check DNS inside gluetun
docker exec gluetun nslookup google.com

# if DNS fails but IP works, check DOT setting
# DOT=off uses plain DNS (current config)
docker exec gluetun env | grep DOT
```

### stale VPN session (connected but no traffic)

this is the scenario autoheal was designed for (v106). the VPN process stays running but the tunnel is dead.

```bash
# check gluetun healthcheck status
docker inspect gluetun --format '{{.State.Health.Status}}'

# if unhealthy, autoheal should restart within 60s
# check autoheal logs
docker logs autoheal --tail 10

# manual restart if autoheal is not working
docker restart gluetun

# wait 30s for VPN to reconnect
sleep 30

# verify
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null | head -3
```

### public IP shows real IP instead of VPN

```bash
# check from gluetun (should show Surfshark IP)
docker exec gluetun wget -qO- http://ipinfo.io

# if showing real IP, VPN tunnel is not active
docker logs gluetun --tail 30 | grep -i "error\|fail\|disconnect"

# restart gluetun
docker restart gluetun
```

---

## autoheal issues

### autoheal not restarting unhealthy containers

```bash
# verify autoheal is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep autoheal

# verify gluetun has the autoheal label
docker inspect gluetun --format '{{index .Config.Labels "autoheal"}}'
# should output: true

# check autoheal logs
docker logs autoheal --tail 20

# verify autoheal configuration
docker inspect autoheal --format '{{json .Config.Env}}' | jq .
# should show AUTOHEAL_CONTAINER_LABEL=autoheal, AUTOHEAL_INTERVAL=60
```

### autoheal restarting gluetun in a loop

if gluetun is fundamentally broken (expired credentials, server issues), autoheal will restart it every ~4 minutes indefinitely:

```bash
# check how many times gluetun has been restarted
docker inspect gluetun --format '{{.RestartCount}}'

# check gluetun logs for the root cause
docker logs gluetun --tail 50

# common root causes:
# 1. expired Surfshark credentials → update .env
# 2. server country blocked → change GLUETUN_SERVER_COUNTRY
# 3. network outage → wait for recovery

# temporarily stop autoheal while debugging
docker stop autoheal

# fix the issue, then restart both
docker compose up -d gluetun autoheal
```

---

## postgresql issues

### postgres won't start

```bash
# check logs
docker logs postgres --tail 50

# common issues:
# "database files are incompatible" → major version upgrade needed
# "could not access directory" → permission issue on /var/lib/postgresql/data
# "shared_preload_libraries" → extension file missing

# check disk space
df -h /mnt/BIG/

# check data directory permissions
ls -la /mnt/BIG/filme/immich/postgresql/
```

### postgres out of disk space

```bash
# check WAL size
docker exec postgres du -sh /var/lib/postgresql/data/pg_wal/

# force WAL cleanup
docker exec postgres psql -U postgres -c "CHECKPOINT;"

# check database sizes
docker exec postgres psql -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) FROM pg_database ORDER BY pg_database_size(pg_database.datname) DESC;"
```

### immich database access issues

```bash
# test connection
docker exec postgres psql -U postgres -d immich -c "SELECT 1;"

# check immich user table (note quoted table name — "user" is a reserved keyword)
docker exec postgres psql -U postgres -d immich -c 'SELECT COUNT(*) FROM "user";'

# check for locked queries
docker exec postgres psql -U postgres -c "SELECT pid, state, query FROM pg_stat_activity WHERE datname = 'immich' AND state != 'idle';"
```

### hedgedoc database access issues

```bash
# test connection
docker exec postgres psql -U postgres -d hedgedoc -c "SELECT 1;"

# check hedgedoc tables exist
docker exec postgres psql -U postgres -d hedgedoc -c "\dt"
```

---

## DNS and networking issues

### pihole not responding

```bash
# check container
docker ps | grep pihole
docker logs pihole --tail 20

# test DNS
dig @127.0.0.1 google.com +short
dig @192.168.21.100 google.com +short

# check pihole web interface
curl -s -o /dev/null -w "%{http_code}" http://localhost:8053/admin/

# restart pihole
docker restart pihole
```

### keepalived VIP missing

```bash
# check if VIP is assigned to bond0
ip addr show bond0 | grep 192.168.21.100

# check keepalived logs
docker logs keepalived --tail 20

# verify keepalived config is mounted correctly
docker exec keepalived cat /container/service/keepalived/assets/keepalived.conf

# restart keepalived
docker restart keepalived

# verify VIP returns
ip addr show bond0 | grep 192.168.21.100
```

### DNS auto-population not working

```bash
# check pihole-dns-update.sh cron output
tail -20 /var/log/pihole-dns-export.log

# run manually to see errors
/root/pihole-dns-update.sh

# check if SSH to amy works (needed for amy container labels)
ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 "docker ps -q | wc -l"

# check pihole.toml hosts array
grep -A 50 "hosts = \[" /mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml | head -60

# check state file
cat /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state
```

### nebula-sync not replicating

```bash
# check logs
docker logs nebula-sync --tail 20

# note: healthcheck is disabled (minimal container has no binaries)
# verify it ran recently by checking pihole config timestamps on amy
ssh kube@192.168.21.130 "ls -la /docker/pihole/etc-pihole/pihole.toml"
```

---

## immich issues

### photos not uploading

```bash
# check immich_server logs
docker logs immich_server --tail 30

# verify upload directory permissions
ls -la /mnt/BIG/filme/immich/photos/

# check API
curl -s http://localhost:2283/api/server/ping

# check postgres connection
docker exec postgres psql -U postgres -d immich -c "SELECT 1;"
```

### machine learning not working

```bash
# check ML container
docker logs immich_machine_learning --tail 30

# verify healthcheck
docker inspect immich_machine_learning --format '{{.State.Health.Status}}'

# check ML cache
du -sh /mnt/BIG/filme/immich/ml-cache/

# restart ML service
docker restart immich_machine_learning
```

### redis errors ("Can't handle RDB format version")

this was fixed in v94 by upgrading from redis:6.2-alpine to redis:7-alpine. if it recurs:

```bash
# check redis version
docker exec immich_redis redis-server --version

# should be redis 7.x
# if downgraded somehow, verify docker-compose.yaml has redis:7-alpine
```

---

## jellyfin issues

### library path errors ("Access to path denied")

fixed in v105 by changing the TV show mount from `/data/tv` to `/data/tvshows`:

```bash
# verify volume mounts
docker inspect jellyfin --format '{{json .Mounts}}' | jq '.[].Destination'

# should show /data/movies, /data/tvshows, /data/music (NOT /data/tv)

# if wrong, redeploy
docker compose up -d --force-recreate jellyfin
```

### no hardware transcoding

this is a known hardware limitation. the HP MicroServer Gen8's BIOS disables the Xeon's integrated GPU. software transcoding is the only option:

```bash
# verify no GPU devices are available
ls -la /dev/dri/ 2>/dev/null || echo "no GPU devices"

# the GPU section is commented out in docker-compose.yaml for future use
```

---

## ARR stack issues

### all ARR apps unreachable

if prowlarr, sonarr, radarr, lidarr, readarr, and bazarr are all down simultaneously, the issue is gluetun:

```bash
# check gluetun
docker inspect gluetun --format '{{.State.Health.Status}}'
docker logs gluetun --tail 20

# see VPN troubleshooting section above
```

### single ARR app not responding

```bash
# check specific app
docker logs <app_name> --tail 30

# verify it can reach gluetun's network
docker exec <app_name> wget -qO- http://localhost:<port> 2>/dev/null || echo "not responding"

# restart the specific app
docker compose restart <app_name>
```

### unpackerr not extracting

```bash
# check logs
docker logs unpackerr --tail 30

# verify API keys are set in .env
grep -E "SONARR_API_KEY|RADARR_API_KEY" /mnt/BIG/filme/docker-compose/.env

# verify unpackerr can reach ARR apps through gluetun
docker exec unpackerr wget -qO- http://gluetun:8989/api/v3/system/status 2>/dev/null | head -5
```

---

## TTS pipeline issues

### tts-pipeline not converting files

```bash
# check container status
docker ps --format "{{.Names}}\t{{.Status}}" | grep tts-pipeline

# check logs
docker logs tts-pipeline --tail 50

# verify input directories exist
ls -la /mnt/BIG/filme/tts/input/

# verify edge-tts API is running
curl -s http://localhost:5050/v1/models | head -5

# test edge-tts directly
curl -s -X POST http://localhost:5050/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input":"test","voice":"ro-RO-AlinaNeural"}' \
  -o /tmp/test.mp3 && echo "TTS working" || echo "TTS failed"
rm -f /tmp/test.mp3
```

### web UI not accessible

```bash
# check if port 5051 is listening
curl -s -o /dev/null -w "%{http_code}" http://localhost:5051
# should return 200

# check tts-pipeline logs for Flask errors
docker logs tts-pipeline --tail 30 | grep -i "flask\|error\|traceback"

# rebuild if webapp.py or start.sh were changed
cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache tts-pipeline
docker compose up -d tts-pipeline
```

### edge-tts API errors

```bash
# check edge-tts container
docker logs edge-tts --tail 20

# common issues:
# "429 Too Many Requests" → rate limited by Microsoft, wait and retry
# "connection refused" → edge-tts container not running
# memory limit reached (512 MB) → check with docker stats edge-tts

# restart edge-tts
docker restart edge-tts
```

### output not appearing in audiobookshelf

```bash
# check if files are being written
ls -lt /mnt/BIG/filme/audiobookshelf/audiobooks/cărți/ | head -5

# check tts-pipeline output logs
docker logs tts-pipeline --tail 50 | grep -i "output\|complete\|error"

# verify audiobookshelf can see the directory
docker exec audiobookshelf ls /audiobooks/ | head -10

# force audiobookshelf library scan via web UI
```

---

## transmission issues

### Flood UI not loading

```bash
# check if transmission is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep transmission

# check logs for Flood-related errors
docker logs transmission --tail 30 | grep -i "flood\|web"

# verify TRANSMISSION_WEB_HOME is set
docker exec transmission env | grep WEB_HOME
# should show: TRANSMISSION_WEB_HOME=/flood-for-transmission/

# if Flood files are missing, rebuild
cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache transmission
docker compose up -d transmission
```

### transmission causing system slowdowns

```bash
# check active torrent count
docker exec transmission transmission-remote -l 2>/dev/null | wc -l

# check system I/O
iostat -x 1 3

# check current queue settings
docker exec transmission env | grep -i "queue\|cache\|peer"

# if settings are missing from env, the docker-compose.yaml may need redeployment
docker compose up -d --force-recreate transmission
```

### FileList tracker issues

transmission is pinned to version 4.0.5 for FileList compatibility. do NOT upgrade:

```bash
# verify transmission version
docker exec transmission transmission-remote -V 2>/dev/null || docker logs transmission | grep -i version | head -3

# if accidentally upgraded, rebuild with pinned version
cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache transmission
docker compose up -d transmission
```

---

## update system issues

### weekly scan not running

```bash
# check cron in TrueNAS UI: System → Advanced → Cron Jobs
# or check if it ran recently
ls -lt /mnt/BIG/filme/docker-compose/configs/secure-update/logs/ | head -3

# run manually
cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/
bash /tmp/secure-container-update.sh status
bash /tmp/secure-container-update.sh weekly
rm /tmp/secure-container-update.sh
```

### container stuck in retry queue

```bash
# check retry queue
cat /mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json

# scan the specific container to see why it's blocked
cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/
bash /tmp/secure-container-update.sh scan <container_name>
rm /tmp/secure-container-update.sh

# manually clear from retry queue if needed
echo '{"containers": []}' > /mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json
```

### trivy scan timeout

```bash
# check trivy server
curl -s http://localhost:8083/healthz

# check trivy logs
docker logs trivy --tail 20

# clear trivy cache (may help with corrupt cache)
docker restart trivy
```

---

## monitoring issues

### grafana dashboard shows no data

the pipeline is: cadvisor (bender:9099) → prometheus (HA VM 192.168.21.220:9090) → grafana

```bash
# 1. verify cadvisor metrics
curl -s http://localhost:9099/metrics | head -5

# 2. check prometheus config on HA VM
# docker exec prometheus cat /etc/prometheus/prometheus.yml
# should list 192.168.21.121:9099 in scrape targets

# 3. if prometheus config lost (HA VM restart), recreate scrape config
```

### grafana dashboard configuration

there are two separate grafana dashboards, one per host. each dashboard has its `instance` variable set to **Constant** type (not Query) to lock it to a specific host:

| dashboard | instance value |
|-----------|---------------|
| bender docker | `192.168.21.121:9099` |
| amy docker | `192.168.21.130:9099` |

if the dashboard shows data from the wrong host, check the `instance` variable type — it must be Constant, not Query.

### beszel-agent not reporting

```bash
# check beszel-agent
docker ps --format "{{.Names}}\t{{.Status}}" | grep beszel-agent

# check logs
docker logs beszel-agent --tail 20

# verify KEY is set
docker inspect beszel-agent --format '{{json .Config.Env}}' | grep KEY

# verify connectivity to beszel hub on amy
curl -s -o /dev/null -w "%{http_code}" http://192.168.21.130:8090
```

---

## TrueNAS-specific issues

### scripts won't execute from /mnt

this is by design in TrueNAS. always copy scripts to /tmp first:

```bash
cp /mnt/BIG/filme/docker-compose/scripts/<script>.sh /tmp/
bash /tmp/<script>.sh <args>
rm /tmp/<script>.sh
```

### cron jobs not running after TrueNAS upgrade

TrueNAS upgrades may reset cron jobs. verify in the web UI: System → Advanced → Cron Jobs. re-create if missing:

| schedule | command |
|----------|---------|
| `30 4 * * 6` | secure-container-update.sh weekly (copy to /tmp pattern) |
| `30 4 * * 0-5` | secure-container-update.sh retry (copy to /tmp pattern) |
| `*/5 * * * *` | `/root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1` |

### DMAR faults / system freezes

HP iLO can generate DMAR interrupt faults that escalate ZFS I/O stalls into hard freezes. fixed in v107 by setting `intel_iommu=off` in GRUB:

```bash
# verify current setting
cat /proc/cmdline | grep -o 'intel_iommu=[a-z]*'
# should show: intel_iommu=off

# if missing or set to "on", update GRUB config
# this is done via the MicroSD card GRUB configuration or TrueNAS UI
```

### ZFS pool degraded

```bash
# check status
zpool status BIG

# if degraded, identify failed disk
zpool status BIG | grep -E "DEGRADED|FAULTED|UNAVAIL"

# check SMART status
smartctl -a /dev/sdX
```

---

## historical fixes reference

| version | issue | fix |
|---------|-------|-----|
| v94 | immich_redis "Can't handle RDB format version 11" | upgraded redis:6.2-alpine → redis:7-alpine |
| v94 | readarr wrong image | corrected to linuxserver/readarr:0.4.19-nightly |
| v94 | spotdl wrong image | corrected to spotdl/spotify-downloader:latest |
| v94 | hedgedoc healthcheck fails (no curl) | changed to Node.js-based healthcheck |
| v96 | jellyfin wrong image | corrected to lscr.io/linuxserver/jellyfin:latest |
| v101 | v100 corrupted — missing services, wrong configs | restored v96 base + approved v97–v100 changes |
| v103 | qBittorrent system crashes | reverted to transmission, pinned to 4.0.5 |
| v104 | WireGuard blocks outbound peers | switched gluetun from WireGuard to OpenVPN |
| v104 | immich_ml healthcheck fails (no curl) | changed to python3-based healthcheck |
| v104 | nebula-sync healthcheck fails (no binaries) | disabled healthcheck |
| v105 | jellyfin "Access to /data/tvshows denied" | added /data/tvshows volume mount, removed /data/tv |
| v106 | stale VPN sessions silently block downloads | added autoheal + IP-based gluetun healthcheck |
| v107 | 812-torrent I/O stampede freezes system | added transmission queue/cache/peer limits |
| v107 | HP iLO DMAR faults cause hard freezes | set intel_iommu=off in GRUB |
| v108 | linuxserver Flood mod downloads on every restart | custom transmission build with pre-baked Flood UI |

---

*previous: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
