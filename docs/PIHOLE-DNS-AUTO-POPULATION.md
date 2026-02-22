# pihole DNS auto-population

## automatic DNS record population for docker services

**document version:** 3.0
**infrastructure version:** bender v109 / amy v99
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [infrastructure](#infrastructure)
3. [problem statement](#problem-statement)
4. [solution architecture](#solution-architecture)
5. [how it works](#how-it-works)
6. [DNS entries generated](#dns-entries-generated)
7. [the script](#the-script)
8. [installation](#installation)
9. [testing](#testing)
10. [troubleshooting](#troubleshooting)
11. [thought process and failed approaches](#thought-process-and-failed-approaches)
12. [TrueNAS limitations](#truenas-limitations)
13. [security considerations](#security-considerations)
14. [limitations and future improvements](#limitations-and-future-improvements)

---

## overview

the pihole-dns-update.sh script automatically creates local DNS records for all docker containers that have tsdproxy labels enabled. it scans running containers on both bender and amy, extracts their `tsdproxy.name` labels, and updates pihole's configuration so that each service is accessible via `<name>.home.arpa` on the local network.

the script runs every 5 minutes via cron on bender. changes are replicated to amy's pihole automatically via nebula-sync (hourly).

---

## infrastructure

| component | details |
|-----------|---------|
| **bender** | 192.168.21.121 — TrueNAS Scale, 36 containers (v109) |
| **amy** | 192.168.21.130 — Debian 13, 29 containers (v99) |
| **pihole VIP** | 192.168.21.100 — keepalived VRRP failover |
| **domain suffix** | `home.arpa` |
| **script location** | `/root/pihole-dns-update.sh` on bender (executable) |
| **reference copy** | `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` |
| **cron schedule** | `*/5 * * * *` |
| **pihole version** | v6 (TOML-based configuration) |

---

## problem statement

with 65 containers across two hosts, many exposing web interfaces via tsdproxy, manually maintaining DNS records is error-prone and tedious. every time a container is added, removed, or renamed, the DNS configuration needs updating.

the goal: automatically generate `*.home.arpa` DNS entries for every container that has `tsdproxy.enable: "true"`, so services are immediately accessible by name on the local network.

---

## solution architecture

```
bender cron (every 5 min)
   |
   v
pihole-dns-update.sh
   |
   +-- scan bender containers (local docker API)
   |   extract tsdproxy.name labels
   |
   +-- scan amy containers (SSH → docker API)
   |   extract tsdproxy.name labels
   |
   +-- build hosts array
   |   add static entries (homeassistant)
   |   add bender entries (192.168.21.121)
   |   add amy entries (192.168.21.130)
   |
   +-- compare md5 hash with previous state
   |
   +-- if changed:
       +-- backup pihole.toml
       +-- replace hosts array in pihole.toml via awk
       +-- chown to pihole user (UID 1000)
       +-- restart pihole container
       +-- save new hash to state file
   |
   v
nebula-sync (hourly)
   |
   +-- replicates pihole.toml from bender to amy
   +-- runs gravity update on amy
```

---

## how it works

### step 1: scan containers

the script queries Docker on both hosts to find containers with `tsdproxy.enable: "true"`:

- **bender (local):** `docker ps -q | xargs docker inspect` — extracts `tsdproxy.enable` and `tsdproxy.name` labels
- **amy (remote):** same command executed via `ssh kube@192.168.21.130` — uses an ed25519 key without passphrase for automated access

### step 2: build DNS entries

for each container with tsdproxy enabled, a DNS entry is created:

- bender containers → `192.168.21.121 <name>.home.arpa`
- amy containers → `192.168.21.130 <name>.home.arpa`

static entries (like Home Assistant) are added manually at the top of the hosts list.

### step 3: change detection

the script calculates an md5 hash of the generated hosts content and compares it to the previous hash stored in a state file. if unchanged, the script exits without modifying anything — no unnecessary pihole restarts.

### step 4: update pihole.toml

pihole v6 uses a TOML configuration file instead of the traditional `custom.list`. the script uses `awk` to replace the `hosts = [...]` array in pihole.toml, preserving all other configuration.

### step 5: replication

nebula-sync on bender replicates the entire pihole configuration to amy hourly with `FULL_SYNC=true`. amy's pihole picks up the DNS entries automatically.

---

## DNS entries generated

### bender entries (192.168.21.121)

| DNS name | tsdproxy.name | service |
|----------|---------------|---------|
| bender-proxy.home.arpa | bender-proxy | tsdproxy |
| bender-dockwatch.home.arpa | bender-dockwatch | dockwatch |
| pihole-bender.home.arpa | pihole-bender | pihole |
| photo.home.arpa | photo | immich |
| media.home.arpa | media | jellyfin |
| books.home.arpa | books | audiobookshelf |
| transmission.home.arpa | transmission | transmission |
| metube.home.arpa | metube | metube |
| jdown.home.arpa | jdown | jdownloader |
| spotdl.home.arpa | spotdl | spotdl |
| pad.home.arpa | pad | hedgedoc |
| vault.home.arpa | vault | vaultwarden |
| sync.home.arpa | sync | syncthing |
| prowlarr.home.arpa | prowlarr | prowlarr |
| sonarr.home.arpa | sonarr | sonarr |
| radarr.home.arpa | radarr | radarr |
| lidarr.home.arpa | lidarr | lidarr |
| readarr.home.arpa | readarr | readarr |
| bazarr.home.arpa | bazarr | bazarr |
| tts.home.arpa | tts | tts-pipeline |
| bender-cadvisor.home.arpa | bender-cadvisor | cadvisor |

### amy entries (192.168.21.130)

| DNS name | tsdproxy.name | service |
|----------|---------------|---------|
| amy-proxy.home.arpa | amy-proxy | tsdproxy |
| amy-dockwatch.home.arpa | amy-dockwatch | dockwatch |
| logs.home.arpa | logs | dozzle |
| pihole-amy.home.arpa | pihole-amy | pihole |
| ntfy.home.arpa | ntfy | ntfy |
| pdf.home.arpa | pdf | stirling |
| home.home.arpa | home | homepage |
| atuin.home.arpa | atuin | atuin |
| rss.home.arpa | rss | miniflux |
| it-tools.home.arpa | it-tools | it-tools |
| files.home.arpa | files | filebrowser |
| wallos.home.arpa | wallos | wallos |
| mealie.home.arpa | mealie | mealie |
| argus.home.arpa | argus | argus |
| lube.home.arpa | lube | lubelogger |
| money.home.arpa | money | spendspentspent |
| limdius.home.arpa | limdius | limdius |
| beszel.home.arpa | beszel | beszel |
| cadvisor.home.arpa | cadvisor | cadvisor |
| netalertx.home.arpa | netalertx | netalertx |

### static entries

| DNS name | IP | service |
|----------|-----|---------|
| homeassistant.horia.wtf | 192.168.21.220 | Home Assistant VM |

---

## the script

the script lives at `/root/pihole-dns-update.sh` on bender (executable) with a reference copy at `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh`.

see [bender/scripts/pihole-dns-update.sh](../bender/scripts/pihole-dns-update.sh) for the complete source.

### key configuration

| variable | value | purpose |
|----------|-------|---------|
| `LOCAL_IP` | 192.168.21.121 | bender's IP for DNS entries |
| `REMOTE_IP` | 192.168.21.130 | amy's IP for DNS entries |
| `SUFFIX` | home.arpa | domain suffix for all entries |
| `TOML_FILE` | /mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml | pihole config file |
| `STATE_FILE` | /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state | change detection hash |

---

## installation

### on bender

```bash
# copy script to /root (executable location)
cp /mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh /root/
chmod +x /root/pihole-dns-update.sh

# add cron job (TrueNAS UI: System → Advanced → Cron Jobs)
# or manually:
# */5 * * * * /root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1
```

### SSH setup for amy access

the script connects to amy as user `kube` (docker group member) via SSH with an ed25519 key:

```bash
# on bender, generate key if not already done
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""

# copy key to amy
ssh-copy-id -i /root/.ssh/id_ed25519.pub kube@192.168.21.130

# test (should return a number without prompting for password)
ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 "docker ps -q | wc -l"
```

### pihole.toml preparation

the script expects a `### CHANGED` marker in pihole.toml. on first run, manually add an empty hosts array:

```toml
  hosts = [
  ] ### CHANGED, default = []
```

---

## testing

### verify script runs correctly

```bash
# run manually and check output
/root/pihole-dns-update.sh

# check log
tail -5 /var/log/pihole-dns-export.log

# verify pihole.toml hosts array
grep -A 50 "hosts = \[" /mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml | head -60
```

### verify DNS resolution

```bash
# test a bender service
dig @192.168.21.100 photo.home.arpa +short
# should return: 192.168.21.121

# test an amy service
dig @192.168.21.100 ntfy.home.arpa +short
# should return: 192.168.21.130

# test a new service (tts-pipeline, added in v109)
dig @192.168.21.100 tts.home.arpa +short
# should return: 192.168.21.121

# test static entry
dig @192.168.21.100 homeassistant.horia.wtf +short
# should return: 192.168.21.220
```

### verify state file

```bash
cat /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state
# should show an md5 hash
```

### verify replication to amy

```bash
# check amy's pihole has the same hosts
ssh kube@192.168.21.130 "docker exec pihole grep -c 'home.arpa' /etc/pihole/pihole.toml"
```

---

## troubleshooting

### DNS entries not appearing

```bash
# check if script ran recently
tail -10 /var/log/pihole-dns-export.log

# run manually to see errors
/root/pihole-dns-update.sh

# check if SSH to amy works
ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 "echo OK"

# check pihole.toml is writable
ls -la /mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml
```

### entries for amy containers missing

```bash
# test SSH access from bender
ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 "docker ps -q | wc -l"

# if SSH fails:
# 1. check kube user exists on amy: ssh root@192.168.21.130 'id kube'
# 2. check kube is in docker group: ssh root@192.168.21.130 'groups kube'
# 3. check authorized_keys: ssh root@192.168.21.130 'cat /home/kube/.ssh/authorized_keys'
```

### pihole not restarting after update

```bash
# check if pihole container is running
docker ps | grep pihole

# manual restart
docker restart pihole

# check pihole.toml is valid
docker logs pihole --tail 10
```

### state file stale (script runs but doesn't update)

```bash
# delete state file to force an update
rm /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state

# run script
/root/pihole-dns-update.sh

# verify
tail -3 /var/log/pihole-dns-export.log
```

---

## thought process and failed approaches

### approach 1: custom.list (failed)

pihole traditionally used `/etc/pihole/custom.list` for local DNS. this was the first approach tried:

```
192.168.21.121  photo.home.arpa
192.168.21.121  media.home.arpa
```

**why it failed:** pihole v6 ignores the custom.list file entirely. all configuration moved to pihole.toml.

### approach 2: pihole API (failed)

pihole v6 has an API, so the next attempt was to use `curl` to add DNS records via the API:

```bash
curl -X POST http://localhost:8053/api/dns/local \
  -H "Authorization: ..." \
  -d '{"domain":"photo.home.arpa","ip":"192.168.21.121"}'
```

**why it failed:** at the time of implementation, pihole v6's local DNS API endpoints were not yet available or documented. the API returned 404 for DNS-related endpoints.

### approach 3: pihole.toml hosts array (success)

the working approach directly modifies the `[dns]` section's `hosts` array in pihole.toml using `awk`. this is the file pihole v6 actually reads for local DNS configuration.

the key insight was discovering that pihole.toml uses a TOML array format:

```toml
[dns]
  hosts = [
    "192.168.21.121 photo.home.arpa",
    "192.168.21.130 ntfy.home.arpa"
  ] ### CHANGED, default = []
```

the `### CHANGED` marker is used by the awk script to identify the end of the hosts array for replacement.

---

## TrueNAS limitations

### script execution

TrueNAS cannot execute scripts from `/mnt/` paths. the pihole-dns-update.sh script must live at `/root/pihole-dns-update.sh` (which is on the boot drive, not the ZFS pool).

a reference copy is kept at `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` for version control (pushed to the git repo), but this copy is not directly executable.

### file ownership

pihole.toml must be owned by UID 1000 (the pihole container user). the script runs `chown 1000:1000` after updating the file. if the ownership is wrong, pihole may fail to read its configuration.

---

## security considerations

- **SSH key authentication**: uses ed25519 key without passphrase for automated access from bender to amy
- **non-root SSH**: connects to amy as `kube` user (docker group member) instead of root
- **file permissions**: pihole.toml owned by UID 1000 (pihole container user)
- **backup before changes**: script creates `.bak` file before modifying pihole.toml
- **change detection**: md5 hash prevents unnecessary modifications and pihole restarts

---

## limitations and future improvements

### current limitations

1. **5-minute delay**: new containers won't have DNS entries for up to 5 minutes
2. **requires container restart**: pihole must restart to load new entries (~2 seconds)
3. **SSH dependency**: amy must be reachable via SSH for its entries to be included
4. **manual entries require script edit**: static DNS entries (like Home Assistant) must be added to the script's `hosts_lines` variable
5. **hourly replication**: amy's pihole can be up to 1 hour behind bender's after a DNS change (nebula-sync is hourly)

### future improvements

- add ntfy notification when DNS entries change
- implement retry logic if amy is temporarily unreachable
- add validation of generated TOML before applying
- consider using pihole v6 API when local DNS endpoints become fully available
- reduce nebula-sync interval for faster replication of DNS changes

---

*related documentation:*
- *[bender/docs/01-ARCHITECTURE.md](../bender/docs/01-ARCHITECTURE.md) — network and DNS configuration*
- *[bender/scripts/pihole-dns-update.sh](../bender/scripts/pihole-dns-update.sh) — the script source*
- *[amy/docs/01-ARCHITECTURE.md](../amy/docs/01-ARCHITECTURE.md) — amy's pihole and keepalived setup*
