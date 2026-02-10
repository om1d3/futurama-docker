# amy troubleshooting guide

## diagnostic procedures and common fixes

**document version:** 2.0
**infrastructure version:** 98
**last updated:** february 2026

---

## table of contents

1. [quick diagnostics](#quick-diagnostics)
2. [container issues](#container-issues)
3. [postgresql issues](#postgresql-issues)
4. [DNS and networking issues](#dns-and-networking-issues)
5. [update system issues](#update-system-issues)
6. [monitoring issues](#monitoring-issues)
7. [service-specific issues](#service-specific-issues)
8. [historical fixes reference](#historical-fixes-reference)

---

## quick diagnostics

### first response checklist

when something appears broken, run these commands in order:

```bash
cd /docker-compose

# 1. how many containers are running vs expected?
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -c "Up"
# expected: 29 (all active services in v98)

# 2. which containers are NOT running?
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"

# 3. any containers in restart loop?
docker ps -a --format "{{.Names}}\t{{.Status}}" | grep -i "restarting"

# 4. any containers unhealthy?
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "unhealthy"

# 5. disk space ok?
df -h / /portainer /docker

# 6. system resources ok?
free -h && uptime
```

### health check suite

```bash
# full automated health check
/docker-compose/scripts/health-checks.sh all

# or target specific services
/docker-compose/scripts/health-checks.sh postgres
/docker-compose/scripts/health-checks.sh ntfy
/docker-compose/scripts/health-checks.sh pihole
```

---

## container issues

### container won't start

**symptoms:** container shows as "exited" or "created" in `docker compose ps`

```bash
# check the exit code and logs
docker inspect <container> --format '{{.State.ExitCode}}'
docker logs <container> --tail 50

# common causes:
# exit code 1   — application error (check logs for specifics)
# exit code 126 — permission denied on entrypoint
# exit code 127 — entrypoint binary not found (wrong image?)
# exit code 137 — killed by OOM (out of memory)
# exit code 139 — segfault (rare, usually bad image)
```

**fix — application error (exit 1):**

```bash
# read the full log output
docker logs <container> 2>&1 | less

# if related to database connectivity, check postgres first
/docker-compose/scripts/health-checks.sh postgres
```

**fix — out of memory (exit 137):**

```bash
# check system memory
free -h

# check which containers use the most memory
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}" | sort -k2 -h -r | head -10

# restart the container (may work if memory pressure was temporary)
docker compose up -d <container>
```

### container in restart loop

**symptoms:** container repeatedly starts and stops, status shows "Restarting"

```bash
# stop the loop first
docker compose stop <container>

# check what's failing
docker logs <container> --tail 100

# common causes:
# - dependency not ready (postgres, valkey)
# - port already in use
# - volume mount path doesn't exist
# - environment variable missing or malformed
```

**fix — dependency not ready:**

```bash
# check if postgres is healthy (many services depend on it)
docker compose ps postgres
docker exec postgres pg_isready -U postgres

# if postgres is down, start it first
docker compose up -d postgres
sleep 10
docker compose up -d <container>
```

**fix — port conflict:**

```bash
# check if the port is already in use
ss -tlnp | grep <port_number>

# if another process holds the port, identify it
lsof -i :<port_number>
```

### container shows "unhealthy"

**symptoms:** `docker ps` shows "(unhealthy)" next to the container

```bash
# check what the healthcheck is testing
docker inspect <container> --format '{{json .Config.Healthcheck}}' | jq .

# check healthcheck logs
docker inspect <container> --format '{{json .State.Health}}' | jq '.Log[-3:]'

# common cause: healthcheck command uses a binary not in the container
# (this was a recurring issue — see historical fixes section)
```

---

## postgresql issues

### postgres won't start

```bash
# check logs
docker logs postgres --tail 50

# check disk space on the data directory
df -h /portainer/postgresql/
du -sh /portainer/postgresql/data/

# check permissions
ls -la /portainer/postgresql/data/

# check if another postgres instance is running
docker ps -a | grep postgres
```

**fix — corrupted WAL files:**

```bash
# WARNING: this may lose recent transactions
docker compose stop postgres atuin miniflux spendspentspent mealie postgres-backup

# try starting with recovery
docker compose up -d postgres
sleep 10
docker logs postgres --tail 20

# if still failing, restore from backup
# (see restore procedures in 07-MAINTENANCE.md)
```

### database connection refused

**symptoms:** services show "connection refused" to postgres in their logs

```bash
# verify postgres is running and healthy
docker compose ps postgres
docker exec postgres pg_isready -U postgres

# verify postgres is listening
docker exec postgres psql -U postgres -c "SELECT 1;"

# check the network
docker network inspect docker-compose_utility-network | grep -A5 postgres
```

**fix — postgres healthy but services can't connect:**

```bash
# restart the affected service (it may have cached a stale connection)
docker compose restart <service_name>

# if all services are affected, restart postgres
docker compose restart postgres
sleep 10
docker compose restart atuin miniflux spendspentspent mealie
```

### database does not exist

**symptoms:** service logs show `FATAL: database "xxx" does not exist`

```bash
# list existing databases
docker exec postgres psql -U postgres -l

# if a database is missing, create it
docker exec postgres psql -U postgres -c "CREATE DATABASE <database_name>;"

# then restore from backup if needed
docker exec -i postgres psql -U postgres -d <database_name> < /docker/postgres-backup/<backup_file>
```

### postgres-backup fails

**symptoms:** postgres-backup logs show errors

```bash
# check logs
docker logs postgres-backup --tail 20

# common issue: "database does not exist"
# this means POSTGRES_DB lists a database that hasn't been created yet
# check the current database list in compose:
grep POSTGRES_DB docker-compose.yaml
# should be: atuin,miniflux,sss,mealie,stirling

# verify all databases exist
docker exec postgres psql -U postgres -l | grep -E "atuin|miniflux|sss|mealie|stirling"
```

> **historical note:** postgres-backup was initially configured with `POSTGRES_DB=all`, which caused `FATAL: database "all" does not exist`. this was fixed by listing databases explicitly. see conversation #26.

---

## DNS and networking issues

### pihole not resolving

```bash
# test DNS resolution through pihole
dig google.com @127.0.0.1
dig google.com @192.168.21.130
dig google.com @192.168.21.100  # VIP

# check pihole container
docker compose ps pihole
docker logs pihole --tail 20

# restart pihole
docker compose restart pihole
```

### keepalived VIP not on amy

```bash
# check if VIP is assigned to amy
ip addr show | grep 192.168.21.100

# if not present, amy is in BACKUP state (bender has it — this is normal)
# check keepalived status
docker logs keepalived --tail 20

# force amy to claim VIP (only if bender is down)
docker compose restart keepalived
```

### containers can't resolve DNS

**symptoms:** containers show DNS resolution errors in logs

```bash
# check the dns anchor is applied
docker inspect <container> --format '{{json .HostConfig.Dns}}'
# should show: ["192.168.21.100"]

# if empty, the service may be missing <<: *default-dns in compose
# or it uses network_mode: host (which uses the host's DNS)

# test from inside a container
docker exec <container> nslookup google.com 192.168.21.100

# emergency fix: restart pihole on both hosts
docker compose restart pihole
# on bender: docker compose restart pihole
```

### .home.arpa domains not resolving

```bash
# test local domain resolution
dig ntfy.home.arpa @192.168.21.100

# if NXDOMAIN, the pihole-dns-update.sh script on bender may not have run
# check on bender: crontab -l | grep pihole-dns
# manual trigger on bender: /root/pihole-dns-update.sh

# verify the DNS entries exist in pihole
# on bender: docker exec pihole cat /etc/pihole/pihole.toml | grep -A50 "hosts ="
```

---

## update system issues

### secure-container-update.sh not running

```bash
# check cron is configured
crontab -l | grep secure-container

# expected output:
# 30 4 * * 3 /docker-compose/scripts/secure-container-update.sh weekly ...
# 30 4 * * 0-2,4-6 /docker-compose/scripts/secure-container-update.sh retry ...

# check last execution
ls -la /docker-compose/configs/secure-update/logs/ | tail -5
cat /docker-compose/configs/secure-update/logs/cron.log | tail -20

# manual test run
/docker-compose/scripts/secure-container-update.sh weekly
```

### trivy scan failures

```bash
# check trivy is running
docker compose ps trivy
curl -s http://localhost:8083/healthz

# if trivy is unhealthy, check logs
docker logs trivy --tail 20

# common fix: clear corrupted cache
docker compose stop trivy
rm -rf /docker/trivy/cache/*
docker compose start trivy
sleep 30  # trivy needs time to rebuild its vulnerability database
curl -s http://localhost:8083/healthz
```

### containers stuck in retry queue

```bash
# view current retry queue
cat /docker-compose/configs/secure-update/retry-queue.json | jq .

# check why a container is blocked (re-scan manually)
docker pull <image>
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --severity CRITICAL,HIGH <image>

# if vulnerabilities are in base image and not exploitable,
# you can manually update the container:
docker compose pull <service>
docker compose up -d <service>

# then clear it from the retry queue
# edit the file and remove the container entry:
nano /docker-compose/configs/secure-update/retry-queue.json
```

### ntfy notifications not arriving

```bash
# check ntfy is running
docker compose ps ntfy
curl -s http://localhost:8888/

# test sending a notification
curl -d "test from amy troubleshooting" http://localhost:8888/test-topic

# check the script's ntfy configuration
grep NTFY /docker-compose/scripts/secure-container-update.sh
# should show: NTFY_ENDPOINT="http://localhost:8888"

# IMPORTANT: bender also sends to amy's ntfy
# if ntfy is down on amy, bender's notifications fail silently
```

---

## monitoring issues

### beszel not collecting data

```bash
# check beszel hub
docker compose ps beszel
curl -s http://localhost:8090/

# check beszel-agent (uses host network)
docker ps | grep beszel-agent
docker logs beszel-agent --tail 20

# verify agent can reach hub
# agent connects to beszel hub on port 8090
docker logs beszel-agent 2>&1 | grep -i "connect\|error"
```

### cadvisor high resource usage

```bash
# check current usage
docker stats cadvisor --no-stream

# expected: <2% CPU, <50MB memory (with resource-saving flags)
# if higher, verify the command flags are applied
docker inspect cadvisor --format '{{json .Config.Cmd}}'
# should show: --housekeeping_interval=30s --docker_only=true --disable_metrics=...

# if flags are missing, recreate
docker compose up -d --force-recreate cadvisor
sleep 30
docker stats cadvisor --no-stream
```

### telegraf not collecting SNMP data

```bash
# check telegraf logs
docker logs telegraf --tail 20

# common errors:
# "connection refused" — target device (switch/printer) is unreachable
# "timeout" — SNMP community string is wrong or device is slow

# test SNMP connectivity manually
docker exec telegraf telegraf --test --config /etc/telegraf/telegraf.conf 2>&1 | head -40

# verify config file is mounted
docker exec telegraf cat /etc/telegraf/telegraf.conf | head -5

# if config changed, restart telegraf
docker compose restart telegraf
```

### grafana dashboard shows no data

the monitoring pipeline is: cadvisor → prometheus (on HA VM 192.168.21.220) → grafana

```bash
# 1. verify cadvisor is serving metrics
curl -s http://localhost:9099/metrics | head -5

# 2. verify prometheus is scraping (on HA VM terminal)
# docker exec prometheus wget -qO- http://192.168.21.130:9099/metrics | head -5

# 3. check prometheus targets (on HA VM terminal)
# docker exec prometheus cat /etc/prometheus/prometheus.yml

# if prometheus config was lost (HA VM restart), recreate it:
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

---

## service-specific issues

### stirling-pdf DPI error

**symptoms:** stirling logs show `DPI value 300 exceeds maximum safe limit of 0`

**fix:** this was resolved in v97 by adding `SYSTEM_MAXDPI=1200` to stirling's environment. if the error reappears, verify the variable is set:

```bash
docker exec stirling env | grep MAXDPI
# should show: SYSTEM_MAXDPI=1200
```

### mealie won't start or shows errors

**fix history:**
- v85.3: migrated from sqlite to postgresql
- v96: image fixed from `hkotel/mealie:latest` to `ghcr.io/mealie-recipes/mealie:latest`

```bash
# verify correct image
docker inspect mealie --format '{{.Config.Image}}'
# should show: ghcr.io/mealie-recipes/mealie:latest

# check database connectivity
docker exec postgres psql -U postgres -d mealie -c "SELECT 1;"
```

### spendspentspent data not persisting

**fix history:**
- v86: added `/files` volume mount and `SSS_SALT` variable
- v95: added `/config` volume mount

```bash
# verify all three volume mounts exist
docker inspect spendspentspent --format '{{json .Mounts}}' | jq '.[].Destination'
# should show: /app-files, /files, /config
```

### miniflux admin login fails

**fix history:** v94 corrected `MINIFLUX_ADMIN_USERNAME` variable name

```bash
# verify environment variable
docker exec miniflux env | grep ADMIN
# should show: ADMIN_USERNAME=<your_username>

# if wrong, check .env file
grep MINIFLUX /docker-compose/.env
```

### netalertx not scanning

netalertx requires `NET_RAW`, `NET_ADMIN`, and `NET_BIND_SERVICE` capabilities and uses `network_mode: host`.

```bash
# verify capabilities
docker inspect netalertx --format '{{json .HostConfig.CapAdd}}'
# should show: ["NET_RAW","NET_ADMIN","NET_BIND_SERVICE"]

# verify host network
docker inspect netalertx --format '{{.HostConfig.NetworkMode}}'
# should show: host
```

---

## historical fixes reference

this section documents issues that were encountered and resolved during the infrastructure's development. these are preserved as reference in case similar issues recur.

| version | service | issue | fix |
|---------|---------|-------|-----|
| v91 | lubelogger | unauthorized SMTP config added | removed MailConfig__* variables, restored minimal config |
| v92 | vaultwarden | migrated to bender | removed from amy compose |
| v93 | all services | DNS not using pihole | added `x-dns` anchor with 192.168.21.100 to all bridge services |
| v94 | postgres | wrong volume path (`/docker/postgres/data`) | corrected to `/portainer/postgresql/data` |
| v94 | miniflux | wrong env var name | corrected to `MINIFLUX_ADMIN_USERNAME` |
| v94 | filebrowser | unhealthy (curl not in image) | removed curl healthcheck |
| v94 | tsdproxy | unhealthy (wget not in image) | removed wget healthcheck |
| v95 | spendspentspent | config not persisting | added `/config` volume mount |
| v96 | stirling | wrong image (`frooodle/s-pdf`) | corrected to `stirlingtools/stirling-pdf:latest` |
| v96 | netalertx | not scanning network | added `cap_add` and fixed volume mount |
| v96 | mealie | wrong image (`hkotel/mealie`) | corrected to `ghcr.io/mealie-recipes/mealie:latest` |
| v97 | stirling | DPI limit error | added `SYSTEM_MAXDPI=1200` |
| v98 | telegraf | separate stack, inconsistent management | consolidated into main compose with `${TIMEZONE}` |
| v98 | cadvisor | high CPU/memory usage | added `--docker_only`, `--housekeeping_interval=30s`, `--disable_metrics` flags |

---

*previous: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
*this is the last document in the amy documentation series*
