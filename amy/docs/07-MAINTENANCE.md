# amy maintenance procedures

## operational runbook

**document version:** 2.0
**infrastructure version:** 98
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

---

## overview

amy runs 29 active services managed by a single docker-compose.yaml (v98). most maintenance is automated through cron jobs and the secure container update system. this document covers both automated and manual procedures.

### automated maintenance summary

| task | schedule | mechanism |
|------|----------|-----------|
| container vulnerability scan + update | wednesday 04:30 | secure-container-update.sh (cron) |
| blocked container retry | daily 04:30 (except wednesday) | secure-container-update.sh retry (cron) |
| postgresql backup | daily (midnight) | postgres-backup container |
| pihole config replication | hourly | nebula-sync on bender → amy |
| image update notifications | wednesday 04:00 | diun |

### key paths

| path | purpose |
|------|---------|
| `/docker-compose/` | compose file, .env, scripts |
| `/docker-compose/scripts/` | secure-container-update.sh, health-checks.sh, rollback.sh |
| `/docker-compose/configs/secure-update/logs/` | update execution logs |
| `/docker/postgres-backup/` | automated database backups |
| `/docker/` | container persistent data |
| `/portainer/postgresql/data/` | postgresql data directory |

---

## daily operations

### what happens automatically

1. **postgres-backup** runs at midnight, backing up atuin, miniflux, sss, mealie, and stirling databases
2. **retry job** runs at 04:30 (except wednesday), re-scanning any containers blocked by vulnerabilities

### recommended daily checks

these are optional but helpful for catching issues early:

```bash
# quick health overview
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "running"

# check if any containers restarted unexpectedly
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "restarting"

# check postgres-backup last run
docker logs postgres-backup --tail 5 2>&1 | tail -3
```

if any containers show as unhealthy or restarting, investigate with:

```bash
docker logs <container_name> --tail 50
```

---

## weekly operations

### what happens automatically (wednesday)

1. **diun** scans all images for updates at 04:00 and sends ntfy notifications
2. **secure-container-update.sh** runs at 04:30:
   - pulls new images for containers with available updates
   - scans each with trivy for critical/high CVEs
   - deploys clean images, blocks vulnerable ones
   - runs health checks after each update
   - sends ntfy notifications for all events

### recommended weekly checks

```bash
# review update logs from wednesday
cat /docker-compose/configs/secure-update/logs/$(date -d "last wednesday" +%Y-%m-%d).log

# check retry queue for stuck containers
cat /docker-compose/configs/secure-update/retry-queue.json

# verify all 29 services are running
docker compose ps --format "table {{.Names}}\t{{.Status}}" | wc -l

# check disk usage
df -h / | tail -1
du -sh /docker/ /portainer/ /docker-compose/configs/secure-update/
```

### clearing the trivy cache

if the trivy cache grows too large:

```bash
# check current size
du -sh /docker/trivy/cache/

# clear and let trivy rebuild on next scan
docker compose stop trivy
rm -rf /docker/trivy/cache/*
docker compose start trivy

# verify trivy is healthy
sleep 10 && docker compose ps trivy
```

---

## monthly operations

### recommended monthly checks

```bash
# review backup retention (should show 7 daily, 4 weekly, 6 monthly)
ls -la /docker/postgres-backup/

# check docker disk usage
docker system df

# prune unused images (only dangling — safe)
docker image prune -f

# check overall system resources
free -h
df -h
uptime
```

### pruning old update logs

```bash
# remove logs older than 180 days
find /docker-compose/configs/secure-update/logs/ -name "*.log" -mtime +180 -delete
find /docker-compose/configs/secure-update/scan-reports/ -name "*.json" -mtime +180 -delete
```

---

## common tasks

### deploy a compose file change

```bash
cd /docker-compose

# always validate before applying
docker compose config > /dev/null && echo "✅ YAML valid" || echo "❌ YAML invalid"

# apply changes (only affected containers are recreated)
docker compose up -d

# verify
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "running"
```

### restart a single service

```bash
# graceful restart
docker compose restart <service_name>

# force recreate (picks up image or config changes)
docker compose up -d --force-recreate <service_name>
```

### update a single service manually

