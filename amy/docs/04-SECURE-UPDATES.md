# amy secure container update system

## security-first container lifecycle management

**document version:** 3.0
**infrastructure version:** 99
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [components](#components)
3. [update workflow](#update-workflow)
4. [critical services](#critical-services)
5. [health checks](#health-checks)
6. [rollback system](#rollback-system)
7. [throttling system](#throttling-system)
8. [notification flow](#notification-flow)
9. [cron schedule](#cron-schedule)
10. [configuration files](#configuration-files)
11. [differences from bender](#differences-from-bender)

---

## overview

amy uses the same secure container update system as bender. the system pulls new images, scans them with trivy, deploys only if clean, runs health checks, and automatically rolls back on failure.

unlike bender (which requires copying scripts to `/tmp/` due to TrueNAS restrictions), amy can execute scripts directly from `/docker-compose/scripts/`.

---

## components

| component | version | purpose |
|-----------|---------|---------|
| secure-container-update.sh | v1.2 | main update orchestration script |
| health-checks.sh | v1.0 | standalone health check suite |
| rollback.sh | v1.0 | manual rollback helper |
| diun | latest | monitors Docker Hub for new image tags |
| trivy | latest | scans images for CVEs (server mode on port 8083:4954) |
| critical-containers.json | — | defines critical services and their test suites |
| retry-queue.json | — | tracks containers blocked by vulnerabilities |

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
   +-- scan with trivy (server mode, port 8083)
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

| container | reason |
|-----------|--------|
| diun | infrastructure — updates itself |
| trivy | infrastructure — scanner should not scan itself |

---

## critical services

amy has 4 critical services (compared to bender's 1):

### postgres

| aspect | detail |
|--------|--------|
| pre-upgrade | full `pg_dumpall` backup to `/docker/backups/postgres/pre-upgrade/` |
| health checks | pg_isready, pg_connect (SELECT 1), pg_databases (check atuin exists) |
| functional tests | atuin_db_access, miniflux_db_access, sss_db_access |
| integration tests | ntfy_http (HTTP 200/301/302 on :8888), miniflux_http (HTTP 200/301/302 on :8385) |
| dependent services | atuin, miniflux, spendspentspent, postgres-backup |
| rollback | restore backup-1 image tag → restart postgres → restart all dependents |

### ntfy

| aspect | detail |
|--------|--------|
| health checks | container_running |
| functional tests | ntfy_http (HTTP 200/301/302 on :8888) |
| reason critical | bender depends on ntfy for update notifications — if ntfy breaks, bender loses alerting |

### beszel

| aspect | detail |
|--------|--------|
| health checks | container_running |
| functional tests | beszel_http (HTTP 200/301/302/401 on :8090) |
| reason critical | monitoring hub for both hosts — losing it means no system metrics |

### spendspentspent

| aspect | detail |
|--------|--------|
| health checks | container_running |
| functional tests | spendspentspent_http (HTTP 200/301/302 on :9021) |
| reason critical | financial data — must not lose access after an update |

### non-critical but monitored

| container | monitoring |
|-----------|-----------|
| pihole | DNS resolution |
| keepalived | VIP presence |
| tsdproxy | tailscale connectivity |
| beszel-agent | agent registration |

---

## health checks

### health-checks.sh capabilities

```bash
# full postgresql suite
bash /docker-compose/scripts/health-checks.sh postgres

# individual service checks
bash /docker-compose/scripts/health-checks.sh ntfy
bash /docker-compose/scripts/health-checks.sh pihole
bash /docker-compose/scripts/health-checks.sh trivy
bash /docker-compose/scripts/health-checks.sh diun
bash /docker-compose/scripts/health-checks.sh vaultwarden

# all checks
bash /docker-compose/scripts/health-checks.sh all
```

note: amy's health-checks.sh includes a vaultwarden check for legacy reasons (vaultwarden was on amy until v92 when it moved to bender). the check will simply report the container as not running, which is correct.

### postgresql health check suite

| check | command | pass criteria |
|-------|---------|---------------|
| container running | docker ps filter | container exists and running |
| health status | docker inspect | healthy |
| pg_isready | pg_isready -U postgres | exit code 0 |
| database exists (atuin) | psql -lqt | atuin found |
| database exists (miniflux) | psql -lqt | miniflux found |
| database exists (sss) | psql -lqt | sss found |
| SELECT 1 | psql SELECT 1 | query succeeds |
| connect to atuin | psql -d atuin | succeeds |
| connect to miniflux | psql -d miniflux | succeeds |
| connect to sss | psql -d sss | succeeds |

---

## rollback system

### automatic rollback (during updates)

same as bender — triggered when health checks fail after deploying a new image.

### manual rollback

```bash
# list available backups for a container
bash /docker-compose/scripts/rollback.sh list-containers ntfy

# rollback container to most recent backup
bash /docker-compose/scripts/rollback.sh container ntfy

# rollback to second-most-recent backup
bash /docker-compose/scripts/rollback.sh container ntfy 2

# list postgresql backups
bash /docker-compose/scripts/rollback.sh list-postgres

# restore full postgresql backup
bash /docker-compose/scripts/rollback.sh postgres /docker/backups/postgres/last/atuin-latest.sql.gz

# restore single database
bash /docker-compose/scripts/rollback.sh database atuin /docker/backups/postgres/daily/atuin-20260210.sql.gz
```

### image backup retention

same as bender — 3 backup tags per container (backup-1, backup-2, backup-3).

---

## throttling system

identical to bender's v1.2 throttling:

| setting | value | purpose |
|---------|-------|---------|
| THROTTLE_DELAY | 60s | wait between container updates |
| MAX_LOAD | 4.0 | skip if 1-min load average exceeds |
| MAX_IOWAIT | 50% | skip if I/O wait percentage exceeds |
| RECOVERY_WAIT | 120s | wait time for system recovery |
| MAX_RECOVERY_ATTEMPTS | 5 | max recovery wait cycles (10 min total) |

```bash
# check system health manually
bash /docker-compose/scripts/secure-container-update.sh health
```

---

## notification flow

amy's ntfy is local, so notifications use `http://localhost:8888`:

| event | priority | tags |
|-------|----------|------|
| weekly scan starting | low | hourglass |
| weekly scan complete | default | white_check_mark |
| daily retry starting | low | arrows_counterclockwise |
| daily retry complete | default | arrows_counterclockwise |
| container rolled back | high | warning, rotating_light |
| rollback FAILED | urgent | rotating_light, skull |
| scan aborted (overloaded) | high | warning |

note: the notification URL comes from the `WATCHTOWER_NOTIFICATION_URL` variable in .env (legacy name). on amy this variable is currently commented out, so notifications from secure-container-update.sh are silently skipped. diun uses its own `DIUN_NOTIF_NTFY_ENDPOINT=http://ntfy:80` which works independently.

---

## cron schedule

| schedule | command | purpose |
|----------|---------|---------|
| wednesday 04:30 | `secure-container-update.sh weekly` | full scan of all containers |
| all days except wednesday 04:30 | `secure-container-update.sh retry` | retry previously blocked containers |

```bash
# verify cron
crontab -l | grep secure-container
```

---

## configuration files

### critical-containers.json

location: `/docker-compose/configs/secure-update/critical-containers.json`

auto-created on first run. defines postgres, ntfy, beszel, and spendspentspent as critical.

### retry-queue.json

location: `/docker-compose/configs/secure-update/retry-queue.json`

tracks containers blocked by vulnerability scans.

### logs

location: `/docker-compose/configs/secure-update/logs/`

one log file per day. retention: 180 days.

### scan reports

location: `/docker-compose/configs/secure-update/scan-reports/`

trivy JSON reports organized by date. retention: 180 days.

### weekly reports

location: `/docker-compose/reports/weekly-reports/`

markdown summary reports. retention: 180 days.

---

## differences from bender

| aspect | amy | bender |
|--------|-----|--------|
| update day | wednesday | saturday |
| trivy host port | 8083 | 8083 |
| trivy internal port | 4954 | 8080 |
| trivy server URL | http://localhost:8083 | http://localhost:8082 |
| diun schedule | wednesday 04:00 | daily 06:00 |
| critical services | 4 (postgres, ntfy, beszel, spendspentspent) | 1 (postgres) |
| script execution | direct | requires `/tmp` copy (TrueNAS) |
| ntfy endpoint | local (`http://localhost:8888`) | remote (`http://${NTFY_ADDRESS}`) |
| postgres image | postgres:17-alpine | immich-app/postgres (vectorchord) |
| postgres databases | atuin, miniflux, sss, mealie, stirling | immich, hedgedoc |
| base path | `/docker-compose` | `/mnt/BIG/filme/docker-compose` |
| backup path | `/docker/backups/postgres` | `/mnt/BIG/filme/backups/postgres` |
| additional cron | none | pihole-dns-update.sh (every 5 min) |
| build-based containers | 0 | 3 (transmission, tts-pipeline, epub2tts-edge) |

---

*previous: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
*next: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
