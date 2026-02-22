# bender maintenance procedures

## operational runbook

**document version:** 3.0
**infrastructure version:** 109
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [daily operations](#daily-operations)
3. [weekly operations](#weekly-operations)
4. [monthly operations](#monthly-operations)
5. [common tasks](#common-tasks)
6. [build-based container maintenance](#build-based-container-maintenance)
7. [TTS pipeline maintenance](#tts-pipeline-maintenance)
8. [backup procedures](#backup-procedures)
9. [restore procedures](#restore-procedures)
10. [emergency procedures](#emergency-procedures)
11. [service-specific maintenance](#service-specific-maintenance)
12. [TrueNAS maintenance](#truenas-maintenance)

---

## overview

bender runs 36 active services managed by a single docker-compose.yaml (v109). most maintenance is automated through cron jobs and the secure container update system. this document covers both automated and manual procedures.

### automated tasks

| task | schedule | system |
|------|----------|--------|
| container vulnerability scan | saturday 04:30 | secure-container-update.sh weekly |
| retry blocked containers | sun–fri 04:30 | secure-container-update.sh retry |
| DNS auto-population | every 5 min | pihole-dns-update.sh |
| pihole config sync | hourly | nebula-sync |
| postgresql backup | daily | postgres-backup container |
| image update notifications | daily 06:00 | diun |
| VPN health recovery | continuous | autoheal + gluetun healthcheck |

---

## daily operations

### verify all containers running

```bash
cd /mnt/BIG/filme/docker-compose

# quick count (expect 36)
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

### check update notifications

review ntfy for container update notifications from diun at `http://ntfy.home.arpa:8888` or `https://ntfy.bunny-enigmatic.ts.net`.

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

if containers are stuck in the retry queue for more than a week, investigate manually:

```bash
# check why a container is blocked
cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/
bash /tmp/secure-container-update.sh scan <container_name>
rm /tmp/secure-container-update.sh
```

### check disk usage

```bash
# ZFS pool status
zpool status BIG

# dataset usage
zfs list -o name,used,avail,refer BIG/filme

# docker image disk usage
docker system df

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

# remove unused volumes (CAUTION: verify no data loss)
docker volume ls --filter dangling=true

# remove build cache
docker builder prune -f
```

### verify backups

```bash
# check postgres backup exists and is recent
ls -lht /mnt/BIG/filme/backups/postgres/ | head -10

# verify backup file sizes are reasonable (not empty)
find /mnt/BIG/filme/backups/postgres/ -name "*.sql*" -mtime -1 -exec ls -lh {} \;

# check backup retention
find /mnt/BIG/filme/backups/postgres/ -name "*.sql*" | wc -l
```

### review ZFS health

```bash
# pool status (look for DEGRADED or FAULTED)
zpool status BIG

# scrub history
zpool history BIG | grep scrub | tail -5

# start manual scrub if needed
zpool scrub BIG
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
```

### view logs

```bash
# recent logs
docker logs <container_name> --tail 50

# follow logs
docker logs <container_name> -f

# logs with timestamps
docker logs <container_name> --tail 100 -t
```

### update a single container manually

```bash
cd /mnt/BIG/filme/docker-compose

# pull new image
docker compose pull <service_name>

# recreate with new image
docker compose up -d <service_name>
```

### force recreate without pulling

```bash
docker compose up -d --force-recreate <service_name>
```

### check container resource usage

```bash
# live resource monitor
docker stats --no-stream

# specific container
docker stats --no-stream <container_name>
```

---

## build-based container maintenance

three containers use `build:` directives and require manual rebuilds instead of `docker compose pull`:

### rebuild transmission

```bash
cd /mnt/BIG/filme/docker-compose

# rebuild image (after editing Dockerfile or to update base image)
docker compose build --no-cache transmission

# deploy rebuilt image
docker compose up -d transmission

# verify
docker ps --format "{{.Names}}\t{{.Status}}" | grep transmission
```

> **WARNING:** transmission is pinned to 4.0.5 (FileList whitelist). do NOT change the base image version in the Dockerfile.

### rebuild tts-pipeline

```bash
cd /mnt/BIG/filme/docker-compose

# rebuild (after editing pipeline.sh, webapp.py, start.sh, or Dockerfile)
docker compose build --no-cache tts-pipeline

# deploy
docker compose up -d tts-pipeline

# verify web UI
curl -s -o /dev/null -w "%{http_code}" http://localhost:5051
```

### rebuild epub2tts-edge

```bash
cd /mnt/BIG/filme/docker-compose

# rebuild (on-demand tool, profiles: tools)
docker compose build --no-cache epub2tts-edge

# run manually (not a persistent service)
docker compose run --rm epub2tts-edge
```

### when to rebuild

- base image security updates (check with `docker compose pull` for non-build services to gauge timing)
- changes to Dockerfile, pipeline.sh, webapp.py, start.sh, or any build context files
- after modifying Flood UI configuration in the transmission build context

---

## TTS pipeline maintenance

### check pipeline status

```bash
# verify tts-pipeline is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep tts-pipeline

# check logs for conversion activity
docker logs tts-pipeline --tail 50

# verify edge-tts API is responding
curl -s http://localhost:5050/v1/models | head -5

# verify web UI is accessible
curl -s -o /dev/null -w "%{http_code}" http://localhost:5051
```

### submit a file for conversion

via web UI: browse to `http://tts.home.arpa:5051` or `https://tts.bunny-enigmatic.ts.net` and upload a file or paste a URL.

via filesystem: drop a PDF, EPUB, or TXT file into the appropriate voice directory:

```bash
# romanian male voice
cp book.epub /mnt/BIG/filme/tts/input/ro-emil/

# romanian female voice
cp book.epub /mnt/BIG/filme/tts/input/ro-alina/

# british male voice
cp book.epub /mnt/BIG/filme/tts/input/en-ryan/

# british female voice
cp book.epub /mnt/BIG/filme/tts/input/en-sonia/
```

### check conversion output

```bash
# list recent audiobooks generated by TTS
ls -lt /mnt/BIG/filme/audiobookshelf/audiobooks/cărți/ | head -10
```

audiobookshelf automatically picks up new M4B files from this directory.

---

## backup procedures

### automated postgres backup

the postgres-backup container runs daily and backs up `immich` and `hedgedoc` databases:

```bash
# verify backup container is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep postgres-backup

# check latest backups
ls -lht /mnt/BIG/filme/backups/postgres/ | head -10
```

### manual postgres backup

```bash
# full dump (all databases)
docker exec postgres pg_dumpall -U postgres > /mnt/BIG/filme/backups/postgres/manual-$(date +%Y%m%d).sql

# single database
docker exec postgres pg_dump -U postgres immich > /mnt/BIG/filme/backups/postgres/immich-$(date +%Y%m%d).sql
```

### configuration backup

the git repository at `~/code/futurama-docker` (pushed to `github.com/om1d3/futurama-docker`) contains all configuration. to update:

```bash
# on laptop
cd ~/code/futurama-docker

# pull latest configs from production
scp root@192.168.21.121:/mnt/BIG/filme/docker-compose/docker-compose.yaml bender/docker-compose.yaml
scp root@192.168.21.121:/mnt/BIG/filme/docker-compose/.env /tmp/bender.env

# re-encrypt .env
gpg --symmetric --cipher-algo AES256 -o bender/.env.gpg /tmp/bender.env
rm /tmp/bender.env

# update .env.example (strip secrets)
sed 's/=.*/=/' /tmp/bender.env > bender/.env.example

# commit and push
git add .
git commit -m "bender v109: <description>"
git push
```

---

## restore procedures

### restore postgres from backup

```bash
# copy rollback script to /tmp
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/

# list available backups
bash /tmp/rollback.sh list postgres

# rollback postgres (handles dependent services)
bash /tmp/rollback.sh postgres

rm /tmp/rollback.sh
```

### restore single container from image backup

```bash
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/

# list backups
bash /tmp/rollback.sh list jellyfin

# rollback to most recent backup
bash /tmp/rollback.sh rollback jellyfin

# rollback to second backup
bash /tmp/rollback.sh rollback jellyfin 2

rm /tmp/rollback.sh
```

### restore from git repository

```bash
# on laptop
cd ~/code/futurama-docker

# decrypt .env
gpg --decrypt --output /tmp/bender.env bender/.env.gpg

# deploy to bender
scp bender/docker-compose.yaml root@192.168.21.121:/mnt/BIG/filme/docker-compose/
scp /tmp/bender.env root@192.168.21.121:/mnt/BIG/filme/docker-compose/.env
rm /tmp/bender.env

# restart services on bender
ssh root@192.168.21.121 'cd /mnt/BIG/filme/docker-compose && docker compose up -d'
```

---

## emergency procedures

### system freeze recovery

the HP MicroServer Gen8 can experience hard freezes from ZFS I/O saturation (especially with many concurrent torrents) or DMAR faults:

1. access HP iLO remote console (if network stack is still responsive)
2. if iLO is unresponsive, physical power cycle via the power button
3. after reboot, TrueNAS will auto-import the ZFS pool and start Docker
4. verify all containers started: `docker compose ps`
5. check for ZFS errors: `zpool status BIG`

### VPN stuck / all downloads failing

```bash
# check gluetun health
docker inspect gluetun --format '{{.State.Health.Status}}'

# if unhealthy, autoheal should restart it within 60s
# if autoheal is not working:
docker restart gluetun

# verify VPN is connected
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null

# if VPN won't connect, check credentials
docker logs gluetun --tail 30
```

### postgres won't start

```bash
# check logs
docker logs postgres --tail 50

# check disk space
df -h /mnt/BIG/

# if data corruption suspected, restore from backup
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/
bash /tmp/rollback.sh postgres
rm /tmp/rollback.sh
```

### pihole down / no DNS

```bash
# check pihole container
docker ps | grep pihole
docker logs pihole --tail 20

# verify keepalived VIP
ip addr show bond0 | grep 192.168.21.100

# if VIP is missing, check keepalived
docker logs keepalived --tail 20

# emergency: restart pihole
docker restart pihole

# verify DNS works
dig @192.168.21.100 google.com +short
```

---

## service-specific maintenance

### immich

```bash
# check immich API
curl -s http://localhost:2283/api/server/ping

# check ML service
docker logs immich_machine_learning --tail 20

# force re-index (if photos not appearing)
# use the immich web UI: Administration → Jobs → Generate thumbnails
```

### vaultwarden

```bash
# check health endpoint
curl -s http://localhost:8484/alive

# backup vaultwarden data (in addition to postgres)
tar czf /mnt/BIG/filme/backups/vaultwarden-$(date +%Y%m%d).tar.gz /mnt/BIG/filme/configs/vaultwarden/
```

### transmission

```bash
# check VPN connectivity from transmission
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null

# check active torrents
docker exec transmission transmission-remote -l 2>/dev/null | tail -5

# if Flood UI not loading after rebuild
docker logs transmission --tail 30 | grep -i flood
```

### autoheal monitoring

```bash
# check autoheal is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep autoheal

# check autoheal logs for recent restarts
docker logs autoheal --tail 20

# verify gluetun has the autoheal label
docker inspect gluetun --format '{{index .Config.Labels "autoheal"}}'
```

---

## TrueNAS maintenance

### cron jobs

verify cron jobs are configured correctly in the TrueNAS web UI under System → Advanced → Cron Jobs:

| schedule | command |
|----------|---------|
| `30 4 * * 6` | `cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh weekly && rm /tmp/secure-container-update.sh` |
| `30 4 * * 0-5` | `cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh retry && rm /tmp/secure-container-update.sh` |
| `*/5 * * * *` | `/root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1` |

### TrueNAS upgrades

before upgrading TrueNAS:

1. verify all postgres backups are current
2. take a ZFS snapshot: `zfs snapshot BIG/filme@pre-upgrade-$(date +%Y%m%d)`
3. document current container versions: `docker compose ps`
4. perform the upgrade
5. after reboot, verify: ZFS pool imported, Docker running, all containers up
6. re-verify cron jobs (TrueNAS upgrades sometimes reset cron)

### GRUB configuration

the GRUB config includes `intel_iommu=off` (set in v107) to prevent HP iLO DMAR faults:

```bash
# verify current setting
cat /proc/cmdline | grep -o 'intel_iommu=[a-z]*'
# should show: intel_iommu=off
```

if this gets reset after a TrueNAS upgrade, re-apply via TrueNAS UI under System → Advanced → Init/Shutdown Scripts or via the MicroSD GRUB configuration.

---

*previous: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
*next: [08-TROUBLESHOOTING.md](./08-TROUBLESHOOTING.md)*
