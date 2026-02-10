# bender maintenance procedures

## operational runbook

**document version:** 2.0
**infrastructure version:** 105
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [daily operations](#daily-operations)
3. [weekly operations](#weekly-operations)
4. [monthly operations](#monthly-operations)
5. [common tasks](#common-tasks)
6. [backup procedures](#backup-procedures)
7. [restore procedures](#restore-procedures)
8. [emergency procedures](#emergency-procedures)
9. [service-specific maintenance](#service-specific-maintenance)
10. [TrueNAS maintenance](#truenas-maintenance)

---

## overview

bender runs 33 active services managed by a single docker-compose.yaml (v105). most maintenance is automated through cron jobs and the secure container update system. this document covers both automated and manual procedures.

### automated maintenance summary

| task | schedule | mechanism |
|------|----------|-----------|
| container vulnerability scan + update | saturday 04:30 | secure-container-update.sh (cron, /tmp copy) |
| blocked container retry | daily 04:30 (except saturday) | secure-container-update.sh retry (cron, /tmp copy) |
| postgresql backup | daily (midnight) | postgres-backup container |
| pihole config replication | hourly | nebula-sync (bender → amy) |
| pihole DNS auto-population | every 5 minutes | /root/pihole-dns-update.sh (cron) |
| image update notifications | daily 06:00 | diun |

### key paths

| path | purpose |
|------|---------|
| `/mnt/BIG/filme/docker-compose/` | compose file, .env, scripts |
| `/mnt/BIG/filme/docker-compose/scripts/` | update, health check, rollback scripts |
| `/mnt/BIG/filme/docker-compose/configs/secure-update/logs/` | update execution logs |
| `/mnt/BIG/filme/backups/postgres/` | automated database backups |
| `/mnt/BIG/filme/configs/` | per-service configuration volumes |
| `/mnt/BIG/filme/immich/postgresql/` | postgresql data directory (CRITICAL) |
| `/root/pihole-dns-update.sh` | DNS auto-population script (executable) |
| `/var/log/pihole-dns-export.log` | DNS auto-population log |

---

## daily operations

### what happens automatically

1. **postgres-backup** runs at midnight, backing up immich and hedgedoc databases
2. **retry job** runs at 04:30 (except saturday), re-scanning containers blocked by vulnerabilities
3. **pihole-dns-update.sh** runs every 5 minutes, scanning containers on both hosts and updating pihole DNS entries
4. **diun** runs at 06:00, checking all container images for available updates and notifying via ntfy on amy

### recommended daily checks

these are optional but helpful for catching issues early:

```bash
cd /mnt/BIG/filme/docker-compose

# quick health overview
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "running"

# any containers restarting?
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "restarting"

# check postgres-backup last run
docker logs postgres-backup --tail 5 2>&1 | tail -3

# check gluetun VPN status
docker logs gluetun --tail 5 2>&1 | grep -i "ip\|connect\|error"
```

---

## weekly operations

### what happens automatically (saturday)

1. **secure-container-update.sh** runs at 04:30 (copied to /tmp first):
   - pulls new images for containers with available updates
   - scans each with trivy for critical/high CVEs
   - deploys clean images, blocks vulnerable ones
   - runs health checks after each update
   - sends ntfy notifications to amy for all events

### recommended weekly checks

```bash
cd /mnt/BIG/filme/docker-compose

# review update logs from saturday
cat configs/secure-update/logs/$(date -d "last saturday" +%Y-%m-%d).log

# check retry queue for stuck containers
cat configs/secure-update/retry-queue.json

# verify all 33 services are running
docker compose ps --format "table {{.Names}}\t{{.Status}}" | wc -l

# check VPN is connected
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null | head -5

# check disk usage
df -h /mnt/BIG/
du -sh /mnt/BIG/filme/configs/ /mnt/BIG/filme/backups/ /mnt/BIG/filme/transmission/
```

### clearing the trivy cache

```bash
# check current size
du -sh /mnt/BIG/filme/configs/trivy/

# clear and rebuild
docker compose stop trivy
rm -rf /mnt/BIG/filme/configs/trivy/*
docker compose start trivy
sleep 30 && docker compose ps trivy
```

---

## monthly operations

### recommended monthly checks

```bash
cd /mnt/BIG/filme/docker-compose

# review backup retention
ls -la /mnt/BIG/filme/backups/postgres/

# check docker disk usage
docker system df

# prune unused images (only dangling — safe)
docker image prune -f

# check ZFS pool health
zpool status BIG

# check ZFS pool usage
zfs list BIG

# check system resources
free -h
df -h /mnt/BIG/
uptime
```

### pruning old update logs

```bash
# remove logs older than 180 days
find /mnt/BIG/filme/docker-compose/configs/secure-update/logs/ -name "*.log" -mtime +180 -delete
find /mnt/BIG/filme/docker-compose/configs/secure-update/scan-reports/ -name "*.json" -mtime +180 -delete
```

### pruning DNS auto-population log

```bash
# check log size
ls -la /var/log/pihole-dns-export.log

# rotate if large (>10MB)
> /var/log/pihole-dns-export.log
```

---

## common tasks

### deploy a compose file change

```bash
cd /mnt/BIG/filme/docker-compose

# always validate before applying
docker compose config > /dev/null && echo "✅ YAML valid" || echo "❌ YAML invalid"

# apply changes (only affected containers are recreated)
docker compose up -d

# verify
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "running"
```

### restart a single service

```bash
cd /mnt/BIG/filme/docker-compose

# graceful restart
docker compose restart <service_name>

# force recreate (picks up image or config changes)
docker compose up -d --force-recreate <service_name>
```

### restart a VPN-routed service

VPN-routed services (transmission, prowlarr, sonarr, etc.) depend on gluetun. restarting them may require restarting gluetun first if there are network issues:

```bash
# restart just the service (usually sufficient)
docker compose restart transmission

# if service can't reach the network, restart gluetun
docker compose restart gluetun
# wait for VPN to reconnect
sleep 15
docker logs gluetun --tail 5

# all VPN-routed services will automatically reconnect
```

### update a single service manually

```bash
cd /mnt/BIG/filme/docker-compose

# pull latest image
docker compose pull <service_name>

# recreate with new image
docker compose up -d --force-recreate <service_name>

# verify
docker compose ps <service_name>
docker logs <service_name> --tail 20
```

> **warning:** do not manually update transmission — it is pinned to 4.0.5 for FileList whitelist compliance. `docker compose pull transmission` will not upgrade it because the tag is explicit.

### view service logs

```bash
# follow logs in real-time
docker logs -f <service_name>

# last 100 lines with timestamps
docker logs -t --tail 100 <service_name>

# search for errors
docker logs <service_name> 2>&1 | grep -i "error\|fatal\|panic"

# for VPN-routed services, also check gluetun if networking issues
docker logs gluetun --tail 50 2>&1 | grep -i "error\|disconnect"
```

### run health checks

```bash
# copy to /tmp first (TrueNAS requirement)
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/

# check all services
bash /tmp/health-checks.sh all

# check specific service
bash /tmp/health-checks.sh postgres
bash /tmp/health-checks.sh vaultwarden
bash /tmp/health-checks.sh immich

# cleanup
rm /tmp/health-checks.sh
```

### access a container shell

```bash
# interactive shell (most containers)
docker exec -it <service_name> /bin/sh

# bash if available (linuxserver images)
docker exec -it <service_name> /bin/bash

# for VPN-routed services (verify VPN IP)
docker exec transmission wget -qO- http://ipinfo.io 2>/dev/null
```

---

## backup procedures

### postgresql — automatic

the `postgres-backup` container handles daily backups automatically.

| property | value |
|----------|-------|
| **databases** | immich, hedgedoc |
| **schedule** | daily at midnight |
| **location** | `/mnt/BIG/filme/backups/postgres/` |
| **retention** | 7 daily, 4 weekly, 6 monthly |

verify backups are running:

```bash
docker logs postgres-backup --tail 10 2>&1
ls -la /mnt/BIG/filme/backups/postgres/
```

### postgresql — manual

```bash
# full backup of all databases
docker exec postgres pg_dumpall -U postgres > /mnt/BIG/filme/backups/postgres/manual/backup-$(date +%Y%m%d-%H%M%S).sql

# single database backup
docker exec postgres pg_dump -U postgres immich > /mnt/BIG/filme/backups/postgres/manual/immich-$(date +%Y%m%d).sql
docker exec postgres pg_dump -U postgres hedgedoc > /mnt/BIG/filme/backups/postgres/manual/hedgedoc-$(date +%Y%m%d).sql

# verify backup
ls -la /mnt/BIG/filme/backups/postgres/manual/
head -20 /mnt/BIG/filme/backups/postgres/manual/backup-*.sql
```

> **important:** bender's postgres uses the immich-specific image with vectorchord extensions. when restoring, ensure you restore to the same image version — standard postgres cannot read the vector extension data.

### configuration backup

the docker-compose.yaml, .env.template, keepalived.conf, and all documentation are version-controlled in the `futurama-docker` git repository.

```bash
# encrypt .env for offline backup
cd /mnt/BIG/filme/docker-compose
gpg --symmetric --cipher-algo AES256 -o .env.gpg .env

# backup compose file
cp docker-compose.yaml docker-compose.yaml.backup.$(date +%Y%m%d)
```

### ZFS snapshots (recommended for media)

```bash
# create a manual snapshot
zfs snapshot BIG/filme@manual-$(date +%Y%m%d)

# list snapshots
zfs list -t snapshot | grep BIG

# check snapshot size
zfs list -t snapshot -o name,used,refer | grep BIG
```

### immich photos backup

immich photos are stored at `/mnt/BIG/filme/immich/photos/`. the recommended backup strategy is ZFS snapshots. for offsite backup:

```bash
# compress and archive (this can be very large)
tar -czvf /tmp/immich-photos-$(date +%Y%m%d).tar.gz /mnt/BIG/filme/immich/photos/
```

---

## restore procedures

### postgresql restore — full

```bash
cd /mnt/BIG/filme/docker-compose

# stop all dependent services
docker compose stop immich_server immich_machine_learning hedgedoc postgres-backup

# restore from backup
docker exec -i postgres psql -U postgres < /mnt/BIG/filme/backups/postgres/manual/backup-20260208.sql

# restart dependent services
docker compose start immich_server immich_machine_learning hedgedoc postgres-backup

# verify
cp scripts/health-checks.sh /tmp/ && bash /tmp/health-checks.sh postgres && rm /tmp/health-checks.sh
```

### postgresql restore — single database

```bash
cd /mnt/BIG/filme/docker-compose

# stop only the affected service
docker compose stop hedgedoc

# drop and recreate
docker exec postgres psql -U postgres -c "DROP DATABASE IF EXISTS hedgedoc;"
docker exec postgres psql -U postgres -c "CREATE DATABASE hedgedoc;"

# restore
docker exec -i postgres psql -U postgres -d hedgedoc < /mnt/BIG/filme/backups/postgres/manual/hedgedoc-20260208.sql

# restart
docker compose start hedgedoc
```

### ZFS snapshot restore

```bash
# list available snapshots
zfs list -t snapshot | grep BIG

# rollback to a snapshot (WARNING: destroys all changes since the snapshot)
zfs rollback BIG/filme@manual-20260208
```

> **warning:** ZFS rollback affects the entire dataset. all container data, media files, and configurations will revert to the snapshot point. use only for disaster recovery.

### container image rollback

```bash
cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/

# list available backups
bash /tmp/rollback.sh list jellyfin

# rollback
bash /tmp/rollback.sh rollback jellyfin

rm /tmp/rollback.sh
```

---

## emergency procedures

### all services down

```bash
# check docker daemon
systemctl status docker

# if docker is down
systemctl restart docker

# bring up all services
cd /mnt/BIG/filme/docker-compose
docker compose up -d

# verify
docker compose ps --format "table {{.Names}}\t{{.Status}}"
```

### VPN down (gluetun failure)

when gluetun fails, all 8 VPN-routed services lose network access.

```bash
# check gluetun status
docker logs gluetun --tail 20

# restart gluetun
docker compose restart gluetun

# wait for VPN to establish
sleep 30

# verify VPN is connected
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null

# if still failing, check VPN credentials
grep SURFSHARK /mnt/BIG/filme/docker-compose/.env

# emergency: restart all VPN-routed services
docker compose restart gluetun transmission prowlarr sonarr radarr lidarr readarr bazarr jdownloader
```

### DNS failure (pihole down)

```bash
# check pihole status
docker compose ps pihole
docker logs pihole --tail 20

# restart pihole
docker compose restart pihole

# check keepalived VIP
ip addr show | grep 192.168.21.100

# if VIP missing, restart keepalived
docker compose restart keepalived

# emergency: set fallback DNS on the host
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

> **note:** if bender's pihole fails, amy's pihole should take over the VIP automatically via keepalived. verify by running `dig @192.168.21.100 google.com` from another device.

### postgresql won't start

```bash
# check logs
docker logs postgres --tail 50

# check disk space
df -h /mnt/BIG/

# check ZFS pool health
zpool status BIG

# check data directory
ls -la /mnt/BIG/filme/immich/postgresql/

# if corrupted, restore from backup (see restore section)
```

### immich not loading photos

```bash
# check immich_server
docker compose ps immich_server
docker logs immich_server --tail 30

# check ML service
docker compose ps immich_machine_learning
docker logs immich_machine_learning --tail 20

# check redis
docker exec immich_redis redis-cli ping

# check postgres connectivity from immich
docker exec postgres psql -U postgres -d immich -c "SELECT COUNT(*) FROM \"user\";"

# restart immich stack
docker compose restart immich_server immich_machine_learning immich_redis
```

### container in restart loop

```bash
# identify the container
docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -i "restarting"

# check logs
docker logs <container_name> --tail 100

# stop the loop
docker compose stop <container_name>

# investigate and fix, then restart
docker compose start <container_name>
```

---

## service-specific maintenance

### gluetun VPN

```bash
# check current VPN IP
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null

# check connection status
docker logs gluetun --tail 10

# force reconnect
docker compose restart gluetun
sleep 30
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null
```

### transmission

```bash
# check download stats
docker logs transmission --tail 10

# verify torrent port is open (51413)
# use an online port checker pointing to your VPN IP

# check disk space for downloads
du -sh /mnt/BIG/filme/transmission/completed/
du -sh /mnt/BIG/filme/transmission/incomplete/
```

> **reminder:** transmission is pinned to 4.0.5 — do not upgrade. FileList whitelist requirement.

### jellyfin

```bash
# check transcoding cache
du -sh /mnt/BIG/filme/configs/jellyfin/data/transcodes/

# clear transcoding cache if too large
docker exec jellyfin rm -rf /config/data/transcodes/*

# scan libraries after media changes
# use jellyfin web UI → dashboard → libraries → scan all libraries
```

### immich

```bash
# check ML model cache
du -sh /mnt/BIG/filme/immich/ml-cache/

# check photo storage usage
du -sh /mnt/BIG/filme/immich/photos/

# check immich server status via API
curl -s http://localhost:2283/api/server-info/ping
```

### pihole and DNS auto-population

```bash
# check DNS entries
docker exec pihole cat /etc/pihole/pihole.toml | grep -A50 "hosts ="

# check auto-population log
tail -20 /var/log/pihole-dns-export.log

# force DNS update
/root/pihole-dns-update.sh

# verify a specific entry resolves
dig media.home.arpa @192.168.21.100
```

### keepalived

```bash
# check VIP ownership
ip addr show | grep 192.168.21.100

# check keepalived status
docker logs keepalived --tail 20

# force failover test (releases VIP to amy)
docker stop keepalived
sleep 10
# verify amy took over: dig @192.168.21.100 google.com
docker start keepalived
# bender reclaims VIP within seconds
```

### postgres-backup

```bash
# check last backup
docker logs postgres-backup --tail 10

# list backups
ls -la /mnt/BIG/filme/backups/postgres/

# manually trigger backup
docker exec postgres-backup /backup.sh
```

### cadvisor

```bash
# check resource usage
docker stats cadvisor --no-stream

# verify metrics endpoint
curl -s http://localhost:9099/metrics | head -5

# stale overlay2 path errors are harmless — ignore them
```

### syncthing

```bash
# check syncthing status (uses host network)
curl -fkLsS -m 2 http://127.0.0.1:8384/rest/noauth/health

# check sync status via web UI
# https://sync.bunny-enigmatic.ts.net
```

---

## TrueNAS maintenance

### before TrueNAS upgrades

TrueNAS upgrades can potentially affect docker state. before upgrading:

```bash
# 1. backup compose file and .env
cd /mnt/BIG/filme/docker-compose
cp docker-compose.yaml docker-compose.yaml.pre-upgrade
cp .env .env.pre-upgrade

# 2. backup postgresql
docker exec postgres pg_dumpall -U postgres > /mnt/BIG/filme/backups/postgres/manual/pre-upgrade-$(date +%Y%m%d).sql

# 3. note running container state
docker compose ps > /tmp/container-state-pre-upgrade.txt

# 4. create ZFS snapshot
zfs snapshot BIG/filme@pre-upgrade-$(date +%Y%m%d)
```

### after TrueNAS upgrades

```bash
# 1. verify docker is running
systemctl status docker

# 2. verify compose file is intact
cat /mnt/BIG/filme/docker-compose/docker-compose.yaml | head -5

# 3. bring up all services
cd /mnt/BIG/filme/docker-compose
docker compose up -d

# 4. verify
docker compose ps --format "table {{.Names}}\t{{.Status}}"

# 5. verify cron jobs survived
crontab -l

# 6. verify pihole-dns-update.sh is still at /root/
ls -la /root/pihole-dns-update.sh
```

### ZFS pool maintenance

```bash
# check pool health (should say "ONLINE" with no errors)
zpool status BIG

# start a scrub (recommended monthly)
zpool scrub BIG

# check scrub progress
zpool status BIG | grep scan

# check pool usage
zfs list BIG
```

---

*previous: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
*next: [08-TROUBLESHOOTING.md](./08-TROUBLESHOOTING.md)*
