# bender secure container update system

## security-first container lifecycle management

**document version:** 2.0
**infrastructure version:** 105
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [components](#components)
3. [TrueNAS execution restriction](#truenas-execution-restriction)
4. [update workflow](#update-workflow)
5. [critical services](#critical-services)
6. [health checks](#health-checks)
7. [rollback procedures](#rollback-procedures)
8. [notifications](#notifications)
9. [schedule](#schedule)
10. [scripts reference](#scripts-reference)
11. [differences from amy](#differences-from-amy)

---

## overview

bender uses the same security-first approach as amy for container updates: every image is scanned with trivy for known vulnerabilities before deployment, and critical services receive additional protection. the key difference is that bender runs on TrueNAS Scale, which imposes filesystem execution restrictions requiring a copy-to-tmp workaround for script execution.

### key principles

1. **scan before deploy** — every image is scanned with trivy before deployment
2. **block on vulnerabilities** — critical and high severity CVEs block updates
3. **automatic rollback** — failed updates trigger automatic rollback to the previous image
4. **critical service protection** — postgres gets pre-upgrade database dumps and extended verification
5. **notification on all events** — ntfy alerts sent to amy's ntfy instance for all events
6. **TrueNAS-safe execution** — scripts are copied to `/tmp/` before running

---

## components

### diun (docker image update notifier)

monitors all container images for available updates and sends notifications to ntfy on amy.

| property | value |
|----------|-------|
| **container** | `diun` |
| **schedule** | `0 6 * * *` (daily 06:00) |
| **watch mode** | all containers by default |
| **ntfy endpoint** | `${NTFY_ADDRESS}` (remote — amy's ntfy) |
| **ntfy topic** | `${DIUN_NTFY_TOPIC}` |
| **ntfy priority** | 3 (default) |

note: bender's diun runs daily at 06:00 (not weekly like amy's). this is because bender has more services and benefits from earlier notification of available updates before the weekly Saturday scan.

### trivy (vulnerability scanner)

scans container images for known CVEs before deployment.

| property | value |
|----------|-------|
| **container** | `trivy` |
| **mode** | server |
| **internal port** | 8080 |
| **host port** | 8083 |
| **endpoint** | `http://localhost:8083` |
| **cache** | `/mnt/BIG/filme/configs/trivy` |

### secure-container-update.sh

orchestrates the entire update process — pull, scan, deploy, verify, rollback.

| property | value |
|----------|-------|
| **version** | 1.2 |
| **location** | `/mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh` |
| **execution** | requires `/tmp` copy (TrueNAS restriction) |

### health-checks.sh

verifies services are functioning correctly after updates.

| property | value |
|----------|-------|
| **version** | 1.0 |
| **location** | `/mnt/BIG/filme/docker-compose/scripts/health-checks.sh` |
| **execution** | requires `/tmp` copy |
| **targets** | postgres, immich, hedgedoc, pihole, jellyfin, transmission, vaultwarden, all |

### rollback.sh

provides manual rollback for containers and postgresql databases.

| property | value |
|----------|-------|
| **version** | 1.0 |
| **location** | `/mnt/BIG/filme/docker-compose/scripts/rollback.sh` |
| **execution** | requires `/tmp` copy |

---

## TrueNAS execution restriction

TrueNAS Scale does not allow executing scripts from `/mnt/` paths (the ZFS-mounted filesystem). all scripts must be copied to `/tmp/` (root filesystem) before execution.

### running scripts manually

```bash
# health checks
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/ && \
  bash /tmp/health-checks.sh all && \
  rm /tmp/health-checks.sh

# manual weekly scan
cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && \
  bash /tmp/secure-container-update.sh weekly && \
  rm /tmp/secure-container-update.sh

# rollback
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/ && \
  bash /tmp/rollback.sh list jellyfin && \
  rm /tmp/rollback.sh
```

### why not /root/?

`/root/` was tested as an alternative execution location, but TrueNAS also restricts execution there for scripts that reference `/mnt/` paths. the `/tmp/` copy approach is the reliable workaround.

the pihole-dns-update.sh is an exception — it lives at `/root/pihole-dns-update.sh` as a self-contained script that runs directly from cron without referencing `/mnt/` for execution.

---

## update workflow

### standard container update

```
1. diun detects new image available (daily 06:00)
   └─► notification sent to ntfy on amy

2. secure-container-update.sh runs (saturday 04:30)
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
   ├─► backup current image tag (up to 3 generations)
   ├─► deploy new image (docker compose up -d)
   ├─► run health checks
   │   ├─► PASS: notify success
   │   └─► FAIL: automatic rollback, notify failure
   │
   └─► generate report
```

### postgresql upgrade process

postgresql on bender is critical — it holds the immich photo database and hedgedoc data. the upgrade process minimizes downtime:

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
├── 7. stop dependent services (immich_server, immich_machine_learning, hedgedoc, postgres-backup)
├── 8. stop postgres
├── 9. start new postgres
├── 10. wait for pg_isready
└── 11. verify databases exist (immich, hedgedoc)

phase 4: verification
├── 12. run functional tests (immich database access, hedgedoc database access)
├── 13. run integration tests (immich API ping, hedgedoc HTTP)
├── 14. start dependent services
├── 15. verify dependent services healthy
└── 16. notify success

phase 4-fail: recovery (if any check fails)
├── 17. stop new postgres
├── 18. restore backup image tag
├── 19. start old postgres
├── 20. start dependent services
└── 21. notify failure with rollback details
```

> **note:** bender's postgres uses the specialized `ghcr.io/immich-app/postgres:14-vectorchord0.4.3` image with vector extensions. do not replace with standard postgres — immich requires the vectorchord/pgvectors extensions for ML-based search.

---

## critical services

### critical container configuration

on bender, only postgres is classified as critical in `/mnt/BIG/filme/docker-compose/configs/secure-update/critical-containers.json`.

| service | pre-upgrade action | health checks | functional tests | integration tests | dependent services |
|---------|-------------------|---------------|------------------|-------------------|--------------------|
| **postgres** | pg_dumpall backup | pg_isready, pg_connect, pg_databases | immich_db_access, hedgedoc_db_access | immich_api_ping, hedgedoc_http | immich_server, immich_machine_learning, hedgedoc, postgres-backup |

### why only postgres is critical

| service | reason not critical |
|---------|---------------------|
| pihole | redundancy via amy (keepalived failover) |
| keepalived | follows pihole status — if pihole is redundant, keepalived failure is tolerable |
| tsdproxy | nice-to-have for remote access, not essential for local operation |
| immich_server | depends on postgres — if postgres is protected, immich is indirectly protected |
| jellyfin | stateless media server — restart recovers it |
| vaultwarden | has its own healthcheck (`curl /alive`), data is in a simple sqlite database that doesn't require special backup procedures |

### vaultwarden health monitoring

although not classified as critical for the update system, vaultwarden is an important service (password manager). it has a built-in healthcheck:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:80/alive"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 10s
```

the health-checks.sh script includes a vaultwarden check target:

```bash
# run vaultwarden health check
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/ && \
  bash /tmp/health-checks.sh vaultwarden && \
  rm /tmp/health-checks.sh
```

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
| **postgres** | container running, health status, pg_isready, database existence (immich, hedgedoc), query execution, immich table access (`"user"` table), hedgedoc table access |
| **immich** | container running, API endpoint (port 2283) |
| **hedgedoc** | container running, HTTP endpoint (port 3000) |
| **pihole** | container running, health status, DNS resolution test |
| **jellyfin** | container running, HTTP endpoint (port 8096) |
| **transmission** | container running, RPC interface test (port 9091) |
| **vaultwarden** | container running, HTTP /alive endpoint (port 8484) |
| **all** | all container status + all individual checks above |

> **note:** the postgres health check uses `SELECT COUNT(*) FROM "user"` (with quotes) for the immich table — `user` is a reserved keyword in postgresql and requires quoting.

### running health checks

```bash
# copy to /tmp first (TrueNAS requirement)
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/

# check all services
bash /tmp/health-checks.sh all

# check specific service
bash /tmp/health-checks.sh postgres
bash /tmp/health-checks.sh vaultwarden

# cleanup
rm /tmp/health-checks.sh
```

---

## rollback procedures

### container rollback

```bash
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/

# list available image backups
bash /tmp/rollback.sh list jellyfin

# rollback to most recent backup
bash /tmp/rollback.sh rollback jellyfin

# rollback to specific backup (2nd most recent)
bash /tmp/rollback.sh rollback jellyfin 2

rm /tmp/rollback.sh
```

### postgresql rollback

postgresql rollback is handled specially due to dependent services:

```bash
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/

# interactive postgresql rollback (stops all dependent services)
bash /tmp/rollback.sh postgres

rm /tmp/rollback.sh
```

the postgresql rollback process:

```
1. confirm rollback (interactive prompt)
2. stop dependent services:
   ├── immich_server
   ├── immich_machine_learning
   ├── hedgedoc
   └── postgres-backup
3. stop postgres
4. restore backup image tag
5. start postgres
6. wait for pg_isready
7. start dependent services
8. verify immich API responds
```

### manual postgresql backup and restore

```bash
# manual backup before risky changes
docker exec postgres pg_dumpall -U postgres > /mnt/BIG/filme/backups/postgres/manual/backup-$(date +%Y%m%d-%H%M%S).sql

# verify backup
ls -la /mnt/BIG/filme/backups/postgres/manual/
head -20 /mnt/BIG/filme/backups/postgres/manual/backup-*.sql

# restore (stop dependent services first)
cd /mnt/BIG/filme/docker-compose
docker compose stop immich_server immich_machine_learning hedgedoc postgres-backup
docker exec -i postgres psql -U postgres < /mnt/BIG/filme/backups/postgres/manual/backup-20260208.sql
docker compose start immich_server immich_machine_learning hedgedoc postgres-backup
```

---

## notifications

### notification events

| event | ntfy message | priority |
|-------|-------------|----------|
| update started | 🔄 bender update started | default (3) |
| container updated | ✅ [container] updated | default (3) |
| vulnerability blocked | ⚠️ [container] blocked (CVE details) | high (4) |
| rollback triggered | ⚠️ rollback: [container] | high (4) |
| rollback failed | 🚨 CRITICAL: [container] rollback failed | urgent (5) |
| update complete (success) | ✅ bender update complete | default (3) |
| update complete (with failures) | ⚠️ bender update complete (N failures) | high (4) |

### ntfy configuration

| property | value |
|----------|-------|
| **endpoint** | `http://${NTFY_ADDRESS}` (remote — amy's ntfy at 192.168.21.130:8888) |
| **topic** | `${DIUN_NTFY_TOPIC}` (from .env) |
| **fallback** | `http://192.168.21.130:8888` if NTFY_ADDRESS is not set |

> **important:** bender does not run its own ntfy instance. all notifications are sent to amy's ntfy. if amy is down, bender's notifications fail silently. this is an accepted tradeoff — see [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md).

---

## schedule

### cron configuration

```bash
# weekly container update — saturday 04:30 AM
30 4 * * 6 cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh weekly && rm /tmp/secure-container-update.sh >> /mnt/BIG/filme/docker-compose/configs/secure-update/logs/cron.log 2>&1

# daily retry for failed containers — 04:30 AM (every day EXCEPT saturday)
30 4 * * 0-5 cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh retry && rm /tmp/secure-container-update.sh >> /mnt/BIG/filme/docker-compose/configs/secure-update/logs/cron.log 2>&1

# pihole DNS auto-population — every 5 minutes
*/5 * * * * /root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1
```

### why saturday?

- amy updates on **wednesday** — staggering prevents simultaneous update failures across both hosts
- weekend timing means less impact if something breaks — most services are for personal use
- the retry job excludes saturday to avoid conflicting with the weekly scan

### retry logic

when a container update is blocked by vulnerabilities:
1. container is added to the retry queue
2. the daily retry job (sunday through friday) re-scans the image
3. if vulnerabilities are resolved upstream, the update proceeds
4. if still vulnerable, the container stays in the retry queue

---

## scripts reference

### file locations

```
/mnt/BIG/filme/docker-compose/scripts/
├── secure-container-update.sh      # v1.2 — main update orchestrator
├── health-checks.sh                # v1.0 — service health verification
├── rollback.sh                     # v1.0 — manual rollback helper
└── pihole-dns-update.sh            # reference copy (executable at /root/)
```

### state files

```
/mnt/BIG/filme/docker-compose/configs/secure-update/
├── critical-containers.json        # critical service definitions (postgres only)
├── retry-queue.json                # blocked containers waiting for retry
├── logs/                           # daily execution logs
│   ├── 2026-02-08.log
│   ├── cron.log                    # cron output
│   └── ...
└── scan-reports/                   # trivy scan results per container
```

### report files

```
/mnt/BIG/filme/docker-compose/reports/weekly-reports/
└── ...                             # weekly update summary reports
```

### image backup retention

the update script maintains up to **3 backup image tags** per container, allowing rollback to any of the 3 previous versions. older backups are automatically pruned.

```
registry/image:latest      ← currently running
registry/image:backup-1    ← previous version (most recent)
registry/image:backup-2    ← older version
registry/image:backup-3    ← oldest kept version
```

---

## differences from amy

| aspect | bender | amy |
|--------|--------|-----|
| **update day** | saturday | wednesday |
| **trivy host port** | 8083 | 8083 |
| **trivy internal port** | 8080 | 4954 |
| **diun schedule** | daily 06:00 | wednesday 04:00 |
| **critical services** | 1 (postgres) | 4 (postgres, ntfy, beszel, spendspentspent) |
| **script execution** | requires `/tmp` copy (TrueNAS) | direct execution |
| **ntfy endpoint** | `http://${NTFY_ADDRESS}` (remote amy) | `http://localhost:8888` (local) |
| **postgres image** | immich-app/postgres (vectorchord) | postgres:17-alpine |
| **postgres databases** | immich, hedgedoc | atuin, miniflux, sss, mealie, stirling |
| **base path** | `/mnt/BIG/filme/docker-compose` | `/docker-compose` |
| **backup path** | `/mnt/BIG/filme/backups/postgres` | `/docker/backups/postgres` |
| **additional cron** | pihole-dns-update.sh (every 5 min) | none |

---

*previous: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
*next: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
