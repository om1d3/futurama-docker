# bender secure container update system

## security-first container updates

**document version:** 1.0  
**infrastructure version:** 86  
**last updated:** january 10, 2026

---

## table of contents

1. [overview](#overview)
2. [update philosophy](#update-philosophy)
3. [system components](#system-components)
4. [update workflow](#update-workflow)
5. [postgresql special handling](#postgresql-special-handling)
6. [health checks](#health-checks)
7. [rollback procedures](#rollback-procedures)
8. [scheduling](#scheduling)
9. [troubleshooting](#troubleshooting)

---

## overview

the secure container update system provides automated, security-first container updates with vulnerability scanning and automatic rollback capabilities.

### key features

| feature | implementation |
|---------|----------------|
| **vulnerability scanning** | trivy server integration |
| **notification** | ntfy via amy |
| **automatic rollback** | on health check failure |
| **postgresql protection** | special handling with backup |
| **retry queue** | failed updates reattempted |
| **logging** | daily logs with full audit trail |

---

## update philosophy

### why security-first

| traditional approach | security-first approach |
|---------------------|------------------------|
| update immediately | scan before deployment |
| hope it works | verify with health checks |
| manual rollback | automatic rollback |
| unknown vulnerabilities | cve threshold enforcement |

### vulnerability thresholds

| severity | action |
|----------|--------|
| **critical** | block update, notify, add to retry queue |
| **high** | block update, notify, add to retry queue |
| **medium** | allow update, warn in notification |
| **low** | allow update, log only |

---

## system components

### diun (docker image update notifier)

| property | value |
|----------|-------|
| **image** | crazymax/diun:latest |
| **schedule** | saturdays at 04:30 |
| **notification** | ntfy (http://192.168.21.130:8080/diun-bender) |

**purpose:** detects available updates for all monitored containers and sends notifications.

### trivy (vulnerability scanner)

| property | value |
|----------|-------|
| **image** | aquasec/trivy:latest |
| **mode** | server |
| **port** | 8082:8080 |
| **database** | auto-updated vulnerability db |

**purpose:** scans container images for known vulnerabilities before deployment.

### secure-container-update.sh

| property | value |
|----------|-------|
| **version** | 1.2 |
| **location** | /mnt/BIG/filme/docker-compose/scripts/ |
| **execution** | manual or via cron |

**purpose:** orchestrates the entire update process with scanning, deployment, and rollback.

---

## update workflow

### standard container update

```
┌──────────────────┐
│  diun detects    │
│  new image       │
├──────────────────┤
│  sends ntfy      │
│  notification    │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  admin runs      │
│  update script   │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  pull new image  │
├──────────────────┤
│  docker pull     │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  trivy scan      │
├──────────────────┤
│  check for       │
│  critical/high   │
└────────┬─────────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌────────┐ ┌────────────┐
│ pass   │ │ fail       │
│        │ │            │
│ deploy │ │ add to     │
│ new    │ │ retry      │
│ image  │ │ queue      │
└───┬────┘ └────────────┘
    │
    ▼
┌──────────────────┐
│  health check    │
├──────────────────┤
│  verify service  │
│  is working      │
└────────┬─────────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌────────┐ ┌────────────┐
│ pass   │ │ fail       │
│        │ │            │
│ done   │ │ rollback   │
│        │ │ to old     │
│        │ │ image      │
└────────┘ └────────────┘
```

### update script phases

| phase | actions |
|-------|---------|
| **1. discovery** | identify containers with available updates |
| **2. backup** | snapshot current image (postgresql: full backup) |
| **3. pull** | download new image |
| **4. scan** | trivy vulnerability assessment |
| **5. deploy** | stop old, start new container |
| **6. verify** | health checks |
| **7. cleanup** | remove old image (or rollback) |

---

## postgresql special handling

### why postgresql is different

| reason | implication |
|--------|-------------|
| **data persistence** | corrupt upgrade = data loss |
| **dependent services** | immich, hedgedoc depend on it |
| **schema migrations** | version changes may require migration |
| **vectorchord extension** | specialized immich extension |

### postgresql update workflow

```
phase 1: preparation
├── 1. notify: "starting postgresql update"
├── 2. stop dependent services (immich, hedgedoc)
├── 3. stop postgres-backup
└── 4. verify postgresql is idle

phase 2: backup
├── 5. pg_dumpall → backup.sql
├── 6. backup data directory
└── 7. tag current image as backup

phase 3: update
├── 8. pull new postgresql image
├── 9. trivy scan new image
├── 10. (if fail) abort and notify
└── 11. stop old postgresql

phase 4: deployment
├── 12. start new postgresql
├── 13. wait for ready (pg_isready)
└── 14. verify databases exist

phase 5: verification
├── 15. run health checks
│   ├── immich connection test
│   ├── hedgedoc connection test
│   └── query execution test
├── 16. start dependent services
├── 17. verify dependent services healthy
└── 18. notify: "postgresql update complete"

phase 5-fail: recovery (if any check fails)
├── 19. stop new postgresql
├── 20. restore backup image tag
├── 21. start old postgresql
├── 22. start dependent services
└── 23. notify: "postgresql update failed, rolled back"
```

### postgresql backup commands

```bash
# manual backup before update
docker exec postgres pg_dumpall -U postgres > /mnt/BIG/filme/docker-compose/backups/postgres/manual-$(date +%Y%m%d).sql

# verify backup
ls -la /mnt/BIG/filme/docker-compose/backups/postgres/
head -50 /mnt/BIG/filme/docker-compose/backups/postgres/manual-*.sql
```

---

## health checks

### health-checks.sh

| property | value |
|----------|-------|
| **version** | 1.0 |
| **location** | /mnt/BIG/filme/docker-compose/scripts/ |

### checks performed

| container | health check |
|-----------|--------------|
| **postgres** | `pg_isready -U postgres` |
| **immich** | http request to api endpoint |
| **hedgedoc** | http request to status endpoint |
| **pihole** | dns query test |
| **jellyfin** | http request to web interface |
| **transmission** | rpc interface test |

### running health checks

```bash
# TrueNAS restriction: copy script to /tmp first
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/
chmod +x /tmp/health-checks.sh

# check all services
/tmp/health-checks.sh all

# check specific service
/tmp/health-checks.sh postgres
/tmp/health-checks.sh immich

# cleanup
rm /tmp/health-checks.sh
```

---

## rollback procedures

### rollback.sh

| property | value |
|----------|-------|
| **version** | 1.0 |
| **location** | /mnt/BIG/filme/docker-compose/scripts/ |

### standard container rollback

```bash
# list available backup images
/tmp/rollback.sh list

# rollback specific container
/tmp/rollback.sh container jellyfin

# rollback with specific image
/tmp/rollback.sh container sonarr lscr.io/linuxserver/sonarr:3.0.10
```

### postgresql rollback

```bash
# full postgresql rollback (uses backup image + data)
/tmp/rollback.sh postgres /mnt/BIG/filme/docker-compose/backups/postgres/manual-20260110.sql

# emergency: restore from data directory backup
docker compose stop immich_server immich_machine_learning hedgedoc postgres-backup
docker compose stop postgres

# restore data directory
rsync -av /mnt/BIG/filme/docker-compose/backups/postgres/data/ /mnt/BIG/filme/immich/postgresql/data/

# restart
docker compose up -d postgres
sleep 30
docker compose up -d immich_server immich_machine_learning hedgedoc postgres-backup
```

---

## scheduling

### update schedule

| day | time | activity |
|-----|------|----------|
| **saturday** | 04:30 | diun checks for updates |
| **saturday** | morning | review notifications |
| **saturday** | afternoon | run manual updates |

### why saturday

| reason | benefit |
|--------|---------|
| **low usage** | minimal disruption |
| **weekend buffer** | time to fix issues |
| **weekly cadence** | predictable maintenance |

### cron configuration (optional)

```bash
# optional: automated updates (not recommended for production)
# 30 4 * * 6 /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh --auto
```

---

## troubleshooting

### container in retry queue

**symptom:** container keeps failing to update

**check:**
```bash
cat /mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json
```

**resolution:**
1. check trivy scan report for specific cves
2. wait for upstream fix, or
3. override threshold (not recommended), or
4. remove from retry queue if acceptable risk

### trivy server not responding

**symptom:** scans fail with connection error

**check:**
```bash
docker ps | grep trivy
curl http://localhost:8082/health
```

**resolution:**
```bash
docker compose up -d trivy
docker logs trivy
```

### health check failures

**symptom:** container deployed but rolled back

**check:**
```bash
cat /mnt/BIG/filme/docker-compose/configs/secure-update/logs/$(date +%Y-%m-%d).log
```

**resolution:**
1. review specific check that failed
2. run manual health check
3. check container logs: `docker logs <container>`

### postgresql rollback failed

**symptom:** postgresql stuck after failed upgrade

**resolution:**
```bash
# manual recovery
cd /mnt/BIG/filme/docker-compose
docker compose stop immich_server immich_machine_learning hedgedoc postgres-backup
docker compose stop postgres

# restore backup image
docker images | grep postgres
docker tag <backup-image-id> ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0

# start postgres
docker compose up -d postgres
sleep 30
docker exec postgres pg_isready -U postgres

# start dependent services
docker compose up -d immich_server immich_machine_learning hedgedoc postgres-backup
```

---

## comparison with amy

| aspect | bender | amy |
|--------|--------|-----|
| **update day** | saturday | wednesday |
| **trivy port** | 8082 | 8082 |
| **critical services** | 1 (postgres) | 8 (postgres, ntfy, beszel, etc.) |
| **script execution** | requires /tmp copy | direct |
| **ntfy endpoint** | http://192.168.21.130:8080 | http://ntfy:80 |
| **postgresql dbs** | immich, hedgedoc | atuin, miniflux, sss |

---

*previous: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*  
*next: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
