# amy troubleshooting guide

## diagnostic procedures and common fixes

**document version:** 3.0
**infrastructure version:** 99
**last updated:** february 2026

---

## table of contents

1. [quick diagnostics](#quick-diagnostics)
2. [container issues](#container-issues)
3. [postgresql issues](#postgresql-issues)
4. [DNS and networking issues](#dns-and-networking-issues)
5. [notification issues](#notification-issues)
6. [monitoring issues](#monitoring-issues)
7. [productivity service issues](#productivity-service-issues)
8. [update system issues](#update-system-issues)
9. [system issues](#system-issues)
10. [historical fixes reference](#historical-fixes-reference)

---

## quick diagnostics

### first response checklist

```bash
cd /docker-compose

# 1. how many containers are running vs expected?
docker compose ps --format "{{.Names}}" | wc -l
# expected: 29 (all active services in v99)

# 2. which containers are NOT running?
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"

# 3. any containers restarting?
docker ps -a --format "{{.Names}}\t{{.Status}}" | grep -i "restarting"

# 4. any containers unhealthy?
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "unhealthy"

# 5. DNS working?
dig @localhost google.com +short

# 6. disk space ok?
df -h / /portainer/ /docker/

# 7. system resources ok?
free -h && uptime
```

### health check suite

```bash
# all checks
bash /docker-compose/scripts/health-checks.sh all

# postgresql suite
bash /docker-compose/scripts/health-checks.sh postgres

# individual services
bash /docker-compose/scripts/health-checks.sh ntfy
bash /docker-compose/scripts/health-checks.sh pihole
bash /docker-compose/scripts/health-checks.sh trivy
bash /docker-compose/scripts/health-checks.sh diun
bash /docker-compose/scripts/health-checks.sh vaultwarden
```

note: the vaultwarden check is a legacy from when vaultwarden ran on amy (moved to bender in v92). it will report the container as not running, which is correct.

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

# check resource usage
docker stats --no-stream <container>

# check logs across restarts
docker logs <container> --tail 100 -t
```

### orphaned containers warning

```bash
# remove orphans
docker compose up -d --remove-orphans
```

---

## postgresql issues

### postgres won't start

```bash
# check logs
docker logs postgres --tail 50

# check disk space (postgres data is at /portainer/)
df -h /portainer/

# check data directory
ls -la /portainer/postgresql/data/

# common issues:
# "database files are incompatible" → major version upgrade needed
# "could not access directory" → permission issue
# disk full → free space on /portainer/ partition
```

### postgres out of disk space

```bash
# check database sizes
docker exec postgres psql -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) FROM pg_database ORDER BY pg_database_size(pg_database.datname) DESC;"

# check WAL size
docker exec postgres du -sh /var/lib/postgresql/data/pg_wal/

# force WAL cleanup
docker exec postgres psql -U postgres -c "CHECKPOINT;"
```

### database access issues

```bash
# test each database
for db in atuin miniflux sss mealie stirling; do
  docker exec postgres psql -U postgres -d $db -c "SELECT 1;" > /dev/null 2>&1 \
    && echo "✅ $db OK" || echo "❌ $db FAILED"
done
```

### postgres volume path confusion

amy's postgres data lives at `/portainer/postgresql/data/` (NOT `/docker/postgres/data/`). this is a legacy path from the original portainer deployment. see [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md) for details.

```bash
# verify the correct path is mounted
docker inspect postgres --format '{{json .Mounts}}' | jq '.[].Source'
# should show: /portainer/postgresql/data
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

# check web interface
curl -s -o /dev/null -w "%{http_code}" http://localhost:8053/admin/

# restart pihole
docker restart pihole
```

### keepalived VIP issues

```bash
# check if VIP is on amy (should only be if bender is down)
ip addr show enp4s0 | grep 192.168.21.100

# check keepalived status
docker logs keepalived --tail 20

# verify keepalived config
cat /docker/keepalived/keepalived.conf

# restart keepalived
docker restart keepalived
```

### VIP stuck on amy after bender recovers

if bender's pihole is healthy but the VIP stays on amy:

```bash
# check bender's keepalived
ssh root@192.168.21.121 'docker logs keepalived --tail 20'

# check bender's pihole health
ssh root@192.168.21.121 'docker inspect pihole --format "{{.State.Health.Status}}"'

# if bender is healthy, restart amy's keepalived to force re-election
docker restart keepalived
```

### nebula-sync config not up to date

nebula-sync runs on bender and pushes config to amy hourly. if amy's pihole has stale config:

```bash
# check last modification time of pihole config
ls -la /docker/pihole/etc-pihole/pihole.toml

# force sync from bender
ssh root@192.168.21.121 'docker restart nebula-sync'

# wait for sync to complete, then restart amy's pihole
sleep 60
docker restart pihole
```

---

## notification issues

### ntfy not receiving notifications

```bash
# check ntfy is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep ntfy

# test HTTP endpoint
curl -s -o /dev/null -w "%{http_code}" http://localhost:8888

# send test notification
curl -s -X POST http://localhost:8888/test \
  -H "Title: Test" \
  -d "Test from troubleshooting"

# check logs
docker logs ntfy --tail 20
```

### bender not sending notifications to amy

```bash
# verify ntfy is reachable from bender
ssh root@192.168.21.121 'curl -s -o /dev/null -w "%{http_code}" http://192.168.21.130:8888'

# check diun config on bender
ssh root@192.168.21.121 'docker exec diun env | grep NTFY'
# should show NTFY_ENDPOINT pointing to amy
```

---

## monitoring issues

### grafana dashboard shows no data

the pipeline is: cadvisor (amy:9099) → prometheus (HA VM 192.168.21.220:9090) → grafana

```bash
# 1. verify cadvisor metrics
curl -s http://localhost:9099/metrics | head -5

# 2. check prometheus is scraping
curl -s "http://192.168.21.220:9090/api/v1/targets" 2>/dev/null | grep -o "192.168.21.130:9099"

# 3. check grafana dashboard variable
# must be Constant type with value "192.168.21.130:9099" (not Query type)
```

### telegraf not collecting SNMP data

```bash
# check telegraf logs
docker logs telegraf --tail 30

# test SNMP connectivity to switch
docker exec telegraf snmpwalk -v2c -c futurama 192.168.21.5 1.3.6.1.2.1.1.5.0 2>/dev/null
# should return switch hostname

# test SNMP connectivity to printer
docker exec telegraf snmpwalk -v2c -c public 192.168.21.10 1.3.6.1.2.1.1.1.0 2>/dev/null
# should return printer description

# verify influxdb is reachable
curl -s "http://192.168.21.220:8086/ping" && echo "OK" || echo "FAILED"

# check telegraf config
docker exec telegraf cat /etc/telegraf/telegraf.conf | head -20
```

### telegraf starlark processor errors

the brother printer parser uses a starlark script. if page counts or drum percentages stop appearing:

```bash
# check for starlark errors
docker logs telegraf 2>&1 | grep -i "starlark\|error" | tail -10

# verify brInfoCounter OID is returning data
docker exec telegraf snmpget -v2c -c public 192.168.21.10 1.3.6.1.4.1.2435.2.3.9.4.2.1.5.5.10.0 2>/dev/null
```

### beszel-agent not reporting

```bash
# check agent
docker ps --format "{{.Names}}\t{{.Status}}" | grep beszel-agent
docker logs beszel-agent --tail 20

# verify KEY is set
docker inspect beszel-agent --format '{{json .Config.Env}}' | grep KEY

# check beszel hub
curl -s -o /dev/null -w "%{http_code}" http://localhost:8090
```

### netalertx not detecting devices

```bash
# check container (host network)
docker ps --format "{{.Names}}\t{{.Status}}" | grep netalertx
docker logs netalertx --tail 20

# verify capabilities
docker inspect netalertx --format '{{json .HostConfig.CapAdd}}'
# should show: ["NET_RAW","NET_ADMIN","NET_BIND_SERVICE"]

# check web UI
curl -s -o /dev/null -w "%{http_code}" http://localhost:20211
```

---

## productivity service issues

### atuin won't start ("unknown command 'server'")

fixed in v99. the upstream image changed from `atuin` binary to `atuin-server`, so the command changed from `server start` to just `start`:

```bash
# check current command
docker inspect atuin --format '{{json .Config.Cmd}}'
# should show: ["start"]

# if it shows ["server","start"], the compose file needs updating
# verify compose has: command: start (not: command: server start)

# check logs
docker logs atuin --tail 20
```

### stirling-pdf DPI error

fixed in v97 by adding `SYSTEM_MAXDPI=1200`:

```bash
# check if SYSTEM_MAXDPI is set
docker exec stirling env | grep MAXDPI
# should show: SYSTEM_MAXDPI=1200

# if missing, redeploy
docker compose up -d --force-recreate stirling
```

### mealie database connection failure

```bash
# verify postgres is healthy
docker inspect postgres --format '{{.State.Health.Status}}'

# test mealie's database
docker exec postgres psql -U postgres -d mealie -c "SELECT 1;"

# check mealie logs
docker logs mealie --tail 30

# restart mealie
docker compose restart mealie
```

### miniflux not accessible

```bash
# check container
docker ps --format "{{.Names}}\t{{.Status}}" | grep miniflux

# test HTTP
curl -s -o /dev/null -w "%{http_code}" http://localhost:8385

# check database connection
docker exec postgres psql -U postgres -d miniflux -c "SELECT 1;"

# check logs
docker logs miniflux --tail 20
```

### spendspentspent bank scraping failing

```bash
# check spendspentspent
docker logs spendspentspent --tail 20

# check playwright-chrome (browser engine)
docker ps --format "{{.Names}}\t{{.Status}}" | grep playwright-chrome
docker logs playwright-chrome --tail 10

# verify playwright connection
curl -s -o /dev/null -w "%{http_code}" http://localhost:3100
```

### limdius slow to start

limdius installs pip dependencies on every container start (~15–30s). this is by design:

```bash
# check if pip install is still running
docker logs limdius --tail 10

# if dependencies fail to install (pypi.org unreachable)
docker restart limdius

# verify it's running after startup
curl -s -o /dev/null -w "%{http_code}" http://localhost:5050
```

---

## update system issues

### weekly scan not running

```bash
# check cron
crontab -l | grep secure-container

# check if it ran recently
ls -lt /docker-compose/configs/secure-update/logs/ | head -3

# run manually
bash /docker-compose/scripts/secure-container-update.sh status
bash /docker-compose/scripts/secure-container-update.sh weekly
```

### container stuck in retry queue

```bash
# check queue
cat /docker-compose/configs/secure-update/retry-queue.json

# scan specific container
bash /docker-compose/scripts/secure-container-update.sh scan <container_name>

# clear queue if needed
echo '{"containers": []}' > /docker-compose/configs/secure-update/retry-queue.json
```

### trivy scan timeout

```bash
# check trivy server
curl -s http://localhost:8083/healthz

# check logs
docker logs trivy --tail 20

# restart trivy (clears cache issues)
docker restart trivy
```

---

## system issues

### disk space running low

```bash
# check all partitions
df -h

# find large files
du -sh /docker/*/ 2>/dev/null | sort -rh | head -10
du -sh /portainer/*/ 2>/dev/null | sort -rh | head -5

# clean docker
docker system prune -f
docker image prune -f

# check postgres backup retention
ls -lh /docker/postgres-backup/daily/ | wc -l
```

### high memory usage

```bash
# check system memory
free -h

# check per-container memory
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}" | sort -k2 -rh | head -10

# common memory-heavy containers on amy:
# playwright-chrome (headless browser)
# stirling (PDF processing)
# postgres (database)
```

### services not starting after reboot

docker should auto-start on boot, but containers need `restart: unless-stopped`:

```bash
# verify docker is running
systemctl status docker

# start all services
cd /docker-compose
docker compose up -d

# verify
docker compose ps --format "table {{.Names}}\t{{.Status}}"
```

### SSH from bender failing

bender's pihole-dns-update.sh connects as `kube@192.168.21.130`:

```bash
# test from bender
ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 "echo OK"

# if fails, check:
# 1. SSH service on amy
systemctl status sshd

# 2. kube user exists and is in docker group
id kube
groups kube

# 3. bender's SSH key is authorized
cat /home/kube/.ssh/authorized_keys
```

---

## historical fixes reference

| version | issue | fix |
|---------|-------|-----|
| v85.3 | argus wrong image | corrected to releaseargus/argus:latest |
| v85.3 | limdius wrong image | corrected to python:3.11-slim |
| v85.3 | mealie migrated to PostgreSQL | added postgres connection config |
| v86 | spendspentspent missing /files mount | added volume mount + SSS_SALT |
| v91 | lubelogger unauthorized SMTP config | removed MailConfig__* variables |
| v92 | vaultwarden moved to bender | removed from amy compose |
| v94 | postgres wrong volume path | corrected to /portainer/postgresql/data |
| v94 | miniflux wrong admin variable | corrected to MINIFLUX_ADMIN_USERNAME |
| v94 | filebrowser healthcheck fails (no curl) | removed curl healthcheck |
| v94 | tsdproxy healthcheck fails (no wget) | removed wget healthcheck |
| v95 | spendspentspent missing /config mount | added /config volume |
| v96 | stirling wrong image | corrected to stirlingtools/stirling-pdf:latest |
| v96 | mealie wrong image | corrected to ghcr.io/mealie-recipes/mealie:latest |
| v96 | netalertx missing capabilities | added NET_RAW, NET_ADMIN, NET_BIND_SERVICE |
| v97 | stirling DPI error | added SYSTEM_MAXDPI=1200 |
| v98 | telegraf standalone compose | consolidated into main docker-compose.yaml |
| v99 | atuin "unknown command 'server'" | changed command from `server start` to `start` |

---

*previous: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
