# bender maintenance procedures

## operational runbook

**document version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

---

## table of contents

1. [overview](#overview)
2. [daily operations](#daily-operations)
3. [weekly operations](#weekly-operations)
4. [monthly operations](#monthly-operations)
5. [common tasks](#common-tasks)
6. [compose change procedure](#compose-change-procedure)
7. [build-based container maintenance](#build-based-container-maintenance)
8. [replication maintenance](#replication-maintenance)
9. [SMART monitoring maintenance](#smart-monitoring-maintenance)
10. [TTS pipeline maintenance](#tts-pipeline-maintenance)
11. [backup procedures](#backup-procedures)
12. [restore procedures](#restore-procedures)
13. [emergency procedures](#emergency-procedures)
14. [service-specific maintenance](#service-specific-maintenance)
15. [TrueNAS maintenance](#truenas-maintenance)

---

## overview

bender runs 39 active services managed by a single docker-compose.yaml (20260721). most maintenance is automated through TrueNAS UI cron jobs and the secure container update system. this document covers both automated and manual procedures.

### automated tasks

| task | schedule | system |
|------|----------|--------|
| critical-data replication to amy | daily 03:30 | bender-replicate.sh |
| DNS auto-population | hourly (hash-guarded) | pihole-dns-update.sh v3.2 |
| container vulnerability scan | saturday 04:30 | secure-container-update.sh weekly |
| retry blocked containers | sun–fri 04:30 | secure-container-update.sh retry |
| SMART short self-tests | monday 05:00 | smart-test.sh short |
| SMART long self-tests | 1st of month 05:00 | smart-test.sh long |
| SMART state-diff report | daily 18:00 | smart-test.sh report |
| pihole config sync to amy | hourly | nebula-sync |
| postgresql backup (5 databases) | daily | postgres-backup container (internal @daily) |
| image update notifications | daily 06:00 | diun |
| VPN health recovery | continuous | autoheal + gluetun healthcheck |

the first seven rows are the seven TrueNAS UI cron jobs; the rest are container-internal schedulers.

---

## daily operations

### verify all containers running

```bash
cd /mnt/BIG/filme/docker-compose

# quick count (expect 39)
docker compose ps --format "{{.Names}}" | wc -l

# show any non-running containers
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"

# check for unhealthy containers
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "unhealthy"
```

### check VPN connectivity

```bash
# verify gluetun is connected and healthy
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null | head -5

# verify gluetun healthcheck passes
docker inspect gluetun --format '{{.State.Health.Status}}'

# check autoheal is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep autoheal
```

### check notifications

review ntfy at `http://ntfy.home.arpa:8888` or `https://ntfy.bunny-enigmatic.ts.net` for: diun update notices, replication success/failure, SMART degradation alerts, update-system events.

---

## weekly operations

### review update reports

```bash
# list recent reports
ls -lt /mnt/BIG/filme/docker-compose/reports/weekly-reports/ | head -5

# read latest report
cat /mnt/BIG/filme/docker-compose/reports/weekly-reports/$(ls -t /mnt/BIG/filme/docker-compose/reports/weekly-reports/ | head -1)
```

### check retry queue

```bash
cat /mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json
```

if containers are stuck for more than a week, investigate:

```bash
bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh scan <container_name>
```

### check disk usage and health

```bash
# ZFS pool status
zpool status BIG

# dataset usage
zfs list -o name,used,avail,refer BIG/filme

# docker image disk usage
docker system df

# SMART status table (manual, human-readable)
bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh status

# large directories
du -sh /mnt/BIG/filme/transmission/completed/*/ 2>/dev/null | sort -rh | head -10
```

---

## monthly operations

### clean up unused docker resources

```bash
cd /mnt/BIG/filme/docker-compose

# remove unused images (keeps backup tags)
docker image prune -f

# check for dangling volumes (CAUTION: verify before removing)
docker volume ls --filter dangling=true

# remove build cache
docker builder prune -f
```

### verify backups

```bash
# check postgres backups exist, are recent, and cover all five databases
ls -lht /mnt/BIG/filme/backups/postgres/ | head -10
ls /mnt/BIG/filme/backups/postgres/ | grep -c forgejo   # should be > 0

# verify backup file sizes are reasonable (not empty)
find /mnt/BIG/filme/backups/postgres/ -name "*.sql*" -mtime -1 -exec ls -lh {} \;
```

### spot-check the amy replica

```bash
ssh kube@10.30.0.11 'ls -la /docker/backups/bender-replica/ && du -sh /docker/backups/bender-replica/*'
```

### review ZFS health

```bash
zpool status BIG
zpool history BIG | grep scrub | tail -5
# scrubs are scheduled by TrueNAS under Data Protection → Scrub Tasks – verify, don't duplicate
```

---

## common tasks

### restart a single service

```bash
cd /mnt/BIG/filme/docker-compose
docker compose restart <service_name>
```

### restart all services

```bash
cd /mnt/BIG/filme/docker-compose
docker compose down && docker compose up -d
# note: this recreates gluetun – transmission and friends come back with it,
# but if anything in the VPN group misbehaves afterwards, recreate the 8 tenants
```

### view logs

```bash
docker logs <container_name> --tail 50
docker logs <container_name> -f
docker logs <container_name> --tail 100 -t
```

### update a single container manually

```bash
cd /mnt/BIG/filme/docker-compose
docker compose pull <service_name>
docker compose up -d <service_name>
```

### apply an env or compose change (recreation is mandatory)

```bash
docker compose up -d --force-recreate <service_name>

# verify the environment actually landed – inspect, not exec:
docker inspect <service_name> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep <VAR>
```

### check container resource usage

```bash
docker stats --no-stream
docker stats --no-stream <container_name>
```

---

## compose change procedure

**the ritual – every compose change follows it, no exceptions:**

1. edit docker-compose.yaml → bump the header version + add a dated changelog entry
2. new secret? add to `.env` (**hex** generation, header version synced to the compose version, changelog entry). new database tenant? create the dedicated user + database first (forgejo pattern – see 02)
3. `docker compose up -d --force-recreate <changed services>` – recreation is MANDATORY for env changes; `up -d` alone does not apply them
4. verify env landed: `docker inspect <c> --format '{{range .Config.Env}}{{println .}}{{end}}'`
5. update docs (this suite), refresh critical-containers.json if dependencies changed, sync the futurama-docker repo (compose + .env.gpg + .env.example + docs), commit – compose bump, docs update, and commit travel together. **count sweep:** if services were added/removed, chase every baked-in count: `grep -rn "39\|expect" docs/` (container total, category tables, tailscale URL count, port tables)
6. new tsdproxy name? run the DNS scraper (or wait for its hour): `bash /mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` – then verify: `dig <name>.home.arpa @10.30.0.2`

---

### rotate the tailscale auth key (both hosts – do this BEFORE the noted expiry)

1. generate a new auth key: https://login.tailscale.com/admin/settings/keys – note the new expiry date
2. bender: edit `/mnt/BIG/filme/docker-compose/.env` → `TSDPROXY_AUTHKEY=<new>` (and remove/update the redundant `TS_AUTHKEY` line per docs/05), update the expiry comment
3. amy: same edit in `/docker-compose/.env`
4. apply (recreation mandatory): on bender `docker compose up -d --force-recreate tsdproxy`; on amy likewise
5. verify one URL per host: `curl -sI https://media.bunny-enigmatic.ts.net | head -1` and `curl -sI https://ntfy.bunny-enigmatic.ts.net | head -1`
6. sync both `.env.gpg` files to the repo (07 → configuration backup)

---

## build-based container maintenance

three containers use `build:` directives and require manual rebuilds instead of `docker compose pull`:

### rebuild transmission

```bash
cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache transmission
docker compose up -d transmission
docker ps --format "{{.Names}}\t{{.Status}}" | grep transmission
```

> **WARNING:** transmission is pinned to 4.0.5 (FileList whitelist). do NOT change the base image version in the Dockerfile.

### rebuild lrrr

```bash
cd /mnt/BIG/filme/docker-compose
# after editing pipeline.sh, webapp.py, start.sh, preprocess.py, or the Dockerfile
docker compose build --no-cache lrrr
docker compose up -d lrrr
curl -s -o /dev/null -w "%{http_code}" http://localhost:5051
```

### rebuild epub2tts-edge

```bash
cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache epub2tts-edge
docker compose run --rm epub2tts-edge   # on-demand tool, not a persistent service
```

### when to rebuild

- base image security updates
- changes to any build-context file
- Flood UI configuration changes (transmission)

---

## replication maintenance

### verify the nightly run

```bash
# most recent replication log
ls -lt /mnt/BIG/filme/docker-compose/configs/secure-update/logs/ | grep -i replicate | head -3

# confirm fresh data on amy
ssh kube@10.30.0.11 'ls -la /docker/backups/bender-replica/'
```

a failed run also pushes an ntfy alert – silence is only good news if the log confirms a run happened.

### manual run

```bash
bash /mnt/BIG/filme/docker-compose/scripts/bender-replicate.sh
```

### what is (and isn't) replicated

| replicated | excluded |
|------------|----------|
| /mnt/BIG/filme/configs/ (service configs incl. vaultwarden, forgejo) | media libraries (filme, seriale, music, books) |
| /mnt/BIG/filme/backups/postgres/ (all five databases' dumps) | download data (transmission, metube, jdownloader, spotdl) |
| /mnt/BIG/filme/docker-compose/ (compose, .env, scripts, state) | regenerable caches (immich ml-cache, trivy cache, jellyfin cache/transcodes) |

retention on amy: 7 days. destination ownership: kube:kube on `/docker/backups/bender-replica`.

### prerequisites (re-verify after SSH key or host changes)

```bash
ssh -o BatchMode=yes kube@10.30.0.11 true && echo "SSH trust OK"
```

### scheduling rule

03:30 daily – never move it into the 04:30 update window, and never let the saturday weekly scan and a replication run coincide on the Gen8.

---

## SMART monitoring maintenance

smart-test.sh v1.1 replaces the TrueNAS SMART UI removed in 25.10 – it talks to smartctl directly and cannot be broken by middleware changes.

### modes and schedules

| mode | schedule | behavior |
|------|----------|----------|
| `short` | `0 5 * * 1` | SHORT self-test on all eligible disks; **skips** disks already testing (never force-aborts) |
| `long` | `0 5 1 * *` | LONG self-test on all eligible disks |
| `report` | `0 18 * * *` | reads health + attributes, diffs against baseline, ntfy **only** on degradation or FAILED health |
| `status` | manual | human-readable table |

```bash
bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh status
```

### watched attributes

5 Reallocated_Sector_Ct, 187 Reported_Uncorrect, 197 Current_Pending_Sector, 198 Offline_Uncorrectable (raw increases alert); 199 UDMA_CRC_Error_Count (warn only – usually cable/backplane). NVMe equivalents via smartctl JSON.

### baselines and disk replacement

baselines live in `configs/secure-update/smart-state/` keyed by **model_serial** – they survive device-letter shuffles. after replacing a disk, do nothing: the next report run creates the new disk's baseline automatically.

### interpretation notes

- "Can't start self-test (N% remaining)" logged by short/long mode = a test is already running; this is a **correct skip**, not a failure. check progress: `smartctl -c /dev/sdX`
- the MicroSD boot device (mmcblk) is skipped automatically
- long tests started at 05:00 have generally finished before the 18:00 report on most disks

### the one forbidden act

never re-create a `midclt call disk.smart_test` cron entry. the 25.04→25.10 auto-converted entries are broken fossils; smart-test.sh is the replacement.

---

## TTS pipeline maintenance

### check pipeline status

```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep lrrr
docker logs lrrr --tail 50
curl -s http://localhost:5050/v1/models | head -5           # edge-tts API
curl -s -o /dev/null -w "%{http_code}" http://localhost:5051  # web UI
```

### submit a file for conversion

via web UI: `http://tts.home.arpa:5051` or `https://tts.bunny-enigmatic.ts.net` – upload a file or paste a URL.

via filesystem – drop a PDF, EPUB, or TXT into the voice directory:

```bash
cp book.epub /mnt/BIG/filme/tts/input/ro-emil/    # Romanian male
cp book.epub /mnt/BIG/filme/tts/input/ro-alina/   # Romanian female
cp book.epub /mnt/BIG/filme/tts/input/en-ryan/    # British male
cp book.epub /mnt/BIG/filme/tts/input/en-sonia/   # British female
```

### check conversion output

```bash
ls -lt /mnt/BIG/filme/audiobookshelf/audiobooks/cărți/ | head -10
```

audiobookshelf picks up new M4B files automatically; ntfy announces success or failure on the `tts-pipeline` topic.

---

## backup procedures

### automated postgres backup

the postgres-backup container runs daily and dumps **all five** databases (immich, hedgedoc, baikal, vikunja, forgejo):

```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep postgres-backup
ls -lht /mnt/BIG/filme/backups/postgres/ | head -10
```

after adding a tenant, verify the container actually carries the new list (env changes need recreation):

```bash
docker inspect postgres-backup --format '{{json .Config.Env}}' | tr ',' '\n' | grep POSTGRES_DB
```

### manual postgres backup

```bash
# full dump (all databases)
docker exec postgres pg_dumpall -U postgres > /mnt/BIG/filme/backups/postgres/manual-$(date +%Y%m%d).sql

# single database
docker exec postgres pg_dump -U postgres immich > /mnt/BIG/filme/backups/postgres/immich-$(date +%Y%m%d).sql
```

### configuration backup (git repo)

the futurama-docker repo (github.com/om1d3/futurama-docker) holds compose + encrypted .env + stripped example + docs:

```bash
# on laptop
cd ~/code/futurama-docker

scp root@10.30.0.12:/mnt/BIG/filme/docker-compose/docker-compose.yaml bender/docker-compose.yaml
scp root@10.30.0.12:/mnt/BIG/filme/docker-compose/.env /tmp/bender.env

# re-encrypt .env
gpg --symmetric --cipher-algo AES256 -o bender/.env.gpg /tmp/bender.env

# regenerate .env.example (strips VALUES only – comments survive, which is why
# secrets must never live in comments; see 05 house rule 3)
sed 's/=.*/=/' /tmp/bender.env > bender/.env.example
shred -u /tmp/bender.env 2>/dev/null || rm -f /tmp/bender.env

git add . && git commit -m "bender 20260721: <description>" && git push
```

the repo should also carry current copies of all six scripts – smart-test.sh and bender-replicate.sh in particular postdate the last sync.

### off-host replica

covered under [replication maintenance](#replication-maintenance) – configs + dumps + the compose tree land on amy nightly.

---

## restore procedures

### restore postgres from backup

```bash
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh list postgres
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh postgres   # handles dependents
```

after any postgres restore, re-verify the immich job concurrency (=1) in Admin UI → Settings → Job Settings – that setting lives in the database.

### restore single container from image backup

```bash
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh list jellyfin
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh rollback jellyfin
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh rollback jellyfin 2
```

### restore from git repository

```bash
# on laptop
cd ~/code/futurama-docker
gpg --decrypt --output /tmp/bender.env bender/.env.gpg
scp bender/docker-compose.yaml root@10.30.0.12:/mnt/BIG/filme/docker-compose/
scp /tmp/bender.env root@10.30.0.12:/mnt/BIG/filme/docker-compose/.env
rm /tmp/bender.env
ssh root@10.30.0.12 'cd /mnt/BIG/filme/docker-compose && docker compose up -d'
```

### restore from the amy replica (disaster recovery)

when the pool or boot device is gone and git is stale or unreachable:

```bash
# from the rebuilt bender, pull everything back
rsync -av kube@10.30.0.11:/docker/backups/bender-replica/docker-compose/ /mnt/BIG/filme/docker-compose/
rsync -av kube@10.30.0.11:/docker/backups/bender-replica/configs/       /mnt/BIG/filme/configs/
rsync -av kube@10.30.0.11:/docker/backups/bender-replica/backups/postgres/ /mnt/BIG/filme/backups/postgres/

# restore databases into a fresh postgres from the newest dumps, then bring the stack up
```

anything recovered that used to live under /root gets relocated onto the pool – /root stays empty.

---

## emergency procedures

### system freeze recovery

the Gen8 can hard-freeze from ZFS I/O saturation or DMAR faults:

1. HP iLO remote console (10.30.0.13) if the network stack still responds
2. otherwise physical power cycle
3. after reboot TrueNAS auto-imports the pool and starts Docker
4. verify all 39 containers: `docker compose ps`
5. `zpool status BIG` for errors
6. if the VPN group misbehaves post-boot, recreate gluetun's tenants (below)

### VPN stuck / all downloads failing

```bash
docker inspect gluetun --format '{{.State.Health.Status}}'
# unhealthy → autoheal restarts it within 60s; if not:
docker restart gluetun
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null
docker logs gluetun --tail 30
```

### VPN tenants orphaned (services "Up" but unreachable after gluetun was recreated)

```bash
cd /mnt/BIG/filme/docker-compose
docker compose up -d --force-recreate transmission prowlarr sonarr radarr lidarr readarr bazarr jdownloader
```

this is the namespace-orphan failure mode – a tenant attached to a destroyed namespace never self-recovers. the update pipeline does this automatically; manual gluetun recreations must do it by hand.

### postgres won't start

```bash
docker logs postgres --tail 50
df -h /mnt/BIG/
bash /mnt/BIG/filme/docker-compose/scripts/rollback.sh postgres
```

### pihole down / no DNS

```bash
docker ps | grep pihole
docker logs pihole --tail 20

# VIP present on the 10G interface?
ip addr show ens1f0 | grep 10.30.0.2

# if VIP missing, check keepalived; amy should hold the VIP within ~5s of a real failure
docker logs keepalived --tail 20

docker restart pihole
dig @10.30.0.2 google.com +short
```

### forgejo admin lockout

```bash
docker exec -u 1000 forgejo forgejo admin user change-password --username <admin> --password '<new>'
```

---

## service-specific maintenance

### immich

```bash
curl -s http://localhost:2283/api/server/ping
docker logs immich_machine_learning --tail 20
# after restores: re-verify job concurrency = 1 (Admin UI → Settings → Job Settings)
# thumbnails/re-index: Administration → Jobs in the web UI
```

### vaultwarden

```bash
curl -s http://localhost:8484/alive
# file-level safety net (postgres does not cover vaultwarden – it uses its own store):
tar czf /mnt/BIG/filme/backups/vaultwarden-$(date +%Y%m%d).tar.gz /mnt/BIG/filme/configs/vaultwarden/
# nightly replication also carries configs/vaultwarden to amy
```

### transmission

```bash
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null   # VPN from the shared namespace
docker exec transmission transmission-remote -l 2>/dev/null | tail -5
docker logs transmission --tail 30 | grep -i flood            # after rebuilds
```

### vikunja

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:3456/api/v1/info
# session sanity: always browse http://tasks.home.arpa:3456 – the PUBLICURL origin (v114)
```

### baikal

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8001
```

### forgejo operations

- **new repo:** create in the UI (uninitialized) THEN push – push-to-create is off
- **clone URLs:** `http://git.home.arpa:3030/<user>/<repo>.git` or `ssh://git@git.home.arpa:2222/<user>/<repo>.git`
- **backup =** daily postgres dump (metadata) + `/mnt/BIG/filme/configs/forgejo` (repo data, replicated nightly)
- **major version upgrade:** read Forgejo release notes, change the image tag deliberately, never through the auto-updater – the rolling :15 tag covers minor/patch only

### autoheal monitoring

```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep autoheal
docker logs autoheal --tail 20
docker inspect gluetun --format '{{index .Config.Labels "autoheal"}}'   # → true
```

---

## TrueNAS maintenance

### cron jobs

verify the seven jobs in the web UI under System → Advanced → Cron Jobs (all as **root**, **Hide Stdout** checked, `bash <path>` form):

| schedule | command |
|----------|---------|
| `30 3 * * *` | `bash /mnt/BIG/filme/docker-compose/scripts/bender-replicate.sh` |
| `0 * * * *` | `bash /mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` |
| `30 4 * * 6` | `bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh weekly` |
| `30 4 * * 0-5` | `bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh retry` |
| `0 5 * * 1` | `bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh short` |
| `0 5 1 * *` | `bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh long` |
| `0 18 * * *` | `bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh report` |

confirm the system timezone is America/Toronto – schedules assume local time. do **not** re-create any `midclt call disk.smart_test` entry (broken 25.04→25.10 auto-conversion) or the old HeavyScript cron; both fossils were deliberately deleted.

### TrueNAS upgrade checklist

**before:**
1. export the config db: System → General → Manage Configuration → Download
2. snapshot the cron state: `midclt call cronjob.query` (or screenshot the UI)
3. verify last night's replication succeeded and postgres backups are current
4. `zfs snapshot BIG/filme@pre-upgrade-$(date +%Y%m%d)`
5. document container versions: `docker compose ps`
6. confirm the Pre Init post-init script is still registered (timeout 900)

**after reboot:**
1. pool imported, Docker running, all 39 containers up: `docker compose ps`
2. all **seven** UI cron jobs present (they should survive – verify anyway)
3. apt works – the idempotent post-init script re-applies developer mode + the **bookworm** repo (25.10.x is bookworm-based, not trixie); if apt fails, run the post-init script manually
4. `/root` is empty-as-expected – nothing persistent belongs there; anything found gets relocated to the pool
5. `bash .../smart-test.sh status` – middleware-free, should be untouched
6. `intel_iommu=off` survived (below)
7. read the release notes for removed features – the 25.10 SMART-UI removal is the precedent

### package upgrades

TrueNAS manages GRUB and its core Python packages – never upgrade those via apt; they arrive with system updates. developer-mode apt is for tooling (rclone, restic, fastfetch via GitHub .deb, ffmpeg), not system components. no scheduled reboots: TrueNAS is built for continuous uptime; reboot only for updates, kernel/ZFS changes, or hardware work.

### GRUB configuration

the MicroSD GRUB config includes `intel_iommu=off` (v107) to prevent HP iLO DMAR faults:

```bash
cat /proc/cmdline | grep -o 'intel_iommu=[a-z]*'
# should show: intel_iommu=off
```

if reset after an upgrade, re-apply via the MicroSD GRUB configuration. the boot MicroSD is a single point of failure – imaging a spare card is backlog 04-A.


---

## script inventory (verified 20260810)

| script | version | purpose |
|--------|---------|---------|
| secure-container-update.sh | 1.3 | update workflow with Trivy gating and health checks |
| health-checks.sh | 1.2 | standalone health checks, also called by the update script |
| rollback.sh | 1.1 | image-level rollback using `:backup-N` tags |
| bender-replicate.sh | 1.1 | nightly rsync of configs and dumps to amy |
| smart-test.sh | 1.1 | SMART testing and alerting, independent of the TrueNAS API |
| pihole-dns-update.sh | 3.2 | scrapes tsdproxy labels on both hosts into Pi-hole |

`rollback.sh` carries a usage note worth remembering. TrueNAS execution
restrictions mean it is run by copying it to `/tmp` first:

```bash
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/ \
  && bash /tmp/rollback.sh list postgres \
  && rm /tmp/rollback.sh
```

`smart-test.sh` exists because TrueNAS 25.10 removed the SMART scheduling
UI, and the auto-converted `midclt call disk.smart_test` cron jobs broke
when the API signature drifted. the script talks to smartctl directly, so
no TrueNAS release can silently break it.

`pihole-dns-update.sh` reaches amy as `kube@10.30.0.11`, not root. that is a
different credential from the one futurama-sync.sh uses.

---

## bender-replicate.sh v1.1 (20260802)

runs at 03:30 daily as a TrueNAS UI cron job. UI-defined jobs survive
TrueNAS updates; `crontab -e` entries do not.

it copies three trees to amy with `--link-dest` hardlink rotation, so seven
daily snapshots cost roughly one full copy plus deltas:

- `configs/`
- `backups/postgres/`
- `docker-compose/`

v1.1 changed three things after a real incident:

**excluded Jellyfin's own backup archives.** `configs/jellyfin/data/data/backups/`
held a single 7.4 GB archive from February. it inflated two snapshots to
about 31 GB each and filled amy's disk.

**moved the free-space check before the mkdir.** aborted runs used to leave
empty dated directories behind, which looked like successful but empty
backups.

**raised the free-space threshold from 5 GB to 10 GB.**

### the silent failure of 2026-07-27 to 07-30

four consecutive nights produced nothing. the script worked correctly: amy
had under 5 GB free, so it aborted and sent a high-priority alert to the
`bender-backup` ntfy topic each time.

nobody was subscribed to that topic.

so the lesson is not about the script. **subscribe to every ntfy topic in
use**, not only the ones you remember.

### measuring the replica

hardlinks make per-directory `du` misleading. the same data is shared
across snapshots, and whichever directory `du` walks first appears to own
all of it. deleting a snapshot that `du` reported as 31 GB recovered about
3 GB.

use `df` before and after to measure a real gain.

---

*previous: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
*next: [08-TROUBLESHOOTING.md](./08-TROUBLESHOOTING.md)*
