# pi-hole DNS auto-population for docker services

## overview

this document describes the implementation of automatic DNS record population for docker containers running on a TrueNAS Scale homelab environment. the solution scans running containers on two hosts (bender and amy), extracts TSDProxy labels, and automatically creates local DNS entries in Pi-hole v6.

## infrastructure

### hosts

| hostname | IP address | role | OS |
|----------|------------|------|-----|
| bender | 192.168.21.121 | primary server (TrueNAS Scale) | Debian-based |
| amy | 192.168.21.130 | secondary server | Debian-based |
| VIP | 192.168.21.100 | keepalived virtual IP for DNS | n/a |

### key services

| service | host | purpose |
|---------|------|---------|
| pi-hole | bender (primary), amy (replica) | DNS server with ad-blocking |
| keepalived | both | high availability for DNS (VIP: 192.168.21.100) |
| nebula-sync | bender | replicates pi-hole config to amy |
| TSDProxy | both | Tailscale proxy with service labels |

## problem statement

managing DNS records for 30+ docker containers across two hosts presents several challenges:

1. **manual maintenance**: adding/removing containers requires manual DNS updates
2. **inconsistency**: easy to forget updating DNS when deploying new services
3. **multiple hosts**: services spread across bender and amy need centralized DNS
4. **high availability**: DNS changes need to replicate to both pi-hole instances

## solution architecture

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
│                     SSH to amy          restart pi-hole      │
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
│  └─────────────┘                   │    │ amy pi-hole │
│                                     │    │ (replica)   │
└────────────────────────────────────┘    └─────────────┘
```

## thought process

### initial approaches considered

#### approach 1: custom.list file (failed)

the first attempt used pi-hole's traditional `custom.list` file for local DNS records:

```bash
# custom.list format
192.168.21.121  books.home.arpa
192.168.21.121  media.home.arpa
```

**why it failed**: pi-hole v6 no longer reads from `custom.list` for local DNS records. the file exists but is not parsed by the DNS resolver.

#### approach 2: pi-hole API (failed)

attempted to use pi-hole v6's API to manage DNS records:

```bash
docker exec pihole pihole api dns/local
```

**why it failed**: the API endpoint `/api/dns/local` returns 404. pi-hole v6's API doesn't expose local DNS management in this way.

#### approach 3: pihole.toml hosts array (success)

discovered that pi-hole v6 stores local DNS records in `/etc/pihole/pihole.toml` under the `[dns]` section:

```toml
[dns]
  hosts = [
    "192.168.21.220 homeassistant.horia.wtf",
    "192.168.21.121 books.home.arpa",
    "192.168.21.130 ntfy.home.arpa"
  ] ### CHANGED, default = []
```

**why it works**: modifying this array and restarting pi-hole properly loads the DNS records.

### TrueNAS script execution limitation

TrueNAS Scale has a security restriction that prevents executing scripts from `/mnt` paths:

```bash
# this fails on TrueNAS
/mnt/BIG/filme/docker-compose/scripts/export-pihole-dns.sh
# error: sudo: process unexpected status 0x57f / killed
```

**solution**: place the executable script in `/root/` which persists across TrueNAS upgrades and is not subject to this restriction.

### cron line length limitation

initial attempt to put the entire script inline in crontab failed:

```
crontab: command too long
```

**solution**: use a dedicated script file in `/root/` instead of inline commands.

## implementation

### prerequisites

1. **SSH key authentication** from bender to amy:

```bash
# on bender as root
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
ssh-copy-id kube@192.168.21.130
```

note: using the `kube` user (member of docker group) instead of root for security.

2. **pi-hole v6** with `pihole.toml` configuration
3. **nebula-sync** configured with `FULL_SYNC=true` for replication
4. **TSDProxy labels** on containers:

```yaml
services:
  myservice:
    labels:
      tsdproxy.enable: "true"
      tsdproxy.name: "myservice"
