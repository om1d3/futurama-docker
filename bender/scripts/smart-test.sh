#!/bin/bash
# ============================================
# smart-test.sh
# Version: 1.1
# Host: bender (TrueNAS Scale)
# ============================================
# Backlog item 15-D: SMART testing + health alerting, independent of
# the TrueNAS middleware API. Context: 25.10 removed the SMART
# scheduling UI; the upgrade auto-converted schedules into
# `midclt call disk.smart_test ...` cron jobs whose API signature
# then drifted and broke (exit 1). This script talks to smartctl
# directly — no TrueNAS release can silently break it.
#
# Modes:
#   short    start SHORT self-test on all eligible disks
#   long     start LONG (extended) self-test on all eligible disks
#   report   read health + critical attributes, compare to saved
#            state, push ntfy ONLY on degradation or failed health
#   status   human-readable table to stdout (manual use)
#
# Eligible disks: whole disks (sd*/nvme*) that answer smartctl.
# The MicroSD boot device (mmcblk) is skipped automatically.
#
# ============================================
# TRUENAS UI CRON SETUP (System -> Advanced -> Cron Jobs, run as root)
#   1. bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh short
#      Schedule: 0 5 * * 1        (weekly, Monday 05:00)
#   2. bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh long
#      Schedule: 0 5 1 * *        (monthly, 1st 05:00)
#   3. bash /mnt/BIG/filme/docker-compose/scripts/smart-test.sh report
#      Schedule: 0 18 * * *       (daily 18:00 — long tests started at
#                                  05:00 have finished on most disks)
# DELETE the broken auto-converted entry:
#   midclt call disk.smart_test LONG '["*"]'
# ============================================
# Critical attributes watched (raw value increases trigger alerts):
#   5   Reallocated_Sector_Ct     — sectors remapped: disk is dying
#   187 Reported_Uncorrect        — uncorrectable read errors
#   197 Current_Pending_Sector    — sectors awaiting remap
#   198 Offline_Uncorrectable     — surface defects found offline
#   199 UDMA_CRC_Error_Count      — cable/backplane errors (warn only)
# NVMe equivalents checked via smartctl JSON when applicable.
# ============================================
# v1.1 (2026-07-20):
#   - FIXED: in-progress detection now reads the Self-test execution
#     status from smartctl -c (the -a phrase grep missed WD180EDGZ's
#     reporting format; status showed IN-TEST=no while 10% remained)
#   - FIXED: starter classifies smartctl output by text — "Can't start
#     self-test" = SKIP (in progress), not FAILED; success requires
#     "Testing has begun"; only true refusals alert via ntfy
# ============================================

set -uo pipefail

# ---------- configuration ----------
NTFY_URL="http://10.30.0.11:8888/bender-smart"
LOG_DIR="/mnt/BIG/filme/docker-compose/configs/secure-update/logs"
STATE_DIR="/mnt/BIG/filme/docker-compose/configs/secure-update/smart-state"
LOG_FILE="${LOG_DIR}/smart-$(date +%Y-%m-%d).log"

CRITICAL_ATTRS=(5 187 197 198)   # alert on any raw increase
WARNING_ATTRS=(199)              # notify low-priority on increase

mkdir -p "${LOG_DIR}" "${STATE_DIR}"

# ---------- helpers ----------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"; }

notify() { # $1=title $2=message $3=priority
  curl -s -o /dev/null -m 10 \
    -H "Title: $1" -H "Priority: ${3:-default}" -H "Tags: minidisc" \
    -d "$2" "${NTFY_URL}" 2>/dev/null || true
}

eligible_disks() {
  # whole disks only; skip the MicroSD boot device and anything
  # that does not answer smartctl
  lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | while read -r name; do
    [[ "${name}" == mmcblk* ]] && continue
    local_dev="/dev/${name}"
    if smartctl -i "${local_dev}" >/dev/null 2>&1; then
      echo "${local_dev}"
    fi
  done
}

disk_id() { # stable identifier for state files: model_serial
  smartctl -i "$1" 2>/dev/null \
    | awk -F': *' '/Device Model|Model Number/{m=$2} /Serial Number/{s=$2} END{gsub(/[ \/]/,"_",m); gsub(/[ \/]/,"_",s); print m"_"s}'
}

test_in_progress() { # returns 0 if a self-test is currently running
  # Primary: Self-test execution status block from -c (value 24x =
  # in progress; wording varies by firmware, so match broadly)
  smartctl -c "$1" 2>/dev/null \
    | sed -n '/Self-test execution status/,/^$/p' \
    | grep -qiE "in progress|of test remaining" && return 0
  # Fallback: the -a phrasing some drives use
  smartctl -a "$1" 2>/dev/null | grep -qi "self-test routine in progress"
}

# ---------- test starters ----------
start_tests() { # $1 = short|long
  local kind="$1"
  local started=0 skipped=0
  log "=== Starting ${kind^^} self-tests ==="
  for dev in $(eligible_disks); do
    if test_in_progress "${dev}"; then
      log "SKIP ${dev}: self-test already in progress"
      skipped=$((skipped+1))
      continue
    fi
    out=$(smartctl -t "${kind}" "${dev}" 2>&1)
    echo "${out}" >> "${LOG_FILE}"
    if echo "${out}" | grep -qi "Testing has begun"; then
      log "Started ${kind} test: ${dev} ($(disk_id "${dev}"))"
      started=$((started+1))
    elif echo "${out}" | grep -qi "Can't start self-test"; then
      log "SKIP ${dev}: a test is already in progress (smartctl refused)"
      skipped=$((skipped+1))
    else
      log "FAILED to start ${kind} test on ${dev}"
      notify "⚠️ SMART: could not start ${kind} test" "${dev} on bender refused the test command — see ${LOG_FILE}" "high"
    fi
  done
  log "=== ${kind^^} tests: ${started} started, ${skipped} skipped ==="
}

