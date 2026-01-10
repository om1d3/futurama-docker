# Amy Troubleshooting Guide

## Diagnostic and Resolution Procedures

**Document Version:** 1.0  
**Infrastructure Version:** 85  
**Last Updated:** January 10, 2026

---

## Table of Contents

1. [Quick Diagnostics](#quick-diagnostics)
2. [Container Issues](#container-issues)
3. [Database Issues](#database-issues)
4. [Network Issues](#network-issues)
5. [DNS and Pi-hole Issues](#dns-and-pi-hole-issues)
6. [Update System Issues](#update-system-issues)
7. [Service-Specific Issues](#service-specific-issues)
8. [Performance Issues](#performance-issues)

---

## Quick Diagnostics

### First Response Checklist

```bash
# 1. Check all container status
docker compose ps

# 2. Check for unhealthy containers
docker compose ps | grep -v "Up\|healthy"

# 3. Check system resources
free -h
df -h
uptime

# 4. Check Docker daemon
systemctl status docker

# 5. Run health checks
/docker-compose/scripts/health-checks.sh all
```

### Common Status Indicators

| Status | Meaning | Action |
|--------|---------|--------|
| `Up (healthy)` | Container running and healthy | None needed |
| `Up (unhealthy)` | Running but health check failing | Check logs |
| `Restarting` | Container crash loop | Check logs, fix config |
| `Exited (0)` | Normal exit (one-shot container) | Usually OK |
| `Exited (1)` | Error exit | Check logs |
| `Exited (137)` | OOM killed | Increase memory |
| `Exited (143)` | SIGTERM received | Manual stop or restart |

---

## Container Issues

### Container Won't Start

**Symptoms:**
- Container immediately exits
- Status shows `Exited` or `Restarting`

**Diagnostics:**
```bash
# Check logs
docker logs <container> 2>&1 | tail -50

# Check compose config
docker compose config | grep -A 30 "<service_name>:"

# Verify image exists
docker images | grep <image_name>
```

**Common Causes and Solutions:**

| Cause | Solution |
|-------|----------|
| Missing environment variable | Check `.env` file |
| Port already in use | `netstat -tlnp \| grep <port>` |
| Volume permission issue | `chown -R 1000:1000 /docker/<service>` |
| Missing directory | Create required directories |
| Corrupted image | `docker compose pull <service>` |

### Container Keeps Restarting

**Symptoms:**
- RestartCount keeps increasing
- Brief periods of availability

**Diagnostics:**
```bash
# Check restart count
docker inspect <container> --format='{{.RestartCount}}'

# Watch restart loop
watch -n 2 'docker ps | grep <container>'

# Check logs across restarts
docker logs <container> 2>&1 | tail -200
```

**Solutions:**
```bash
# Stop restart loop
docker compose stop <container>

# Fix issue based on logs, then restart
docker compose up -d <container>
```

### Container Unhealthy

**Symptoms:**
- Status shows `(unhealthy)`
- Service may be partially working

**Diagnostics:**
```bash
# Check health check definition
docker inspect <container> --format='{{json .Config.Healthcheck}}' | jq

# See health check history
docker inspect <container> --format='{{json .State.Health}}' | jq

# Run health check manually
docker exec <container> <healthcheck_command>
```

---

## Database Issues

### PostgreSQL Won't Start

**Symptoms:**
- postgres container exits
- Dependent services fail

**Diagnostics:**
```bash
docker logs postgres --tail 100
```

**Common Errors:**

| Error | Solution |
|-------|----------|
| "database files are incompatible" | Check PostgreSQL version, restore from backup |
| "could not open file" | Check permissions: `chown -R 1000:1000 /docker/postgresql` |
| "FATAL: password authentication failed" | Check `POSTGRES_PASSWORD` in `.env` |
| "database system was not properly shut down" | Recovery runs automatically, wait |

### Database Connection Refused

**Symptoms:**
- Services can't connect to postgres
- "Connection refused" errors

**Diagnostics:**
```bash
# Check postgres is running
docker ps | grep postgres

# Check postgres is accepting connections
docker exec postgres pg_isready -U postgres

# Test connection
docker exec postgres psql -U postgres -c "SELECT 1"

# Check network
docker network inspect utility-network | grep postgres
```

**Solutions:**
```bash
# If postgres running but not accepting
docker restart postgres
sleep 30
docker exec postgres pg_isready -U postgres

# If network issue
docker compose down
docker compose up -d
```

### Restore Database from Backup

```bash
# Stop dependent services
docker compose stop atuin miniflux spendspentspent

# Identify backup to restore
ls -la /docker/backups/postgres/daily/

# Restore specific database
docker exec -i postgres psql -U postgres < /docker/backups/postgres/daily/atuin-20260110.sql

# Or restore all databases
docker exec -i postgres psql -U postgres < /docker/backups/postgres/manual/full-backup.sql

# Restart services
docker compose start atuin miniflux spendspentspent
```

---

## Network Issues

### Container Can't Reach Other Containers

**Symptoms:**
- Inter-container communication fails
- "Connection refused" between services

**Diagnostics:**
```bash
# Check network exists
docker network ls | grep utility-network

# Check container is on network
docker inspect <container> --format='{{json .NetworkSettings.Networks}}' | jq

# Test connectivity
docker exec <container1> ping <container2>
docker exec <container1> wget -qO- http://<container2>:<port>
```

**Solutions:**
```bash
# Reconnect to network
docker network connect utility-network <container>

# Recreate network (CAUTION: affects all containers)
docker compose down
docker network rm utility-network
docker compose up -d
```

### External Network Unreachable

**Symptoms:**
- Containers can't reach internet
- DNS resolution fails

**Diagnostics:**
```bash
# Test from container
docker exec <container> ping 8.8.8.8
docker exec <container> nslookup google.com

# Check host networking
ping 8.8.8.8
cat /etc/resolv.conf
```

**Solutions:**
```bash
# If DNS issue, temporarily use external DNS
docker exec <container> sh -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'

# Check Docker DNS settings
cat /etc/docker/daemon.json
```

---

## DNS and Pi-hole Issues

### Pi-hole Not Resolving

**Symptoms:**
- DNS queries fail
- Devices can't reach internet

**Diagnostics:**
```bash
# Test Pi-hole directly
dig @127.0.0.1 google.com
dig @192.168.21.130 google.com

# Check Pi-hole status
docker exec pihole pihole status

# Check FTL (DNS resolver) is running
docker exec pihole pgrep pihole-FTL
```

**Solutions:**
```bash
# Restart Pi-hole
docker compose restart pihole

# Restart DNS resolver
docker exec pihole pihole restartdns

# Rebuild gravity database
docker exec pihole pihole -g
```

### Keepalived VIP Not Working

**Symptoms:**
- VIP (192.168.21.100) unreachable
- Failover not happening

**Diagnostics:**
```bash
# Check VIP assignment
ip addr | grep 192.168.21.100

# Check Keepalived logs
docker logs keepalived 2>&1 | tail -30

# Check VRRP state
docker logs keepalived 2>&1 | grep -E "MASTER|BACKUP|priority"

# Check health script status
docker logs keepalived 2>&1 | grep -E "Script|succeeded|failed"
```

**Solutions:**
```bash
# If health script failing
docker exec keepalived wget -q --spider --timeout=2 http://127.0.0.1:8053/admin/
echo "Exit code: $?"

# Restart Keepalived
docker compose restart keepalived

# Check peer communication (on other host)
docker logs keepalived 2>&1 | grep "192.168.21"
```

### Pi-hole Sync Issues (nebula-sync)

**Symptoms:**
- Amy's Pi-hole config doesn't match bender's
- Blocklists out of sync

**Note:** nebula-sync runs on bender, not amy. Check bender's logs:
```bash
# On bender
docker logs nebula-sync 2>&1 | tail -20
```

---

## Update System Issues

### Updates Not Running

**Symptoms:**
- No update notifications
- Containers never updated

**Diagnostics:**
```bash
# Check cron jobs
crontab -l

# Check cron log
cat /docker-compose/configs/secure-update/logs/cron.log

# Check Diun is running
docker compose ps diun
docker logs diun 2>&1 | tail -20
```

**Solutions:**
```bash
# Verify cron is running
systemctl status cron

# Test update script manually
/docker-compose/scripts/secure-container-update.sh status

# Trigger manual scan
/docker-compose/scripts/secure-container-update.sh scan <container>
```

### Diun Not Sending Notifications

**Symptoms:**
- Updates detected but no ntfy notification
- Diun logs show notification errors

**Diagnostics:**
```bash
# Check Diun logs for ntfy errors
docker logs diun 2>&1 | grep -i ntfy

# Test ntfy connectivity
docker exec diun wget -qO- http://ntfy:80/v1/health
```

**Common Errors:**

| Error | Solution |
|-------|----------|
| "connection refused" | Check ntfy container is running |
| "dial tcp [::1]:8888" | Wrong endpoint - use `http://ntfy:80` |
| "topic not found" | Check `DIUN_NTFY_TOPIC` in compose |

**Solution:**
```bash
# Verify Diun config
docker compose config | grep -A 20 "diun:"

# Should show: DIUN_NOTIF_NTFY_ENDPOINT=http://ntfy:80
# NOT: http://localhost:8888
```

### Trivy Scan Failures

**Symptoms:**
- Scans timeout or fail
- Vulnerability data not available

**Diagnostics:**
```bash
# Check Trivy is running
docker compose ps trivy
docker logs trivy 2>&1 | tail -20

# Test Trivy manually
curl -s http://localhost:8083/healthz
```

**Solutions:**
```bash
# Restart Trivy
docker compose restart trivy

# Wait for database download (first run takes time)
docker logs -f trivy 2>&1 | grep -i database
```

---

## Service-Specific Issues

### ntfy Issues

**Symptoms:**
- Notifications not received
- ntfy web interface not loading

**Diagnostics:**
```bash
# Check ntfy health
curl -s http://localhost:8888/v1/health

# Check logs
docker logs ntfy 2>&1 | tail -30

# Test sending notification
curl -d "Test message" http://localhost:8888/test-topic
```

### Vaultwarden Issues

**Symptoms:**
- Can't log in
- Sync failures

**Diagnostics:**
```bash
# Check container status
docker compose ps vaultwarden

# Check logs
docker logs vaultwarden 2>&1 | tail -50

# Verify data directory
ls -la /docker/vaultwarden/
```

### Miniflux Issues

**Symptoms:**
- Can't log in
- Feed refresh failures

**Diagnostics:**
```bash
# Check database connection
docker exec miniflux /usr/bin/miniflux -info

# Check logs
docker logs miniflux 2>&1 | tail -50

# Verify database exists
docker exec postgres psql -U postgres -c "\l" | grep miniflux
```

### Beszel Issues

**Symptoms:**
- Agent not reporting
- Dashboard empty

**Diagnostics:**
```bash
# Check Beszel hub
docker logs beszel 2>&1 | tail -30

# Check Beszel agent
docker logs beszel-agent 2>&1 | tail -30

# Verify connectivity
curl -s http://localhost:8090/
```

---

## Performance Issues

### High CPU Usage

**Diagnostics:**
```bash
# Find high CPU containers
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}" | sort -k2 -h -r | head -10

# Check host CPU
top -bn1 | head -20
```

**Solutions:**
- Identify and restart problematic container
- Check for infinite loops in logs
- Consider resource limits in compose

### High Memory Usage

**Diagnostics:**
```bash
# Container memory usage
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}" | sort -k2 -h -r | head -10

# Host memory
free -h
```

**Solutions:**
```bash
# If PostgreSQL using too much memory
docker exec postgres psql -U postgres -c "SHOW shared_buffers;"

# Restart memory-hungry container
docker compose restart <container>
```

### Disk Space Issues

**Diagnostics:**
```bash
# Host disk usage
df -h

# Docker disk usage
docker system df -v

# Find large directories
du -h /docker/ --max-depth=2 | sort -h | tail -20
```

**Solutions:**
```bash
# Clean unused Docker resources
docker system prune -f

# Clean old images
docker image prune -af

# Clean old logs
find /docker-compose/configs/secure-update/logs/ -mtime +30 -delete
```

---

## Emergency Recovery

### Complete Service Failure

```bash
# 1. Check Docker daemon
systemctl status docker
systemctl restart docker

# 2. Restart all containers
cd /docker-compose
docker compose down
docker compose up -d

# 3. Verify critical services
docker compose ps | grep -E "postgres|ntfy|pihole"
```

### Restore from Backup

```bash
# 1. Stop all services
docker compose down

# 2. Restore Docker data directory
tar -xzvf /backup/amy-docker-YYYYMMDD.tar.gz -C /

# 3. Restore .env if needed
gpg -d .env.gpg > .env
chmod 600 .env

# 4. Start services
docker compose up -d
```

---

## Quick Reference: Error Messages

| Error | Likely Cause | Quick Fix |
|-------|--------------|-----------|
| "port already in use" | Another process on port | `netstat -tlnp \| grep <port>` |
| "permission denied" | Wrong file ownership | `chown -R 1000:1000 /docker/<service>` |
| "no such file or directory" | Missing volume/directory | Create directory |
| "connection refused" | Service not running/wrong port | Check service status |
| "name resolution failed" | DNS issue | Check Pi-hole, use 8.8.8.8 temporarily |
| "OOM killed" | Out of memory | Increase swap, add RAM, reduce services |

---

*Previous: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*  
*This is the final document in the series.*