```

### script location

| location | purpose |
|----------|---------|
| `/root/pihole-dns-update.sh` | executable (cron runs this) |
| `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` | reference copy for documentation |

### the script

```bash
#!/bin/bash
# ============================================
# pihole-dns-update.sh
# version: 3.0 - pi-hole v6 TOML edition
# ============================================
# scans running docker containers on bender and amy,
# extracts tsdproxy labels, and updates pi-hole's pihole.toml
# hosts array. only updates if changes are detected.
# relies on nebula-sync (FULL_SYNC=true) to replicate to amy.
# ============================================
# installation:
#   - place executable copy in: /root/pihole-dns-update.sh
#   - place reference copy in: /mnt/BIG/filme/docker-compose/scripts/
#   - TrueNAS cannot execute scripts from /mnt directly!
# ============================================
# cron (every 5 minutes):
#   */5 * * * * /root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1
# ============================================
# pi-hole v6 uses pihole.toml [dns] hosts = [] array
# instead of custom.list file.
# ============================================

LOCAL_IP="192.168.21.121"
REMOTE_IP="192.168.21.130"
SUFFIX="home.arpa"
TOML_FILE="/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml"
STATE_FILE="/mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state"

# get bender entries (local)
bender_entries=$(docker ps -q | xargs -I{} docker inspect {} --format "{{index .Config.Labels \"tsdproxy.enable\"}}|{{index .Config.Labels \"tsdproxy.name\"}}" 2>/dev/null | grep "^true|" | cut -d"|" -f2 | grep -v "^$" | sort -u)

# get amy entries (remote via SSH)
amy_entries=$(ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 "docker ps -q | xargs -I{} docker inspect {} --format \"{{index .Config.Labels \\\"tsdproxy.enable\\\"}}|{{index .Config.Labels \\\"tsdproxy.name\\\"}}\"" 2>/dev/null | grep "^true|" | cut -d"|" -f2 | grep -v "^$" | sort -u)

# build hosts array content
# manual entries go first (add your static entries here)
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

# calculate hash for change detection
new_hash=$(echo "$hosts_lines" | md5sum | cut -d" " -f1)
old_hash=$(cat "$STATE_FILE" 2>/dev/null || echo "")

# only update if changes detected
if [ "$new_hash" != "$old_hash" ]; then
  # use awk to replace the hosts array in pihole.toml
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
  
  # verify new file is valid before replacing
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

### how it works

1. **every 5 minutes**, cron executes `/root/pihole-dns-update.sh`

2. **scan bender containers**:
   ```bash
   docker ps -q | xargs -I{} docker inspect {} --format "..."
   ```
   extracts `tsdproxy.enable` and `tsdproxy.name` labels from running containers

3. **scan amy containers** via SSH:
   ```bash
   ssh kube@192.168.21.130 "docker ps -q | xargs -I{} docker inspect {} ..."
   ```

4. **build DNS entries** in TOML format:
   ```toml
   hosts = [
     "192.168.21.220 homeassistant.horia.wtf",
     "192.168.21.121 books.home.arpa",
     "192.168.21.130 ntfy.home.arpa"
   ]
   ```

5. **change detection**: calculate MD5 hash of new entries and compare with stored hash
   - if unchanged: exit silently (no unnecessary restarts)
   - if changed: proceed with update

6. **update pihole.toml**: use `awk` to replace the `hosts = [...]` array

7. **restart pi-hole**: `docker restart pihole` to load new entries

8. **nebula-sync** (configured separately, runs hourly) replicates the configuration to amy's pi-hole instance

## DNS entries generated

### bender services (192.168.21.121)

| DNS name | service |
|----------|---------|
| books.home.arpa | audiobookshelf |
| media.home.arpa | jellyfin |
| photo.home.arpa | immich |
| pad.home.arpa | hedgedoc |
| sync.home.arpa | syncthing |
| transmission.home.arpa | transmission |
| metube.home.arpa | metube |
| jdown.home.arpa | jdownloader |
| spotdl.home.arpa | spotdl |
| pihole-bender.home.arpa | pi-hole web UI |
| bender-proxy.home.arpa | TSDProxy |
| bender-dockwatch.home.arpa | dockwatch |

