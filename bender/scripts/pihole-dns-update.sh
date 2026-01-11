#!/bin/bash
# ============================================
# pihole-dns-update.sh
# Version: 3.0 - Pi-hole v6 TOML Edition
# ============================================
# Scans running Docker containers on bender and amy,
# extracts tsdproxy labels, and updates Pi-hole's pihole.toml
# hosts array. Only updates if changes are detected.
# Relies on nebula-sync (FULL_SYNC=true) to replicate to amy.
# ============================================
# INSTALLATION:
#   - Place executable copy in: /root/pihole-dns-update.sh
#   - Place reference copy in: /mnt/BIG/filme/docker-compose/scripts/
#   - TrueNAS cannot execute scripts from /mnt directly!
# ============================================
# CRON (every 5 minutes):
#   */5 * * * * /root/pihole-dns-update.sh >> /var/log/pihole-dns-export.log 2>&1
# ============================================
# Pi-hole v6 uses pihole.toml [dns] hosts = [] array
# instead of custom.list file.
# ============================================

LOCAL_IP="192.168.21.121"
REMOTE_IP="192.168.21.130"
SUFFIX="home.arpa"
TOML_FILE="/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml"
STATE_FILE="/mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state"

# Get bender entries (local)
bender_entries=$(docker ps -q | xargs -I{} docker inspect {} --format "{{index .Config.Labels \"tsdproxy.enable\"}}|{{index .Config.Labels \"tsdproxy.name\"}}" 2>/dev/null | grep "^true|" | cut -d"|" -f2 | grep -v "^$" | sort -u)

# Get amy entries (remote via SSH)
amy_entries=$(ssh -o ConnectTimeout=5 -o BatchMode=yes kube@192.168.21.130 "docker ps -q | xargs -I{} docker inspect {} --format \"{{index .Config.Labels \\\"tsdproxy.enable\\\"}}|{{index .Config.Labels \\\"tsdproxy.name\\\"}}\"" 2>/dev/null | grep "^true|" | cut -d"|" -f2 | grep -v "^$" | sort -u)

# Build hosts array content
# Manual entries go first (add your static entries here)
hosts_lines='    "192.168.21.220 homeassistant.horia.wtf",'

# Add bender entries
for name in $bender_entries; do
  hosts_lines="$hosts_lines"$'\n'"    \"${LOCAL_IP} ${name}.${SUFFIX}\","
done

# Add amy entries
for name in $amy_entries; do
  hosts_lines="$hosts_lines"$'\n'"    \"${REMOTE_IP} ${name}.${SUFFIX}\","
done

# Remove trailing comma from last line
hosts_lines=$(echo "$hosts_lines" | sed '$ s/,$//')

# Calculate hash for change detection
new_hash=$(echo "$hosts_lines" | md5sum | cut -d" " -f1)
old_hash=$(cat "$STATE_FILE" 2>/dev/null || echo "")

# Only update if changes detected
if [ "$new_hash" != "$old_hash" ]; then
  # Use awk to replace the hosts array in pihole.toml
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
  
  # Verify new file is valid before replacing
  if [ -s "${TOML_FILE}.new" ]; then
    cp "$TOML_FILE" "${TOML_FILE}.bak"
    mv "${TOML_FILE}.new" "$TOML_FILE"
    chown 1000:1000 "$TOML_FILE"
    echo "$new_hash" > "$STATE_FILE"
    docker restart pihole >/dev/null 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updated DNS entries"
  fi
fi
