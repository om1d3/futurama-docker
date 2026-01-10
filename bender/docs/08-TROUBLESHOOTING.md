# bender troubleshooting guide

## problem resolution guide

**document version:** 1.0  
**infrastructure version:** 86  
**last updated:** january 10, 2026

---

## table of contents

1. [quick diagnostics](#quick-diagnostics)
2. [container issues](#container-issues)
3. [database issues](#database-issues)
4. [network issues](#network-issues)
5. [storage issues](#storage-issues)
6. [service-specific issues](#service-specific-issues)

---

## quick diagnostics

### system status commands

```bash
# all containers status
docker compose ps

# container resource usage
docker stats --no-stream

# disk usage
df -h /mnt/BIG

# docker disk usage
docker system df

# recent logs across all containers
docker compose logs --tail 20
```

### health check script

```bash
# copy to /tmp first (TrueNAS requirement)
cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/
chmod +x /tmp/health-checks.sh

# run all checks
/tmp/health-checks.sh all

# check specific service
/tmp/health-checks.sh postgres

# cleanup
rm /tmp/health-checks.sh
```

---

## container issues

### container won't start

**symptoms:** container exits immediately or crashes on startup

**diagnosis:**
```bash
# check logs
docker logs <container> --tail 100

# check if port is in use
netstat -tlnp | grep <port>

# check docker events
docker events --since 10m --filter container=<container>
```

**common causes:**

| cause | solution |
|-------|----------|
| port conflict | change port in compose or stop conflicting service |
| missing volume | create directory: `mkdir -p /mnt/BIG/filme/configs/<service>` |
| permission denied | fix permissions: `chown -R 1000:1000 /mnt/BIG/filme/configs/<service>` |
| config error | check compose syntax: `docker compose config` |
| resource limit | increase memory/cpu in compose |

---

### container unhealthy

**symptoms:** container running but health check failing

**diagnosis:**
```bash
# check health status
docker inspect <container> --format '{{.State.Health.Status}}'

# view health check logs
docker inspect <container> --format '{{json .State.Health.Log}}' | jq

# run health check manually
docker exec <container> <health-check-command>
```

**common causes:**

| cause | solution |
|-------|----------|
| slow startup | increase health check start_period |
| internal service issue | check application logs |
| network issue | verify container network connectivity |

---

### container using too much memory

**symptoms:** container consuming excessive ram, host slowdown

**diagnosis:**
```bash
# check memory usage
docker stats <container> --no-stream

# check memory limit
docker inspect <container> --format '{{.HostConfig.Memory}}'
```

**solutions:**
1. add memory limit in compose:
   ```yaml
   deploy:
     resources:
       limits:
         memory: 2G
   ```
2. restart container to clear cache
3. check for memory leaks in application

---

## database issues

### postgresql won't start

**symptoms:** postgres container exits, dependent services fail

**diagnosis:**
```bash
# check postgres logs
docker logs postgres --tail 100

# check data directory
ls -la /mnt/BIG/filme/immich/postgresql/data/

# check permissions
stat /mnt/BIG/filme/immich/postgresql/data/
```

**common causes:**

| cause | solution |
|-------|----------|
| corrupt data | restore from backup |
| wrong permissions | `chown -R 70:70 /mnt/BIG/filme/immich/postgresql/data/` |
| disk full | free up space, check df |
| lock file stale | remove postmaster.pid if postgres not running |

---

### database connection refused

**symptoms:** services can't connect to postgres

**diagnosis:**
```bash
# check postgres is running
docker ps | grep postgres

# test connection
docker exec postgres pg_isready -U postgres

# check network
docker network inspect media-network | grep postgres
```

**solutions:**
```bash
# restart postgres
docker compose restart postgres

# wait for startup
sleep 30

# verify
docker exec postgres pg_isready -U postgres
```

---

### database corruption

**symptoms:** query errors, data inconsistency, crash loops

**resolution:**

1. **stop dependent services**
   ```bash
   docker compose stop immich_server immich_machine_learning hedgedoc postgres-backup
   docker compose stop postgres
   ```

2. **attempt recovery**
   ```bash
   # start in recovery mode
   docker compose up -d postgres
   docker exec postgres pg_isready -U postgres
   
   # if successful, check databases
   docker exec postgres psql -U postgres -c "\l"
   ```

3. **if recovery fails, restore from backup**
   ```bash
   # remove corrupt data
   rm -rf /mnt/BIG/filme/immich/postgresql/data/*
   
   # start fresh postgres
   docker compose up -d postgres
   sleep 30
   
   # restore from backup
   docker exec -i postgres psql -U postgres < /mnt/BIG/filme/docker-compose/backups/postgres/daily/latest.sql
   ```

4. **restart services**
   ```bash
   docker compose up -d immich_server immich_machine_learning hedgedoc postgres-backup
   ```

---

## network issues

### container can't reach internet

**symptoms:** downloads fail, api calls timeout

**diagnosis:**
```bash
# test from container
docker exec <container> ping -c 3 8.8.8.8
docker exec <container> curl -I https://google.com

# check dns
docker exec <container> cat /etc/resolv.conf
```

**solutions:**
```bash
# restart docker
systemctl restart docker

# recreate network
docker compose down
docker network prune
docker compose up -d
```

---

### containers can't communicate

**symptoms:** services fail to connect to each other

**diagnosis:**
```bash
# check containers are on same network
docker network inspect media-network

# test connectivity
docker exec immich_server ping -c 3 postgres
docker exec sonarr curl -I http://transmission:9091
```

**solutions:**
```bash
# ensure services use same network in compose
# check network: section in docker-compose.yaml

# recreate containers
docker compose up -d --force-recreate
```

---

### tailscale/tsdproxy issues

**symptoms:** can't access services via tailscale urls

**diagnosis:**
```bash
# check tsdproxy status
docker logs tsdproxy --tail 50

# verify tailscale connection
docker exec tsdproxy tailscale status
```

**solutions:**

| issue | solution |
|-------|----------|
| auth expired | generate new auth key, update .env, restart tsdproxy |
| service not discovered | verify tsdproxy labels in compose |
| wrong port | check tsdproxy.container_port label |

---

## storage issues

### disk full

**symptoms:** container crashes, write errors

**diagnosis:**
```bash
# check disk usage
df -h /mnt/BIG

# find large directories
du -sh /mnt/BIG/filme/* | sort -hr | head -10

# check docker storage
docker system df -v
```

**solutions:**

```bash
# clean docker
docker system prune -a --volumes

# clean transmission completed
rm -rf /mnt/BIG/filme/transmission/completed/*

# clean jellyfin cache
rm -rf /mnt/BIG/filme/configs/jellyfin/cache/*

# clean old backups
find /mnt/BIG/filme/docker-compose/backups/postgres/ -mtime +30 -delete
```

---

### permission denied errors

**symptoms:** container can't read/write files

**diagnosis:**
```bash
# check current permissions
ls -la /mnt/BIG/filme/configs/<service>/

# check container user
docker exec <container> id
```

**solutions:**
```bash
# standard services (puid/pgid 1000)
chown -R 1000:1000 /mnt/BIG/filme/configs/<service>

# postgresql
chown -R 70:70 /mnt/BIG/filme/immich/postgresql/

# pihole
chown -R 999:999 /mnt/BIG/filme/configs/pihole/
```

---

## service-specific issues

### immich issues

**photo upload fails:**
```bash
# check upload directory permissions
ls -la /mnt/BIG/filme/immich/upload/

# check immich logs
docker logs immich_server --tail 50

# verify postgresql connection
docker exec immich_server curl -s http://localhost:2283/api/server/ping
```

**ml not working:**
```bash
# check ml container
docker logs immich_machine_learning --tail 50

# verify model cache
ls -la /mnt/BIG/filme/immich/model-cache/
```

---

### transmission issues

**vpn not connecting:**
```bash
# check transmission logs
docker logs transmission --tail 100

# verify vpn credentials in .env
grep TRANSMISSION_VPN .env

# test connectivity
docker exec transmission curl ifconfig.me
```

**downloads stuck:**
```bash
# check if vpn is connected
docker exec transmission curl ifconfig.me

# verify download directories
ls -la /mnt/BIG/filme/transmission/
```

---

### pihole issues

**dns queries failing:**
```bash
# test dns
dig @192.168.21.121 -p 8053 google.com

# check pihole logs
docker logs pihole --tail 50

# verify pihole is healthy
curl http://192.168.21.121:8054/admin/
```

**keepalived failover not working:**
```bash
# check keepalived status
docker logs keepalived

# verify vip assignment
ip addr show | grep 192.168.21.100

# check health script
docker exec keepalived cat /container/service/keepalived/assets/healthcheck.sh
```

---

### arr stack issues

**indexer problems:**
```bash
# check prowlarr logs
docker logs prowlarr --tail 50

# verify prowlarr can reach indexers
docker exec prowlarr curl -I https://example-indexer.com
```

**download client connection:**
```bash
# verify transmission is reachable from sonarr
docker exec sonarr curl -I http://transmission:9091

# check transmission rpc
docker exec sonarr curl -u transmission:transmission http://transmission:9091/transmission/rpc
```

---

## escalation

if issues persist after troubleshooting:

1. **collect diagnostics:**
   ```bash
   docker compose ps > /tmp/diag-ps.txt
   docker compose logs --tail 100 > /tmp/diag-logs.txt
   docker system df > /tmp/diag-df.txt
   ```

2. **check documentation:** review relevant service documentation

3. **community resources:** consult service-specific forums/discord

4. **backup before changes:** always backup before attempting fixes

---

*previous: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*  
*this is the final document in the series.*