```bash
# pull latest image
docker compose pull <service_name>

# recreate with new image
docker compose up -d --force-recreate <service_name>

# verify
docker compose ps <service_name>
docker logs <service_name> --tail 20
```

### view service logs

```bash
# follow logs in real-time
docker logs -f <service_name>

# last 100 lines with timestamps
docker logs -t --tail 100 <service_name>

# search for errors
docker logs <service_name> 2>&1 | grep -i "error\|fatal\|panic"
```

### access a container shell

```bash
# interactive shell (most containers)
docker exec -it <service_name> /bin/sh

# bash if available
docker exec -it <service_name> /bin/bash

# run a single command
docker exec <service_name> <command>
```

### check service health

```bash
# run full health check suite
/docker-compose/scripts/health-checks.sh all

# check specific service
/docker-compose/scripts/health-checks.sh postgres
/docker-compose/scripts/health-checks.sh ntfy
/docker-compose/scripts/health-checks.sh pihole
```

---

## backup procedures

### postgresql — automatic

the `postgres-backup` container handles daily backups automatically.

| property | value |
|----------|-------|
| **databases** | atuin, miniflux, sss, mealie, stirling |
| **schedule** | daily at midnight |
| **location** | `/docker/postgres-backup/` |
| **retention** | 7 daily, 4 weekly, 6 monthly |

verify backups are running:

```bash
docker logs postgres-backup --tail 10 2>&1
ls -la /docker/postgres-backup/
```

### postgresql — manual

```bash
# full backup of all databases
docker exec postgres pg_dumpall -U postgres > /docker/backups/postgres/manual/backup-$(date +%Y%m%d-%H%M%S).sql

# single database backup
docker exec postgres pg_dump -U postgres atuin > /docker/backups/postgres/manual/atuin-$(date +%Y%m%d).sql
docker exec postgres pg_dump -U postgres miniflux > /docker/backups/postgres/manual/miniflux-$(date +%Y%m%d).sql
docker exec postgres pg_dump -U postgres sss > /docker/backups/postgres/manual/sss-$(date +%Y%m%d).sql
docker exec postgres pg_dump -U postgres mealie > /docker/backups/postgres/manual/mealie-$(date +%Y%m%d).sql
docker exec postgres pg_dump -U postgres stirling > /docker/backups/postgres/manual/stirling-$(date +%Y%m%d).sql

# verify backup
ls -la /docker/backups/postgres/manual/
head -20 /docker/backups/postgres/manual/backup-*.sql
```

### configuration backup

the docker-compose.yaml, .env.template, telegraf.conf, and all documentation are version-controlled in the `futurama-docker` git repository.

```bash
# encrypt .env for offline backup
cd /docker-compose
gpg --symmetric --cipher-algo AES256 -o .env.gpg .env

# backup compose file
cp docker-compose.yaml docker-compose.yaml.backup.$(date +%Y%m%d)
```

### full data backup

```bash
# backup entire docker data directory (stop services first for consistency)
docker compose stop
tar -czvf /tmp/amy-docker-$(date +%Y%m%d).tar.gz /docker/
docker compose start

# or backup while running (less consistent but no downtime)
tar -czvf /tmp/amy-docker-$(date +%Y%m%d).tar.gz /docker/
```

---

## restore procedures

### postgresql restore — full

```bash
# stop all dependent services
docker compose stop atuin miniflux spendspentspent mealie postgres-backup

# restore from backup
docker exec -i postgres psql -U postgres < /docker/backups/postgres/manual/backup-20260208.sql

# restart dependent services
docker compose start atuin miniflux spendspentspent mealie postgres-backup

# verify
/docker-compose/scripts/health-checks.sh postgres
```

### postgresql restore — single database

```bash
# stop only the affected service
docker compose stop miniflux

# drop and recreate the database
docker exec postgres psql -U postgres -c "DROP DATABASE IF EXISTS miniflux;"
docker exec postgres psql -U postgres -c "CREATE DATABASE miniflux;"

# restore
docker exec -i postgres psql -U postgres -d miniflux < /docker/backups/postgres/manual/miniflux-20260208.sql

# restart the service
docker compose start miniflux
```

### container image rollback

