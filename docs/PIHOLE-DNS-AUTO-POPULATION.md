# pihole DNS auto-population

## automatic local DNS for container services

**document version:** 2.0
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [architecture](#architecture)
3. [how it works](#how-it-works)
4. [approaches tested](#approaches-tested)
5. [current DNS entries](#current-dns-entries)
6. [script reference](#script-reference)
7. [adding manual entries](#adding-manual-entries)
8. [tailscale split DNS integration](#tailscale-split-dns-integration)
9. [testing and verification](#testing-and-verification)
10. [troubleshooting](#troubleshooting)
11. [files reference](#files-reference)
12. [security considerations](#security-considerations)

---

## overview

every container service with a `tsdproxy.enable: "true"` label automatically gets a local DNS entry in pihole, making it accessible via `<name>.home.arpa` on the local network. a cron job on bender scans running containers on both bender and amy every 5 minutes, generates DNS entries, and updates pihole's configuration.

| property | value |
|----------|-------|
| **domain suffix** | `.home.arpa` (RFC 8375 compliant for private networks) |
| **scan interval** | every 5 minutes |
| **scan scope** | running containers on bender and amy |
| **label used** | `tsdproxy.enable: "true"` + `tsdproxy.name` |
| **pihole version** | v6 (uses `pihole.toml` hosts array) |
| **replication** | nebula-sync to amy pihole (hourly) |
| **script** | `/root/pihole-dns-update.sh` on bender |

---

## architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      bender (primary)                        │
│                      192.168.21.121                          │
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐      │
│  │ cron        │───▶│ pihole-dns- │───▶│ pihole.toml │      │
│  │ (5 min)     │    │ update.sh   │    │ hosts = []  │      │
│  └─────────────┘    └──────┬──────┘    └──────┬──────┘      │
│                            │                   │             │
│                     SSH to amy          restart pihole        │
│                            │                   │             │
└────────────────────────────┼───────────────────┼─────────────┘
                             │                   │
                             ▼                   ▼
┌────────────────────────────────────┐    ┌─────────────┐
│              amy                    │    │ nebula-sync │
│         192.168.21.130              │    │ (hourly)    │
│                                     │    └──────┬──────┘
│  ┌─────────────┐                   │           │
│  │ docker      │◀── scan labels    │           ▼
│  │ containers  │                   │    ┌─────────────┐
│  └─────────────┘                   │    │ amy pihole  │
│                                     │    │ (replica)   │
└────────────────────────────────────┘    └─────────────┘
```

---

## how it works

1. **cron triggers** `/root/pihole-dns-update.sh` every 5 minutes on bender
2. **script scans bender** — runs `docker inspect` on all running containers, extracts `tsdproxy.enable` and `tsdproxy.name` labels
3. **script scans amy** — SSHes to `kube@192.168.21.130` and runs the same docker inspect command
4. **generates DNS entries** — maps each `tsdproxy.name` to `<name>.home.arpa` with the host's IP address
5. **change detection** — computes md5 hash of new entries and compares to stored hash in `.dns-state` file
6. **if changed** — updates `pihole.toml` hosts array using awk, creates backup, restarts pihole
7. **nebula-sync** — replicates pihole configuration (including DNS entries) to amy's pihole hourly

### why pihole.toml and not custom.list?

pihole v6 changed how local DNS records are stored. the traditional `custom.list` file exists but is not read by the DNS resolver. DNS entries must be placed in the `pihole.toml` file under the `[dns]` section's `hosts = []` array.

---

## approaches tested

three approaches were tested during development. only the third works with pihole v6.

| approach | method | result |
|----------|--------|--------|
| **custom.list** | write entries to `/etc/pihole/custom.list` + `pihole reloadlists` | ❌ pihole v6 does not read from custom.list for local DNS |
| **pihole API** | use `/api/dns/local` endpoint | ❌ endpoint returns 404 in pihole v6 |
| **pihole.toml hosts array** | modify `[dns] hosts = []` in pihole.toml + restart pihole | ✅ works — entries loaded after restart |

---

## current DNS entries

the script generates entries for all services with `tsdproxy.enable: "true"` labels. as of v98 (amy) and v105 (bender):

### bender services (192.168.21.121)

| DNS name | tsdproxy.name | service |
|----------|--------------|---------|
| bender-cadvisor.home.arpa | bender-cadvisor | cadvisor |
| bender-dockwatch.home.arpa | bender-dockwatch | dockwatch |
| bender-proxy.home.arpa | bender-proxy | tsdproxy |
| books.home.arpa | books | audiobookshelf |
| jdown.home.arpa | jdown | jdownloader |
| media.home.arpa | media | jellyfin |
| metube.home.arpa | metube | metube |
| pad.home.arpa | pad | hedgedoc |
| photo.home.arpa | photo | immich |
| pihole-bender.home.arpa | pihole-bender | pihole |
| prowlarr.home.arpa | prowlarr | prowlarr |
| sonarr.home.arpa | sonarr | sonarr |
| radarr.home.arpa | radarr | radarr |
| lidarr.home.arpa | lidarr | lidarr |
| readarr.home.arpa | readarr | readarr |
| bazarr.home.arpa | bazarr | bazarr |
| spotdl.home.arpa | spotdl | spotdl |
| sync.home.arpa | sync | syncthing |
| transmission.home.arpa | transmission | transmission |
| vault.home.arpa | vault | vaultwarden |

### amy services (192.168.21.130)

| DNS name | tsdproxy.name | service |
|----------|--------------|---------|
| amy-dockwatch.home.arpa | amy-dockwatch | dockwatch |
| amy-proxy.home.arpa | amy-proxy | tsdproxy |
| argus.home.arpa | argus | argus |
| atuin.home.arpa | atuin | atuin |
| beszel.home.arpa | beszel | beszel |
| cadvisor.home.arpa | cadvisor | cadvisor |
| files.home.arpa | files | filebrowser |
| home.home.arpa | home | homepage |
| it-tools.home.arpa | it-tools | it-tools |
| limdius.home.arpa | limdius | limdius |
| logs.home.arpa | logs | dozzle |
| lube.home.arpa | lube | lubelogger |
| mealie.home.arpa | mealie | mealie |
| money.home.arpa | money | spendspentspent |
| netalertx.home.arpa | netalertx | netalertx |
| ntfy.home.arpa | ntfy | ntfy |
| pdf.home.arpa | pdf | stirling-pdf |
| pihole-amy.home.arpa | pihole-amy | pihole |
| rss.home.arpa | rss | miniflux |
| wallos.home.arpa | wallos | wallos |

### manual entries

| DNS name | IP address | purpose |
|----------|------------|---------|
| homeassistant.horia.wtf | 192.168.21.220 | home assistant VM |

---

## script reference

### script location

| location | purpose |
|----------|---------|
| `/root/pihole-dns-update.sh` | executable on bender (cron runs this) |
| `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` | reference copy on bender filesystem |
| `bender/scripts/pihole-dns-update.sh` | reference copy in git repository |

### the script (v3.0)

```bash
#!/bin/bash
LOCAL_IP="192.168.21.121"
REMOTE_IP="192.168.21.130"
SUFFIX="home.arpa"
TOML_FILE="/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml"
STATE_FILE="/mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state"

# get bender entries (local)
bender_entries=$(docker ps -q | xargs -I{} docker inspect {} \
  --format "{{index .Config.Labels \"tsdproxy.enable\"}}|{{index .Config.Labels \"tsdproxy.name\"}}" \
  2>/dev/null | grep "^true|" | cut -d"|" -f2 | grep -v "^$" | sort -u)

# get amy entries (remote via SSH)
amy_entries=$(ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 \
  "docker ps -q | xargs -I{} docker inspect {} \
  --format \"{{index .Config.Labels \\\"tsdproxy.enable\\\"}}|{{index .Config.Labels \\\"tsdproxy.name\\\"}}\"" \
  2>/dev/null | grep "^true|" | cut -d"|" -f2 | grep -v "^$" | sort -u)

# build hosts array content
# manual entries go first
hosts_lines='    "192.168.21.220 homeassistant.horia.wtf",'

# add bender entries
for name in $bender_entries; do
  hosts_lines="$hosts_lines"$'\n'"    \"${LOCAL_IP} ${name}.${SUFFIX}\","
done

# add amy entries
for name in $amy_entries; do
  hosts_lines="$hosts_lines"$'\n'"    \"${REMOTE_IP} ${name}.${SUFFIX}\","
done

# remove trailing comma from last line
hosts_lines=$(echo "$hosts_lines" | sed '$ s/,$//')

# change detection
new_hash=$(echo "$hosts_lines" | md5sum | cut -d" " -f1)
old_hash=$(cat "$STATE_FILE" 2>/dev/null || echo "")

# only update if changes detected
if [ "$new_hash" != "$old_hash" ]; then
  awk -v new_hosts="$hosts_lines" '
    /^  hosts = \[/ {
      print "  hosts = ["
      print new_hosts
      while (getline && !/\] ### CHANGED/) {}
      print "  ] ### CHANGED, default = []"
      next
    }
    { print }
  ' "$TOML_FILE" > "${TOML_FILE}.new"

  if [ -s "${TOML_FILE}.new" ]; then
    cp "$TOML_FILE" "${TOML_FILE}.bak"
    mv "${TOML_FILE}.new" "$TOML_FILE"
    chown 1000:1000 "$TOML_FILE"
    echo "$new_hash" > "$STATE_FILE"
    docker restart pihole >/dev/null 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updated DNS entries"
  fi
fi
```

### cron configuration

```cron
*/5 * * * * /root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1
```

### pihole.toml format

the script modifies the `[dns]` section of pihole.toml:

```toml
[dns]
  hosts = [
    "192.168.21.220 homeassistant.horia.wtf",
    "192.168.21.121 books.home.arpa",
    "192.168.21.121 media.home.arpa",
    "192.168.21.130 ntfy.home.arpa",
    "192.168.21.130 vault.home.arpa"
  ] ### CHANGED, default = []
```

the `### CHANGED` marker is used by the awk command to identify the end of the auto-generated block.

---

## adding manual entries

to add static DNS entries (devices that aren't docker containers), edit `/root/pihole-dns-update.sh` and modify the `hosts_lines` variable:

```bash
# manual entries go first (add your static entries here)
hosts_lines='    "192.168.21.220 homeassistant.horia.wtf",
    "192.168.21.50 printer.home.arpa",
    "192.168.21.60 nas.home.arpa",'
```

after editing, force an update:

```bash
rm /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state
/root/pihole-dns-update.sh
```

> **important:** also update the reference copy at `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` and commit to git.

---

## tailscale split DNS integration

when connected to tailscale (at home or away), `.home.arpa` domains resolve through pihole via tailscale's split DNS feature.

### configuration

in the tailscale admin console (https://login.tailscale.com/admin/dns):

| setting | value |
|---------|-------|
| **split DNS domain** | `home.arpa` |
| **nameserver** | `192.168.21.100` (keepalived VIP) |

### how it works

```
device with tailscale connected
  ↓
DNS query for *.home.arpa
  ↓
tailscale split DNS → 192.168.21.100:53
  ↓
tailscale subnet router forwards to local network
  ↓
pihole answers with local IP
  ↓
traffic routes appropriately:
  - at home: direct to 192.168.21.121 or .130
  - away: via tailscale subnet router
```

### why not use pihole's tailscale IP?

pihole is behind tsdproxy, which only proxies HTTP/HTTPS. DNS queries (port 53) to pihole's tailscale IP time out. the keepalived VIP (`192.168.21.100`) is used instead, routed through the tailscale subnet router.

### result

| scenario | DNS resolution | traffic path |
|----------|---------------|-------------|
| at home, no tailscale | direct via pihole VIP | local network |
| at home, with tailscale | split DNS via subnet router → pihole VIP | local network |
| away, with tailscale | split DNS via subnet router → pihole VIP | tailscale tunnel |

---

## testing and verification

### verify DNS resolution

```bash
# test bender services
dig +short books.home.arpa @192.168.21.100
dig +short media.home.arpa @192.168.21.100

# test amy services
dig +short ntfy.home.arpa @192.168.21.100
dig +short vault.home.arpa @192.168.21.100

# test manual entries
dig +short homeassistant.horia.wtf @192.168.21.100
```

### check current pihole hosts

```bash
docker exec pihole grep -A50 "^  hosts = \[" /etc/pihole/pihole.toml
```

### view auto-population logs

```bash
tail -20 /var/log/pihole-dns-export.log
```

### force update

```bash
# remove state file to force regeneration
rm /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state
/root/pihole-dns-update.sh
```

### verify entries are NOT in pihole web UI

entries in the `pihole.toml` hosts array do **not** appear in the pihole web interface under "Local DNS > DNS Records". this is a pihole v6 limitation. entries are visible only through:

```bash
docker exec pihole grep -A50 "^  hosts = \[" /etc/pihole/pihole.toml
```

and by checking DNS resolution directly with `dig`.

---

## troubleshooting

### DNS entry not resolving

1. check pihole is running:
   ```bash
   docker ps | grep pihole
   ```

2. verify the entry exists in pihole.toml:
   ```bash
   docker exec pihole grep "media.home.arpa" /etc/pihole/pihole.toml
   ```

3. if missing, check if the container has the correct labels:
   ```bash
   docker inspect jellyfin --format '{{index .Config.Labels "tsdproxy.enable"}}|{{index .Config.Labels "tsdproxy.name"}}'
   # should show: true|media
   ```

4. force update and restart:
   ```bash
   rm /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state
   /root/pihole-dns-update.sh
   ```

### SSH connection to amy fails

1. test SSH manually:
   ```bash
   ssh -o BatchMode=yes kube@192.168.21.130 "echo OK"
   ```

2. verify SSH key is installed:
   ```bash
   ssh-copy-id kube@192.168.21.130
   ```

3. verify kube user is in docker group on amy:
   ```bash
   ssh kube@192.168.21.130 "groups"
   # should include: docker
   ```

### script not running

1. check cron:
   ```bash
   crontab -l | grep pihole
   # should show: */5 * * * * /root/pihole-dns-update.sh ...
   ```

2. check script is executable:
   ```bash
   ls -la /root/pihole-dns-update.sh
   ```

3. run manually and check for errors:
   ```bash
   /root/pihole-dns-update.sh
   echo $?
   ```

### pihole ad-blocking impact

pihole's ad-blocking does **not** affect `.home.arpa` domains. the DNS query processing order is:

```
1. local DNS records (pihole.toml hosts) ← checked FIRST
2. blocklists (gravity.db)
3. upstream DNS (1.1.1.1, 8.8.8.8)
```

local entries take priority over blocklists, so `.home.arpa` domains are never blocked.

---

## files reference

| file | location | purpose |
|------|----------|---------|
| script (executable) | `/root/pihole-dns-update.sh` | cron runs this |
| script (reference) | `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` | reference copy |
| script (git) | `bender/scripts/pihole-dns-update.sh` | version-controlled reference |
| pihole config | `/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml` | DNS configuration |
| state file | `/mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state` | change detection hash |
| backup | `/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml.bak` | auto-created before updates |
| log file | `/var/log/pihole-dns-export.log` | cron output |

---

## security considerations

1. **SSH key authentication**: uses ed25519 key without passphrase for automated access from bender to amy
2. **non-root SSH**: connects to amy as `kube` user (docker group member) instead of root — limits blast radius if key is compromised
3. **read-only docker access**: the script only inspects container labels — it does not modify containers on either host
4. **file permissions**: pihole.toml owned by UID 1000 (pihole container user) — script sets correct ownership after modification
5. **backup before modify**: the script creates `pihole.toml.bak` before every update
6. **change detection**: hash comparison prevents unnecessary pihole restarts (no restart = no DNS interruption)
7. **batch mode SSH**: `BatchMode=yes` prevents SSH from hanging on password prompts if key auth fails

---

*this is a shared document referenced by both [bender](../bender/docs/) and [amy](../amy/docs/) documentation.*
