# amy troubleshooting guide

## diagnostic procedures and common fixes

**document version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

---

## table of contents

1. [quick diagnostics](#quick-diagnostics)
2. [container issues](#container-issues)
3. [postgresql issues](#postgresql-issues)
4. [DNS and networking issues](#dns-and-networking-issues)
5. [tsdproxy issues](#tsdproxy-issues)
6. [notification issues](#notification-issues)
7. [monitoring issues](#monitoring-issues)
8. [oxidized issues](#oxidized-issues)
9. [productivity app issues](#productivity-app-issues)
10. [finance and automation issues](#finance-and-automation-issues)
11. [update system issues](#update-system-issues)
12. [replica hosting issues](#replica-hosting-issues)
13. [historical fixes reference](#historical-fixes-reference)

---

## quick diagnostics

### first response checklist

```bash
cd /docker-compose

# 1. how many containers are running vs expected?
docker compose ps --format "{{.Names}}" | wc -l
# expected: 25 (running services in 20260810.2; 31 defined, six parked)

# 2. which containers are NOT running?
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"

# 3. restarting / unhealthy?
docker ps -a --format "{{.Names}}\t{{.Status}}" | grep -iE "restarting|unhealthy"

# 4. the two hubs answering?
curl -s -o /dev/null -w "ntfy: %{http_code}\n" http://localhost:8888
curl -s -o /dev/null -w "beszel: %{http_code}\n" http://localhost:8090

# 5. DNS via the VIP?
dig @10.30.0.2 google.com +short

# 6. disk space (single SSD carries everything, incl. bender's replica)
df -h /

# 7. load ok? (i3-2310M – comfortable below 4.0)
uptime
```

### health check suite

```bash
./scripts/health-checks.sh postgres
./scripts/health-checks.sh container ntfy
./scripts/health-checks.sh all
```

---

## container issues

### container won't start / keeps restarting

```bash
docker inspect <container> --format '{{.State.ExitCode}} {{.RestartCount}} {{.State.OOMKilled}}'
docker logs <container> --tail 50
```

exit-code cheat sheet as on bender: 1 app error, 126/127 entrypoint problems, 137 OOM/stop, 139 segfault, 143 SIGTERM.

### env change "didn't apply"

`up -d` does not recreate on env change:

```bash
docker compose up -d --force-recreate <service>
docker inspect <service> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep <VAR>
```

---

## postgresql issues

### postgres won't start

```bash
docker logs postgres --tail 50
df -h /
ls -la /portainer/postgresql/data/
```

**the v94 scar:** if the data directory looks suspiciously empty, verify the volume path in the compose file is `/portainer/postgresql/data` – a "clean" /docker path once orphaned all five databases. the legacy path is canonical.

### per-tenant access checks

```bash
for db in atuin miniflux sss mealie stirling; do
  docker exec postgres psql -U postgres -d $db -c "SELECT 1;" >/dev/null 2>&1 \
    && echo "$db: OK" || echo "$db: FAIL"
done
```

### dependent apps down after a postgres event

atuin, miniflux, mealie, and spendspentspent gate on `service_healthy` – they start only after pg_isready passes. if they're stuck "created", postgres's healthcheck is the blocker, not the apps.

---

## DNS and networking issues

### pihole not responding

```bash
docker ps | grep pihole
docker logs pihole --tail 20
dig @127.0.0.1 google.com +short
dig @10.30.0.11 google.com +short
docker restart pihole
```

### local pihole changes keep disappearing

by design – nebula-sync overwrites amy's pihole from bender hourly (FULL_SYNC). make the change on **bender**; it arrives within the hour.

### keepalived / VIP questions

```bash
ip addr show enp4s0 | grep 10.30.0.2   # amy holds the VIP ONLY while bender's pihole is down
docker logs keepalived --tail 20
```

amy holding the VIP is a symptom pointing at bender, not an amy problem. amy stuck NOT taking the VIP while bender is genuinely dead → check the VRRP password matches bender's and the peer IP in `/docker/keepalived/keepalived.conf` is 10.30.0.12.

### DNSSEC oddities after a failover

amy's pihole runs quad9 + DNSSEC (bender's does not) – domains with broken DNSSEC chains fail on amy but resolve on bender. that's the documented upstream asymmetry, not a malfunction.

---

## tsdproxy issues

### all amy tailscale URLs dead after a reboot

the v101/v104 double-scar:

```bash
docker logs tsdproxy --tail 30
# 1. auth: TSNET_FORCE_LOGIN=1 should surface a login URL in the logs if the key lapsed –
#    rotate TSDPROXY_AUTHKEY in .env, then:
docker compose up -d --force-recreate tsdproxy
# 2. routing: verify the hostname target is the LIVE IP:
docker inspect tsdproxy --format '{{range .Config.Env}}{{println .}}{{end}}' | grep TSDPROXY_HOSTNAME
# → must be 10.30.0.11 (v104 fixed the stale 192.168.21.130)
```

---

## notification issues

### no notifications arriving (from either host)

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8888
docker logs ntfy --tail 30
curl -d "test" http://localhost:8888/test        # should appear on subscribed clients

# reachable from bender?  (run ON bender)
# curl -s -o /dev/null -w "%{http_code}" http://10.30.0.11:8888
```

while ntfy is down, alerts are **lost, not queued** – after recovery, review bender's update/replication/SMART logs for anything that fired during the outage.

### amy's own diun silent

diun posts in-network to `http://ntfy:80` – if ntfy was recreated and the network alias hiccuped:

```bash
docker exec diun wget -qO- http://ntfy:80 2>/dev/null | head -1 || echo "cannot reach ntfy"
docker compose restart diun
```

---

## monitoring issues

### beszel shows no data / one host missing

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8090
docker logs beszel --tail 20
# amy's own agent:
docker logs beszel-agent --tail 20     # host network, port 45876
# bender's agent is bender-side – check there if only bender is missing
```

### grafana empty for amy

pipeline: amy cadvisor (10.30.0.11:9099) → prometheus (10.30.0.41:9090) → grafana.

```bash
curl -s http://localhost:9099/metrics | head -5
# prometheus scrape target must be 10.30.0.11:9099 (no 192.168.21.x leftovers)
# dashboard instance variable: Constant, 10.30.0.11:9099
```

### netalertx noisy or blind

```bash
docker logs netalertx --tail 20
# host network + NET_RAW/NET_ADMIN/NET_BIND_SERVICE caps are required (v96 fix) –
# if scanning stopped after an edit, verify the cap_add block survived
```

### telegraf gaps (switch/printer metrics)

```bash
docker logs telegraf --tail 20
# config is the read-only legacy path: /portainer/telegraf/config/telegraf.conf
# SNMP targets: nod + Brother MFC-L3710CW – reachable? community strings unchanged?
```

---

## oxidized issues

### nod-config repo not receiving commits

```bash
docker logs oxidized --tail 30
curl -s http://localhost:8889/nodes | head -5
```

triage order: (1) **PAT expired** – regenerate the amy-oxidized fine-grained PAT on GitHub, update the oxidized config, `docker restart oxidized`; (2) nod unreachable / credentials rotated on the switch; (3) genuinely no config changes (hourly runs with no diff produce no commit – check the repo's last-commit age against known switch changes).

---

## productivity app issues

### miniflux "cross-origin request detected" / can't log in

v103 behavior: full login binds to the BASE_URL origin `http://rss.home.arpa:8385`. use that origin; `DISABLE_HTTP_ORIGIN_CHECK=1` covers the rest. it is amy's vikunja-lesson equivalent.

### mealie unreachable or links wrong

BASE_URL is the tailscale origin (`https://mealie.bunny-enigmatic.ts.net`) – links generated for LAN users will point remote. worker counts are deliberately 1/1 on the i3.

### atuin fails after image update

`command: start` is the v99 fix for upstream's binary rename. "unknown subcommand" after an update means upstream moved again – check their changelog, adjust the command, changelog the compose.

### stirling DPI errors

`SYSTEM_MAXDPI=1200` (v97) is the fix for "DPI value exceeds maximum safe limit" – verify it survived recreation via docker inspect.

### filebrowser sees no files

its roots are `/docker` and `/portainer` mounts – if a path 404s, the host directory moved, which on amy means someone violated the path conventions in 03.

---

## finance and automation issues

### spendspentspent import/automation failures

```bash
docker restart playwright-chrome     # first move – shared browser wedges first
docker logs spendspentspent --tail 30
curl -s -o /dev/null -w "%{http_code}" http://localhost:9021
docker exec postgres psql -U postgres -d sss -c "SELECT 1;"
```

never touch `SSS_SALT` – existing password hashes die with it.

### limdius down

```bash
docker logs limdius --tail 30
# python:3.11-slim installs deps at start – a PyPI hiccup at boot shows here; restart retries:
docker compose restart limdius
```

### playwright-chrome session exhaustion

10 concurrent sessions, queue 10 – both consumers hammering it shows as timeouts:

```bash
docker logs playwright-chrome --tail 20
docker restart playwright-chrome
```

---

## update system issues

### weekly scan didn't run

```bash
crontab -l | grep secure-container
ls -lt <state path>/logs/ | head -3        # path VERIFY – see 04
./scripts/secure-container-update.sh status
./scripts/secure-container-update.sh weekly
```

### container stuck in retry queue

```bash
cat <state path>/retry-queue.json
./scripts/secure-container-update.sh scan <container>
```

### trivy issues

```bash
curl -s http://localhost:8083/healthz
docker logs trivy --tail 20
docker restart trivy
```

amy's trivy mapping (8083:4954) matches its script URL (localhost:8083) – no bender-style port audit item here.

---

## replica hosting issues

### bender reports replication failure

from the amy side, three checks cover it:

```bash
# 1. is kube's authorized_keys still trusting bender's root key?
grep -c "ssh-" /home/kube/.ssh/authorized_keys

# 2. destination present, kube-owned, writable?
ls -ld /docker/backups/bender-replica && touch /docker/backups/bender-replica/.writetest && rm $_

# 3. disk full?
df -h /
```

anything else is bender-side (its log names the failing phase).

### replica contents look wrong

media/downloads/caches are excluded by design. configs + postgres dumps + the docker-compose tree must be present and dated within ~24h. never prune from the amy side – retention is bender's job.

---

## homepage: "Host validation failed"

**symptom.** the browser shows a rendered error page, not a shell error:

```
Error
Host validation failed. See logs for more details.
```

**cause.** homepage 16.2.6 refuses any request whose `Host` header is not
in `HOMEPAGE_ALLOWED_HOSTS`. only `localhost:3000` and `127.0.0.1:3000` are
allowed by default.

**diagnosis.** the log names the exact rejected value, including the port:

```bash
docker logs --tail 20 homepage | grep -i "host validation"
```

**fix.** add every access path to the variable in the compose file. the
value must match the log output exactly. see 02.

**note.** this error masks every other homepage fault, because no page ever
renders. fix it first, then judge whether the configuration is correct.

---

## homepage: dashboard loads but is empty

**cause.** the `/app/config` mount points at a directory with no service
definitions.

**diagnosis.**

```bash
docker inspect homepage --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
ls /docker/homepage/ /docker/homepage/config/
```

the authored files are `services.yaml`, `bookmarks.yaml`, `widgets.yaml`,
`docker.yaml`, `proxmox.yaml`. whichever directory holds those is the one
to mount.

**fix.** mount `/docker/homepage`, not `/docker/homepage/config`.

---

## homepage: a tile shows NOT FOUND or EXITED

these mean different things and it matters.

**NOT FOUND** means homepage cannot find a container by that name. either
the name in `services.yaml` is wrong, or the container does not exist. all
six parked services report NOT FOUND once their containers are removed, and
that is correct.

**EXITED** means homepage found the container and it is stopped. so the
docker endpoint works and the service is genuinely down.

check the name and the host:

```bash
grep -n -A6 "<Tile Name>" /docker/homepage/services.yaml
docker ps -a --filter name=<container> --format '{{.Names}}\t{{.Status}}'
```

`server:` must name an endpoint from `docker.yaml`. amy uses the local
socket. bender is reached through dockerproxy at 10.30.0.12:2375.

---

## oxidized: no backups, container restarting

**symptom.** the log repeats one line:

```
A server is already running. Check /tmp/oxidized.pid
```

**cause, layered.** the visible fault is a stale pid file. the underlying
fault is why the process died. check the crash files, not the log:

```bash
docker exec oxidized ls -la /home/oxidized/.config/oxidized/crashes/
docker exec oxidized cat /home/oxidized/.config/oxidized/crashes/<ip>
```

the crash file names the oxidized version in its stack trace. compare it
against the version in an older crash file. a difference means the image
drifted.

**the 2026-08-08 case.** 0.37.0 passes `max_window_size` to
`Net::SSH.start`, and the bundled net-ssh 7.3.0 rejects unknown options
with `ArgumentError`. every fetch died. the image is now pinned to 0.36.0.

**note.** `docker restart` does NOT clear a stale pid file, because the
file lives in the container's writable layer and restart reuses it. only a
recreate clears it:

```bash
docker rm -f oxidized && docker compose up -d oxidized
```

**note.** the git repository and the GitHub push are independent. local
commits can exist while the push fails silently. test the push directly:

```bash
docker exec oxidized git --git-dir=/home/oxidized/.config/oxidized/nod-config.git push origin HEAD
```

---

## keepalived: restart loop after an image change

**symptom.** the log reports a non-existent interface and addresses you do
not recognize:

```
WARNING - interface eth0 for vrrp_instance VI_1 doesn't exist
Default interface eth0 doesn't exist for static address 192.168.1.231
Keepalived_vrrp exited with permanent error CONFIG. Terminating
```

those addresses are the osixia image's own examples. so keepalived is
reading its default config, not yours.

**cause.** the config path differs between versions. 2.3.4 reads
`/etc/keepalived/keepalived.conf`. 2.0.20 reads
`/usr/local/etc/keepalived/keepalived.conf`. amy mounts the former.

**diagnosis.** the log's own first lines name the file it opened:

```bash
docker logs keepalived | grep -i "opening file\|configuration file"
```

**fix.** pin the version that matches the mount. amy uses a digest for
2.3.4.

**note.** DNS does not fail during this. bender holds the VIP as MASTER, so
`10.30.0.2` keeps answering. that makes the fault quiet, which is why the
log check matters.

**healthy state on amy:**

```
(PIHOLE_VIP) Entering BACKUP STATE (init)
VRRP_Script(chk_pihole) succeeded
```

amy must NOT hold the VIP. confirm with `ip addr show | grep 10.30.0.2`,
which should return only amy's own 10.30.0.11.

---

## root filesystem filling

the 2026-08-08 incident took / from 97% to 60%. the causes, in order of
size:

```bash
df -h /
docker system df
du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -12
du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -h | tail -5
```

**docker images.** 108 images with 16.94 GB reclaimable. `docker image
prune -a -f` recovers it. note that this also deletes the `:backup-N`
rollback tags. see 04.

**container json logs.** a tsdproxy error loop wrote 211 MB. truncate with
`truncate -s 0 <path>`. the permanent fix is log rotation. see 04.

**the bender replica.** `/docker/backups/bender-replica` is bender's
nightly copy and the largest single tree. do not delete it casually.

**a warning about measuring it.** the replica uses hardlinks, so `du` per
directory is misleading. the same data is shared across snapshots, and
whichever directory `du` walks first appears to own all of it. deleting a
"31 GB" snapshot recovered only about 3 GB. use `df` before and after to
measure the real gain.

**a coupling worth knowing.** bender-replicate.sh refuses to run when amy
has less than 10 GB free, and reports the abort to the `bender-backup` ntfy
topic. so amy's disk state gates bender's backups. four nights failed
silently in July under the old 5 GB threshold, because nobody was
subscribed to that topic.

---

## historical fixes reference

versions through v104 are the original sequential counters. the date-based scheme (`YYYYMMDD`) was drafted for 20260721 but that release was delivered as a patch script and never applied, so the compose header stayed at 104 until 20260810. same-day edits append `.2`.

| version | issue | fix |
|---------|-------|-----|
| v85.3 | argus, limdius wrong images; mealie on sqlite | images corrected; mealie → postgres |
| v86 | sss missing /files mount + SALT | mount + SSS_SALT added |
| v91 | unauthorized lubelogger SMTP config | removed; minimal config is the approved state |
| v92 | vaultwarden on the wrong host | migrated to bender |
| v93 | services bypassing local DNS | DNS anchor added to all utility-network services |
| v94 | postgres pointed at empty /docker path – databases "gone" | restored /portainer/postgresql/data (canonical); MINIFLUX_ADMIN_USERNAME fixed; broken curl/wget healthchecks removed (filebrowser, tsdproxy) |
| v95 | sss config lost on recreation | /config mount added |
| v96 | stirling, mealie, netalertx broken images/volumes/caps | stirlingtools image; mealie ghcr image; netalertx volume + NET_* caps |
| v97 | stirling "DPI exceeds maximum safe limit of 0" | SYSTEM_MAXDPI=1200 |
| v98 | telegraf orphaned in a separate compose | consolidated (legacy config path kept); cadvisor resource flags |
| v99 | atuin "server start" no longer exists | command → `start` (upstream binary rename) |
| v100 | – | tax-calculator added (static nginx site) |
| v101 | tsdproxy silent auth failure | TSNET_FORCE_LOGIN=1 |
| v102 | – | oxidized added (nod config → GitHub hourly) |
| v103 | miniflux cross-origin login failures | BASE_URL=http://rss.home.arpa:8385 + DISABLE_HTTP_ORIGIN_CHECK=1 |
| v104 | tsnet re-auth failing after reboot; proxies routing to dead pre-migration IP | TS_AUTHKEY added; AMY_HOST_IP → 10.30.0.11 |
| 20260721 | – | NEVER APPLIED. delivered as a patch script that was not run. its two changes landed in 20260810 instead. |
| 20260808 | oxidized produced no backups since 2026-06-10; container in a restart loop | image had drifted `:latest` → 0.37.0, which passes `max_window_size` to `Net::SSH.start`; net-ssh 7.3.0 rejects unknown options with ArgumentError, so every fetch died. pinned 0.36.0. a stale `/tmp/oxidized.pid` held the restart loop; `docker restart` does not clear it, only a recreate does. |
| 20260808 | oxidized pushed nothing to GitHub since mid-May | local commits existed, the push was failing separately. fixed with the pin; both faults were independent. |
| 20260808 | tsdproxy names unreachable after the auth-key rotation | the rotation was applied to `/portainer/tsdproxy/`, a DECOY directory from the Portainer era that nothing reads. the live path is `/docker/tsdproxy/config/`. the v3 beta reads `authKey` from the yaml, so the key exists in three places that must agree. |
| 20260808 | root filesystem at 97% | 108 docker images with 16.94 GB reclaimable, plus a 211 MB tsdproxy json log from the error loop. pruned to 60%. NOTE: the prune also deleted the `:backup-N` rollback tags the update system keeps. |
| 20260810 | keepalived restart loop after pinning to the 2.0.20 tag | 2.0.20 reads `/usr/local/etc/keepalived/keepalived.conf`, not `/etc/keepalived/`, so it ignored amy's mount and loaded the image's example config (interface eth0, addresses 192.168.1.231/.232). DNS never failed because bender holds the VIP. reverted, then pinned by digest to 2.3.4. |
| 20260810 | homepage returned "Host validation failed. See logs for more details." | homepage 16.2.6 refuses any Host header not in `HOMEPAGE_ALLOWED_HOSTS`. only localhost:3000 and 127.0.0.1:3000 are allowed by default. added all three access paths. |
| 20260810 | homepage dashboard empty once host validation passed | the mount pointed at `/docker/homepage/config`, which held only generated defaults. the authored files (services.yaml, bookmarks.yaml, widgets.yaml, docker.yaml, proxmox.yaml) sit one level up. mount corrected to `/docker/homepage`. |
| 20260810 | four homepage tiles wrong | stirling container name `stirling-pdf` → `stirling`; vaultwarden server `amy` → `bender` and href → 10.30.0.12:8484 (moved in v92); filebrowser icon `sh-filebrowser` → `sh-file-browser`; lubelogger href port 8987 → 8989. |
| 20260810 | six services restarted on every `docker compose up -d` despite being stopped by hand | `profiles: ["parked"]` added, so the parked state is configuration rather than a manual act. |
| 2026-07 | – | became bender's replica target (/docker/backups/bender-replica) |

---

*previous: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