### amy services (192.168.21.130)

| DNS name | service |
|----------|---------|
| ntfy.home.arpa | ntfy notifications |
| vault.home.arpa | vaultwarden |
| beszel.home.arpa | beszel monitoring |
| home.home.arpa | homepage dashboard |
| files.home.arpa | filebrowser |
| mealie.home.arpa | mealie recipes |
| rss.home.arpa | miniflux |
| atuin.home.arpa | atuin shell history |
| money.home.arpa | spendspentspent |
| pdf.home.arpa | stirling-pdf |
| it-tools.home.arpa | it-tools |
| lube.home.arpa | lubelogger |
| argus.home.arpa | argus |
| netalertx.home.arpa | netalertx |
| logs.home.arpa | dozzle |
| cadvisor.home.arpa | cadvisor |
| limdius.home.arpa | limdius |
| pihole-amy.home.arpa | pi-hole web UI |
| amy-proxy.home.arpa | TSDProxy |
| amy-dockwatch.home.arpa | dockwatch |

### manual entries

| DNS name | IP address | purpose |
|----------|------------|---------|
| homeassistant.horia.wtf | 192.168.21.220 | home assistant |

## adding manual entries

edit `/root/pihole-dns-update.sh` and modify the `hosts_lines` variable:

```bash
# manual entries go first (add your static entries here)
hosts_lines='    "192.168.21.220 homeassistant.horia.wtf",
    "192.168.21.50 printer.home.arpa",
    "192.168.21.60 nas.home.arpa",'
```

## testing

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

### check current pi-hole hosts

```bash
docker exec pihole grep -A50 "^  hosts = \[" /etc/pihole/pihole.toml
```

### view logs

```bash
tail -f /var/log/pihole-dns-export.log
```

### force update

```bash
# remove state file to force regeneration
rm /mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state
/root/pihole-dns-update.sh
```

## files reference

| file | location | purpose |
|------|----------|---------|
| script (executable) | `/root/pihole-dns-update.sh` | cron runs this |
| script (reference) | `/mnt/BIG/filme/docker-compose/scripts/pihole-dns-update.sh` | documentation |
| pi-hole config | `/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml` | DNS configuration |
| state file | `/mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state` | change detection hash |
| backup | `/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml.bak` | auto-created before updates |
| log file | `/var/log/pihole-dns-export.log` | cron output |

## troubleshooting

### DNS not resolving

1. check pi-hole is running:
   ```bash
   docker ps | grep pihole
   ```

2. verify hosts array in pihole.toml:
   ```bash
   docker exec pihole grep -A10 "hosts = \[" /etc/pihole/pihole.toml
   ```

3. restart pi-hole:
   ```bash
   docker restart pihole
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

3. check kube user is in docker group on amy:
   ```bash
   ssh kube@192.168.21.130 "groups"
   ```

### script not running

1. check cron is configured:
   ```bash
   crontab -l | grep pihole
   ```

2. check script is executable:
   ```bash
   ls -la /root/pihole-dns-update.sh
   ```

3. run manually and check for errors:
   ```bash
   /root/pihole-dns-update.sh
   ```

## security considerations

1. **SSH key authentication**: uses ed25519 key without passphrase for automated access
2. **non-root SSH**: connects to amy as `kube` user (docker group member) instead of root
3. **file permissions**: pihole.toml owned by UID 1000 (pi-hole container user)
4. **backup before changes**: script creates `.bak` file before modifying pihole.toml

## limitations

1. **5-minute delay**: new containers won't have DNS entries for up to 5 minutes
2. **requires container restart**: pi-hole must restart to load new entries
3. **SSH dependency**: amy must be reachable via SSH for its entries to be included
4. **manual entries require script edit**: static DNS entries must be added to the script

## future improvements

- [ ] add ntfy notification when DNS entries change
- [ ] implement retry logic if amy is temporarily unreachable
- [ ] add validation of generated TOML before applying
- [ ] consider using pi-hole v6 API when local DNS endpoints become available
