# amy maintenance procedures

## operational runbook

**document version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

---

## table of contents

1. [overview](#overview)
2. [daily operations](#daily-operations)
3. [weekly operations](#weekly-operations)
4. [monthly operations](#monthly-operations)
5. [common tasks](#common-tasks)
6. [compose change procedure](#compose-change-procedure)
7. [replica hosting duties](#replica-hosting-duties)
8. [backup procedures](#backup-procedures)
9. [restore procedures](#restore-procedures)
10. [emergency procedures](#emergency-procedures)
11. [service-specific maintenance](#service-specific-maintenance)
12. [host (Debian) maintenance](#host-debian-maintenance)

---

## overview

amy runs 25 of 31 defined services from a single docker-compose.yaml (20260810.2); six are parked. automation is lighter than bender's – no build containers, no SMART subsystem (single SSD, still worth a manual smartctl habit), no replication *source* duties.

### automated tasks

| task | schedule | system |
|------|----------|--------|
| container vulnerability scan | wednesday 04:30 | secure-container-update.sh weekly (crontab) |
| retry blocked containers | other days 04:30 | secure-container-update.sh retry (crontab) |
| image update notifications | wednesday 04:00 | diun → local ntfy |
| postgresql backup (5 databases) | daily | postgres-backup container (internal @daily) |
| switch config backup | hourly | oxidized → github.com/om1d3/nod-config |
| receive bender's replica | daily 03:30 | (driven from bender) |
| pihole config refresh | hourly | nebula-sync push from bender |

---

## daily operations

```bash
cd /docker-compose

# quick count (expect 31)
docker compose ps --format "{{.Names}}" | wc -l

# non-running / unhealthy
docker compose ps --format "table {{.Names}}\t{{.Status}}" | grep -v "Up"
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i "unhealthy"

# the hub services specifically – silent ntfy is silent everything
curl -s -o /dev/null -w "ntfy: %{http_code}\n" http://localhost:8888
curl -s -o /dev/null -w "beszel: %{http_code}\n" http://localhost:8090
```

---

## weekly operations

### update reports and retry queue

```bash
cat /docker-compose/configs/secure-update/retry-queue.json 2>/dev/null   # path VERIFY (see 04)
./scripts/secure-container-update.sh status
```

### oxidized freshness

```bash
# last commit age on nod-config – hours old is healthy, days old means PAT or reachability
docker logs oxidized --tail 20
curl -s http://localhost:8889/nodes | head -5
```

### replica landing zone

```bash
ls -la /docker/backups/bender-replica/
df -h /                                   # amy's single SSD carries the replica – watch headroom
```

### disk health (manual habit – no smart-test.sh here)

```bash
sudo smartctl -H /dev/sda && sudo smartctl -A /dev/sda | grep -E "Reallocated|Pending|Offline_Unc|CRC"
```

---

## monthly operations

```bash
docker image prune -f
docker builder prune -f

# verify backups: recent, non-empty, all five databases represented
ls -lht /docker/postgres-backup/ | head -10
find /docker/postgres-backup/ -name "*.sql*" -mtime -1 -exec ls -lh {} \;

# debian housekeeping
sudo apt update && apt list --upgradable
```

---

## common tasks

```bash
cd /docker-compose

docker compose restart <service>
docker logs <service> --tail 50

# manual single-container update
docker compose pull <service> && docker compose up -d <service>

# env/compose change (recreation mandatory) + verification
docker compose up -d --force-recreate <service>
docker inspect <service> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep <VAR>
```

---

## compose change procedure

same ritual as bender, minus the TrueNAS ceremony:

1. edit docker-compose.yaml → bump header version + dated changelog entry
2. new secret? add to `.env` (**hex**), sync the .env header version, changelog it
3. `docker compose up -d --force-recreate <changed services>`
4. verify via `docker inspect`
5. update docs, sync futurama-docker (compose + .env.gpg + .env.example + docs), commit together. **count sweep** on service add/remove: `grep -rn "31\|expected:" docs/`
6. new tsdproxy name? it appears in DNS on bender's next hourly scrape (or trigger it from bender: `bash /mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh`), then `dig <name>.home.arpa @10.30.0.2`

---

## replica hosting duties

the entire contract, checked in one block:

```bash
# 1. SSH trust for bender's root key still valid (run FROM bender):
#    ssh -o BatchMode=yes kube@10.30.0.11 true
# 2. destination healthy and owned by kube:
ls -ld /docker/backups/bender-replica && stat -c '%U:%G' /docker/backups/bender-replica
# 3. fresh content (dated within ~24h):
ls -la /docker/backups/bender-replica/docker-compose/
# 4. disk headroom:
df -h /
```

never repurpose, prune, or "organize" that directory from the amy side – retention is managed by bender's script.

---

## backup procedures

### automated postgres backup

```bash
docker ps --format "{{.Names}}\t{{.Status}}" | grep postgres-backup
ls -lht /docker/postgres-backup/ | head -10
```

### manual postgres backup

```bash
docker exec postgres pg_dumpall -U postgres > /docker/postgres-backup/manual-$(date +%Y%m%d).sql
docker exec postgres pg_dump -U postgres sss > /docker/postgres-backup/sss-$(date +%Y%m%d).sql
```

### configuration backup (git repo)

```bash
# on the workstation
cd ~/code/futurama-docker
scp kube@10.30.0.11:/docker-compose/docker-compose.yaml amy/docker-compose.yaml
ssh kube@10.30.0.11 'sudo cat /docker-compose/.env' > /tmp/amy.env   # .env is root-owned; plain scp as kube will fail
gpg --symmetric --cipher-algo AES256 -o amy/.env.gpg /tmp/amy.env
sed 's/=.*/=/' /tmp/amy.env > amy/.env.example    # comments survive – no secrets in comments!
shred -u /tmp/amy.env 2>/dev/null || rm -f /tmp/amy.env
git add . && git commit -m "amy 20260721: <description>" && git push
```

do NOT commit `/docker/keepalived/keepalived.conf` (inline VRRP password) or anything under `/docker/oxidized/` (GitHub PAT) – template them if repo copies are wanted.

---

## restore procedures

### restore a database

```bash
# stop the consumer, restore, start
docker compose stop miniflux
zcat /docker/postgres-backup/<dump>.sql.gz | docker exec -i postgres psql -U postgres -d miniflux
docker compose start miniflux
```

### restore a container image

```bash
./scripts/rollback.sh list ntfy
./scripts/rollback.sh rollback ntfy
./scripts/rollback.sh postgres     # dependent-aware
```

### rebuild amy from zero

1. Debian + docker + compose; create `/docker`, `/docker-compose`, `/portainer/postgresql`, `/portainer/telegraf/config`
2. from the futurama-docker repo: amy compose, `gpg --decrypt .env.gpg` → .env, scripts/
3. recreate the two out-of-band secrets: keepalived.conf (VRRP password matching bender) and oxidized config (fresh PAT)
4. `docker compose up -d postgres` → restore the five databases from `/docker/postgres-backup` (or from off-site) → `docker compose up -d`
5. re-establish kube's authorized_key for bender's root (replication resumes at the next 03:30)
6. re-add root's crontab entries (weekly/retry – see 04)

---

## emergency procedures

### ntfy down (silent infrastructure)

```bash
docker logs ntfy --tail 30
docker compose up -d --force-recreate ntfy
curl -d "test after recovery" http://localhost:8888/test
```

remember: while ntfy is down, bender's alerts are lost, not queued – check bender's logs for anything that fired during the gap.

### pihole VIP behavior

```bash
# does amy currently hold the VIP? (only when bender's pihole is down)
ip addr show enp4s0 | grep 10.30.0.2
docker logs keepalived --tail 20
dig @10.30.0.2 google.com +short
```

amy holding the VIP for long means bender's pihole is genuinely down – fix bender; amy will cede automatically (priority 100 < 200).

### postgres won't start

```bash
docker logs postgres --tail 50
df -h /
ls -la /portainer/postgresql/data/    # the canonical (legacy) path – see the v94 scar
./scripts/rollback.sh postgres
```

---

## service-specific maintenance

### ntfy

```bash
curl -d "ping" http://localhost:8888/test    # then check your phone/browser
```

### beszel

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8090
# both hosts' agents should show recent data in the UI
```

### oxidized

```bash
docker logs oxidized --tail 20
# PAT rotation: GitHub → new fine-grained PAT scoped to nod-config →
# update /docker/oxidized config → docker restart oxidized → verify a push lands
```

### spendspentspent / limdius (browser automation)

```bash
# both consume playwright-chrome – restart the browser first on weirdness:
docker restart playwright-chrome
curl -s -o /dev/null -w "%{http_code}" http://localhost:9021   # sss
curl -s -o /dev/null -w "%{http_code}" http://localhost:5050   # limdius
```

### miniflux

full login works on `http://rss.home.arpa:8385` (the BASE_URL origin, v103) – cross-origin failures on other paths are the documented behavior, not a regression.

### mealie

BASE_URL is the tailscale origin (`https://mealie.bunny-enigmatic.ts.net`) – the inverse choice from miniflux; generated links favor remote use.

### atuin

`command: start` (v99) – if an image update ever fails on "unknown subcommand", upstream moved the binary again; check their changelog before touching the command.

### netalertx / telegraf

host-network monitors; netalertx data under /docker/netalertx, telegraf config at the legacy /portainer path (read-only). after switch or printer changes, telegraf's SNMP targets live in that conf.

---

## host (Debian) maintenance

- **updates:** ordinary `apt update && apt upgrade` cadence; docker engine from Docker's repo. no TrueNAS-style landmines
- **crontab:** root's crontab is the scheduler and persists across upgrades – still, keep the entries mirrored in 04's table so a host rebuild can restore them
- **reboots:** only for kernel updates; verify afterwards: 31 containers up, VIP NOT held (bender healthy), ntfy test message delivered, replica directory intact
- **time:** schedules assume America/Toronto – verify `timedatectl` after installs


---

## working with parked services (20260810)

six services are parked. see 02 for the list and the reasoning.

```bash
# what starts by default
docker compose config --services | wc -l          # 25

# what is defined in total
docker compose --profile parked config --services | wc -l   # 31

# start one parked service on demand
docker compose up -d tax-calculator

# start all six
docker compose --profile parked up -d

# stop and remove one again
docker compose stop tax-calculator && docker compose rm -f tax-calculator
```

`docker compose start <name>` does not work for a parked service. it does
not enable the profile. use `up -d`.

---

## version bump ritual

amy follows bender's convention. every change to the compose file gets a
version and a changelog entry, even a one-line change.

1. back up: `cp docker-compose.yaml docker-compose.yaml.<current>.backup`
2. bump the header to `YYYYMMDD`, or `YYYYMMDD.2` for a second edit the same day
3. add a changelog block at the TOP of the list; amy's changelog is newest first
4. record REQUIRED steps and NOTEs in that block
5. `docker compose config -q`
6. `diff` against the backup and read it
7. apply
8. if the `.env` changed in the same release, bump its header to the same version

two changes were applied by hand on 2026-08-08 without a version bump: the
tsdproxy and oxidized pins. they were recorded retroactively in 20260810.
that gap is the reason for the ritual.

---

## configuration is version controlled

amy does not hold a git checkout. bender is the single committer and
collects amy's files over SSH.

on bender:

```bash
/root/futurama-sync.sh --dry-run     # show what would change
/root/futurama-sync.sh "amy: <what changed>"
```

the script pulls, triggers encryption on both hosts, copies both hosts'
manifest files into a neutral clone, then commits and pushes to forgejo.
forgejo mirrors to GitHub.

secrets never leave their host in plaintext. each host encrypts its own
with `encrypt-secrets.sh`, and only the `.gpg` files are copied.

on amy, files in the manifest include the compose file, `scripts/`,
`configs/`, homepage, ntfy, argus, limdius.py, the tax calculator site, and
telegraf's config. encrypted: `.env`, oxidized's config and router.db,
tsdproxy.yaml, keepalived.conf.

---

## ntfy topics

amy hosts ntfy, and it is the notification endpoint for both hosts.
subscribe to every topic in use, not only the ones you remember:

| topic | producer |
|-------|----------|
| container-updates-bender | bender diun, secure-container-update.sh |
| container-updates-amy | amy diun |
| tts-pipeline | bender audiobook-foundry |
| bender-backup | bender-replicate.sh |

four high-priority backup failures went unseen in July because the
`bender-backup` topic had no subscriber. the script worked correctly and
reported correctly. nobody was listening.

---

*previous: [06-BENEFITS-TRADEOFFS.md](./06-BENEFITS-TRADEOFFS.md)*
*next: [08-TROUBLESHOOTING.md](./08-TROUBLESHOOTING.md)*
