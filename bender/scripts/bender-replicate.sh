#!/bin/bash
# ============================================
# bender-replicate.sh
# Version: 1.2
# Host: bender (TrueNAS Scale) → amy (10.30.0.11)
# ============================================
# Backlog item 01-A (partial): off-machine, on-site copy of bender's
# critical small data. Media is deliberately OUT of scope — this
# protects the rebuildability layer, not the library.
#
# What it copies:
#   /mnt/BIG/filme/configs/           (all service configs incl.
#                                      vaultwarden, forgejo, pihole)
#   /mnt/BIG/filme/backups/postgres/  (daily/weekly/monthly dumps)
#   /mnt/BIG/filme/docker-compose/    (compose, .env, scripts,
#                                      secure-update state)
#
# How: rsync over SSH to kube@amy with daily hardlink rotation —
# each day is a full browsable tree, unchanged files cost zero
# extra space (hardlinks), RETAIN_DAYS days of history survive
# an rm/ransomware event propagating through a plain mirror.
#
# ============================================
# 1.1 CHANGES (2026-08-02):
#   - EXCLUDED configs/jellyfin/data/data/backups/ — Jellyfin's own
#     backup archives (7GB+ each, weekly). A backup inside a backup.
#     They ballooned the 07-23 and 07-31 snapshots to ~31G and filled
#     amy's disk. The config tree itself is already replicated.
#   - EXCLUDED configs/jellyfin/data/trickplay/ — scrub-preview cache,
#     regenerable. Not present today; guard for when it appears.
#   - MOVED the free-space check BEFORE the mkdir on amy. Aborted runs
#     no longer leave empty 4K date-directories behind.
#   - RAISED the free-space threshold from 5GB to 10GB. 5GB proved too
#     thin against real snapshot sizes.
# ============================================
# ONE-TIME SETUP
# 1. bender root's SSH key already trusts kube@amy (the DNS scraper
#    uses it). Verify:  ssh -o BatchMode=yes kube@10.30.0.11 true
# 2. On amy, create the destination with kube ownership:
#      sudo mkdir -p /docker/backups/bender-replica
#      sudo chown -R kube:kube /docker/backups/bender-replica
# 3. TrueNAS UI -> System -> Advanced -> Cron Jobs -> Add:
#      Command:  bash /mnt/BIG/filme/docker-compose/scripts/bender-replicate.sh
#      Schedule: 30 3 * * *   (daily 03:30 — after amy's 02:00 sss
#                              rsync, before the 04:30 update windows)
#      Run as:   root
#    (UI-defined jobs survive TrueNAS updates; crontab -e does not.)
# 4. First run by hand and inspect the log:
#      bash /mnt/BIG/filme/docker-compose/scripts/bender-replicate.sh
#      ssh kube@10.30.0.11 'ls -la /docker/backups/bender-replica/'
# ============================================

set -uo pipefail

# ---------- configuration ----------
DEST_HOST="kube@10.30.0.11"
DEST_BASE="/docker/backups/bender-replica"
RETAIN_DAYS=7

SOURCES=(
  "/mnt/BIG/filme/configs"
  "/mnt/BIG/filme/backups/postgres"
  "/mnt/BIG/filme/docker-compose"
)

# Regenerable bulk excluded — keeps the copy small and meaningful.
EXCLUDES=(
  # v1.2 FIX: each pattern is relative to its SOURCE, not to /mnt/BIG/filme.
  # The loop passes "${src}/" with a trailing slash, so rsync's transfer root
  # is the source directory itself and it tests paths like "trivy/". The
  # earlier "configs/trivy/" form matched nothing, and every directory listed
  # here was copied in full. Measured on 2026-08-21: trivy 3.0 GB and
  # jellyfin/cache 674 MB were present in the replica despite being listed.
  "--exclude=trivy/"                       # vuln DB cache, re-downloads
  "--exclude=jellyfin/cache/"              # image/chapter cache
  "--exclude=jellyfin/data/transcodes/"
  "--exclude=jellyfin/data/data/backups/"  # v1.1: Jellyfin's own archives
  "--exclude=jellyfin/data/trickplay/"     # v1.1: scrub-preview cache
  # v1.2: 7.9 GB of downloaded artwork. Rebuilds from the media library.
  # jellyfin/data/data/ is NOT excluded: it holds library.db, users and
  # watch state, and it is not regenerable.
  "--exclude=jellyfin/data/metadata/"
  "--exclude=tsdproxy/data/"               # tailscale state, re-auths
  "--exclude=reports/"                     # scan reports
  "--exclude=*.sock"
)

NTFY_URL="http://10.30.0.11:8888/bender-backup"
LOG_DIR="/mnt/BIG/filme/docker-compose/configs/secure-update/logs"
LOG_FILE="${LOG_DIR}/replicate-$(date +%Y-%m-%d).log"
LOCK_FILE="/tmp/bender-replicate.lock"

