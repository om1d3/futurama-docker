#!/bin/bash
# ============================================
# pihole-dns-update.sh
# Version: 3.2 - Added homeassistant.home.arpa
# ============================================
LOCAL_IP="10.30.0.12"
REMOTE_IP="10.30.0.11"
SUFFIX="home.arpa"
TOML_FILE="/mnt/BIG/filme/configs/pihole/etc-pihole/pihole.toml"
STATE_FILE="/mnt/BIG/filme/configs/pihole/etc-pihole/.dns-state"
bender_entries=$(docker ps -q | xargs -I{} docker inspect {} --format "{{index .Config.Labels \"tsdproxy.enable\"}}|{{index .Config.Labels \"tsdproxy.name\"}}" 2>/dev/null | grep "^true|" | cut -d"|" -f2 | grep -v "^$" | sort -u)
amy_entries=$(ssh -o ConnectTimeout=5 -o BatchMode=yes kube@10.30.0.11 "docker ps -q | xargs -I{} docker inspect {} --format \"{{index .Config.Labels \\\"tsdproxy.enable\\\"}}|{{index .Config.Labels \\\"tsdproxy.name\\\"}}\"" 2>/dev/null | grep "^true|" | cut -d"|" -f2 | grep -v "^$" | sort -u)
hosts_lines='    "100.113.200.104 homeassistant.bunny-enigmatic.ts.net",'
hosts_lines="${hosts_lines}"$'\n''    "10.30.0.41 homeassistant.home.arpa",'
for name in $bender_entries; do
  hosts_lines="${hosts_lines}"$'\n'"    \"${LOCAL_IP} ${name}.${SUFFIX}\","
done
for name in $amy_entries; do
  hosts_lines="${hosts_lines}"$'\n'"    \"${REMOTE_IP} ${name}.${SUFFIX}\","
done
hosts_lines=$(echo "$hosts_lines" | sed '$ s/,$//')
new_hash=$(echo "$hosts_lines" | md5sum | cut -d" " -f1)
old_hash=$(cat "$STATE_FILE" 2>/dev/null || echo "")
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
