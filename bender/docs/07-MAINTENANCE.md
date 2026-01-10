# bender maintenance procedures

## operational runbook

**document version:** 1.0  
**infrastructure version:** 86  
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

---

## maintenance schedule

### routine schedule

| frequency | day | time | tasks |
|-----------|-----|------|-------|
| **daily** | every | - | monitor notifications, check container health |
| **weekly** | saturday | 04:30 | diun update check, review & apply updates |
| **monthly** | 1st saturday | - | full system review, storage cleanup |
| **quarterly** | - | - | credential rotation, documentation review |

---

## daily operations

### morning check (~5 minutes)

1. **check ntfy notifications**
   - review any overnight alerts from diun, beszel, or services
   - address any critical notifications immediately

2. **verify container status**
   ```bash
   ssh root@192.168.21.121 'cd /mnt/BIG/filme/docker-compose && docker compose ps'
   ```

3. **quick health check**
   ```bash
   # verify critical services
   curl -s http://192.168.21.121:2283/api/server/ping  # immich
   curl -s http://192.168.21.121:8054/admin/           # pihole
   ```

### monitoring dashboards

| service | url | purpose |
|---------|-----|---------|
| **dockwatch** | https://bender-dockwatch.bunny-enigmatic.ts.net | container overview |
| **pihole** | https://bender-pihole.bunny-enigmatic.ts.net | dns statistics |
| **immich** | https://immich.bunny-enigmatic.ts.net | photo management |

---

## weekly operations

### saturday update review

1. **check diun notifications**
   - review which containers have available updates
   - note any containers repeatedly in retry queue

2. **run security scan preview**
   ```bash
   ssh root@192.168.21.121
   cd /mnt/BIG/filme/docker-compose
   
   # preview what would be updated
   docker images --format "{{.Repository}}:{{.Tag}}" | head -10
   ```

3. **apply updates**
   ```bash
   # copy script to /tmp (TrueNAS requirement)
   cp scripts/secure-container-update.sh /tmp/
   chmod +x /tmp/secure-container-update.sh
   
   # run update for specific container
   /tmp/secure-container-update.sh jellyfin
   
   # or update all
   /tmp/secure-container-update.sh all
   
   # cleanup
   rm /tmp/secure-container-update.sh
   ```

4. **verify post-update**
   ```bash
   docker compose ps
   cp scripts/health-checks.sh /tmp/
   /tmp/health-checks.sh all
   rm /tmp/health-checks.sh
   ```

### storage check

```bash
# check disk usage
df -h /mnt/BIG

# check largest directories
du -sh /mnt/BIG/filme/* | sort -hr | head -10

# check docker disk usage
docker system df
```

---

## monthly operations

### 1st saturday of month

1. **full container update review**
   - address any containers in retry queue
   - check for major version upgrades

2. **storage cleanup**
   ```bash
   # remove unused docker resources
   docker system prune -a --volumes --filter "until=720h"
   
   # check immich storage
   du -sh /mnt/BIG/filme/immich/*
   
   # check transmission completed
   ls -la /mnt/BIG/filme/transmission/completed/
   ```

3. **backup verification**
   ```bash
   # list postgresql backups
   ls -la /mnt/BIG/filme/docker-compose/backups/postgres/
   
   # verify latest backup is valid
   head -50 /mnt/BIG/filme/docker-compose/backups/postgres/daily/$(ls -t /mnt/BIG/filme/docker-compose/backups/postgres/daily/ | head -1)
   ```

4. **log review**
   ```bash
   # check update logs
   ls -la /mnt/BIG/filme/docker-compose/configs/secure-update/logs/
   
   # review recent errors
   grep -i error /mnt/BIG/filme/docker-compose/configs/secure-update/logs/*.log | tail -20
   ```

---

## common tasks

### restart a service

```bash
cd /mnt/BIG/filme/docker-compose

# restart single service
docker compose restart jellyfin

# restart with fresh container
docker compose up -d --force-recreate jellyfin
```

### view logs

```bash
# last 100 lines
docker logs --tail 100 jellyfin

# follow logs
docker logs -f immich_server

# logs with timestamps
docker logs -t --since 1h sonarr
```