TODAY=$(date +%Y-%m-%d)
DEST_TODAY="${DEST_BASE}/${TODAY}"
DEST_LATEST="${DEST_BASE}/latest"

# ---------- helpers ----------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"; }

notify() { # $1=title $2=message $3=priority
  curl -s -o /dev/null -m 10 \
    -H "Title: $1" -H "Priority: ${3:-default}" -H "Tags: floppy_disk" \
    -d "$2" "${NTFY_URL}" 2>/dev/null || true
}

fail() {
  log "ERROR: $1"
  notify "🚨 bender replication FAILED" "$1 — see ${LOG_FILE}" "high"
  rm -f "${LOCK_FILE}"
  exit 1
}

# ---------- preflight ----------
mkdir -p "${LOG_DIR}"

if [[ -e "${LOCK_FILE}" ]]; then
  fail "Lock file exists (previous run still active or crashed): ${LOCK_FILE}"
fi
echo "$$" > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

ssh -o BatchMode=yes -o ConnectTimeout=10 "${DEST_HOST}" true 2>/dev/null \
  || fail "SSH to ${DEST_HOST} failed (BatchMode key check)"

for src in "${SOURCES[@]}"; do
  [[ -d "${src}" ]] || fail "Source missing: ${src}"
done

# Free-space sanity FIRST (v1.1): refuse if amy has <10GB free.
# Runs before mkdir so an abort leaves no empty date-directory.
AVAIL_KB=$(ssh "${DEST_HOST}" "df -Pk '${DEST_BASE}' | awk 'NR==2{print \$4}'")
if [[ "${AVAIL_KB:-0}" -lt 10485760 ]]; then
  fail "amy has <10GB free at ${DEST_BASE} (${AVAIL_KB}KB) — aborting before filling the disk"
fi

ssh "${DEST_HOST}" "mkdir -p '${DEST_TODAY}'" \
  || fail "Cannot create ${DEST_TODAY} on amy"

# ---------- replicate ----------
log "=== Replication starting → ${DEST_TODAY} (link-dest: latest) ==="
START=$(date +%s)
RSYNC_FAILED=0

# --link-dest makes unchanged files hardlinks into yesterday's tree:
# full daily snapshots at ~incremental cost.
LINKDEST_OPT=""
if ssh "${DEST_HOST}" "[ -d '${DEST_BASE}/latest' ]"; then
  LINKDEST_OPT="--link-dest=${DEST_BASE}/latest"
fi

for src in "${SOURCES[@]}"; do
  name=$(basename "${src}")
  log "Syncing ${src} ..."
  rsync -a --delete --numeric-ids --timeout=600 \
    ${LINKDEST_OPT:+"${LINKDEST_OPT}/${name}"} \
    "${EXCLUDES[@]}" \
    "${src}/" "${DEST_HOST}:${DEST_TODAY}/${name}/" \
    >> "${LOG_FILE}" 2>&1
  rc=$?
  # rsync 24 = files vanished mid-transfer (live system) — acceptable
  if [[ ${rc} -ne 0 && ${rc} -ne 24 ]]; then
    log "rsync failed for ${src} (exit ${rc})"
    RSYNC_FAILED=1
  fi
done

[[ ${RSYNC_FAILED} -eq 0 ]] || fail "One or more rsync transfers failed (see log)"

# ---------- rotate ----------
ssh "${DEST_HOST}" "ln -sfn '${DEST_TODAY}' '${DEST_BASE}/latest'" \
  || fail "Failed to update latest symlink"

# Delete dated dirs older than RETAIN_DAYS (only our YYYY-MM-DD dirs)
ssh "${DEST_HOST}" "find '${DEST_BASE}' -maxdepth 1 -type d \
  -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' -mtime +${RETAIN_DAYS} \
  -exec rm -rf {} +" \
  || log "WARN: retention cleanup returned nonzero (continuing)"

# ---------- report ----------
ELAPSED=$(( $(date +%s) - START ))
SIZE=$(ssh "${DEST_HOST}" "du -sh '${DEST_TODAY}' 2>/dev/null | cut -f1")
TOTAL=$(ssh "${DEST_HOST}" "du -sh '${DEST_BASE}' 2>/dev/null | cut -f1")
COUNT=$(ssh "${DEST_HOST}" "find '${DEST_BASE}' -maxdepth 1 -type d -name '20*' | wc -l")

log "=== Done in ${ELAPSED}s — today: ${SIZE:-?}, all ${COUNT:-?} snapshots: ${TOTAL:-?} (apparent; hardlinks shared) ==="
notify "💾 bender replication OK" \
  "Snapshot ${TODAY}: ${SIZE:-?} in ${ELAPSED}s. ${COUNT:-?} snapshots retained (${RETAIN_DAYS}d)." \
  "low"

exit 0
