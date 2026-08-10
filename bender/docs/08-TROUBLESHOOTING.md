# bender troubleshooting guide

## diagnostic procedures and common fixes

**document version:** 5.0
**infrastructure version:** 20260809
**last updated:** august 2026

---

## table of contents

1. [quick diagnostics](#quick-diagnostics)
2. [container issues](#container-issues)
3. [VPN and download issues](#vpn-and-download-issues)
4. [autoheal issues](#autoheal-issues)
5. [postgresql issues](#postgresql-issues)
6. [DNS and networking issues](#dns-and-networking-issues)
7. [immich issues](#immich-issues)
8. [jellyfin issues](#jellyfin-issues)
9. [ARR stack issues](#arr-stack-issues)
10. [forgejo issues](#forgejo-issues)
11. [vikunja issues](#vikunja-issues)
12. [TTS pipeline issues](#tts-pipeline-issues)
13. [transmission issues](#transmission-issues)
14. [update system issues](#update-system-issues)
15. [replication issues](#replication-issues)
16. [SMART monitoring issues](#smart-monitoring-issues)
17. [monitoring issues](#monitoring-issues)
18. [TrueNAS-specific issues](#truenas-specific-issues)
19. [historical fixes reference](#historical-fixes-reference)

---

## quick diagnostics

### first response checklist

```bash
cd /mnt/BIG/filme/docker-compose

# 1. how many containers are running vs expected?
docker compose ps --format "{{.Names}}" | wc -l
# expected: 39 (all active services in 20260721)

# 2. which containers are NOT running?
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"

# 3. any containers restarting?
docker ps -a --format "{{.Names}}\t{{.Status}}" | grep -i "restarting"

# 4. any containers unhealthy?
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "unhealthy"

# 5. VPN connected?
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null | head -3

# 6. DNS answering via the VIP?
dig @10.30.0.2 google.com +short

# 7. disk space ok?
df -h /mnt/BIG/

# 8. ZFS pool healthy?
zpool status BIG | head -10

# 9. system resources ok? (Gen8 comfortable below load 4.0)
free -h && uptime
```

### health check suite

```bash
# full postgresql check
bash /mnt/BIG/filme/docker-compose/scripts/health-checks.sh postgres

# specific container
bash /mnt/BIG/filme/docker-compose/scripts/health-checks.sh container jellyfin

# all containers
bash /mnt/BIG/filme/docker-compose/scripts/health-checks.sh all
```

(noexec pool – the `bash` prefix is load-bearing. the old copy-to-/tmp incantation is retired.)

---

## container issues

### container won't start

```bash
docker inspect <container> --format '{{.State.ExitCode}}'
docker logs <container> --tail 50

# common exit codes:
# 1   – application error (check logs)
# 126 – permission denied on entrypoint
# 127 – entrypoint not found (wrong image?)
# 137 – killed by OOM or docker stop
# 139 – segfault
# 143 – SIGTERM (graceful stop)
```

### container keeps restarting

```bash
docker inspect <container> --format '{{.RestartCount}}'
docker inspect <container> --format '{{.State.OOMKilled}}'
docker stats --no-stream <container>
docker logs <container> --tail 100 -t
```

### env change "didn't apply" / service still uses the old secret

`up -d` does NOT recreate a container on env-file change. this is the single most common self-inflicted issue:

```bash
docker compose up -d --force-recreate <service>

# verify with inspect (NOT docker exec env – that shows the shell's view):
docker inspect <service> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep <VAR>
```

### orphaned containers warning

```bash
docker compose ps -a --format "{{.Names}}" | sort > /tmp/compose.txt
docker ps -a --format "{{.Names}}" | sort > /tmp/docker.txt
diff /tmp/compose.txt /tmp/docker.txt

docker rm -f <orphan_name>
docker compose up -d --remove-orphans
```

---

## VPN and download issues

### gluetun won't connect

```bash
docker logs gluetun --tail 50

# common issues:
# "auth failed" → credentials expired, update SURFSHARK_OPENVPN_USER/PASSWORD in .env
#                 then force-recreate gluetun AND its 8 tenants
# "connection refused" → Surfshark server down, try different country
# "tun device not available" → /dev/net/tun missing, check device mount

# verify credentials landed (inspect, not exec):
docker inspect gluetun --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i openvpn
```

### gluetun healthy but no internet in VPN containers

```bash
docker exec gluetun wget -qO- http://ipinfo.io
docker exec transmission curl -s http://ipinfo.io 2>/dev/null || echo "no connectivity"
docker exec gluetun nslookup google.com
```

### VPN tenants "Up" but unreachable (orphaned namespace)

the signature failure: gluetun was recreated (update, credential change, manual recreate) and transmission/ARR apps show "Up" but nothing answers on their ports. containers attached to a destroyed network namespace never self-recover:

```bash
cd /mnt/BIG/filme/docker-compose
docker compose up -d --force-recreate transmission prowlarr sonarr radarr lidarr readarr bazarr jdownloader
```

the v1.3 update pipeline does this automatically after gluetun updates; every **manual** gluetun recreation must be followed by it. this failure mode also presented as "transmission not binding on 9091 despite running" during the 25.10.3.1-era debugging – resolved by the reboot cycle plus tenant recreation.

### stale VPN session (connected but no traffic)

the scenario autoheal exists for (v106):

```bash
docker inspect gluetun --format '{{.State.Health.Status}}'
# unhealthy → autoheal restarts within 60s
docker logs autoheal --tail 10

# manual fallback:
docker restart gluetun && sleep 30
docker exec gluetun wget -qO- http://ipinfo.io 2>/dev/null | head -3
```

### public IP shows real IP instead of VPN

```bash
docker exec gluetun wget -qO- http://ipinfo.io
docker logs gluetun --tail 30 | grep -i "error\|fail\|disconnect"
docker restart gluetun
```

---

## autoheal issues

### autoheal not restarting unhealthy containers

```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep autoheal
docker inspect gluetun --format '{{index .Config.Labels "autoheal"}}'   # → true
docker logs autoheal --tail 20
docker inspect autoheal --format '{{json .Config.Env}}' | jq .
# AUTOHEAL_CONTAINER_LABEL=autoheal, AUTOHEAL_INTERVAL=60
```

### autoheal restarting gluetun in a loop

a fundamentally broken gluetun restarts every ~4 minutes forever:

```bash
docker inspect gluetun --format '{{.RestartCount}}'
docker logs gluetun --tail 50

# root causes: expired Surfshark credentials (.env), blocked server country, network outage
docker stop autoheal          # pause the loop while debugging
# fix the cause, then:
docker compose up -d gluetun autoheal
# and recreate the 8 tenants (see orphaned namespace above)
```

---

## postgresql issues

### postgres won't start

```bash
docker logs postgres --tail 50

# "database files are incompatible" → major version mismatch (wrong image tag?)
# "could not access directory" → permission issue on the data path
# "shared_preload_libraries" → vchord/vectors extension file missing (wrong image?)

df -h /mnt/BIG/
ls -la /mnt/BIG/filme/immich/postgresql/
```

### postgres out of disk space

```bash
docker exec postgres du -sh /var/lib/postgresql/data/pg_wal/
docker exec postgres psql -U postgres -c "CHECKPOINT;"
docker exec postgres psql -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) FROM pg_database ORDER BY pg_database_size(pg_database.datname) DESC;"
```

### per-tenant access checks (all five databases)

```bash
# immich – note the quoted "user" table (reserved keyword)
docker exec postgres psql -U postgres -d immich -c 'SELECT COUNT(*) FROM "user";'

# hedgedoc
docker exec postgres psql -U postgres -d hedgedoc -c "SELECT 1;"

# baikal
docker exec postgres psql -U postgres -d baikal -c "SELECT 1;"

# vikunja
docker exec postgres psql -U postgres -d vikunja -c 'SELECT COUNT(*) FROM tasks;'

# forgejo – MUST authenticate as the dedicated user; success proves per-user auth
docker exec postgres psql -U forgejo -d forgejo -c 'SELECT COUNT(*) FROM repository;'
```

### forgejo can't reach its database

```bash
# password mismatch between .env and the postgres user is the usual cause:
docker exec -it postgres psql -U postgres -c "ALTER USER forgejo WITH PASSWORD '<FORGEJO_DB_PASSWORD from .env>';"
docker compose up -d --force-recreate forgejo
```

### locked queries

```bash
docker exec postgres psql -U postgres -c "SELECT pid, state, query FROM pg_stat_activity WHERE state != 'idle';"
```

---

## DNS and networking issues

### pihole not responding

```bash
docker ps | grep pihole
docker logs pihole --tail 20

dig @127.0.0.1 google.com +short
dig @10.30.0.12 google.com +short
dig @10.30.0.2 google.com +short     # via the VIP

curl -s -o /dev/null -w "%{http_code}" http://localhost:8053/admin/
docker restart pihole
```

### keepalived VIP missing

```bash
# VIP lives on the 10G interface
ip addr show ens1f0 | grep 10.30.0.2

docker logs keepalived --tail 20
docker exec keepalived cat /container/service/keepalived/assets/keepalived.conf

docker restart keepalived
ip addr show ens1f0 | grep 10.30.0.2
```

if bender's pihole is genuinely down, amy should claim the VIP within ~5 seconds – clients keep resolving either way.

### DNS auto-population not working

```bash
# the scraper is hourly and hash-guarded; run it manually for immediate effect:
bash /mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh

# SSH to amy must work (amy container labels):
ssh -o ConnectTimeout=5 -o BatchMode=yes kube@10.30.0.11 "docker ps -q | wc -l"

# inspect the current hosts array and state hash:
grep -A 50 "hosts = \[" /mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml | head -60
cat /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state

# a new tsdproxy name resolves after the script runs:
dig <name>.home.arpa @10.30.0.2 +short
```

static entries (the homeassistant pair – LAN 10.30.0.41 and the tailscale address) are maintained at the top of the script itself; they survive every regeneration because the script writes them first.

### nebula-sync not replicating

```bash
docker logs nebula-sync --tail 20
# healthcheck is disabled by design (minimal container has no binaries)
# verify by timestamp on amy:
ssh kube@10.30.0.11 "ls -la /docker/pihole/etc-pihole/pihole.toml"
```

### host unreachable / traffic silently dropped after cabling work

the eno1 precedent: bender's onboard NIC was patched into a mislabeled switch port and silently carried (and dropped) 150+ Mb/s. if bender's connectivity degrades after any physical work:

```bash
ip route | head -3                 # default route must be via ens1f0
ip -s link show eno1               # should be DOWN with no traffic counters moving
```

the switch port for eno1 is administratively down; it stays that way.

---

## immich issues

### photos not uploading

```bash
docker logs immich_server --tail 30
ls -la /mnt/BIG/filme/immich/photos/
curl -s http://localhost:2283/api/server/ping
docker exec postgres psql -U postgres -d immich -c "SELECT 1;"
```

### machine learning not working

```bash
docker logs immich_machine_learning --tail 30
docker inspect immich_machine_learning --format '{{.State.Health.Status}}'
du -sh /mnt/BIG/filme/immich/ml-cache/
docker restart immich_machine_learning
```

### high load / OOM during bulk uploads

the v112 incident (load 10.96, txg_sync stalls >120s) is contained by the resource limits and job concurrency 1. if it recurs:

```bash
docker stats --no-stream immich_server immich_machine_learning
# verify limits are active:
docker inspect immich_server --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}'
# verify job concurrency = 1 in Admin UI → Settings → Job Settings
# (stored in the database – resets are possible after restores)
```

### redis errors ("Can't handle RDB format version")

fixed in v94 (redis:6.2 → 7-alpine). if it recurs, verify the image:

```bash
docker exec immich_redis redis-server --version   # must be 7.x
```

---

## jellyfin issues

### library path errors ("Access to path denied")

fixed in 20260721 (`/data/tv` → `/data/tvshows`):

```bash
docker inspect jellyfin --format '{{json .Mounts}}' | jq '.[].Destination'
# should show /data/movies, /data/tvshows, /data/music (NOT /data/tv)
docker compose up -d --force-recreate jellyfin
```

### jellyfin "never updates"

by design – the image is pinned to `10.11.11` (v114). the floating 10.11 tag does not exist on lscr.io. to take a patch:

```bash
# edit the tag in docker-compose.yaml (e.g. 10.11.12), bump header + changelog, then:
docker compose pull jellyfin && docker compose up -d jellyfin
```

Diun's blind spot: it announces re-pushes of the pinned tag, not new sibling tags – check linuxserver's tag list when a patch is rumored. NEVER move to major 12 casually.

### no hardware transcoding

known hardware limitation – HP BIOS disables the Xeon iGPU:

```bash
ls -la /dev/dri/ 2>/dev/null || echo "no GPU devices"
# the GPU section stays commented in docker-compose.yaml for future hardware
```

---

## ARR stack issues

### all ARR apps unreachable

if prowlarr, sonarr, radarr, lidarr, readarr, and bazarr are all down simultaneously, the issue is gluetun – see [VPN and download issues](#vpn-and-download-issues), including the orphaned-namespace recovery.

### single ARR app not responding

```bash
docker logs <app_name> --tail 30
docker compose restart <app_name>
```

### unpackerr not extracting

```bash
docker logs unpackerr --tail 30
grep -E "SONARR_API_KEY|RADARR_API_KEY" /mnt/BIG/filme/docker-compose/.env
docker exec unpackerr wget -qO- http://gluetun:8989/api/v3/system/status 2>/dev/null | head -5
```

---

## forgejo issues

### web UI unreachable

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:3030   # expect 200
docker logs forgejo --tail 30
dig git.home.arpa @10.30.0.2 +short                            # DNS entry present?
```

### database connection failures

see [forgejo can't reach its database](#forgejo-cant-reach-its-database) – the dedicated-user password must match `.env`, and env changes require force-recreate.

### push rejected / repo "not found" on first push

push-to-create is disabled. create the repository in the web UI (uninitialized) first, then push.

### SSH clone/push fails

```bash
# git SSH is on 2222, not 22:
ssh -T -p 2222 git@git.home.arpa
# clone form: ssh://git@git.home.arpa:2222/<user>/<repo>.git
```

### admin lockout

```bash
docker exec -u 1000 forgejo forgejo admin user change-password --username <admin> --password '<new>'
```

### upgraded past v15 accidentally

should be impossible via the pipeline (rolling :15 tag) – if the tag was edited by mistake, restore the previous image via rollback.sh and read the Forgejo migration notes before retrying deliberately.

---

## vikunja issues

### users logged out with "malformed token" / sessions not sticking

the v114 saga – three causes, all must hold:

1. **origin match:** `VIKUNJA_SERVICE_PUBLICURL` must equal the URL actually browsed (`http://tasks.home.arpa:3456`). browsing via the tailscale URL breaks sessions by design of the app.
2. **real hex secret:** `VIKUNJA_JWT_SECRET` must be a genuine `openssl rand -hex 32` value – base64 characters or placeholder values corrupt/invalidate tokens.
3. **recreation applied:** any change to the above reaches the container only via `docker compose up -d --force-recreate vikunja` (verify with docker inspect).

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:3456/api/v1/info   # expect 200
docker inspect vikunja --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E "PUBLICURL|JWT"
```

note: changing the JWT secret logs everyone out once – expected.

### tasks database sanity

```bash
docker exec postgres psql -U postgres -d vikunja -c 'SELECT COUNT(*) FROM tasks;'
```

---

## TTS pipeline issues

### lrrr not converting files

```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep lrrr
docker logs lrrr --tail 50
ls -la /mnt/BIG/filme/tts/input/

# edge-tts API up?
curl -s http://localhost:5050/v1/models | head -5

# direct synthesis test
curl -s -X POST http://localhost:5050/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input":"test","voice":"ro-RO-AlinaNeural"}' \
  -o /tmp/test.mp3 && echo "TTS working" || echo "TTS failed"
rm -f /tmp/test.mp3
```

### web UI not accessible

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:5051   # expect 200
docker logs lrrr --tail 30 | grep -i "flask\|error\|traceback"

# rebuild after changes to webapp.py / start.sh / pipeline.sh
cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache lrrr && docker compose up -d lrrr
```

### edge-tts API errors

```bash
docker logs edge-tts --tail 20
# "429 Too Many Requests" → Microsoft rate limit, wait and retry
# memory limit (512 MB) → docker stats edge-tts
docker restart edge-tts
```

### output not appearing in audiobookshelf

```bash
ls -lt /mnt/BIG/filme/audiobookshelf/audiobooks/cărți/ | head -5
docker logs lrrr --tail 50 | grep -i "output\|complete\|error"
docker exec audiobookshelf ls /audiobooks/ | head -10
# force a library scan via the audiobookshelf web UI if needed
```

---

## transmission issues

### Flood UI not loading

```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep transmission
docker logs transmission --tail 30 | grep -i "flood\|web"
docker inspect transmission --format '{{range .Config.Env}}{{println .}}{{end}}' | grep WEB_HOME
# → TRANSMISSION_WEB_HOME=/flood-for-transmission/

cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache transmission && docker compose up -d transmission
```

### transmission running but port 9091 dead

this is the gluetun namespace problem wearing a transmission costume – see [VPN tenants "Up" but unreachable](#vpn-tenants-up-but-unreachable-orphaned-namespace). recreate gluetun's tenants; if the whole host just rebooted, recreate them anyway.

### transmission causing system slowdowns

```bash
docker exec transmission transmission-remote -l 2>/dev/null | wc -l
iostat -x 1 3
docker inspect transmission --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -iE "queue|cache|peer"
# limits missing → redeploy:
docker compose up -d --force-recreate transmission
```

### FileList tracker issues

transmission is pinned to 4.0.5 – do NOT upgrade:

```bash
docker exec transmission transmission-remote -V 2>/dev/null || docker logs transmission | grep -i version | head -3
# if accidentally upgraded: fix the Dockerfile FROM line, then
docker compose build --no-cache transmission && docker compose up -d transmission
```

---

## update system issues

### weekly scan not running

```bash
# the schedule lives in the TrueNAS UI: System → Advanced → Cron Jobs (verify against 07's table)
ls -lt /mnt/BIG/filme/docker-compose/configs/secure-update/logs/ | head -3

# run manually
bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh status
bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh weekly
```

if the job vanished, a TrueNAS upgrade or a stray `crontab -e` habit is the suspect – only UI-defined jobs persist.

### container stuck in retry queue

```bash
cat /mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json
bash /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh scan <container_name>

# manual clear if justified:
echo '{"containers": []}' > /mnt/BIG/filme/docker-compose/configs/secure-update/retry-queue.json
```

### trivy scan timeout

```bash
curl -s http://localhost:8083/healthz
docker logs trivy --tail 20
docker restart trivy    # clears a corrupt cache
```

note the standing audit item: the script's `TRIVY_SERVER` constant historically said `localhost:8082` while the container publishes on 8083 – scans worked via the containerized fallback path. if scans slow down or fail oddly, check which path is being taken. <!-- VERIFY: v1.3 constant -->

---

## replication issues

### nightly run failed / no fresh replica on amy

```bash
# read the latest replication log
ls -lt /mnt/BIG/filme/docker-compose/configs/secure-update/logs/ | grep -i replicate | head -3

# SSH trust intact?
ssh -o BatchMode=yes kube@10.30.0.11 true && echo "SSH OK"

# destination exists with kube ownership?
ssh kube@10.30.0.11 'ls -ld /docker/backups/bender-replica'

# manual run with live output
bash /mnt/BIG/filme/docker-compose/scripts/bender-replicate.sh
```

failure also pushes an ntfy alert; a silent night with no log entry means the cron itself didn't fire – check the UI cron table.

### replica missing expected content

media libraries, download data, and caches are excluded **by design**. configs, postgres dumps, and the docker-compose tree must be present; anything else missing means the exclusion list needs review in the script.

---

## SMART monitoring issues

### "FAILED to start short test" / "Can't start self-test (N% remaining)"

a self-test is already running on that disk – this is a **correct skip**, not a failure (v1.1 classifies it properly; v1.0 did not):

```bash
smartctl -c /dev/sdX | grep -A2 "Self-test execution"
```

never force-abort a running test to start another.

### SMART cron failing with midclt/EFAULT

that is the 25.10 auto-converted fossil – delete it from the UI cron list. smart-test.sh is the replacement; the fossil must never be recreated.

### report alerts after replacing a disk

expected once: the new disk has no baseline, so the first report creates one. baselines are keyed by model_serial in `configs/secure-update/smart-state/` – device-letter changes alone never reset them.

### attribute increase alert received

```bash
bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh status
smartctl -a /dev/sdX
zpool status BIG
```

reallocated/pending/offline-uncorrectable increases mean plan a disk replacement; CRC errors (199) usually mean reseat the cable or backplane connection first.

---

## monitoring issues

### grafana dashboard shows no data

the pipeline is: cadvisor (bender 10.30.0.12:9099) → prometheus (HA VM 10.30.0.41:9090) → grafana

```bash
# 1. cadvisor answering?
curl -s http://localhost:9099/metrics | head -5

# 2. prometheus scrape targets on the HA VM must list 10.30.0.12:9099 –
#    any lingering 192.168.21.x target returns nothing since the v113 migration

# 3. dashboard `instance` variable: Constant type, value 10.30.0.12:9099
#    (amy's dashboard: 10.30.0.11:9099). Query-type variables pick up the wrong host.
```

### beszel-agent not reporting

```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep beszel-agent
docker logs beszel-agent --tail 20
docker inspect beszel-agent --format '{{json .Config.Env}}' | grep KEY
curl -s -o /dev/null -w "%{http_code}" http://10.30.0.11:8090   # hub on amy
```

---

## TrueNAS-specific issues

### scripts won't execute from /mnt

by design – the pool is noexec. invoke with bash; never copy to /tmp anymore:

```bash
bash /mnt/BIG/filme/docker-compose/scripts/<script>.sh <args>
```

### cron jobs missing after a TrueNAS upgrade

verify all **seven** UI jobs against the table in [07-MAINTENANCE.md](./07-MAINTENANCE.md). UI jobs should survive; anything scheduled via `crontab -e` will not (the 2026-07 crontab loss is the precedent). while on that screen: no `midclt disk.smart_test` entries, no HeavyScript entry – fossils stay deleted.

### TrueNAS upgrade ate something

symptoms: scripts gone from /root (HeavyScript precedent), root crontab empty, apt broken. recovery: UI cron jobs should have survived (verify); re-run the post-init script (or `install-dev-tools`) if apt fails – 25.10.x wants the **bookworm** repo; restore any /root content from the amy replica – and relocate it onto the pool where it belongs.

### apt refuses to install packages

```bash
# developer mode reverted after an upgrade – the Pre Init script should re-apply it;
# manual: install-dev-tools, then ensure the bookworm repo line exists in sources.list
# GRUB and TrueNAS-managed python packages are NEVER upgraded via apt – they arrive
# with TrueNAS system updates only
```

### SMB shares unreachable

precedent: SMB was found bound to 127.0.0.1 only. fix:

```bash
midclt call smb.update '{"bindip": []}'    # bind all interfaces
```

### DMAR faults / system freezes

HP iLO DMAR interrupt faults escalate ZFS I/O stalls into hard freezes. fixed in v107 via GRUB:

```bash
cat /proc/cmdline | grep -o 'intel_iommu=[a-z]*'
# should show: intel_iommu=off – if reset after an upgrade, re-apply via the MicroSD GRUB config
```

### ZFS pool degraded

```bash
zpool status BIG
zpool status BIG | grep -E "DEGRADED|FAULTED|UNAVAIL"
bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh status
smartctl -a /dev/sdX
```

---

## historical fixes reference

versioned rows are dated by their compose changelog entries. the 2026-xx incident rows (below the version rows) are reconstructed from session context and TrueNAS version breadcrumbs – the events and fixes are verified, the month attributions are best-effort. from 2026-07-21 the version scheme is date-based (`YYYYMMDD`, harmonized across hosts); the 20260721 row was formerly drafted as v116.

| version / date | issue | fix |
|---------------|-------|-----|
| v94 | immich_redis "Can't handle RDB format version 11" | redis:6.2-alpine → redis:7-alpine |
| v94 | readarr wrong image | pinned linuxserver/readarr:0.4.19-nightly |
| v94 | spotdl wrong image | corrected to spotdl/spotify-downloader:latest |
| v94 | hedgedoc healthcheck fails (no curl) | Node.js-based healthcheck |
| v96 | jellyfin wrong image source | corrected to lscr.io/linuxserver/jellyfin |
| v101 | v100 corrupted – missing services, wrong configs | restored v96 base + approved v97–v100 changes |
| v102–v103 | qBittorrent hard crashes (ZFS I/O pattern) | reverted to transmission, pinned 4.0.5 (FileList) |
| v104 | WireGuard blocked outbound peers on all Surfshark servers | gluetun switched to OpenVPN |
| v104 | immich_ml healthcheck fails (no curl) | python3-based healthcheck |
| v104 | nebula-sync healthcheck fails (no binaries) | healthcheck disabled |
| 20260721 | jellyfin "Access to /data/tvshows denied" | /data/tvshows mount added, /data/tv removed |
| v106 | stale VPN sessions silently block downloads | autoheal + IP-based gluetun healthcheck |
| v107 | 812-torrent I/O stampede freezes system | transmission queue/cache/peer limits |
| v107 | HP iLO DMAR faults cause hard freezes | intel_iommu=off in GRUB |
| v108 | linuxserver Flood mod downloads on every restart | custom transmission build, pre-baked Flood UI |
| v110 | – | baikal CalDAV/CardDAV added (postgres tenant) |
| v111 | – | vikunja added (postgres tenant, JWT secret in .env) |
| v112 | immich OOM, load 10.96, txg_sync stalls | resource caps + job concurrency 1 |
| v113 | subnet migration | 10.30.0.0/24; VIP → 10.30.0.2; keepalived → ens1f0; tts-pipeline → lrrr |
| v114 | vikunja session chaos (malformed-token logouts) | real hex JWT secret, PUBLICURL = browsed origin, extended TTLs; jellyfin pin 10.11.11 documented |
| v115 | – | forgejo added: :15 LTS, dedicated pg user, ports 3030/2222, backup + replication coverage |
| 20260721 | – | postgres-backup pinned :14 (major-matched to postgres 14); .env drops redundant TS_AUTHKEY |
| 2026-05 | eno1 on mislabeled switch port silently dropping 150+ Mb/s (load 9–10) | port Gi1/0/7 shut, ARP cleared, default route confirmed on ens1f0 (load → 0.37) |
| 2026-05 | SMB bound to 127.0.0.1 only | `midclt call smb.update '{"bindip": []}'` |
| 2026-05/07 | pihole-dns-update stale IPs, then static HA entries needed | v3.1 (IP migration) → v3.2 (homeassistant static entries); later moved to hourly UI cron |
| 2026-06 | apt blocked; packages lost to upgrades | developer mode via install-dev-tools + bookworm repo + idempotent Pre Init script |
| 2026-06/07 | transmission "Up" but 9091 dead (gluetun namespace) | reboot cycle + tenant recreation; codified as the orphaned-namespace runbook |
| 2026-07 | root crontab silently emptied by upgrade | all seven schedules → TrueNAS UI cron; HeavyScript + midclt fossils deleted |
| 2026-07 | SMART UI removed (25.10), auto-converted crons broken | smart-test.sh v1.1 (middleware-free, state-diff alerts) |
| 2026-07 | no off-host copy of configs/secrets/dumps | bender-replicate.sh nightly replica to amy |
| 2026-07 | update pipeline blind to new tenants + namespace risk | secure-container-update.sh v1.3 (5-tenant tests, gluetun critical) |


---

## influxdb: not accepting connections after a restart

**symptom.** the container is running, but `influx` reports
`connection refused` on 8086.

**cause, usually not a fault.** influxdb opens every shard before it starts
the HTTP listener. that takes minutes.

**diagnosis.** count progress rather than waiting blindly:

```bash
docker logs influxdb 2>&1 | awk '/InfluxDB starting/{n=0} /Opened shard/{n++} END{print n}'
docker logs influxdb 2>&1 | grep -c "Listening on HTTP"
docker stats influxdb --no-stream
```

a rising shard count with CPU near 100 percent means it is working. the
listener count reaching its expected value means it is ready.

**critical.** every restart begins the shard opening from zero. so do not
restart it to "fix" a slow start. that discards all progress.

**if it is genuinely slow rather than merely starting**, check the index
type. an `index_version=inmem` line in the log means the slow path.

```bash
docker exec influxdb ls /var/lib/influxdb/data/homeassistant/autogen/2/
```

an `index` directory means TSI is active.

---

## influxdb: permission denied at first start

**symptom.**

```
run: create server: mkdir all: mkdir /var/lib/influxdb/meta: permission denied
```

**cause.** the data directory is owned by root. the image runs as uid 1500.

**fix.**

```bash
docker compose stop influxdb
chown -R 1500:1500 /mnt/BIG/filme/influxdb
docker compose up -d influxdb
```

note that this is 1500, not the 1000 that forgejo uses. confirm with
`docker run --rm influxdb:1.11 id influxdb`.

---

## Home Assistant reports successful writes, but influxdb receives nothing

this one cost several hours, so the diagnosis order matters.

**the trap.** Home Assistant can log `Wrote N events` while the data lands
somewhere else entirely. a UI config entry in
`.storage/core.config_entries` overrides the `influxdb:` block in
`configuration.yaml`, and the YAML is then read by nothing.

**diagnosis, in this order:**

1. prove the API works, outside Home Assistant, with a manual curl to
   `/write`. a 204 means the network path and credentials are fine.
2. read the config from inside the container, not from the host path you
   edited: `docker exec homeassistant grep -A8 "^influxdb:" /config/configuration.yaml`
3. check for a shadowing config entry:

```bash
docker exec homeassistant python3 -c "
import json
d=json.load(open('/config/.storage/core.config_entries'))
for e in d['data']['entries']:
    if e['domain']=='influxdb':
        print(e.get('title'), json.dumps(e.get('data'))[:200])
"
```

**fix.** delete the UI entry, so `configuration.yaml` becomes the single
source.

**the general rule.** verify configuration from the process that consumes
it, not from the file you edited. this is the fourth instance of that fault
class in this infrastructure, after amy's `/portainer/tsdproxy` decoy, the
Home Assistant add-on data path, and amy's keepalived config path.

**a second trap in the same episode.** a verification probe is only as good
as its vantage point. a `curl` to a tailnet name from a host that is not on
the tailnet fails no matter how healthy the service is. confirm the prober
is on the network being probed before trusting its silence.

---

## oxidized: no backups, container restarting (amy, documented here for cross-reference)

the visible fault is a stale `/tmp/oxidized.pid`. the underlying fault is
why the process died, and the crash files hold that, not the log.

`docker restart` does not clear a stale pid file, because the file lives in
the container's writable layer. only a recreate clears it.

full detail is in amy's 08-TROUBLESHOOTING.

---

## a note on pinned images and silent breakage

two services broke in one week because an unpinned `:latest` moved:
tsdproxy pulled a 3.0 beta, and amy's oxidized pulled a version with an
incompatible SSH option. both failures were silent for weeks.

when a service starts behaving oddly after working for months, check
whether its image changed:

```bash
docker inspect <container> --format '{{.Config.Image}} {{.Image}}'
docker images --digests | grep <image>
docker logs <container> 2>&1 | grep -i version | head -3
```

a version string in the log that differs from what the documentation says
is the answer.

---

*previous: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
