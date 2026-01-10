# amy secure container update system

## security-first container updates with vulnerability scanning

**document version:** 1.0  
**infrastructure version:** 85  
**last updated:** january 10, 2026

---

## table of contents

1. [overview](#overview)
2. [components](#components)
3. [update workflow](#update-workflow)
4. [critical container handling](#critical-container-handling)
5. [health checks](#health-checks)
6. [rollback procedures](#rollback-procedures)
7. [notifications](#notifications)
8. [schedule](#schedule)
9. [scripts reference](#scripts-reference)

---

## overview

amy uses a security-first approach to container updates that prevents deployment of images with known vulnerabilities.

### key principles

1. **scan before deploy**: every image is scanned with trivy before deployment
2. **block on vulnerabilities**: critical and high cves block updates
3. **automatic rollback**: failed updates trigger automatic rollback
4. **critical service protection**: special handling for essential services
5. **notification on all events**: ntfy alerts for updates, blocks, and failures

### differences from bender

| aspect | amy | bender |
|--------|-----|--------|
| **update day** | wednesday | saturday |
| **trivy port** | 8083 | 8082 |
| **critical services** | 8 | 1 (postgres only) |
| **script execution** | direct | requires /tmp copy |
| **ntfy endpoint** | http://ntfy:80 (local) | http://${NTFY_ADDRESS} |

---

## components

### diun (docker image update notifier)

monitors all containers for available updates.

```yaml
diun:
  image: crazymax/diun:latest
  environment:
    - DIUN_WATCH_SCHEDULE=0 30 4 * * 3  # wednesday 04:30
    - DIUN_PROVIDERS_DOCKER_WATCHBYDEFAULT=true
    - DIUN_NOTIF_NTFY_ENDPOINT=http://ntfy:80
    - DIUN_NOTIF_NTFY_TOPIC=${DIUN_NTFY_TOPIC}
```

### trivy (vulnerability scanner)

scans container images for known vulnerabilities.

```yaml
trivy:
  image: aquasec/trivy:latest
  command: ["server", "--listen", "0.0.0.0:8080"]
  ports:
    - "8083:8080"
```

### secure-container-update.sh

orchestrates the update process with safety checks.

### health-checks.sh

verifies services are functioning after updates.

### rollback.sh

provides manual rollback capabilities.

---

## update workflow

### standard container update

```
┌─────────────────────────────────────────────────────────────────┐
│                    container update workflow                     │
└─────────────────────────────────────────────────────────────────┘

1. diun detects new image available
   └─► notification sent to ntfy

2. secure-container-update.sh runs (wednesday 04:30)
   ├─► pull new image
   ├─► scan with trivy
   │   ├─► critical/high cve found?
   │   │   ├─► yes: block update, add to retry queue, notify
   │   │   └─► no: continue
   ├─► tag current image as backup
   ├─► deploy new image
   ├─► run health checks
   │   ├─► pass: complete, notify success
   │   └─► fail: rollback, notify failure
   └─► clean old backups (keep 3)
```

### postgresql update (special handling)

```
┌─────────────────────────────────────────────────────────────────┐
│                   postgresql update workflow                     │
└─────────────────────────────────────────────────────────────────┘

1. pull new postgres image
2. scan with trivy
3. if clean:
   ├─► pg_dumpall → backup.sql (all databases)
   ├─► stop postgres container
   ├─► tag current image as :backup-1
   ├─► start with new image
   ├─► run health checks:
   │   ├─► pg_isready
   │   ├─► SELECT 1
   │   └─► test dependent services (atuin, miniflux, sss)
   ├─► if health checks pass: success
   └─► if health checks fail:
       ├─► stop postgres
       ├─► restore :backup-1 image
       ├─► start postgres
       └─► notify failure
```

---

## critical container handling

### critical services list

stored in `/docker-compose/configs/secure-update/critical-containers.json`:

```json
["postgres", "ntfy", "beszel", "pihole", "keepalived", "vaultwarden", "spendspentspent", "diun"]
```

### special handling per service

| service | special handling |
|---------|------------------|
| **postgres** | full database backup before update |
| **ntfy** | verify notification delivery after update |
| **pihole** | verify dns resolution after update |
| **keepalived** | verify vip status after update |
| **vaultwarden** | verify api health after update |
| **beszel** | verify monitoring endpoint after update |
| **spendspentspent** | verify database connection after update |
| **diun** | verify ntfy connectivity after update |

---

## health checks

### available checks

```bash
# run all checks
/docker-compose/scripts/health-checks.sh all

# run specific check
/docker-compose/scripts/health-checks.sh postgres
/docker-compose/scripts/health-checks.sh ntfy
/docker-compose/scripts/health-checks.sh pihole
/docker-compose/scripts/health-checks.sh trivy
/docker-compose/scripts/health-checks.sh diun
/docker-compose/scripts/health-checks.sh vaultwarden
```

### check details

| service | health check method |
|---------|---------------------|
| **postgres** | `pg_isready` + `SELECT 1` + dependent service tests |
| **ntfy** | http health endpoint + test notification |
| **pihole** | dns query test + web interface check |
| **trivy** | http healthz endpoint |
| **diun** | process check + ntfy connectivity |
| **vaultwarden** | http health endpoint |

---

## rollback procedures

### automatic rollback

triggered when health checks fail after an update:

1. stop the failed container
2. restore previous image from `:backup-1` tag
3. start container with restored image
4. verify health
5. notify via ntfy

### manual rollback

```bash
# list available backups for a container
/docker-compose/scripts/rollback.sh list-containers postgres

# rollback to previous version
/docker-compose/scripts/rollback.sh container postgres 1

# rollback postgresql database
/docker-compose/scripts/rollback.sh list-postgres
/docker-compose/scripts/rollback.sh postgres <backup-file>
```

### postgresql database restore

```bash
# list available backups
ls -la /docker/backups/postgres/daily/

# restore specific database
docker exec -i postgres psql -U postgres < /docker/backups/postgres/daily/atuin-20260110.sql

# restore all databases
docker exec -i postgres psql -U postgres < /docker/backups/postgres/manual/full-backup.sql
```

---

## notifications

### ntfy integration

all events are sent to ntfy:

| event | priority | topic |
|-------|----------|-------|
| update available | default (3) | container-updates-amy |
| update blocked (cve) | high (4) | container-updates-amy |
| update success | default (3) | container-updates-amy |
| update failed | urgent (5) | container-updates-amy |
| rollback triggered | high (4) | container-updates-amy |

### notification format

```
title: [amy] container update: <service>
body: <status> - <details>
tags: <appropriate emoji>
priority: <1-5>
```

---

## schedule

### update schedule

| task | schedule | description |
|------|----------|-------------|
| **weekly updates** | wednesday 04:30 | full update cycle |
| **retry queue** | daily 04:30 | retry failed/blocked updates |

### cron configuration

```bash
# view current cron
crontab -l

# expected entries:
30 4 * * 3 /docker-compose/scripts/secure-container-update.sh weekly >> /docker-compose/configs/secure-update/logs/cron.log 2>&1
30 4 * * * /docker-compose/scripts/secure-container-update.sh retry >> /docker-compose/configs/secure-update/logs/cron.log 2>&1
```

### why wednesday?

- **staggered from bender**: bender updates on saturday
- **mid-week timing**: allows weekday troubleshooting if issues arise
- **prevents simultaneous failures**: both hosts never update the same day

### retry logic

failed updates (blocked by vulnerabilities) are added to a retry queue. the daily retry job:
1. checks if vulnerabilities have been fixed
2. re-scans with trivy
3. updates if now clean
4. keeps in queue if still vulnerable

---

## scripts reference

### secure-container-update.sh

```bash
# run weekly update
/docker-compose/scripts/secure-container-update.sh weekly

# process retry queue
/docker-compose/scripts/secure-container-update.sh retry

# show status
/docker-compose/scripts/secure-container-update.sh status

# scan specific container
/docker-compose/scripts/secure-container-update.sh scan postgres

# update specific container
/docker-compose/scripts/secure-container-update.sh update ntfy
```

### health-checks.sh

```bash
# all health checks
/docker-compose/scripts/health-checks.sh all

# specific service
/docker-compose/scripts/health-checks.sh postgres
/docker-compose/scripts/health-checks.sh ntfy
/docker-compose/scripts/health-checks.sh pihole
```

### rollback.sh

```bash
# list container backups
/docker-compose/scripts/rollback.sh list-containers [container]

# rollback container
/docker-compose/scripts/rollback.sh container [container] [n]

# list postgresql backups
/docker-compose/scripts/rollback.sh list-postgres

# restore postgresql
/docker-compose/scripts/rollback.sh postgres [backup-file]
/docker-compose/scripts/rollback.sh database [db-name] [backup-file]
```

---

## comparison with bender

| aspect | amy | bender |
|--------|-----|--------|
| **update day** | wednesday | saturday |
| **trivy port** | 8083 | 8082 |
| **critical services** | 8 | 1 (postgres) |
| **script execution** | direct | requires /tmp copy |
| **ntfy endpoint** | http://ntfy:80 | http://${NTFY_ADDRESS} |
| **postgresql dbs** | atuin, miniflux, sss | immich, hedgedoc |

---

*previous: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*  
*next: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