```bash
# use the rollback script
/docker-compose/scripts/rollback.sh list-containers <service_name>
/docker-compose/scripts/rollback.sh container <service_name>

# or manual rollback
docker compose stop <service_name>
docker tag <old_image> <service_image>:latest
docker compose up -d <service_name>
```

### full docker-compose rollback

```bash
# restore from backup
cp docker-compose.yaml docker-compose.yaml.broken
cp docker-compose.yaml.backup.<date> docker-compose.yaml

# validate
docker compose config > /dev/null && echo "✅ YAML valid"

# apply
docker compose up -d
```

---

## emergency procedures

### all services down

```bash
# check docker daemon
systemctl status docker

# if docker is down, restart it
systemctl restart docker

# bring up all services
cd /docker-compose
docker compose up -d

# verify
docker compose ps --format "table {{.Names}}\t{{.Status}}"
```

### DNS failure (pihole down)

```bash
# check pihole status
docker compose ps pihole
docker logs pihole --tail 20

# restart pihole
docker compose restart pihole

# check keepalived VIP status
ip addr show | grep 192.168.21.100

# if VIP is not on amy, check keepalived
docker logs keepalived --tail 20
docker compose restart keepalived

# emergency: set fallback DNS on the host
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

### postgresql won't start

```bash
# check logs for the error
docker logs postgres --tail 50

# common fix: check disk space
df -h /portainer/postgresql/

# common fix: check permissions
ls -la /portainer/postgresql/data/

# if data is corrupted, restore from backup
docker compose stop postgres atuin miniflux spendspentspent mealie postgres-backup
# (restore procedure — see restore section above)
```

### ntfy down (no notifications)

```bash
# check ntfy status
docker compose ps ntfy
docker logs ntfy --tail 20

# restart ntfy
docker compose restart ntfy

# test notification delivery
curl -d "test message" http://localhost:8888/test-topic

# IMPORTANT: bender also depends on amy's ntfy for notifications
# if ntfy stays down, bender's diun and update script notifications will fail silently
```

### container in restart loop

```bash
# identify the container
docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -i "restarting"

# check logs for the root cause
docker logs <container_name> --tail 100

# stop the container to prevent restart loop
docker compose stop <container_name>

# investigate and fix, then restart
docker compose start <container_name>
```

---

## service-specific maintenance

### pihole

```bash
# check gravity database (blocklists)
docker exec pihole pihole -g

# check query log stats
docker exec pihole pihole -c -e

# flush DNS cache
docker exec pihole pihole restartdns
```

### telegraf (SNMP monitoring)

telegraf monitors the cisco 3750x switch and brother MFC-L3710CW printer via SNMP. the config is read-only mounted from `/portainer/telegraf/config/telegraf.conf`.

```bash
# check telegraf status
docker logs telegraf --tail 20

# test SNMP connectivity to the switch
docker exec telegraf telegraf --test --config /etc/telegraf/telegraf.conf 2>&1 | head -30

# if modifying telegraf.conf, edit the source file:
nano /portainer/telegraf/config/telegraf.conf

# then restart telegraf to pick up changes
docker compose restart telegraf
```

### cadvisor

```bash
# check cadvisor resource usage
docker stats cadvisor --no-stream

# verify metrics endpoint
curl -s http://localhost:9099/metrics | head -20

# if cadvisor errors about stale overlay2 paths, these are harmless
# they occur when containers are removed but cadvisor still references old paths
docker logs cadvisor 2>&1 | grep -c "no such file"
```

### postgres-backup

```bash
# check last backup status
docker logs postgres-backup --tail 10

# list backups by database
ls -la /docker/postgres-backup/

# manually trigger a backup
docker exec postgres-backup /backup.sh
```

### keepalived

```bash
# check VIP status
ip addr show | grep 192.168.21.100

# check keepalived logs
docker logs keepalived --tail 20

# force failover test (on amy — will release VIP to bender if bender is healthy)
docker stop keepalived
sleep 10
# verify bender took over VIP: dig @192.168.21.100 google.com
docker start keepalived
```

---

*previous: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
*next: [08-TROUBLESHOOTING.md](./08-TROUBLESHOOTING.md)*
