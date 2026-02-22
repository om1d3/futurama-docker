# bender secure container update system

## security-first container lifecycle management

**document version:** 3.0
**infrastructure version:** 109
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [components](#components)
3. [TrueNAS execution restriction](#truenas-execution-restriction)
4. [update workflow](#update-workflow)
5. [build-based containers](#build-based-containers)
6. [critical services](#critical-services)
7. [health checks](#health-checks)
8. [rollback system](#rollback-system)
9. [throttling system](#throttling-system)
10. [notification flow](#notification-flow)
11. [cron schedule](#cron-schedule)
12. [configuration files](#configuration-files)
13. [differences from amy](#differences-from-amy)

---

## overview

bender uses a custom secure container update system that ensures no container is deployed with known CRITICAL or HIGH vulnerabilities. the system pulls new images, scans them with trivy, deploys only if clean, runs health checks, and automatically rolls back on failure.

the system consists of three scripts and two JSON configuration files, managed by cron jobs that run weekly (full scan) and daily (retry blocked containers).

as of v108, three containers use `build:` directives instead of pre-built images. these require special handling — see [build-based containers](#build-based-containers).

---

## components

| component | version | purpose |
|-----------|---------|---------|
| secure-container-update.sh | v1.2 | main update orchestration script |
| health-checks.sh | v1.2 | standalone health check suite |
| rollback.sh | v1.1 | manual rollback helper |
| pihole-dns-update.sh | v3.0 | DNS auto-population (separate cron) |
| diun | latest | monitors Docker Hub for new image tags |
| trivy | latest | scans images for CVEs (server mode on port 8083:8080) |
| critical-containers.json | — | defines critical services and their test suites |
| retry-queue.json | — | tracks containers blocked by vulnerabilities |

---

## TrueNAS execution restriction

TrueNAS does not allow executing scripts from `/mnt/` paths. the cron system works around this by copying scripts to `/tmp/` before execution:

```bash
# weekly scan (saturday 04:30)
30 4 * * 6 cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh weekly && rm /tmp/secure-container-update.sh

# daily retry (sunday–friday 04:30, excludes saturday)
30 4 * * 0-5 cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh retry && rm /tmp/secure-container-update.sh

# pihole DNS update (every 5 minutes, runs from /root/)
*/5 * * * * /root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1
```

for manual use:

```bash
# run health checks
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/
bash /tmp/health-checks.sh postgres
rm /tmp/health-checks.sh

# manual rollback
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/
bash /tmp/rollback.sh list jellyfin
rm /tmp/rollback.sh
```

---

## update workflow

```
1. check system health (load average < 4.0, iowait < 50%)
   |
   v
2. for each running container:
   |
   +-- pull new image
   |   |
   |   v
   +-- scan with trivy (server mode, port 8082)
   |   |
   |   +-- CRITICAL or HIGH found → add to retry queue → skip
   |   |
   |   v
   +-- pre-upgrade actions (backup for critical containers)
   |   |
   |   v
   +-- stop container
   |   |
   |   v
   +-- backup current image (rotate backup-1/2/3 tags)
   |   |
   |   v
   +-- start with new image (docker compose up -d --force-recreate)
   |   |
   |   v
   +-- wait 30 seconds
   |   |
   |   v
   +-- run health checks
   |   |
   |   +-- FAIL → rollback to backup-1 → notify
   |   |
   |   v
   +-- restart dependent services (critical containers only)
   |   |
   |   v
   +-- re-run integration tests
   |   |
   |   +-- FAIL → rollback → notify
   |   |
   |   v
   +-- SUCCESS → remove from retry queue
   |
   v
3. wait THROTTLE_DELAY (60s) between containers
   |
   v
4. check system health again before next container
   |
   +-- overloaded → wait up to 5 × 120s for recovery
   +-- still overloaded → skip remaining containers
   |
   v
5. generate report + send ntfy notification
```

### containers skipped by the update system

the following containers are never auto-updated:

| container | reason |
|-----------|--------|
| diun | infrastructure — updates itself |
| trivy | infrastructure — scanner should not scan itself |
| transmission | build-based — requires manual `docker compose build` |
| tts-pipeline | build-based — requires manual `docker compose build` |

---

## build-based containers

three containers use `build:` instead of `image:` and cannot be updated by the standard pull-scan-deploy pipeline:

| container | build context | update procedure |
|-----------|--------------|------------------|
| transmission | `/mnt/BIG/filme/configs/transmission/` | edit Dockerfile → `docker compose build --no-cache transmission` → `docker compose up -d transmission` |
| tts-pipeline | `/mnt/BIG/filme/configs/tts-pipeline/` | edit Dockerfile/scripts → `docker compose build --no-cache tts-pipeline` → `docker compose up -d tts-pipeline` |
| epub2tts-edge | `/mnt/BIG/filme/configs/epub2tts-edge/` | edit Dockerfile → `docker compose build --no-cache epub2tts-edge` (profiles: tools, on-demand) |

these containers are effectively pinned to their Dockerfile definitions. to update the base image (e.g., linuxserver/transmission), edit the `FROM` line in the Dockerfile and rebuild.

**transmission is pinned to 4.0.5** — do NOT change the base image version. FileList whitelist requirement.

---

## critical services

only postgres is classified as critical on bender:

### postgres

| aspect | detail |
|--------|--------|
| pre-upgrade | full `pg_dumpall` backup to `/mnt/BIG/filme/backups/postgres/pre-upgrade/` |
| health checks | pg_isready, pg_connect (SELECT 1), pg_databases (check immich exists) |
| functional tests | immich_db_access (`SELECT COUNT(*) FROM "user"` — note quoted table name), hedgedoc_db_access |
| integration tests | immich_api_ping (`/api/server/ping` → "pong"), hedgedoc_http (HTTP 200/301/302) |
| dependent services | immich_server, immich_machine_learning, hedgedoc, postgres-backup |
| rollback | restore backup-1 image tag → restart postgres → restart all dependents |

> **important:** the immich database uses a `"user"` table (quoted) because `user` is a PostgreSQL reserved keyword. health checks must use `'SELECT COUNT(*) FROM "user"'` with proper quoting.

### non-critical but monitored

| container | monitoring |
|-----------|-----------|
| pihole | DNS resolution check |
| keepalived | VIP presence |
| tsdproxy | tailscale connectivity |
| immich_server | API ping |
| immich_redis | redis-cli ping |
| vaultwarden | HTTP /alive endpoint |

---

## health checks

### health-checks.sh capabilities

```bash
# full postgresql suite (13 checks)
bash /tmp/health-checks.sh postgres

# single container basic checks (4 checks: running, healthy, restart count, OOM)
bash /tmp/health-checks.sh container jellyfin

# all running containers
bash /tmp/health-checks.sh all
```

### postgresql health check suite

| check | command | pass criteria |
|-------|---------|---------------|
| container running | docker ps filter | container exists and running |
| docker healthcheck | docker inspect | healthy or starting |
| restart count | docker inspect | < 3 restarts |
| OOM kill | docker inspect | OOMKilled = false |
| pg_isready | pg_isready -U postgres | exit code 0 |
| pg_connect | SELECT 1 | query succeeds |
| pg_databases | list databases | immich found |
| immich DB access | SELECT COUNT(*) FROM "user" | query succeeds |
| hedgedoc DB access | SELECT 1 on hedgedoc | query succeeds |
| write test | CREATE/DROP temp table | succeeds |
| immich API | curl /api/server/ping | returns "pong" |
| hedgedoc HTTP | curl localhost:3000 | HTTP 200/301/302 |

---

## rollback system

### automatic rollback (during updates)

triggered when health checks fail after deploying a new image. the system:

1. stops the failed container
2. restores the backup-1 image tag
3. starts the container with the previous image
4. for critical containers: restarts all dependent services
5. sends ntfy notification

### manual rollback

```bash
# copy script to /tmp
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/

# list available backups for a container
bash /tmp/rollback.sh list jellyfin

# rollback to most recent backup
bash /tmp/rollback.sh rollback jellyfin

# rollback to second-most-recent backup
bash /tmp/rollback.sh rollback sonarr 2

# special postgresql rollback (handles dependents)
bash /tmp/rollback.sh postgres

rm /tmp/rollback.sh
```

### image backup retention

the system maintains 3 backup tags per container:

```
registry/image:latest      ← currently running
registry/image:backup-1    ← previous version (most recent)
registry/image:backup-2    ← older version
registry/image:backup-3    ← oldest kept version
```

older backups are automatically pruned during rotation.

---

## throttling system

added in v1.2 to prevent ZFS I/O saturation on the HP MicroServer Gen8:

| setting | value | purpose |
|---------|-------|---------|
| THROTTLE_DELAY | 60s | wait between container updates |
| MAX_LOAD | 4.0 | skip if 1-min load average exceeds |
| MAX_IOWAIT | 50% | skip if I/O wait percentage exceeds |
| RECOVERY_WAIT | 120s | wait time for system recovery |
| MAX_RECOVERY_ATTEMPTS | 5 | max recovery wait cycles (10 min total) |

the system checks health before each container update. if overloaded, it waits up to 5 × 120s = 10 minutes for recovery. if recovery fails, remaining containers are skipped and listed in the report.

```bash
# check system health manually
cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/
bash /tmp/secure-container-update.sh health
rm /tmp/secure-container-update.sh
```

---

## notification flow

notifications go to ntfy on amy via the `NTFY_ADDRESS` environment variable:

| event | priority | tags |
|-------|----------|------|
| weekly scan starting | low | hourglass |
| weekly scan complete | default | white_check_mark |
| daily retry starting | low | arrows_counterclockwise |
| daily retry complete | default | arrows_counterclockwise |
| container rolled back | high | warning, rotating_light |
| rollback FAILED | urgent | rotating_light, skull |
| scan aborted (overloaded) | high | warning |

the ntfy endpoint is configured in `.env` as `NTFY_ADDRESS=http://192.168.21.130:8080` and loaded via `WATCHTOWER_NOTIFICATION_URL` (legacy variable name from the watchtower era).

---

## cron schedule

| schedule | command | purpose |
|----------|---------|---------|
| saturday 04:30 | `secure-container-update.sh weekly` | full scan of all containers |
| sun–fri 04:30 | `secure-container-update.sh retry` | retry previously blocked containers |
| every 5 min | `/root/pihole-dns-update.sh` | DNS auto-population |

---

## configuration files

### critical-containers.json

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/critical-containers.json`

auto-created on first run. defines which containers get special treatment (pre-upgrade backups, extended health checks, dependent service restarts).

### retry-queue.json

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json`

tracks containers that were blocked by vulnerability scans. the daily retry job processes this queue.

### logs

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/logs/`

one log file per day. retention: 180 days.

### scan reports

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/scan-reports/`

trivy JSON reports organized by date. retention: 180 days.

### weekly reports

location: `/mnt/BIG/filme/docker-compose/reports/weekly-reports/`

markdown summary reports. retention: 180 days.

---

## differences from amy

| aspect | bender | amy |
|--------|--------|-----|
| update day | saturday | wednesday |
| trivy host port | 8083 | 8083 |
| trivy internal port | 8080 | 4954 |
| trivy server URL | http://localhost:8082 | http://localhost:8083 |
| diun schedule | daily 06:00 | wednesday 04:00 |
| critical services | 1 (postgres) | 4 (postgres, ntfy, beszel, spendspentspent) |
| script execution | requires `/tmp` copy (TrueNAS) | direct execution |
| ntfy endpoint | `http://${NTFY_ADDRESS}` (remote amy) | `http://localhost:8888` (local) |
| postgres image | immich-app/postgres (vectorchord) | postgres:17-alpine |
| postgres databases | immich, hedgedoc | atuin, miniflux, sss, mealie, stirling |
| base path | `/mnt/BIG/filme/docker-compose` | `/docker-compose` |
| backup path | `/mnt/BIG/filme/backups/postgres` | `/docker/backups/postgres` |
| additional cron | pihole-dns-update.sh (every 5 min) | none |
| build-based containers | 3 (transmission, tts-pipeline, epub2tts-edge) | 0 |

---

*previous: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
*next: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
