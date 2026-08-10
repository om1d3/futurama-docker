# bender secure container update system

## security-first container lifecycle management

**document version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

---

## table of contents

1. [overview](#overview)
2. [components](#components)
3. [script execution on TrueNAS](#script-execution-on-truenas)
4. [update workflow](#update-workflow)
5. [build-based containers](#build-based-containers)
6. [critical services](#critical-services)
7. [health checks](#health-checks)
8. [rollback system](#rollback-system)
9. [throttling system](#throttling-system)
10. [notification flow](#notification-flow)
11. [cron schedule](#cron-schedule)
12. [configuration files](#configuration-files)
13. [known audit items](#known-audit-items)
14. [differences from amy](#differences-from-amy)

---

## overview

bender uses a custom secure container update system that ensures no container is deployed with known CRITICAL or HIGH vulnerabilities. the system pulls new images, scans them with trivy, deploys only if clean, runs health checks, and automatically rolls back on failure.

the system consists of the orchestration script plus health-check and rollback helpers, two JSON configuration files, and TrueNAS UI cron jobs that run weekly (full scan) and daily (retry blocked containers).

script v1.3 (2026-07) made two structural changes: **gluetun joined postgres as a critical service** (its update destroys the network namespace shared by eight dependents, which the pipeline now recreates in order), and the critical-containers definition gained forgejo coverage (dependent restart + functional test through the dedicated database user).

three containers use `build:` directives instead of pre-built images and require special handling – see [build-based containers](#build-based-containers).

---

## components

| component | version | purpose |
|-----------|---------|---------|
| secure-container-update.sh | v1.3 | main update orchestration script |
| health-checks.sh | v1.2 | standalone health check suite |
| rollback.sh | v1.1 | manual rollback helper |
| pihole-dns-update.sh | v3.2 | DNS auto-population (separate hourly cron) |
| smart-test.sh | v1.1 | SMART testing + alerting (separate crons; shares the secure-update state tree) |
| bender-replicate.sh | v1.0 | nightly replication to amy (separate cron; replicates this system's own code and state) |
| diun | latest | monitors registries for new image tags (daily 06:00) |
| trivy | latest | scans images for CVEs (server mode, host port 8083) |
| critical-containers.json | – | defines critical services and their test suites |
| retry-queue.json | – | tracks containers blocked by vulnerabilities |

---

## script execution on TrueNAS

the pool is mounted noexec – scripts under `/mnt/` cannot be executed directly. all invocations use the `bash <path>` form. the legacy copy-to-/tmp pattern (documented through v3.0 of this suite) is retired.

scheduled entries (TrueNAS UI cron, run as root, Hide Stdout):

```bash
# weekly scan (saturday 04:30)
30 4 * * 6   bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh weekly

# daily retry (sunday–friday 04:30, excludes saturday)
30 4 * * 0-5 bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh retry
```

for manual use:

```bash
# status overview (includes critical-container readout)
bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh status

# scan a single container without deploying
bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh scan <container>

# system health gate check
bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh health

# health checks
bash /mnt/BIG/filme/docker-compose/scripts/health-checks.sh postgres

# manual rollback
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh list jellyfin
```

only **UI-defined** cron jobs survive TrueNAS upgrades – root's crontab was silently emptied by one (discovered 2026-07). never schedule anything via `crontab -e` on bender.

---

## update workflow

```
1. check system health (load average < 4.0, iowait < 50%)
   │
   ▼
2. for each running container:
   │
   ├── pull new image
   │   │
   │   ▼
   ├── scan with trivy (server mode)
   │   │
   │   ├── CRITICAL or HIGH found → add to retry queue → skip
   │   │
   │   ▼
   ├── pre-upgrade actions (backup for critical containers)
   │   │
   │   ▼
   ├── stop container
   │   │
   │   ▼
   ├── backup current image (rotate backup-1/2/3 tags)
   │   │
   │   ▼
   ├── start with new image (docker compose up -d --force-recreate)
   │   │
   │   ▼
   ├── wait 30 seconds
   │   │
   │   ▼
   ├── run health checks
   │   │
   │   ├── FAIL → rollback to backup-1 → notify
   │   │
   │   ▼
   ├── restart dependent services (critical containers only;
   │   gluetun: ordered recreation of all 8 namespace tenants)
   │   │
   │   ▼
   ├── re-run integration tests
   │   │
   │   ├── FAIL → rollback → notify
   │   │
   │   ▼
   ├── SUCCESS → remove from retry queue
   │
   ▼
3. wait THROTTLE_DELAY (60s) between containers
   │
   ▼
4. check system health again before next container
   │
   ├── overloaded → wait up to 5 × 120s for recovery
   ├── still overloaded → skip remaining containers
   │
   ▼
5. generate report + send ntfy notification
```

### containers skipped by the update system

the following containers are never auto-updated:

| container | reason |
|-----------|--------|
| diun | infrastructure – updates itself |
| trivy | infrastructure – scanner should not scan itself |
| transmission | build-based – requires manual `docker compose build`; base image PINNED 4.0.5 |
| audiobook-foundry | build-based – requires manual `docker compose build` |

(epub2tts-edge never appears to the updater – `profiles: tools` means it is not a running container.)

additionally, **jellyfin is effectively pinned by policy** (v114): the image tag is the explicit `10.11.11`, so a pull updates nothing until the tag in the compose file is bumped by hand. patch bumps happen on Diun notification; major 12 never happens through the pipeline.

---

## build-based containers

| container | build context | update procedure |
|-----------|--------------|------------------|
| transmission | `/mnt/BIG/filme/configs/transmission/` | edit Dockerfile → `docker compose build --no-cache transmission` → `docker compose up -d transmission` |
| audiobook-foundry | `/mnt/BIG/filme/configs/audiobook-foundry/` | `git pull` → `docker compose build --no-cache audiobook-foundry` → `docker compose up -d audiobook-foundry` |
| epub2tts-edge | `/mnt/BIG/filme/configs/epub2tts-edge/` | edit Dockerfile → `docker compose build --no-cache epub2tts-edge` (profiles: tools, on-demand) |

these containers are effectively pinned to their Dockerfile definitions. to update the base image, edit the `FROM` line and rebuild.

**transmission is pinned to 4.0.5** – do NOT change the base image version. FileList whitelist requirement; 4.0.6+ means an immediate ban.

rebuilt images can still be scanned manually: `trivy image <local-image>` against the server on :8083.

---

## critical services

two services are classified as critical on bender as of script v1.3:

### postgres

| aspect | detail |
|--------|--------|
| pre-upgrade | full `pg_dumpall` backup to `/mnt/BIG/filme/backups/postgres/pre-upgrade/` |
| health checks | pg_isready, pg_connect (SELECT 1), pg_databases (verify all five tenants exist) |
| functional tests | immich_db_access (`SELECT COUNT(*) FROM "user"` – note quoted table name), hedgedoc_db_access, vikunja_db_access (tasks count), forgejo_db_access (repository count **as the dedicated forgejo user** – proves per-user auth survived the upgrade), baikal_db_access (SELECT 1 for now; upgrade to a table probe once a stable table name is confirmed via `\dt`) |
| integration tests | immich_api_ping (`/api/server/ping` → "pong"), hedgedoc_http (HTTP 200/301/302), vikunja_http (`/api/v1/info` → 200), forgejo_http (:3030) |
| dependent services | immich_server, immich_machine_learning, hedgedoc, postgres-backup, baikal, vikunja, forgejo |
| rollback | restore backup-1 image tag → restart postgres → restart all dependents |

> **important:** the immich database uses a `"user"` table (quoted) because `user` is a PostgreSQL reserved keyword. health checks must use `'SELECT COUNT(*) FROM "user"'` with proper quoting.

### gluetun (v1.3)

| aspect | detail |
|--------|--------|
| why critical | eight containers share gluetun's network namespace. recreating gluetun destroys that namespace; tenants left attached to the dead one appear "Up" but have no connectivity and do not self-recover |
| health checks | container_running, container_not_restarting, no_oom_kill |
| dependent services (recreated in this order) | transmission, prowlarr, sonarr, radarr, lidarr, readarr, bazarr, jdownloader |
| update duration | long by design – 8 recreations plus per-container waits |
| rollback | restore backup-1 → recreate gluetun → recreate all eight tenants again |

the same ordered-recreation rule applies to **manual** gluetun operations: any `--force-recreate gluetun` must be followed by recreating the eight tenants.

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
# full postgresql suite
bash /mnt/BIG/filme/docker-compose/scripts/health-checks.sh postgres

# single container basic checks (running, healthy, restart count, OOM)
bash /mnt/BIG/filme/docker-compose/scripts/health-checks.sh container jellyfin

# all running containers
bash /mnt/BIG/filme/docker-compose/scripts/health-checks.sh all
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
| pg_databases | list non-template databases | all five tenants found |
| immich DB access | SELECT COUNT(*) FROM "user" | query succeeds |
| hedgedoc DB access | SELECT 1 on hedgedoc | query succeeds |
| write test | CREATE/DROP temp table | succeeds |
| immich API | curl /api/server/ping | returns "pong" |
| hedgedoc HTTP | curl localhost:3000 | HTTP 200/301/302 |

note: health-checks.sh is at v1.2 and predates baikal/vikunja/forgejo – its standalone postgres suite covers the original checks, while the v1.3 **update script** carries the vikunja and forgejo functional/integration tests internally. extending health-checks.sh to the five-tenant world is an open improvement.

---

## rollback system

### automatic rollback (during updates)

triggered when health checks fail after deploying a new image. the system:

1. stops the failed container
2. restores the backup-1 image tag
3. starts the container with the previous image
4. for critical containers: restarts all dependent services (gluetun: full ordered tenant recreation)
5. sends ntfy notification

### manual rollback

```bash
# list available backups for a container
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh list jellyfin

# rollback to most recent backup
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh rollback jellyfin

# rollback to second-most-recent backup
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh rollback sonarr 2

# special postgresql rollback (handles dependents)
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh postgres
```

### image backup retention

the system maintains 3 backup tags per container:

```
registry/image:latest      ← currently running
registry/image:backup-1    ← previous version (most recent)
registry/image:backup-2    ← older version
registry/image:backup-3    ← oldest kept version
```

older backups are automatically pruned during rotation. since v1.3, configuration files the script rewrites (e.g. critical-containers.json) are preserved with versioned backup names rather than a single `.bak`, matching the scripts directory convention.

---

## throttling system

added in v1.2 to prevent ZFS I/O saturation on the HP MicroServer Gen8 (values verified against the script constants):

| setting | value | purpose |
|---------|-------|---------|
| THROTTLE_DELAY | 60s | wait between container updates |
| MAX_LOAD | 4.0 | skip if 1-min load average exceeds |
| MAX_IOWAIT | 50% | skip if I/O wait percentage exceeds |
| RECOVERY_WAIT | 120s | wait time for system recovery |
| MAX_RECOVERY_ATTEMPTS | 5 | max recovery wait cycles (10 min total) |

the system checks health before each container update. if overloaded, it waits up to 5 × 120s = 10 minutes for recovery. if recovery fails, remaining containers are skipped and listed in the report.

**scheduling interaction:** the weekly scan (saturday 04:30) must never overlap the nightly replication (03:30). the one-hour offset is deliberate; if either schedule moves, preserve the gap – two I/O-heavy jobs at once is exactly the stampede the throttles exist to prevent.

---

## notification flow

notifications go to ntfy on amy. the script reads its endpoint from `WATCHTOWER_NOTIFICATION_URL` in `.env` (legacy variable name from the watchtower era – the script sources `.env` and uses this value directly):

| event | priority | tags |
|-------|----------|------|
| weekly scan starting | low | hourglass |
| weekly scan complete | default | white_check_mark |
| daily retry starting | low | arrows_counterclockwise |
| daily retry complete | default | arrows_counterclockwise |
| container rolled back | high | warning, rotating_light |
| rollback FAILED | urgent | rotating_light, skull |
| scan aborted (overloaded) | high | warning |

diun sends its own update-available notifications via `${NTFY_ADDRESS}` / `${DIUN_NTFY_TOPIC}`. smart-test.sh and bender-replicate.sh push to their own topics on the same ntfy instance.

---

## cron schedule

the update system owns two of bender's seven UI cron jobs:

| schedule | command | purpose |
|----------|---------|---------|
| `30 4 * * 6` | `bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh weekly` | full scan of all containers |
| `30 4 * * 0-5` | `bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh retry` | retry previously blocked containers |

the **canonical seven-job table** (replication, DNS scraper, the three smart-test modes, and these two) lives in [07-MAINTENANCE.md](./07-MAINTENANCE.md) → TrueNAS maintenance – edit schedules there first, then mirror. all jobs run as root with Hide Stdout, America/Toronto local time. the weekly scan must never overlap the 03:30 replication window.

---

## configuration files

### critical-containers.json

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/critical-containers.json`

auto-created on first run; v1.3 shape defines postgres and gluetun with their pre-upgrade actions, health/functional/integration tests, and dependent-service lists (postgres dependents include baikal, vikunja, forgejo).

### retry-queue.json

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json`

tracks containers blocked by vulnerability scans. the daily retry job processes this queue. manual reset: `echo '{"containers": []}' > <path>`.

### logs

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/logs/` – one file per day, 180-day retention. smart-test.sh writes its `smart-YYYY-MM-DD.log` files here too.

### scan reports

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/scan-reports/` – trivy JSON by date, 180-day retention.

### SMART state

location: `/mnt/BIG/filme/docker-compose/configs/secure-update/smart-state/` – per-disk baselines keyed by model_serial (survive device-letter shuffles).

### weekly reports

location: `/mnt/BIG/filme/docker-compose/reports/weekly-reports/` – markdown summaries, 180-day retention.

---

## known audit items

- **TRIVY_SERVER port mismatch:** the v1.2 script constant was `http://localhost:8082`, while the trivy container publishes on host port **8083** (8083:8080). scanning still functioned via the script's containerized-fallback path, but the constant is at best misleading. <!-- VERIFY: confirm the TRIVY_SERVER value in v1.3 and align it with 8083, or document why 8082 works -->
- **health-checks.sh tenant gap:** v1.2 standalone suite predates baikal/vikunja/forgejo (covered inside the v1.3 update script instead). folding the new tenants into health-checks.sh would restore one-command verification.

---

## differences from amy

| aspect | bender | amy |
|--------|--------|-----|
| update day | saturday | wednesday |
| script version | v1.3 (postgres + gluetun critical) | v1.2 |
| trivy port mapping | 8083:8080 (listen 8080) | 8083:4954 (listen 4954) |
| diun schedule | daily 06:00 | wednesday 04:00 |
| critical services | 2 (postgres, gluetun) | 4 (postgres, ntfy, beszel, spendspentspent) |
| script execution | `bash <path>` (noexec pool) | direct execution |
| cron mechanism | TrueNAS UI jobs (7) | root crontab (weekly wed 04:30, retry other days) |
| ntfy endpoint | remote amy (10.30.0.11:8888) | local (`http://ntfy:80` container-side for diun) |
| postgres image | immich-app/postgres:14 (vectorchord) | postgres:17-alpine |
| postgres databases | immich, hedgedoc, baikal, vikunja, forgejo | atuin, miniflux, sss, mealie, stirling |
| dedicated DB users | forgejo (exception → future template) | none |
| base path | `/mnt/BIG/filme/docker-compose` | `/docker-compose` |
| backup path | `/mnt/BIG/filme/backups/postgres` | `/docker/postgres-backup` |
| additional crons | replication, DNS scraper, 3× smart-test | none documented <!-- VERIFY: amy crontab -l --> |
| build-based containers | 3 (transmission, audiobook-foundry, epub2tts-edge) | 0 |


---

## image pinning policy (20260808)

pins exist because unpinned `:latest` tags broke production silently, twice
in one week, on both hosts.

| service | pin | reason |
|---------|-----|--------|
| jellyfin | `10.11.11` | the floating `10.11` tag does not exist on lscr.io. bump patches manually. NEVER major 12. |
| postgres-backup | `:14` | major-matched to the postgres 14 server, for restore compatibility |
| tsdproxy | digest `sha256:e75357d5...` | `:latest` resolves to 3.0.0-beta.1 |
| influxdb | `1.11` | 1.x is required by Home Assistant's config format |
| forgejo | `:15` | LTS line; majors are manual per Forgejo policy |

**prefer a digest over a tag.** a digest names one exact image. the
tsdproxy fault was caused by a tag moving under a working deployment.
amy's keepalived fault was caused by pinning to a tag that was assumed
equivalent and was not.

get a digest from what is running:

```bash
docker inspect <image>:latest --format '{{index .RepoDigests 0}}'
```

### diun blind spot

diun watches tags. a digest-pinned service produces no notifications, and a
pinned tag such as jellyfin's `10.11.11` only notifies on a re-push of that
exact tag. so pinned images need deliberate review rather than waiting for
an alert.

---

## containers that must not be casually recreated

| service | reason |
|---------|--------|
| influxdb | needs several minutes to open its shards before accepting connections, and every restart repeats that work |
| audiobook-foundry | build-based; a recreate without a build uses the old image |
| transmission | build-based, and pinned to 4.0.5 for the FileList whitelist |
| postgres | every dependent service waits on its healthcheck |

influxdb is the new one. the update system should treat it as a special
case, the way gluetun already is.

---

## the prune trap

`docker image prune -a` recovers a great deal of space. it also deletes
every `:backup-N` tag, which is this system's image-level rollback stock.

on amy, that happened on 2026-08-08. rollback was unavailable until the
next update cycle re-tagged the backups. any specific image can still be
re-pulled from its registry by digest.

**a scheduled prune must exclude the `backup-N` pattern.** `docker image
prune -f` without `-a` is safe, because it removes only untagged layers.

---

## rollback paths, by layer

| layer | mechanism | note |
|-------|-----------|------|
| image | `:backup-N` tags, `rollback.sh` v1.1 | destroyed by `prune -a` |
| compose file | dated `.backup` copies in the compose directory | take one BEFORE every edit |
| config and scripts | git, through futurama-sync.sh | forgejo, mirrored to GitHub |
| postgres | postgres-backup daily dumps, 7d/4w/6m | five databases |
| configs and dumps | bender-replicate.sh v1.1 to amy, 7 days | hardlink rotation |
| pool | ZFS snapshots | the only protection for `influxdb/` and media |

note that `configs/` and the postgres dumps have two independent copies,
while `influxdb/` has only ZFS snapshots. that was deliberate, because
telemetry does not belong in a nightly config replica.

---

*previous: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
*next: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
