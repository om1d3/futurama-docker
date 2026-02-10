# amy secure container update system

## security-first container lifecycle management

**document version:** 2.0
**infrastructure version:** 98
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [components](#components)
3. [update workflow](#update-workflow)
4. [critical services](#critical-services)
5. [health checks](#health-checks)
6. [rollback procedures](#rollback-procedures)
7. [notifications](#notifications)
8. [schedule](#schedule)
9. [scripts reference](#scripts-reference)
10. [differences from bender](#differences-from-bender)

---

## overview

amy uses a security-first approach to container updates. every image is scanned for known vulnerabilities before deployment, and critical services receive additional protection through pre-upgrade backups, extended health checks, and automatic rollback.

### key principles

1. **scan before deploy** — every image is scanned with trivy before deployment
2. **block on vulnerabilities** — critical and high severity CVEs block updates
3. **automatic rollback** — failed updates trigger automatic rollback to the previous image
4. **critical service protection** — essential services get pre-upgrade backups and extended verification
5. **notification on all events** — ntfy alerts for updates, blocks, failures, and completions

### system components

```
┌─────────────────────────────────────────────────────────────────┐
│                    secure update system                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │    diun     │───►│   trivy     │───►│   script    │         │
│  │  (monitor)  │    │   (scan)    │    │  (update)   │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│        │                   │                  │                  │
│        ▼                   ▼                  ▼                  │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │    ntfy     │    │   block     │    │  rollback   │         │
│  │  (notify)   │    │ (if vuln)   │    │ (if fail)   │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## components

### diun (docker image update notifier)

monitors all container images for available updates and sends notifications to ntfy.

| property | value |
|----------|-------|
| **container** | `diun` |
| **schedule** | `0 4 * * 3` (wednesday 04:00) |
| **watch mode** | all containers by default |
| **ntfy endpoint** | `http://ntfy:80` (docker network) |
| **ntfy topic** | `${DIUN_NTFY_TOPIC}` |

diun runs slightly before the update script (04:00 vs 04:30) so that notifications about available updates arrive before the script attempts to apply them.

### trivy (vulnerability scanner)

scans container images for known CVEs before deployment.

| property | value |
|----------|-------|
| **container** | `trivy` |
| **mode** | server |
| **internal port** | 4954 |
| **host port** | 8083 |
| **endpoint** | `http://localhost:8083` |
| **cache** | `/docker/trivy/cache` |

### secure-container-update.sh

orchestrates the entire update process — pull, scan, deploy, verify, rollback.

| property | value |
|----------|-------|
| **version** | 1.2 |
| **location** | `/docker-compose/scripts/secure-container-update.sh` |
| **execution** | direct (no /tmp copy needed, unlike bender) |

### health-checks.sh

verifies services are functioning correctly after updates.

| property | value |
|----------|-------|
| **version** | 1.0 |
| **location** | `/docker-compose/scripts/health-checks.sh` |
| **targets** | postgres, ntfy, pihole, trivy, diun, vaultwarden, all |

### rollback.sh

provides manual rollback for containers and postgresql databases.

| property | value |
|----------|-------|
| **version** | 1.0 |
| **location** | `/docker-compose/scripts/rollback.sh` |

---

## update workflow

### standard container update

```
1. diun detects new image available
   └─► notification sent to ntfy

2. secure-container-update.sh runs (wednesday 04:30)
   ├─► pull new image
   ├─► scan with trivy
   │   ├─► critical/high CVE found?
   │   │   ├─► YES: block update, add to retry queue, notify
   │   │   └─► NO: continue
   │   │
   ├─► is this a critical container?
   │   ├─► YES: run pre-upgrade backup, extended health checks
   │   └─► NO: standard update
   │   │
   ├─► backup current image tag
   ├─► deploy new image (docker compose up -d)
   ├─► run health checks
   │   ├─► PASS: notify success
   │   └─► FAIL: automatic rollback, notify failure
   │
   └─► generate report
```

### postgresql upgrade process

postgresql receives special handling to minimize downtime:

```
phase 1: preparation (database still running)
├── 1. pull new postgres image
├── 2. scan with trivy
└── 3. if vulnerabilities found → abort

phase 2: backup (database still running)
├── 4. pg_dumpall full backup
├── 5. verify backup file exists and is non-empty
└── 6. if backup fails → abort

phase 3: deployment
├── 7. stop dependent services (atuin, miniflux, spendspentspent, postgres-backup)
├── 8. stop postgres
├── 9. start new postgres
├── 10. wait for pg_isready
└── 11. verify all databases exist (atuin, miniflux, sss, mealie, stirling)

phase 4: verification
├── 12. run functional tests (SELECT 1 on each database)
├── 13. start dependent services
├── 14. verify dependent services healthy
└── 15. notify success

phase 4-fail: recovery (if any check fails)
├── 16. stop new postgres
├── 17. restore backup image tag
├── 18. start old postgres
├── 19. start dependent services
└── 20. notify failure with rollback details
```

---

## critical services

### critical container configuration

critical services receive pre-upgrade backups, extended health checks, functional tests, and automatic rollback. the configuration is stored in `/docker-compose/configs/secure-update/critical-containers.json`.

| service | pre-upgrade action | health checks | functional tests | dependent services |
|---------|-------------------|---------------|------------------|--------------------|
| **postgres** | pg_dumpall backup | pg_isready, pg_connect, pg_databases | atuin_db_access, miniflux_db_access, sss_db_access | atuin, miniflux, spendspentspent, postgres-backup |
| **ntfy** | none | container_running | ntfy_http (port 8888) | none |
| **beszel** | none | container_running | beszel_http (port 8090) | none |
| **spendspentspent** | none | container_running | spendspentspent_http (port 9021) | none |

### non-critical services

these services use standard container health checks only (running, not restarting, no OOM):

pihole, keepalived, tsdproxy, beszel-agent, and all other services.

> **note:** vaultwarden was moved to bender in v92 and is no longer part of amy's update cycle.

### vulnerability thresholds

| severity | threshold | action |
|----------|-----------|--------|
| **critical** | 0 | blocks deployment |
| **high** | 0 | blocks deployment |
| **medium** | unlimited | allowed (warning logged) |
| **low** | unlimited | allowed (informational) |

---

## health checks

### available checks

| target | checks performed |
|--------|------------------|
| **postgres** | container running, health status, pg_isready, database existence (atuin, miniflux, sss, mealie, stirling), query execution, per-database connectivity |
| **ntfy** | container running, HTTP endpoint (port 8888) |
| **pihole** | container running, health status, DNS resolution test |
| **trivy** | container running, health status, healthz endpoint |
| **diun** | container running, error count, configuration loaded |
| **all** | all container status + all individual checks above |

> **note:** vaultwarden was migrated to bender in v92. the health-checks.sh script still contains a `vaultwarden` check target that is now unused on amy — it fails gracefully since the container no longer exists here. see bender's [04-SECURE-UPDATES.md](../../bender/docs/04-SECURE-UPDATES.md) for vaultwarden health check details.

### running health checks

```bash
# check all services
/docker-compose/scripts/health-checks.sh all

# check specific service
/docker-compose/scripts/health-checks.sh postgres
/docker-compose/scripts/health-checks.sh ntfy
/docker-compose/scripts/health-checks.sh pihole
```

### health check output example

```
==========================================
Amy Health Checks - 2026-02-08
==========================================

=== All Containers Status ===
✓ 29 containers running
✗ 0 containers stopped unexpectedly

=== PostgreSQL Health Checks ===
✓ PostgreSQL container is running
✓ PostgreSQL health status: healthy
✓ PostgreSQL is accepting connections
✓ Database 'atuin' exists
✓ Database 'miniflux' exists
✓ Database 'sss' exists
✓ Database 'mealie' exists
✓ Database 'stirling' exists
✓ PostgreSQL can execute queries

==========================================
Results: 11 passed, 0 failed, 0 warnings
==========================================
```

---

## rollback procedures

### container rollback

the update script maintains backup image tags for each container (up to 3 generations).

```bash
# list available image backups for a container
/docker-compose/scripts/rollback.sh list-containers ntfy

# rollback to most recent backup
/docker-compose/scripts/rollback.sh container ntfy

# rollback to specific backup (2nd most recent)
/docker-compose/scripts/rollback.sh container ntfy 2
```

### postgresql rollback

```bash
# list postgresql backups
/docker-compose/scripts/rollback.sh list-postgres

# restore full backup
/docker-compose/scripts/rollback.sh postgres /docker/backups/postgres/manual/backup-20260208.sql

# restore single database
/docker-compose/scripts/rollback.sh database atuin /docker/postgres-backup/daily/atuin-20260208.sql.gz
```

### manual postgresql backup and restore

```bash
# manual backup before risky changes
docker exec postgres pg_dumpall -U postgres > /docker/backups/postgres/manual/backup-$(date +%Y%m%d-%H%M%S).sql

# verify backup
ls -la /docker/backups/postgres/manual/
head -50 /docker/backups/postgres/manual/backup-*.sql

# restore (stop dependent services first)
docker compose stop atuin miniflux spendspentspent postgres-backup
docker exec -i postgres psql -U postgres < /docker/backups/postgres/manual/backup-20260208.sql
docker compose start atuin miniflux spendspentspent postgres-backup
```

### automatic rollback triggers

the update script automatically rolls back when:
- container fails to start after update
- health check fails after update
- critical service becomes unhealthy
- dependent services fail to reconnect

---

## notifications

### notification events

| event | ntfy message | priority |
|-------|-------------|----------|
| update started | 🔄 amy update started | default (3) |
| container updated | ✅ [container] updated | default (3) |
| vulnerability blocked | ⚠️ [container] blocked (CVE details) | high (4) |
| rollback triggered | ⚠️ rollback: [container] | high (4) |
| rollback failed | 🚨 CRITICAL: [container] rollback failed | urgent (5) |
| update complete (success) | ✅ amy update complete | default (3) |
| update complete (with failures) | ⚠️ amy update complete (N failures) | high (4) |

### ntfy configuration

| property | value |
|----------|-------|
| **endpoint** | `http://localhost:8888` (local ntfy) |
| **topic** | `${DIUN_NTFY_TOPIC}` (from .env) |
| **delivery** | docker network (diun) + localhost (script) |

---

## schedule

### cron configuration

```bash
# weekly container update — wednesday 04:30 AM
30 4 * * 3 /docker-compose/scripts/secure-container-update.sh weekly >> /docker-compose/configs/secure-update/logs/cron.log 2>&1

# daily retry for failed containers — 04:30 AM (every day EXCEPT wednesday)
30 4 * * 0-2,4-6 /docker-compose/scripts/secure-container-update.sh retry >> /docker-compose/configs/secure-update/logs/cron.log 2>&1
```

### why wednesday?

- bender updates on **saturday** — staggering prevents simultaneous update failures
- mid-week timing allows weekday troubleshooting if something breaks
- the retry job excludes wednesday to avoid conflicting with the weekly scan

### retry logic

when a container update is blocked by vulnerabilities:
1. container is added to the retry queue (`/docker-compose/configs/secure-update/retry-queue.json`)
2. the daily retry job re-scans the image with trivy
3. if vulnerabilities are resolved upstream, the update proceeds
4. if still vulnerable, the container stays in the retry queue

---

## scripts reference

### file locations

```
/docker-compose/scripts/
├── secure-container-update.sh   # v1.2 — main update orchestrator
├── health-checks.sh             # v1.0 — service health verification
└── rollback.sh                  # v1.0 — manual rollback helper
```

### state files

```
/docker-compose/configs/secure-update/
├── critical-containers.json     # critical service definitions
├── retry-queue.json             # blocked containers waiting for retry
├── logs/                        # daily execution logs
│   ├── 2026-02-08.log
│   ├── cron.log                 # cron output
│   └── ...
└── scan-reports/                # trivy scan results per container
```

### report files

```
/docker-compose/reports/weekly-reports/
└── ...                          # weekly update summary reports
```

### image backup retention

the update script maintains up to **3 backup image tags** per container, allowing rollback to any of the 3 previous versions. older backups are automatically pruned.

---

## differences from bender

| aspect | amy | bender |
|--------|-----|--------|
| **update day** | wednesday | saturday |
| **trivy host port** | 8083 | 8083 |
| **trivy internal port** | 4954 | 8080 |
| **critical services** | 4 (postgres, ntfy, beszel, spendspentspent) | 1 (postgres) |
| **script execution** | direct (`/docker-compose/scripts/`) | requires `/tmp` copy (TrueNAS restriction) |
| **ntfy endpoint (script)** | `http://localhost:8888` | `http://${NTFY_ADDRESS}` (remote) |
| **ntfy endpoint (diun)** | `http://ntfy:80` (docker network) | `http://${NTFY_ADDRESS}` (remote) |
| **postgres databases** | atuin, miniflux, sss, mealie, stirling | immich, hedgedoc |
| **base path** | `/docker-compose` | `/mnt/BIG/filme/docker-compose` |
| **backup path** | `/docker/backups/postgres` | `/mnt/BIG/filme/backups/postgres` |

the key architectural difference is that amy runs ntfy locally, so both the script and diun can reach it directly. bender must use the remote ntfy address on amy since it doesn't run its own notification server.

---

*previous: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
*next: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
