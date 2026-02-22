# amy maintenance procedures

## operational runbook

**document version:** 3.0
**infrastructure version:** 99
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
10. [system maintenance](#system-maintenance)

---

## overview

amy runs 29 active services managed by a single docker-compose.yaml (v99). most maintenance is automated through cron jobs and the secure container update system. unlike bender, amy can execute scripts directly without copying to `/tmp/`.

### automated tasks

| task | schedule | system |
|------|----------|--------|
| container vulnerability scan | wednesday 04:30 | secure-container-update.sh weekly |
| retry blocked containers | all other days 04:30 | secure-container-update.sh retry |
| pihole config sync | hourly (from bender) | nebula-sync on bender |
| postgresql backup | daily | postgres-backup container |
| image update notifications | wednesday 04:00 | diun |

---

## daily operations

### verify all containers running

```bash
cd /docker-compose

# quick count (expect 29)
docker compose ps --format "{{.Names}}" | wc -l

# show any non-running containers
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"

# check for unhealthy containers
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "unhealthy"
```

### check notification system

```bash
# verify ntfy is responding
curl -s -o /dev/null -w "%{http_code}" http://localhost:8888

# send test notification
curl -s -X POST http://localhost:8888/test \
  -H "Title: Health Check" \
  -d "Amy maintenance check $(date)"
```

---

## weekly operations

### review update reports

```bash
# list recent reports
ls -lt /docker-compose/reports/weekly-reports/ | head -5

# read latest report
cat /docker-compose/reports/weekly-reports/$(ls -t /docker-compose/reports/weekly-reports/ | head -1)
```

### check retry queue

```bash
cat /docker-compose/configs/secure-update/retry-queue.json
```

if containers are stuck for more than a week:

```bash
bash /docker-compose/scripts/secure-container-update.sh scan <container_name>
```

### check disk usage

```bash
# filesystem usage
df -h /

# docker disk usage
docker system df

# largest directories
du -sh /docker/*/ 2>/dev/null | sort -rh | head -10
du -sh /portainer/*/ 2>/dev/null | sort -rh | head -5
```

---

## monthly operations

### clean up unused docker resources

```bash
cd /docker-compose

# remove unused images
docker image prune -f

# remove build cache
docker builder prune -f

# check for dangling volumes
docker volume ls --filter dangling=true
```

### verify backups

```bash
# check postgres backup exists and is recent
ls -lht /docker/postgres-backup/ | head -10

# verify backup sizes are reasonable
find /docker/postgres-backup/ -name "*.sql*" -mtime -1 -exec ls -lh {} \;
```

### system updates

```bash
# update debian packages
apt update && apt upgrade -y

# check if reboot required
[ -f /var/run/reboot-required ] && echo "Reboot required" || echo "No reboot needed"
```

---

## common tasks

### restart a single service

```bash
cd /docker-compose
docker compose restart <service_name>
```

### restart all services

```bash
cd /docker-compose
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
cd /docker-compose
docker compose pull <service_name>
docker compose up -d <service_name>
```

### check container resource usage

```bash
docker stats --no-stream
```

---

## backup procedures

### automated postgres backup

postgres-backup runs daily and backs up atuin, miniflux, sss, mealie, and stirling:

```bash
# verify backup container is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep postgres-backup

# check latest backups
ls -lht /docker/postgres-backup/ | head -10
```

### manual postgres backup

```bash
# full dump (all databases)
docker exec postgres pg_dumpall -U postgres > /docker/backups/postgres/manual-$(date +%Y%m%d).sql

# single database
docker exec postgres pg_dump -U postgres atuin > /docker/backups/postgres/atuin-$(date +%Y%m%d).sql
```

### configuration backup

the git repository at `~/code/futurama-docker` (pushed to `github.com/om1d3/futurama-docker`) contains all configuration:

```bash
# on laptop
cd ~/code/futurama-docker

# pull latest configs from production
scp root@192.168.21.130:/docker-compose/docker-compose.yaml amy/docker-compose.yaml
scp root@192.168.21.130:/docker-compose/.env /tmp/amy.env

# re-encrypt .env
gpg --symmetric --cipher-algo AES256 -o amy/.env.gpg /tmp/amy.env
rm /tmp/amy.env

# update .env.example
sed 's/=.*/=/' /tmp/amy.env > amy/.env.example

# commit and push
git add .
git commit -m "amy v99: <description>"
git push
```

---

## restore procedures

### restore postgres from backup

```bash
# list available backups
bash /docker-compose/scripts/rollback.sh list-postgres

# restore full backup
bash /docker-compose/scripts/rollback.sh postgres /docker/postgres-backup/last/atuin-latest.sql.gz

# restore single database
bash /docker-compose/scripts/rollback.sh database atuin /docker/postgres-backup/daily/atuin-20260210.sql.gz
```

### restore single container from image backup

```bash
# list backups
bash /docker-compose/scripts/rollback.sh list-containers ntfy

# rollback to most recent backup
bash /docker-compose/scripts/rollback.sh container ntfy

# rollback to second backup
bash /docker-compose/scripts/rollback.sh container ntfy 2
```

### restore from git repository

```bash
# on laptop
cd ~/code/futurama-docker

# decrypt .env
gpg --decrypt --output /tmp/amy.env amy/.env.gpg

# deploy to amy
scp amy/docker-compose.yaml root@192.168.21.130:/docker-compose/
scp /tmp/amy.env root@192.168.21.130:/docker-compose/.env
rm /tmp/amy.env

# restart services on amy
ssh root@192.168.21.130 'cd /docker-compose && docker compose up -d'
```

---

## emergency procedures

### ntfy down (both hosts lose notifications)

```bash
# check ntfy
docker ps | grep ntfy
docker logs ntfy --tail 20

# restart ntfy
docker restart ntfy

# verify
curl -s -o /dev/null -w "%{http_code}" http://localhost:8888
```

### pihole down / DNS failover active

if bender's pihole failed and amy is serving DNS:

```bash
# verify amy's pihole is healthy
docker ps | grep pihole
dig @localhost google.com +short

# check keepalived VIP is on amy
ip addr show enp4s0 | grep 192.168.21.100

# check when nebula-sync last replicated config
ls -la /docker/pihole/etc-pihole/pihole.toml
```

### postgres won't start

```bash
# check logs
docker logs postgres --tail 50

# check disk space
df -h /
df -h /portainer/

# check data directory
ls -la /portainer/postgresql/data/

# if data corruption suspected
bash /docker-compose/scripts/rollback.sh list-postgres
```

### all services down after reboot

```bash
# start all services
cd /docker-compose
docker compose up -d

# verify
docker compose ps --format "table {{.Names}}\t{{.Status}}"
```

---

## service-specific maintenance

### atuin

the atuin command was changed from `server start` to `start` in v99 due to an upstream binary change (atuin → atuin-server):

```bash
# verify atuin is running
docker ps --format "{{.Names}}\t{{.Status}}" | grep atuin

# check logs for startup errors
docker logs atuin --tail 20

# if atuin fails with "unknown command 'server'", verify compose has:
#   command: start
# (not: command: server start)
```

### telegraf

```bash
# check telegraf is collecting data
docker logs telegraf --tail 20

# verify SNMP connectivity to switch
docker exec telegraf snmpwalk -v2c -c futurama 192.168.21.5 1.3.6.1.2.1.1.5.0 2>/dev/null || echo "SNMP failed"

# verify SNMP connectivity to printer
docker exec telegraf snmpwalk -v2c -c public 192.168.21.10 1.3.6.1.2.1.1.1.0 2>/dev/null || echo "SNMP failed"

# check influxdb connectivity
curl -s "http://192.168.21.220:8086/ping" && echo "InfluxDB reachable" || echo "InfluxDB unreachable"
```

### beszel

```bash
# check beszel hub
curl -s -o /dev/null -w "%{http_code}" http://localhost:8090

# check beszel-agent
docker ps --format "{{.Names}}\t{{.Status}}" | grep beszel-agent

# verify bender's agent is reporting (check beszel web UI)
```

### mealie

```bash
# check mealie
docker ps --format "{{.Names}}\t{{.Status}}" | grep mealie

# verify database connection
docker exec postgres psql -U postgres -d mealie -c "SELECT 1;"

# check logs
docker logs mealie --tail 20
```

### spendspentspent

```bash
# check service
docker ps --format "{{.Names}}\t{{.Status}}" | grep spendspentspent

# verify database
docker exec postgres psql -U postgres -d sss -c "SELECT 1;"

# check playwright-chrome (needed for bank scraping)
docker ps --format "{{.Names}}\t{{.Status}}" | grep playwright-chrome
```

---

## system maintenance

### cron jobs

verify cron jobs are configured:

```bash
crontab -l | grep -E "secure-container|retry"
```

expected:

| schedule | command |
|----------|---------|
| `30 4 * * 3` | `bash /docker-compose/scripts/secure-container-update.sh weekly` |
| `30 4 * * 0-2,4-6` | `bash /docker-compose/scripts/secure-container-update.sh retry` |

### debian system updates

```bash
# check for updates
apt update
apt list --upgradable

# apply updates
apt upgrade -y

# reboot if kernel was updated
[ -f /var/run/reboot-required ] && reboot
```

### docker updates

```bash
# check docker version
docker --version
docker compose version

# update docker (if using docker's official repo)
apt update && apt upgrade docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
```

### SSH key for bender access

bender's pihole-dns-update.sh connects to amy as user `kube` via SSH. if amy is reinstalled or SSH keys are regenerated:

```bash
# on bender, verify SSH access works
ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 "docker ps -q | wc -l"

# if it fails, re-copy bender's public key to amy
ssh-copy-id kube@192.168.21.130
```

---

*previous: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
*next: [08-TROUBLESHOOTING.md](./08-TROUBLESHOOTING.md)*
