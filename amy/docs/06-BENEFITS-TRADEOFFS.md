# amy benefits and tradeoffs

## design decisions analysis

**document version:** 5.0
**infrastructure version:** 20260810.2
**last updated:** august 2026

---

## table of contents

1. [repurposed laptop as second host](#repurposed-laptop-as-second-host)
2. [amy as the notification and monitoring seat](#amy-as-the-notification-and-monitoring-seat)
3. [amy as bender's replica target](#amy-as-benders-replica-target)
4. [shared postgresql (17-alpine)](#shared-postgresql-17-alpine)
5. [valkey over redis](#valkey-over-redis)
6. [four critical services](#four-critical-services)
7. [oxidized for switch-config backup](#oxidized-for-switch-config-backup)
8. [shared headless browser](#shared-headless-browser)
9. [pihole upstream asymmetry](#pihole-upstream-asymmetry)
10. [static-site tax calculator](#static-site-tax-calculator)
11. [legacy /portainer paths kept canonical](#legacy-portainer-paths-kept-canonical)
12. [watchtower kept as commented fallback](#watchtower-kept-as-commented-fallback)
13. [tailscale via tsdproxy](#tailscale-via-tsdproxy)

---

## repurposed laptop as second host

### decision

run the secondary host on a spare Intel i3-2310M laptop instead of buying dedicated hardware.

### benefits

- **zero cost**, low power, and a built-in UPS (the laptop battery)
- **plain Debian**: direct script execution, ordinary crontab, apt without ceremony – the anti-TrueNAS
- **adequate**: 31 lightweight containers fit comfortably in 16 GB

### tradeoffs

- **2 cores/4 threads**: the load gate (4.0) trips more easily; heavyweight tenants (playwright-chrome, stirling OCR) budget carefully
- **single SSD**: no redundancy – mitigated by daily postgres dumps and the fact that amy's services are individually rebuildable; the residual risk is the bender-replica living on this same disk
- **aging hardware**: replacement path is the eventual k8s worker fleet

---

## amy as the notification and monitoring seat

### decision

place ntfy (notifications) and beszel (metrics hub) on amy, not bender.

### benefits

- **the watcher is not the watched**: bender's saturday updates, TrueNAS upgrades, and pool incidents get reported *by amy* – alerts survive the outage they describe
- **update-day offsetting** (amy wednesday, bender saturday) means one host is always fully stable

### tradeoffs

- **amy down = silent infrastructure**: accepted, and the reason amy's stack stays small, boring, and update-gated
- **cross-host coupling**: every bender producer needs amy reachable at notification time

---

## amy as bender's replica target

### decision

receive bender's nightly critical-data rsync into /docker/backups/bender-replica.

### benefits

- **real DR**: bender's configs, secrets, and database dumps survive a total bender loss
- **cheap**: reuses existing SSH trust; excluded regenerable bulk keeps it small
- **self-carrying**: the replica includes bender's compose + scripts – the rebuild kit travels with the data

### tradeoffs

- **secrets sprawl**: bender's .env now lives on amy's disk – amy's physical security and disk disposal now matter to bender
- **single-SSD landing zone**: the replica's own durability is one laptop SSD; the git repo + off-site copies are the second line

### duties (the whole contract)

keep kube's SSH trust valid, keep disk space free, be up at 03:30.

---

## shared postgresql (17-alpine)

### decision

one postgres:17-alpine instance for five tenants: atuin, miniflux, sss, mealie, stirling (stirling's app-side linkage unverified – see 02).

### benefits

- **RAM efficiency** on a 16 GB laptop
- **one backup pipeline**: postgres-backup-local:17 dumps all five daily (7d/4w/6m)
- **boring mainline image**: unlike bender (chained to immich's vectorchord build), amy runs stock postgres and upgrades on its own terms

### tradeoffs

- **shared superuser**: all five tenants ride the `postgres` user – the forgejo-style dedicated-user pattern from bender has not been applied here yet
- **single point of failure** for five apps – hence critical-service treatment

### v94 scar

a "clean" volume path (/docker/postgres/data) once orphaned the real databases; restoring `/portainer/postgresql/data` fixed it. that path is canonical; see 03.

---

## valkey over redis

### decision

run valkey (8-alpine) as the redis-compatible cache.

### benefits

- **license clarity**: valkey is the community fork with an open license trajectory
- **drop-in**: RESP-compatible; appendonly persistence enabled

### tradeoffs

- essentially none at this scale; consumers that hardcode "redis" in health tooling need the name adjusted
- **open audit item:** no v104 compose service actually references valkey – confirm its consumer(s) or retire it (see 02)

---

## four critical services

### decision

classify postgres, ntfy, beszel, and spendspentspent as critical in the update system (versus bender's postgres + gluetun).

### benefits

- the choices encode amy's actual blast radii: five databases (postgres), all alerting (ntfy), all metrics (beszel), and finance data with a browser-automation dependency (sss)

### tradeoffs

- longer update cycles for those four (pre-actions, dependent restarts, integration re-tests) – fine on a wednesday at 04:30

---

## oxidized for switch-config backup

### decision

back up nod's (Cisco 3750X) running config hourly to a private GitHub repo via oxidized.

### benefits

- **closes the config-loss hole**: switch configs die with hardware; now every change lands in git within the hour
- **diffable history**: `git log` on nod-config answers "what changed on the switch and when"
- **off-site by construction**: GitHub is the off-site copy

### tradeoffs

- **PAT lifecycle**: the amy-oxidized token expires; a silent push failure looks like "no changes" – check the repo's last-commit age during weekly review
- **secret outside .env**: the PAT lives in oxidized's config directory – never commit that directory

---

## shared headless browser

### decision

one browserless/chrome (playwright-chrome) serves both spendspentspent and limdius, rather than per-app browsers.

### benefits

- one Chrome's worth of RAM instead of two; session caps (10) and timeouts centralized

### tradeoffs

- shared failure domain: a wedged Chrome degrades both consumers – restart playwright-chrome first when either misbehaves
- no formal depends_on: consumers reconnect over ws://, so ordering is soft

---

## pihole upstream asymmetry

### decision

amy's pihole uses quad9 (9.9.9.9) + 1.1.1.1 with DNSSEC and REV_SERVER pointing at fry; bender's uses 1.1.1.1 + 8.8.8.8 without the DNSSEC flag.

### benefits

- **provider diversity across the HA pair**: an upstream outage or filtering anomaly on one provider set doesn't take both DNS personalities down identically
- **reverse lookups**: REV_SERVER at fry gives amy's pihole local hostname resolution for `lan` devices

### tradeoffs

- **behavioral drift on failover**: a VIP migration subtly changes DNSSEC and upstream behavior – remember this when debugging "DNS acts differently today"
- nebula-sync replicates lists/config, not these env-level upstream settings – the asymmetry is deliberate and persistent

---

## static-site tax calculator

### decision

serve the Ontario T1 calculator as static HTML under nginx:alpine (v100).

### benefits

- **zero state, zero database, zero attack surface** beyond nginx; read-only mount
- CRA-rate updates are file edits, not deployments

### tradeoffs

- yearly manual rate maintenance – inherent to the domain

---

## legacy /portainer paths kept canonical

### decision

keep /portainer/postgresql/data and /portainer/telegraf/config as canonical rather than migrating them under /docker.

### benefits

- **zero-risk continuity**: the v94 incident proved that "tidying" a live database path is how data gets orphaned
- migration buys aesthetics, not function

### tradeoffs

- two exceptions to the /docker convention forever documented (03 does)
- a future migration, if ever, is a deliberate dump-restore-verify with downtime

---

## watchtower kept as commented fallback

### decision

keep the watchtower service definition in the compose file, commented, marked do-not-remove.

### benefits

- **break-glass updater**: if the secure update system is ever wedged mid-crisis, uncommenting watchtower restores dumb-but-working updates in one edit

### tradeoffs

- dead YAML weight and the standing temptation to "clean it up" – resist; it's insurance, not cruft

---

## tailscale via tsdproxy

### decision

same pattern as bender: tsdproxy labels → automatic `*.bunny-enigmatic.ts.net` HTTPS.

### benefits / tradeoffs

as bender's 06, plus amy's two scars now encoded in the compose:

- **v101**: TSNET_FORCE_LOGIN=1 – silent auth failure became a visible login prompt
- **v104**: TS_AUTHKEY added and AMY_HOST_IP corrected – post-reboot re-auth failures and proxies routing to the dead pre-migration IP

origin-sensitive apps exist here too: miniflux (v103) binds full login to `http://rss.home.arpa:8385`, amy's counterpart to bender's vikunja lesson.


---

## keepalived auth_pass: weaker than it looks (20260810)

amy's `keepalived.conf` carries the VRRP secret inline as `auth_pass`.
that was already noted as a hygiene item. a new finding makes it smaller
than it appears.

the keepalived log reports:

```
(/etc/keepalived/keepalived.conf: Line 21) Truncating auth_pass to 8 characters
```

VRRP limits `auth_pass` to 8 characters. the configured value is 32. so
24 characters have never had any effect on either host.

two consequences.

**it is not a strong secret and cannot be made one.** the protocol caps it.
VRRP authentication is a weak check by design, and it is normally paired
with a trusted network segment rather than treated as real protection.

**rotation is still a two-host operation.** VRRP requires the same secret
on both peers. so a rotation must edit both files, then restart the BACKUP
first and the MASTER second. changing one host alone breaks the VIP, which
is the DNS failover.

two further messages appear in the same log and are pre-existing:

```
Script user 'keepalived_script' does not exist
SECURITY VIOLATION - scripts are being executed but script_security not enabled
```

both appear because the config defines a `vrrp_script` health check. the
check runs as root. neither is new, and neither is currently harmful.

---

## two hosts, two keepalived mechanisms

this is deliberate and worth stating plainly, because it looks like drift.

| | amy | bender |
|---|---|---|
| version | 2.3.4 | 2.0.20 |
| pin | digest | tag |
| config path | `/etc/keepalived/keepalived.conf` | `/container/service/keepalived/assets/keepalived.conf` |
| mechanism | direct mount | `--copy-service` |

VRRP is a protocol, so the two versions interoperate. an attempt to reach
version parity by pinning amy to 2.0.20 failed, because that version reads
a different path and therefore ignored amy's mount. real parity would
require changing the mount as well, which is a genuine change and not the
no-op it was assumed to be.

---

*previous: [05-ENV-REFERENCE.md](./05-ENV-REFERENCE.md)*
*next: [07-MAINTENANCE.md](./07-MAINTENANCE.md)*
