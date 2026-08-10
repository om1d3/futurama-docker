# amy secure container update system

## security-first container lifecycle management

**document version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

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
11. [known audit items](#known-audit-items)
12. [differences from bender](#differences-from-bender)

---

## overview

amy uses the same secure container update system as bender: pull → trivy scan (block on CRITICAL/HIGH) → deploy → health check → rollback on failure, with a daily retry queue for blocked containers. amy runs script **v1.2**; bender has since moved to v1.3 (five-tenant tests, gluetun-critical) – amy has no gluetun and fewer tenants, so v1.2 remains adequate, but the version skew is a tracked item.

execution is refreshingly plain compared to bender: scripts run directly, schedules live in root's crontab, and Debian does not destroy crontabs on upgrade.

---

## components

| component | version | purpose |
|-----------|---------|---------|
| secure-container-update.sh | v1.2 | main update orchestration script |
| health-checks.sh | v1.0 | standalone health check suite |
| rollback.sh | v1.0 | manual rollback helper |
| diun | latest | new-tag notifications (wednesday 04:00, via local ntfy) |
| trivy | latest | CVE scanning server (`--listen 4954`, host port 8083) |
| critical-containers.json | – | defines the four critical services |
| retry-queue.json | – | containers blocked by vulnerabilities |

---

## update workflow

identical shape to bender's v1.2 pipeline:

```
health gate (load/iowait) → per container: pull → trivy scan
  → blocked ⇒ retry queue
  → critical pre-upgrade actions
  → stop → rotate backup-1/2/3 tags → force-recreate → wait 30s
  → health + functional + integration checks → fail ⇒ rollback to backup-1
  → critical: restart dependents → re-run integration tests
  → 60s throttle between containers → report + ntfy
```

### containers skipped

| container | reason |
|-----------|--------|
| diun | infrastructure – updates itself |
| trivy | infrastructure – scanner should not scan itself |

amy has no build-based containers – everything else is eligible.

---

## critical services

four services are classified as critical on amy:

### postgres

| aspect | detail |
|--------|--------|
| pre-upgrade | full `pg_dumpall` to the backup path |
| health checks | pg_isready, connect, database presence (atuin, miniflux, sss, mealie, stirling) |
| dependent services | postgres-backup, atuin, miniflux, mealie, spendspentspent (a `stirling` DB also exists – app linkage unverified, see 02) |
| rollback | backup-1 image → restart postgres → restart dependents |

### ntfy

| aspect | detail |
|--------|--------|
| why critical | it is the notification hub for BOTH hosts – a broken ntfy means silent infrastructure |
| checks | container running/healthy, HTTP reachability on :8888 |
| note | ntfy's update is the one update you double-check by hand: send a test message after |

### beszel

| aspect | detail |
|--------|--------|
| why critical | monitoring hub – both hosts' agents report here |
| checks | container running, HTTP :8090 |

### spendspentspent

| aspect | detail |
|--------|--------|
| why critical | finance data; depends on postgres (sss) + playwright-chrome |
| checks | container running, HTTP :9021, database access |

<!-- VERIFY: the per-service test lists above reflect the documented v1.2 critical set; diff against amy's live critical-containers.json at next touch -->

---

## health checks

```bash
# from /docker-compose/scripts – direct execution, no bash prefix needed
./health-checks.sh postgres
./health-checks.sh container ntfy
./health-checks.sh all
```

amy's health-checks.sh is v1.0 – it predates bender's v1.2 refinements. the postgres suite covers readiness/connect/database-presence; the per-tenant depth bender gained (quoted-"user" immich probe etc.) has no amy equivalent yet beyond database presence.

---

## rollback system

same 3-tag rotation as bender:

```
image:latest / image:backup-1 / image:backup-2 / image:backup-3
```

```bash
./rollback.sh list ntfy
./rollback.sh rollback ntfy
./rollback.sh rollback ntfy 2
./rollback.sh postgres      # dependent-aware postgres rollback
```

---

## throttling system

same constants as bender's v1.2 (the script is shared lineage):

| setting | value |
|---------|-------|
| THROTTLE_DELAY | 60s |
| MAX_LOAD | 4.0 |
| MAX_IOWAIT | 50% |
| RECOVERY_WAIT | 120s |
| MAX_RECOVERY_ATTEMPTS | 5 |

the i3-2310M hits the load gate more easily than bender's Xeon – a scan skipping containers on amy usually means playwright-chrome or stirling was busy, not that anything is wrong.

---

## notification flow

notifications go to the **local** ntfy – no cross-host dependency for amy's own updates:

| producer | endpoint |
|----------|----------|
| secure-container-update.sh | local ntfy (localhost:8888) |
| diun | `http://ntfy:80` (container network) |

event/priority table matches bender's (scan start/complete low/default; rollback high; rollback-failed urgent).

---

## cron schedule

| schedule | command | purpose |
|----------|---------|---------|
| wednesday 04:30 | `secure-container-update.sh weekly` | full scan (offset from bender's saturday) |
| all other days 04:30 | `secure-container-update.sh retry` | retry blocked containers |

```bash
crontab -l | grep secure-container
```

<!-- VERIFY: paste the literal crontab -l output here at next revision – schedule shape is documented, exact lines unconfirmed -->

the wednesday/saturday split means the two hosts never scan simultaneously, and one host is always fully stable while the other updates. amy also hosts bender's 03:30 replication window – amy's own 04:30 wednesday scan follows it by an hour, same discipline as bender's.

---

## configuration files

| file | purpose |
|------|---------|
| critical-containers.json | the four critical definitions |
| retry-queue.json | blocked-container queue |
| logs/ | per-day logs, 180-day retention |
| scan-reports/ | trivy JSON by date, 180-day retention |

<!-- VERIFY: exact state-directory path on amy -->

---

## known audit items

- **script version skew:** amy v1.2 / bender v1.3. nothing in v1.3 is amy-critical (gluetun, five-tenant probes), but the shared lineage should reconverge – port the versioned-backup convention and per-tenant probes when next touching amy's script.
- **health-checks.sh v1.0:** two versions behind bender's v1.2; upgrade opportunistically.
- **postgres-backup image tag:** amy pins `:17` (major-matched) – this is *better* practice than bender's `:latest`; propagate amy's convention to bender rather than the reverse. **(done: bender 20260721 pins `:14`.)**

---

## differences from bender

| aspect | amy | bender |
|--------|-----|--------|
| update day | wednesday | saturday |
| script version | v1.2 | v1.3 (postgres + gluetun critical) |
| trivy port mapping | 8083:4954 (listen 4954) | 8083:8080 (listen 8080) |
| trivy script URL | http://localhost:8083 (consistent) | historic 8082 constant (audit item) |
| diun schedule | wednesday 04:00 | daily 06:00 |
| critical services | 4 (postgres, ntfy, beszel, spendspentspent) | 2 (postgres, gluetun) |
| script execution | direct | `bash <path>` (noexec pool) |
| cron mechanism | root crontab (survives Debian upgrades) | TrueNAS UI jobs (7) |
| ntfy endpoint | local | remote (amy) |
| postgres image | postgres:17-alpine | immich-app/postgres:14 (vectorchord) |
| postgres databases | atuin, miniflux, sss, mealie, stirling | immich, hedgedoc, baikal, vikunja, forgejo |
| base path | `/docker-compose` | `/mnt/BIG/filme/docker-compose` |
| backup path | `/docker/postgres-backup` | `/mnt/BIG/filme/backups/postgres` |
| build-based containers | 0 | 3 |
| extra duties | hosts bender's replica; runs oxidized | replicates to amy; SMART self-testing |


---

## image pinning policy (20260810)

three services are pinned. each pin exists because an unpinned `:latest`
broke production, and each break was silent for weeks.

| service | pin | reason |
|---------|-----|--------|
| tsdproxy | digest `sha256:e75357d5...` | `:latest` resolves to 3.0.0-beta.1 |
| oxidized | tag `0.36.0` | 0.37.0 passes `max_window_size`; net-ssh 7.3.0 rejects it |
| keepalived | digest `sha256:19026918...` | pins the running 2.3.4; the 2.0.20 tag reads a different config path |

**prefer a digest over a tag.** a digest names the exact image. a tag can
move, and both the tsdproxy and oxidized faults were caused by a tag
moving underneath a working deployment.

**pin what runs, not what you assume runs.** the 20260810 keepalived
failure came from pinning to a version that was believed to be identical
to `:latest` and was not. get the digest from the running container:

```bash
docker inspect <image>:latest --format '{{index .RepoDigests 0}}'
```

### diun blind spot

diun watches tags. a digest-pinned service produces no update
notifications at all. so a pinned image will not be reported when a new
version appears, and the version must be reviewed deliberately.

---

## the prune incident (2026-08-08)

`docker image prune -a` recovered 16.94 GB from 108 images and took the
root filesystem from 97% to 60%. it also deleted every `:backup-N` tag.

those tags are the update system's rollback stock. so image-level rollback
was unavailable until the next update cycle re-tagged them. a specific
image can still be re-pulled from its registry by digest.

**any scheduled prune must exclude the `backup-N` pattern**, or it will
delete its own safety net on a timer. `docker image prune -f` without `-a`
is safe, because it removes only untagged layers.

---

## log rotation is not configured

a tsdproxy error loop produced a 211 MB json log on 2026-08-08. docker
applies no size limit by default.

the fix is host-wide rather than per service:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

placed in `/etc/docker/daemon.json`. it needs a docker restart, which
bounces every container on amy including pihole. so do it in a planned
window. existing containers adopt the limit at their next recreate.

---

*previous: [03-DIRECTORY-STRUCTURE.md](./03-DIRECTORY-STRUCTURE.md)*
*next: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
