#!/bin/bash
# ============================================
# unifi-ctl.sh - start and stop the UniFi controller on demand
# Version: 1.0
# Host: bender (TrueNAS Scale)
# ============================================
# The UniFi controller and its MongoDB are behind profiles: ["unifi"], so a
# plain "docker compose up -d" leaves them down. This script starts them
# when you need to change Wi-Fi settings, and stops them afterwards.
#
# An adopted access point keeps serving every SSID while the controller is
# off. You lose statistics and the client list, not the network.
#
# USAGE, from bender:
#   cp /mnt/BIG/filme/docker-compose/scripts/unifi-ctl.sh /tmp/ \
#     && bash /tmp/unifi-ctl.sh start && rm /tmp/unifi-ctl.sh
#
# TrueNAS execution restrictions are the reason for the copy to /tmp. The
# same pattern is used by rollback.sh and secure-container-update.sh.
# ============================================

set -uo pipefail

COMPOSE_DIR="/mnt/BIG/filme/docker-compose"
PROFILE="unifi"
URL="https://10.30.0.12:8443"
NEED_MB=1600          # unifi 1G + mongo 768M, rounded down

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

usage() {
  cat <<EOF
Usage: $0 {start|stop|status|backup-reminder}

  start            start MongoDB and the controller, then wait for the web UI
  stop             stop both containers, leaving their data in place
  status           show the state of both containers
  backup-reminder  print what to do after changing settings

The controller is only needed to adopt a device or change a setting. The
access point keeps serving every SSID while it is stopped.
EOF
}

check_memory() {
  local avail
  avail="$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)"
  say "  memory available: ${avail} MB, needed about ${NEED_MB} MB"
  if [ "$avail" -lt "$NEED_MB" ]; then
    warn "this host reports less memory than the controller needs."
    warn "much of the used memory is usually ZFS ARC, which the kernel"
    warn "reclaims under pressure. Check with:"
    warn "  awk '/^size/ {print \$1, \$3/1073741824}' /proc/spl/kstat/zfs/arcstats"
    warn "Continuing. Stop a heavy container if the start fails."
  fi
}

do_start() {
  cd "$COMPOSE_DIR" || { warn "cannot enter $COMPOSE_DIR"; exit 1; }
  check_memory

  if [ ! -s /mnt/BIG/filme/configs/unifi-db/init-mongo.sh ]; then
    warn "init-mongo.sh is missing. MongoDB will create no UniFi user and"
    warn "the controller cannot connect. Put it in place first."
    exit 1
  fi

  say "starting MongoDB and the controller"
  docker compose --profile "$PROFILE" up -d || { warn "compose failed"; exit 1; }

  say "waiting for the web UI, up to 180 seconds"
  local i=0
  while [ "$i" -lt 36 ]; do
    if curl -sk -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null | grep -qE '^(200|302)$'; then
      say ""
      say "  ready: $URL"
      say ""
      say "  FIRST START ONLY: set Settings -> System -> Advanced ->"
      say "  Inform Host to 10.30.0.12, or the access point cannot adopt."
      say ""
      return 0
    fi
    i=$((i + 1))
    sleep 5
  done

  warn "the web UI did not answer within 180 seconds. Read the log:"
  warn "  docker logs --tail 40 unifi"
  warn "  docker logs --tail 40 unifi-db"
  return 1
}

do_stop() {
  cd "$COMPOSE_DIR" || { warn "cannot enter $COMPOSE_DIR"; exit 1; }
  say "stopping the controller and MongoDB"
  # stop, NOT down: down removes the containers, and the restart policy
  # would then not apply. stop leaves them in place and stopped.
  docker compose --profile "$PROFILE" stop
  say ""
  say "  stopped. The access point keeps serving every SSID."
  say ""
}

do_status() {
  docker ps -a --filter name=unifi --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  say ""
  if curl -sk -o /dev/null -w '' "$URL" 2>/dev/null; then
    say "  web UI answers at $URL"
  else
    say "  web UI does not answer. The controller is stopped, or still starting."
  fi
}

do_backup_reminder() {
  cat <<EOF

After you change a setting, take a backup BEFORE you stop the controller:

  Settings -> System -> Backup -> Download Backup

The scheduled auto-backup never runs while the controller is off, so a
manual backup is the only copy. It lands in:

  /mnt/BIG/filme/configs/unifi/data/backup/

That path is inside configs/, therefore bender-replicate.sh copies it to
amy each night.

EOF
}

case "${1:-}" in
  start)           do_start ;;
  stop)            do_stop ;;
  status)          do_status ;;
  backup-reminder) do_backup_reminder ;;
  *)               usage; exit 1 ;;
esac