# ---------- attribute reading ----------
get_attr_raw() { # $1=dev $2=attr_id -> raw value (SATA) or empty
  smartctl -A "$1" 2>/dev/null | awk -v id="$2" '$1 == id {print $10; exit}'
}

get_nvme_field() { # $1=dev $2=field -> value or empty
  smartctl -A "$1" 2>/dev/null | grep -i "^${2}" | awk -F': *' '{gsub(/[,%]/,"",$2); print $2}' | awk '{print $1}'
}

overall_health() { # PASSED / FAILED / UNKNOWN
  local h
  h=$(smartctl -H "$1" 2>/dev/null | grep -Ei "overall-health|SMART Health Status" | awk -F': *' '{print $2}')
  case "${h}" in
    PASSED|OK) echo "PASSED" ;;
    "") echo "UNKNOWN" ;;
    *) echo "FAILED" ;;
  esac
}

last_selftest_result() {
  smartctl -l selftest "$1" 2>/dev/null | awk 'NR==7 {sub(/^# *1 */,""); print; exit}'
}

# ---------- report mode ----------
run_report() {
  log "=== SMART report starting ==="
  local problems="" warnings=""

  for dev in $(eligible_disks); do
    local id health state_file is_nvme
    id=$(disk_id "${dev}")
    state_file="${STATE_DIR}/${id}.state"
    health=$(overall_health "${dev}")
    is_nvme=0; [[ "${dev}" == /dev/nvme* ]] && is_nvme=1

    log "--- ${dev} (${id}): health=${health}"

    if [[ "${health}" == "FAILED" ]]; then
      problems="${problems}${dev} (${id}): overall health FAILED\n"
    fi

    # gather current values
    declare -A current=()
    if [[ ${is_nvme} -eq 1 ]]; then
      current[media_errors]=$(get_nvme_field "${dev}" "Media and Data Integrity Errors")
      current[percent_used]=$(get_nvme_field "${dev}" "Percentage Used")
      current[spare]=$(get_nvme_field "${dev}" "Available Spare")
    else
      for attr in "${CRITICAL_ATTRS[@]}" "${WARNING_ATTRS[@]}"; do
        current[${attr}]=$(get_attr_raw "${dev}" "${attr}")
      done
    fi

    # compare with previous state
    if [[ -f "${state_file}" ]]; then
      while IFS='=' read -r key old; do
        local new="${current[${key}]:-}"
        [[ -z "${new}" || -z "${old}" ]] && continue
        # numeric compare where possible; raw fields can carry suffixes
        local new_n="${new%%[^0-9]*}" old_n="${old%%[^0-9]*}"
        [[ -z "${new_n}" || -z "${old_n}" ]] && continue
        if [[ "${new_n}" -gt "${old_n}" ]]; then
          local line="${dev} (${id}): attr ${key} increased ${old_n} -> ${new_n}"
          log "DEGRADATION: ${line}"
          if [[ " ${WARNING_ATTRS[*]} " == *" ${key} "* ]]; then
            warnings="${warnings}${line}\n"
          else
            problems="${problems}${line}\n"
          fi
        fi
      done < "${state_file}"
    else
      log "No previous state for ${id} — baseline created"
    fi

    # write new state
    : > "${state_file}"
    for key in "${!current[@]}"; do
      [[ -n "${current[${key}]}" ]] && echo "${key}=${current[${key}]}" >> "${state_file}"
    done

    log "last self-test: $(last_selftest_result "${dev}")"
  done

  # notifications: only on findings
  if [[ -n "${problems}" ]]; then
    notify "🚨 bender SMART: disk degradation" "$(echo -e "${problems}")" "urgent"
    log "ALERT sent (critical)"
  fi
  if [[ -n "${warnings}" ]]; then
    notify "⚠️ bender SMART: warning attributes" "$(echo -e "${warnings}")\nUsually cable/backplane — reseat before suspecting the disk." "default"
    log "Alert sent (warning)"
  fi
  if [[ -z "${problems}" && -z "${warnings}" ]]; then
    log "All disks clean — no notification (by design)"
  fi
  log "=== SMART report complete ==="
}

# ---------- status mode ----------
show_status() {
  printf "%-12s %-30s %-8s %-10s %s\n" "DEVICE" "IDENTITY" "HEALTH" "IN-TEST" "LAST SELF-TEST"
  for dev in $(eligible_disks); do
    local intest="no"
    test_in_progress "${dev}" && intest="RUNNING"
    printf "%-12s %-30s %-8s %-10s %s\n" \
      "${dev}" "$(disk_id "${dev}")" "$(overall_health "${dev}")" \
      "${intest}" "$(last_selftest_result "${dev}")"
  done
  echo ""
  echo "Watched attrs — critical: ${CRITICAL_ATTRS[*]} | warning: ${WARNING_ATTRS[*]}"
  echo "State files: ${STATE_DIR}"
}

# ---------- main ----------
case "${1:-help}" in
  short|long) start_tests "$1" ;;
  report)     run_report ;;
  status)     show_status ;;
  *)
    cat << EOF
Usage: $0 <short|long|report|status>

  short    start SHORT self-test on all eligible disks (weekly cron)
  long     start LONG self-test on all eligible disks (monthly cron)
  report   compare health/attributes to saved state; ntfy on findings (daily cron)
  status   print current table (manual)

TrueNAS: invoke via 'bash $0 <mode>' in UI cron jobs (pool is noexec).
EOF
    ;;
esac
