# amy maintenance procedures

## operational guide for day-to-day management

**document version:** 1.0  
**infrastructure version:** 85  
**last updated:** january 10, 2026

---

## table of contents

1. [maintenance schedule](#maintenance-schedule)
2. [daily operations](#daily-operations)
3. [weekly operations](#weekly-operations)
4. [monthly operations](#monthly-operations)
5. [common tasks](#common-tasks)
6. [backup procedures](#backup-procedures)
7. [emergency procedures](#emergency-procedures)
8. [service-specific maintenance](#service-specific-maintenance)

---

## maintenance schedule

### automated tasks

| task | schedule | script/service |
|------|----------|----------------|
| **container updates** | wednesday 04:30 | `secure-container-update.sh weekly` |
| **retry failed updates** | daily 04:30 | `secure-container-update.sh retry` |
| **postgresql backup** | daily (via container) | `postgres-backup` container |
| **pihole sync** | every 30 min | `nebula-sync` (bender → amy) |

### manual tasks

| task | frequency | procedure |
|------|-----------|-----------|
| **review update reports** | weekly | check `/docker-compose/reports/` |
| **verify backups** | weekly | test restore procedure |
| **check disk space** | monthly | `df -h` |
| **review logs** | monthly | dozzle or `docker logs` |
| **security audit** | quarterly | review access, update passwords |

---

## daily operations

### health check

```bash
# quick status check
cd /docker-compose
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"

# should return empty if all services healthy
```

### check notifications

1. verify ntfy is receiving messages
2. check phone/desktop for any alerts
3. review beszel dashboard for anomalies

### monitor resources

```bash
# system resources
htop  # or top

# docker disk usage
docker system df

# container resource usage
docker stats --no-stream
```

---

## weekly operations

### review update reports

```bash
# list recent reports
ls -la /docker-compose/reports/weekly-reports/

# view latest report
cat /docker-compose/reports/weekly-reports/$(ls -t /docker-compose/reports/weekly-reports/ | head -1)
```

### check retry queue

```bash
# view containers awaiting retry
cat /docker-compose/configs/secure-update/retry-queue.json
```

### verify postgresql backups

```bash
# list recent backups
ls -la /docker/backups/postgres/daily/

# check backup sizes (should be > 0)
du -h /docker/backups/postgres/daily/*
```

### test dns failover (monthly recommended)

```bash
# from any device on the network
dig @192.168.21.100 google.com

# should resolve successfully
```

---

## monthly operations

### disk space audit

```bash
# system disk usage
df -h

# docker specific
docker system df -v

# large files in docker directory
du -h /docker/ --max-depth=2 | sort -h | tail -20
```

### log review

```bash
# check for errors in critical services
docker logs postgres 2>&1 | grep -i error | tail -20
docker logs ntfy 2>&1 | grep -i error | tail -20
docker logs pihole 2>&1 | grep -i error | tail -20
```

### clean up

```bash
# remove unused docker resources (caution: removes unused images)
docker system prune -f

# remove old logs (keep 30 days)
find /docker-compose/configs/secure-update/logs/ -type f -mtime +30 -delete

# remove old scan reports (keep 90 days)
find /docker-compose/configs/secure-update/scan-reports/ -type f -mtime +90 -delete
```

### security review

- review vaultwarden audit logs
- check for unauthorized access attempts
- verify pihole blocklists are current
- update any expiring credentials

---

## common tasks

### restart a service

```bash
cd /docker-compose

# restart single service
docker compose restart <service_name>

# examples
docker compose restart ntfy
docker compose restart postgres
docker compose restart pihole
```

### update a single service manually

```bash
cd /docker-compose

# pull new image
docker compose pull <service_name>

# recreate with new image
docker compose up -d --force-recreate <service_name>

# verify
docker compose ps <service_name>
```

### view service logs

```bash
# follow logs in real-time
docker logs -f <service_name>

# last 100 lines
docker logs --tail 100 <service_name>

# with timestamps
docker logs -t --tail 100 <service_name>
```

### check service health

```bash
# run health checks script
/docker-compose/scripts/health-checks.sh all

# or specific service
/docker-compose/scripts/health-checks.sh postgres
/docker-compose/scripts/health-checks.sh ntfy
```

### access service shell

```bash
# interactive shell in container
docker exec -it <service_name> /bin/sh

# or bash if available
docker exec -it <service_name> /bin/bash

# run single command
docker exec <service_name> <command>
```

---

## backup procedures

### postgresql backup

#### automatic (daily)

the `postgres-backup` container automatically backs up all databases daily:
- location: `/docker/backups/postgres/daily/`
- retention: 7 daily, 4 weekly, 6 monthly

#### manual backup

```bash
# full backup of all databases
docker exec postgres pg_dumpall -U postgres > /docker/backups/postgres/manual/backup-$(date +%Y%m%d-%H%M%S).sql

# single database backup
docker exec postgres pg_dump -U postgres atuin > /docker/backups/postgres/manual/atuin-$(date +%Y%m%d).sql
docker exec postgres pg_dump -U postgres miniflux > /docker/backups/postgres/manual/miniflux-$(date +%Y%m%d).sql
docker exec postgres pg_dump -U postgres sss > /docker/backups/postgres/manual/sss-$(date +%Y%m%d).sql
```

### configuration backup

```bash
# backup .env (encrypted)
cd /docker-compose
gpg --symmetric --cipher-algo AES256 -o .env.gpg .env

# backup docker-compose.yaml
cp docker-compose.yaml docker-compose.yaml.backup.$(date +%Y%m%d)
```

### full service data backup

```bash
# stop services before backup (optional but safer)
docker compose stop

# backup entire docker directory
tar -czvf /backup/amy-docker-$(date +%Y%m%d).tar.gz /docker/

# restart services
docker compose start
```

---

## emergency procedures

### service won't start

```bash
# check logs for errors
docker logs <service_name> 2>&1 | tail -50

# check if port is in use
netstat -tlnp | grep <port>

# verify compose file syntax
docker compose config > /dev/null && echo "✅ valid"

# try recreating the container
docker compose up -d --force-recreate <service_name>
```

### postgresql recovery

```bash
# if postgres won't start, check data directory
ls -la /docker/postgresql/data/

# check postgres logs
docker logs postgres 2>&1 | tail -100

# if corruption suspected, restore from backup
docker compose stop postgres
mv /docker/postgresql/data /docker/postgresql/data.corrupted
docker compose up -d postgres
# wait for new db to initialize, then restore
docker exec -i postgres psql -U postgres < /docker/backups/postgres/daily/latest.sql
```

### dns failure (both hosts)

```bash
# temporarily use external dns
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# debug pihole
docker logs pihole 2>&1 | tail -50
docker compose restart pihole

# check keepalived
docker logs keepalived 2>&1 | tail -20
```

### out of disk space

```bash
# identify largest consumers
du -h /docker/ --max-depth=2 | sort -h | tail -20

# emergency cleanup
docker system prune -af  # warning: removes all unused images

# remove old backups
find /docker/backups/ -type f -mtime +7 -delete

# check and clean logs
truncate -s 0 /docker/*/logs/*.log  # if applicable
```

### rollback failed update

```bash
# use rollback script
/docker-compose/scripts/rollback.sh list-containers <service_name>
/docker-compose/scripts/rollback.sh container <service_name> 1

# or manually
docker stop <service_name>
docker tag <service_name>:latest <service_name>:failed
docker tag <service_name>:backup-1 <service_name>:latest
docker compose up -d <service_name>
```

---

## service-specific maintenance

### postgresql

```bash
# check database sizes
docker exec postgres psql -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) FROM pg_database;"

# vacuum and analyze (maintenance)
docker exec postgres psql -U postgres -c "VACUUM ANALYZE;"

# check connections
docker exec postgres psql -U postgres -c "SELECT * FROM pg_stat_activity;"
```

### pihole

```bash
# update gravity (blocklists)
docker exec pihole pihole -g

# view query log
docker exec pihole pihole -t

# check status
docker exec pihole pihole status
```

### ntfy

```bash
# check topics
ls -la /docker/ntfy/cache/

# view recent messages (if logging enabled)
docker logs ntfy 2>&1 | tail -50
```

### vaultwarden

```bash
# backup vault data
cp -r /docker/vaultwarden /backup/vaultwarden-$(date +%Y%m%d)

# check for admin token issues
docker logs vaultwarden 2>&1 | grep -i admin
```

### beszel

```bash
# check agent connections
docker logs beszel 2>&1 | grep -i agent

# verify bender agent is reporting
curl -s http://localhost:8090/api/status
```

---

## cron jobs reference

### current crontab

```bash
# view current cron jobs
crontab -l

# expected entries:
# 30 4 * * 3 /docker-compose/scripts/secure-container-update.sh weekly >> /docker-compose/configs/secure-update/logs/cron.log 2>&1
# 30 4 * * * /docker-compose/scripts/secure-container-update.sh retry >> /docker-compose/configs/secure-update/logs/cron.log 2>&1
```

### edit cron jobs

```bash
# edit crontab
crontab -e

# verify changes
crontab -l
```

---

## quick reference commands

```bash
# status
docker compose ps
/docker-compose/scripts/health-checks.sh all

# logs
docker logs -f <service>
docker compose logs -f

# updates
/docker-compose/scripts/secure-container-update.sh status
/docker-compose/scripts/secure-container-update.sh scan <service>

# backups
ls -la /docker/backups/postgres/daily/
docker exec postgres-backup /backup.sh  # manual backup

# restart all
docker compose down && docker compose up -d

# validate config
docker compose config > /dev/null && echo "✅ valid"
```

---

*previous: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*  
*next: [08-TROUBLESHOOTING.md](./08-TROUBLESHOOTING.md)*