### update single container

```bash
cd /mnt/BIG/filme/docker-compose

# pull new image
docker compose pull jellyfin

# recreate with new image
docker compose up -d jellyfin
```

### access container shell

```bash
# interactive shell
docker exec -it postgres bash

# run single command
docker exec postgres pg_isready -U postgres
```

### check container resource usage

```bash
# live stats
docker stats --no-stream

# specific container
docker stats jellyfin --no-stream
```

---

## backup procedures

### postgresql backup

#### automatic (daily via postgres-backup)
- runs at 04:00 daily
- 7-day retention
- stored in `/mnt/BIG/filme/docker-compose/backups/postgres/`

#### manual backup

```bash
# full database dump
docker exec postgres pg_dumpall -U postgres > /mnt/BIG/filme/docker-compose/backups/postgres/manual-$(date +%Y%m%d-%H%M).sql

# single database
docker exec postgres pg_dump -U postgres immich > /mnt/BIG/filme/docker-compose/backups/postgres/immich-$(date +%Y%m%d).sql
```

### configuration backup

```bash
# backup .env (encrypted)
cd /mnt/BIG/filme/docker-compose
gpg --symmetric --cipher-algo AES256 -o .env.gpg .env

# backup compose file
cp docker-compose.yaml docker-compose.yaml.backup-$(date +%Y%m%d)

# backup all configs
tar -czvf configs-backup-$(date +%Y%m%d).tar.gz configs/
```

### restore procedures

#### restore postgresql

```bash
# stop services
docker compose stop immich_server immich_machine_learning hedgedoc postgres-backup

# restore database
docker exec -i postgres psql -U postgres < /mnt/BIG/filme/docker-compose/backups/postgres/manual-20260110.sql

# restart services
docker compose up -d immich_server immich_machine_learning hedgedoc postgres-backup
```

#### restore configuration

```bash
# decrypt .env
gpg -d .env.gpg > .env
chmod 600 .env

# restore compose file
cp docker-compose.yaml.backup-20260110 docker-compose.yaml

# restore configs
tar -xzvf configs-backup-20260110.tar.gz
```

---

## emergency procedures

### service won't start

1. **check logs**
   ```bash
   docker logs <service> --tail 50
   ```

2. **check config**
   ```bash
   docker compose config
   ```

3. **recreate container**
   ```bash
   docker compose up -d --force-recreate <service>
   ```

### database corruption

1. **stop all dependent services**
   ```bash
   docker compose stop immich_server immich_machine_learning hedgedoc postgres-backup
   ```

2. **stop postgresql**
   ```bash
   docker compose stop postgres
   ```

3. **restore from backup**
   ```bash
   # restore data directory from ZFS snapshot or backup
   # or restore from sql dump
   docker compose up -d postgres
   sleep 30
   docker exec -i postgres psql -U postgres < /path/to/backup.sql
   ```

4. **restart services**
   ```bash
   docker compose up -d immich_server immich_machine_learning hedgedoc postgres-backup
   ```

### disk full

1. **identify large files**
   ```bash
   du -sh /mnt/BIG/filme/* | sort -hr | head -10
   ```

2. **clean docker**
   ```bash
   docker system prune -a --volumes
   ```

3. **clean transmission**
   ```bash
   rm -rf /mnt/BIG/filme/transmission/completed/*
   ```

### network issues

1. **check docker network**
   ```bash
   docker network ls
   docker network inspect media-network
   ```

2. **restart docker**
   ```bash
   systemctl restart docker
   ```

3. **recreate network**
   ```bash
   docker compose down
   docker network prune
   docker compose up -d
   ```

### tailscale disconnected

1. **check tsdproxy status**
   ```bash
   docker logs tsdproxy
   ```

2. **restart tsdproxy**
   ```bash
   docker compose restart tsdproxy
   ```

3. **re-authenticate if needed**
   - generate new auth key from tailscale admin
   - update `TSDPROXY_AUTHKEY` in .env
   - restart tsdproxy

---

*previous: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*  
*next: [08-TROUBLESHOOTING.md](./08-TROUBLESHOOTING.md)*
