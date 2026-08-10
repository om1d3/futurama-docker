#!/bin/bash
# ============================================
# Secure Container Update Script
# Version: 1.3
# Host: bender (TrueNAS Scale)
# ============================================
# This script implements a secure container update workflow:
# 1. Checks for available updates
# 2. Pulls new images
# 3. Scans with Trivy for vulnerabilities
# 4. Deploys only if no CRITICAL or HIGH vulnerabilities
# 5. Runs health checks and functional tests
# 6. Auto-rollback on failure
# ============================================
# Schedule: Saturday 04:30 AM (weekly), Daily 04:30 AM (retry)
# ============================================
# USAGE: Due to TrueNAS execution restrictions, run with:
# cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh weekly && rm /tmp/secure-container-update.sh
# ============================================
# v1.1: Fixed Immich API endpoint, removed bc dependency
# v1.2: Added throttling and system health checks to prevent ZFS I/O saturation
#       - Added THROTTLE_DELAY (60s between container updates)
#       - Added MAX_LOAD check (skip if load > 4.0)
#       - Added MAX_IOWAIT check (skip if iowait > 50%)
#       - Added check_system_health() function
#       - Added wait_for_system_recovery() function
# v1.3: Added per-app database + HTTP health checks (compose v115 services)
#       - Added vikunja_db_access, forgejo_db_access, baikal_db_access
#         functional tests (schema-level probes, not just SELECT 1)
#       - forgejo_db_access authenticates as the dedicated forgejo user,
#         verifying credentials/permissions survived the postgres upgrade
#       - Added vikunja_http (:3456/api/v1/info) and forgejo_http (:3030)
#         integration tests
#       - Reference these in critical-containers.json to activate
# ============================================

set -uo pipefail

# ============================================
# CONFIGURATION
# ============================================

# Paths (all under /mnt/BIG/filme/docker-compose/)
BASE_DIR="/mnt/BIG/filme/docker-compose"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yaml"
ENV_FILE="${BASE_DIR}/.env"
CONFIG_DIR="${BASE_DIR}/configs/secure-update"
SCRIPTS_DIR="${BASE_DIR}/scripts"
REPORTS_DIR="${BASE_DIR}/reports/weekly-reports"
LOG_DIR="${CONFIG_DIR}/logs"
SCAN_REPORTS_DIR="${CONFIG_DIR}/scan-reports"

# Files
RETRY_QUEUE="${CONFIG_DIR}/retry-queue.json"
CRITICAL_CONTAINERS="${CONFIG_DIR}/critical-containers.json"

# Thresholds
MAX_CRITICAL=0
MAX_HIGH=0

# Image backup retention
IMAGE_BACKUP_COUNT=3

# Report retention (days)
REPORT_RETENTION_DAYS=180

# Trivy server
TRIVY_SERVER="http://localhost:8082"

# ============================================
# THROTTLING CONFIGURATION (v1.2)
# Prevents ZFS I/O saturation on HP MicroServer Gen8
# ============================================
THROTTLE_DELAY=60          # Seconds to wait between container updates
MAX_LOAD=4.0               # Skip updates if 1-minute load average exceeds this
MAX_IOWAIT=50              # Skip updates if I/O wait percentage exceeds this
RECOVERY_WAIT=120          # Seconds to wait for system recovery before retrying
MAX_RECOVERY_ATTEMPTS=5    # Maximum attempts to wait for system recovery

# Notification (loaded from .env)
source "${ENV_FILE}" 2>/dev/null || true
NTFY_URL="${WATCHTOWER_NOTIFICATION_URL:-}"

# Timestamps
DATE=$(date +%Y-%m-%d)
DATETIME=$(date +%Y-%m-%d_%H-%M-%S)
LOG_FILE="${LOG_DIR}/${DATE}.log"

# ============================================
# INITIALIZATION
# ============================================

mkdir -p "${CONFIG_DIR}" "${LOG_DIR}" "${SCAN_REPORTS_DIR}" "${REPORTS_DIR}"
mkdir -p "${BASE_DIR}/backups/postgres/pre-upgrade"

# Initialize retry queue if not exists
if [[ ! -f "${RETRY_QUEUE}" ]]; then
    echo '{"containers": []}' > "${RETRY_QUEUE}"
fi

# Initialize critical containers list if not exists
if [[ ! -f "${CRITICAL_CONTAINERS}" ]]; then
    cat > "${CRITICAL_CONTAINERS}" << 'EOF'
{
  "critical": [
    {
      "name": "postgres",
      "pre_upgrade": ["backup_postgres"],
      "health_checks": ["pg_isready", "pg_connect", "pg_databases"],
      "functional_tests": ["immich_db_access", "hedgedoc_db_access"],
      "integration_tests": ["immich_api_ping", "hedgedoc_http"],
      "dependent_services": ["immich_server", "immich_machine_learning", "hedgedoc", "postgres-backup"]
    }
  ],
  "non_critical": [
    "pihole",
    "keepalived",
    "tsdproxy",
    "immich_server",
    "immich_redis"
  ]
}
EOF
fi

# ============================================
# LOGGING FUNCTIONS
# ============================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_success() { log "SUCCESS" "$1"; }

# ============================================
# NOTIFICATION FUNCTIONS
# ============================================

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-package}"
    
    if [[ -n "${NTFY_URL}" ]]; then
        curl -s -o /dev/null \
            -H "Title: ${title}" \
            -H "Priority: ${priority}" \
            -H "Tags: ${tags}" \
            -d "${message}" \
            "${NTFY_URL}" 2>/dev/null || true
    fi
}

# ============================================
# SYSTEM HEALTH FUNCTIONS (v1.2)
# ============================================

get_load_average() {
    # Get 1-minute load average
    awk '{print $1}' /proc/loadavg
}

get_iowait() {
    # Get current I/O wait percentage from iostat
    # Returns integer percentage
    local iowait=$(iostat -c 1 2 2>/dev/null | tail -1 | awk '{print $4}' | cut -d. -f1)
    echo "${iowait:-0}"
}

check_system_health() {
    # Returns 0 if system is healthy enough to proceed
    # Returns 1 if system is overloaded
    
    local current_load=$(get_load_average)
    local current_iowait=$(get_iowait)
    
    log_info "System health check: load=${current_load}, iowait=${current_iowait}%"
    
    # Check load average (using awk for float comparison)
    local load_ok=$(awk -v current="${current_load}" -v max="${MAX_LOAD}" 'BEGIN {print (current < max) ? 1 : 0}')
    
    if [[ "${load_ok}" -eq 0 ]]; then
        log_warn "System load (${current_load}) exceeds threshold (${MAX_LOAD})"
        return 1
    fi
    
    # Check I/O wait
    if [[ "${current_iowait}" -gt "${MAX_IOWAIT}" ]]; then
        log_warn "I/O wait (${current_iowait}%) exceeds threshold (${MAX_IOWAIT}%)"
        return 1
    fi
    
    log_info "System health OK"
    return 0
}

wait_for_system_recovery() {
    # Wait for system to recover before proceeding
    # Returns 0 if system recovers, 1 if max attempts reached
    
    local attempts=0
    
    while [[ ${attempts} -lt ${MAX_RECOVERY_ATTEMPTS} ]]; do
        if check_system_health; then
            log_info "System recovered after ${attempts} wait cycles"
            return 0
        fi
        
        attempts=$((attempts + 1))
        log_warn "System overloaded, waiting ${RECOVERY_WAIT}s for recovery (attempt ${attempts}/${MAX_RECOVERY_ATTEMPTS})"
        sleep "${RECOVERY_WAIT}"
    done
    
    log_error "System did not recover after ${MAX_RECOVERY_ATTEMPTS} attempts"
    return 1
}

# ============================================
# CONTAINER MANAGEMENT FUNCTIONS
# ============================================

get_running_containers() {
    docker ps --format '{{.Names}}' | sort
}

get_current_image() {
    local container="$1"
    docker inspect "${container}" --format '{{.Config.Image}}' 2>/dev/null || echo ""
}

get_current_image_id() {
    local container="$1"
    docker inspect "${container}" --format '{{.Image}}' 2>/dev/null || echo ""
}

pull_new_image() {
    local image="$1"
    log_info "Pulling image: ${image}"
    docker pull "${image}" 2>&1 | tee -a "${LOG_FILE}"
    return ${PIPESTATUS[0]}
}

get_latest_image_id() {
    local image="$1"
    docker inspect "${image}" --format '{{.Id}}' 2>/dev/null || echo ""
}

is_update_available() {
    local container="$1"
    local current_id=$(get_current_image_id "${container}")
    local image=$(get_current_image "${container}")
    
    if [[ -z "${image}" ]]; then
        return 1
    fi
    
    pull_new_image "${image}" > /dev/null 2>&1
    local latest_id=$(get_latest_image_id "${image}")
    
    if [[ "${current_id}" != "${latest_id}" ]]; then
        return 0
    fi
    return 1
}

# ============================================
# IMAGE BACKUP FUNCTIONS
# ============================================

backup_image() {
    local container="$1"
    local image=$(get_current_image "${container}")
    local base_image=$(echo "${image}" | cut -d: -f1)
    
    log_info "Creating backup tags for ${container}"
    
    # Rotate backups: backup-3 -> delete, backup-2 -> backup-3, backup-1 -> backup-2, current -> backup-1
    for i in $(seq $((IMAGE_BACKUP_COUNT)) -1 1); do
        local old_tag="${base_image}:backup-${i}"
        
        if docker image inspect "${old_tag}" > /dev/null 2>&1; then
            if [[ ${i} -eq ${IMAGE_BACKUP_COUNT} ]]; then
                docker rmi "${old_tag}" 2>/dev/null || true
            else
                local new_tag="${base_image}:backup-$((i + 1))"
                docker tag "${old_tag}" "${new_tag}" 2>/dev/null || true
            fi
        fi
    done
    
    # Tag current as backup-1
    local current_id=$(get_current_image_id "${container}")
    if [[ -n "${current_id}" ]]; then
        docker tag "${current_id}" "${base_image}:backup-1"
        log_success "Tagged current image as ${base_image}:backup-1"
    fi
}

restore_backup() {
    local container="$1"
    local image=$(get_current_image "${container}")
    local base_image=$(echo "${image}" | cut -d: -f1)
    local backup_tag="${base_image}:backup-1"
    
    log_warn "Restoring ${container} from backup"
    
    if docker image inspect "${backup_tag}" > /dev/null 2>&1; then
        docker tag "${backup_tag}" "${image}"
        log_success "Restored ${image} from ${backup_tag}"
        return 0
    else
        log_error "No backup found for ${container}"
        return 1
    fi
}

# ============================================
# TRIVY SCANNING FUNCTIONS
# ============================================

scan_image() {
    local image="$1"
    local safe_name=$(echo ${image} | tr '/:' '_')
    local report_file="${SCAN_REPORTS_DIR}/${DATE}/${safe_name}.json"
    
    mkdir -p "${SCAN_REPORTS_DIR}/${DATE}"
    
    log_info "Scanning image: ${image}"
    
    # Use Trivy client mode to connect to server
    if command -v trivy &> /dev/null; then
        trivy image --server "${TRIVY_SERVER}" --format json --output "${report_file}" "${image}" 2>&1 | tee -a "${LOG_FILE}"
    else
        # Fallback: use docker to run trivy
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:latest image --server "${TRIVY_SERVER}" \
            --format json "${image}" > "${report_file}" 2>&1
    fi
    
    if [[ -f "${report_file}" && -s "${report_file}" ]]; then
        echo "${report_file}"
    else
        echo ""
    fi
}

count_vulnerabilities() {
    local report_file="$1"
    local severity="$2"
    
    if [[ ! -f "${report_file}" ]]; then
        echo "0"
        return
    fi
    
    local count=$(jq -r "[.Results[]?.Vulnerabilities[]? | select(.Severity == \"${severity}\")] | length" "${report_file}" 2>/dev/null || echo "0")
    echo "${count}"
}

check_scan_result() {
    local report_file="$1"
    
    local critical=$(count_vulnerabilities "${report_file}" "CRITICAL")
    local high=$(count_vulnerabilities "${report_file}" "HIGH")
    local medium=$(count_vulnerabilities "${report_file}" "MEDIUM")
    local low=$(count_vulnerabilities "${report_file}" "LOW")
    
    log_info "Scan results: CRITICAL=${critical}, HIGH=${high}, MEDIUM=${medium}, LOW=${low}"
    
    if [[ ${critical} -gt ${MAX_CRITICAL} ]]; then
        log_error "CRITICAL vulnerabilities (${critical}) exceed threshold (${MAX_CRITICAL})"
        return 1
    fi
    
    if [[ ${high} -gt ${MAX_HIGH} ]]; then
        log_error "HIGH vulnerabilities (${high}) exceed threshold (${MAX_HIGH})"
        return 1
    fi
    
    log_success "Scan passed: No CRITICAL or HIGH vulnerabilities"
    return 0
}

# ============================================
# POSTGRES-SPECIFIC FUNCTIONS
# ============================================

backup_postgres() {
    log_info "Creating PostgreSQL backup before upgrade"
    
    local backup_dir="${BASE_DIR}/backups/postgres/pre-upgrade"
    local backup_file="${backup_dir}/backup-${DATETIME}.sql"
    
    mkdir -p "${backup_dir}"
    
    if docker exec postgres pg_dumpall -U postgres > "${backup_file}" 2>&1; then
        if [[ -s "${backup_file}" ]]; then
            local size=$(du -h "${backup_file}" | cut -f1)
            log_success "PostgreSQL backup created: ${backup_file} (${size})"
            return 0
        fi
    fi
    
    log_error "PostgreSQL backup failed!"
    rm -f "${backup_file}"
    return 1
}

# ============================================
# HEALTH CHECK FUNCTIONS
# ============================================

run_health_check() {
    local container="$1"
    local check_type="$2"
    
    case "${check_type}" in
        # Container-level checks
        "container_running")
            docker ps --filter "name=${container}" --filter "status=running" -q | grep -q .
            ;;
        "container_not_restarting")
            local restart_count=$(docker inspect "${container}" --format '{{.RestartCount}}' 2>/dev/null || echo "999")
            [[ ${restart_count} -lt 3 ]]
            ;;
        "no_oom_kill")
            local oom=$(docker inspect "${container}" --format '{{.State.OOMKilled}}' 2>/dev/null || echo "true")
            [[ "${oom}" == "false" ]]
            ;;
        
        # PostgreSQL checks
        "pg_isready")
            docker exec postgres pg_isready -U postgres > /dev/null 2>&1
            ;;
        "pg_connect")
            docker exec postgres psql -U postgres -c "SELECT 1" > /dev/null 2>&1
            ;;
        "pg_databases")
            docker exec postgres psql -U postgres -c "\l" 2>/dev/null | grep -q "immich"
            ;;
        
        # PostgreSQL functional tests
        "immich_db_access")
            docker exec postgres psql -U postgres -d immich -c 'SELECT COUNT(*) FROM "user"' > /dev/null 2>&1
            ;;
        "hedgedoc_db_access")
            docker exec postgres psql -U postgres -d hedgedoc -c "SELECT 1" > /dev/null 2>&1
            ;;
        # v1.3: schema-level probe — proves the tasks table survived, not just connectivity
        "vikunja_db_access")
            docker exec postgres psql -U postgres -d vikunja -c 'SELECT COUNT(*) FROM tasks' > /dev/null 2>&1
            ;;
        # v1.3: authenticates as the dedicated forgejo user — verifies the
        # user's credentials and permissions survived the postgres upgrade
        "forgejo_db_access")
            docker exec postgres psql -U forgejo -d forgejo -c 'SELECT COUNT(*) FROM repository' > /dev/null 2>&1
            ;;
        # v1.3: connectivity probe; upgrade to a real table once the baikal
        # schema is confirmed (docker exec postgres psql -U postgres -d baikal -c '\dt')
        "baikal_db_access")
            docker exec postgres psql -U postgres -d baikal -c "SELECT 1" > /dev/null 2>&1
            ;;
        
        # Integration tests
        "immich_api_ping")
            curl -s -f "http://localhost:2283/api/server/ping" 2>/dev/null | grep -q "pong"
            ;;
        "hedgedoc_http")
            local code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3000" 2>/dev/null)
            [[ "${code}" =~ ^(200|302|301)$ ]]
            ;;
        # v1.3: vikunja API info endpoint returns 200 with instance metadata
        "vikunja_http")
            local vcode=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3456/api/v1/info" 2>/dev/null)
            [[ "${vcode}" == "200" ]]
            ;;
        # v1.3: forgejo web root (host port 3030)
        "forgejo_http")
            local fcode=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3030" 2>/dev/null)
            [[ "${fcode}" =~ ^(200|302|301)$ ]]
            ;;
        
        *)
            log_warn "Unknown health check: ${check_type}"
            return 0
            ;;
    esac
}

run_all_health_checks() {
    local container="$1"
    local check_types="$2"
    local all_passed=true
    
    for check in ${check_types}; do
        if run_health_check "${container}" "${check}"; then
            log_success "Health check passed: ${check}"
        else
            log_error "Health check failed: ${check}"
            all_passed=false
        fi
    done
    
    if ${all_passed}; then
        return 0
    else
        return 1
    fi
}

# ============================================
# CONTAINER UPDATE FUNCTIONS
# ============================================

is_critical_container() {
    local container="$1"
    jq -e ".critical[] | select(.name == \"${container}\")" "${CRITICAL_CONTAINERS}" > /dev/null 2>&1
}

get_critical_config() {
    local container="$1"
    local field="$2"
    jq -r ".critical[] | select(.name == \"${container}\") | .${field}[]?" "${CRITICAL_CONTAINERS}" 2>/dev/null | tr '\n' ' '
}

update_container() {
    local container="$1"
    local image=$(get_current_image "${container}")
    local is_critical=$(is_critical_container "${container}" && echo "true" || echo "false")
    
    log_info "=========================================="
    log_info "Updating container: ${container}"
    log_info "Image: ${image}"
    log_info "Critical: ${is_critical}"
    log_info "=========================================="
    
    # Step 1: Pull new image (BEFORE any database operations)
    log_info "Step 1: Pulling new image"
    if ! pull_new_image "${image}"; then
        log_error "Failed to pull new image"
        return 1
    fi
    
    # Step 2: Scan with Trivy (BEFORE any database operations)
    log_info "Step 2: Scanning with Trivy"
    local report_file=$(scan_image "${image}")
    
    if [[ -z "${report_file}" ]]; then
        log_error "Failed to scan image"
        return 1
    fi
    
    if ! check_scan_result "${report_file}"; then
        log_warn "Container ${container} blocked due to vulnerabilities"
        add_to_retry_queue "${container}"
        return 2
    fi
    
    # Step 3: Pre-upgrade actions (backup for critical containers)
    if [[ "${is_critical}" == "true" ]]; then
        log_info "Step 3: Running pre-upgrade actions"
        local pre_upgrade=$(get_critical_config "${container}" "pre_upgrade")
        
        for action in ${pre_upgrade}; do
            log_info "Running pre-upgrade action: ${action}"
            if ! ${action}; then
                log_error "Pre-upgrade action failed: ${action}"
                return 1
            fi
        done
    fi
    
    # Step 4: Stop container
    log_info "Step 4: Stopping container"
    docker stop "${container}" 2>&1 | tee -a "${LOG_FILE}"
    
    # Step 5: Backup current image
    log_info "Step 5: Backing up current image"
    backup_image "${container}"
    
    # Step 6: Start with new image
    log_info "Step 6: Starting with new image"
    cd "${BASE_DIR}"
    docker compose up -d --force-recreate "${container}" 2>&1 | tee -a "${LOG_FILE}"
    
    # Wait for container to start
    sleep 30
    
    # Step 7: Run health checks and functional tests
    log_info "Step 7: Running health checks"
    
    local checks="container_running container_not_restarting no_oom_kill"
    
    if [[ "${is_critical}" == "true" ]]; then
        checks="${checks} $(get_critical_config "${container}" "health_checks")"
        checks="${checks} $(get_critical_config "${container}" "functional_tests")"
        checks="${checks} $(get_critical_config "${container}" "integration_tests")"
    fi
    
    if ! run_all_health_checks "${container}" "${checks}"; then
        # Step 8: Rollback on failure
        log_error "Health checks failed - initiating rollback"
        rollback_container "${container}"
        return 1
    fi
    
    # Restart dependent services for critical containers
    if [[ "${is_critical}" == "true" ]]; then
        log_info "Restarting dependent services"
        local dependents=$(get_critical_config "${container}" "dependent_services")
        
        for dep in ${dependents}; do
            log_info "Restarting: ${dep}"
            docker compose up -d --force-recreate "${dep}" 2>&1 | tee -a "${LOG_FILE}"
        done
        
        sleep 30
        
        # Re-run integration tests after dependent restart
        log_info "Re-running integration tests after dependent restart"
        local integration_tests=$(get_critical_config "${container}" "integration_tests")
        
        if ! run_all_health_checks "${container}" "${integration_tests}"; then
            log_error "Integration tests failed after dependent restart - initiating rollback"
            rollback_container "${container}"
            return 1
        fi
    fi
    
    log_success "Container ${container} updated successfully"
    remove_from_retry_queue "${container}"
    return 0
}

rollback_container() {
    local container="$1"
    
    log_warn "=========================================="
    log_warn "ROLLBACK: ${container}"
    log_warn "=========================================="
    
    # Stop current container
    docker stop "${container}" 2>&1 | tee -a "${LOG_FILE}"
    
    # Restore backup image
    if restore_backup "${container}"; then
        # Start with restored image
        cd "${BASE_DIR}"
        docker compose up -d --force-recreate "${container}" 2>&1 | tee -a "${LOG_FILE}"
        
        sleep 30
        
        # Verify rollback
        if run_health_check "${container}" "container_running"; then
            log_success "Rollback successful for ${container}"
            
            # Restart dependent services
            if is_critical_container "${container}"; then
                local dependents=$(get_critical_config "${container}" "dependent_services")
                for dep in ${dependents}; do
                    docker compose up -d --force-recreate "${dep}" 2>&1 | tee -a "${LOG_FILE}"
                done
            fi
            
            send_notification \
                "⚠️ Container Rolled Back" \
                "Container ${container} was rolled back to previous version after failed health checks" \
                "high" \
                "warning,rotating_light"
            
            return 0
        fi
    fi
    
    log_error "Rollback FAILED for ${container}"
    send_notification \
        "🚨 CRITICAL: Rollback Failed" \
        "Container ${container} rollback failed! Manual intervention required!" \
        "urgent" \
        "rotating_light,skull"
    
    return 1
}

# ============================================
# RETRY QUEUE FUNCTIONS
# ============================================

add_to_retry_queue() {
    local container="$1"
    local current=$(cat "${RETRY_QUEUE}")
    
    if ! echo "${current}" | jq -e ".containers[] | select(. == \"${container}\")" > /dev/null 2>&1; then
        echo "${current}" | jq ".containers += [\"${container}\"]" > "${RETRY_QUEUE}"
        log_info "Added ${container} to retry queue"
    fi
}

remove_from_retry_queue() {
    local container="$1"
    local current=$(cat "${RETRY_QUEUE}")
    
    echo "${current}" | jq ".containers -= [\"${container}\"]" > "${RETRY_QUEUE}"
    log_info "Removed ${container} from retry queue"
}

get_retry_queue() {
    jq -r '.containers[]' "${RETRY_QUEUE}" 2>/dev/null
}

# ============================================
# REPORT GENERATION
# ============================================

generate_report() {
    local deployed="$1"
    local blocked="$2"
    local rolledback="$3"
    local unchanged="$4"
    local scan_type="$5"
    local skipped="${6:-}"
    
    local report_file="${REPORTS_DIR}/${DATE}-${scan_type}-report.md"
    
    local deployed_count=$(echo -e "${deployed}" | grep -c "✅" || echo 0)
    local blocked_count=$(echo -e "${blocked}" | grep -c "❌" || echo 0)
    local rolledback_count=$(echo -e "${rolledback}" | grep -c "⚠️" || echo 0)
    local unchanged_count=$(echo -e "${unchanged}" | grep -c "⏸️" || echo 0)
    local skipped_count=$(echo -e "${skipped}" | grep -c "⏭️" || echo 0)
    
    cat > "${report_file}" << EOF
# Container Update Report

**Host:** bender
**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Scan Type:** ${scan_type}

## Summary

| Status | Count |
|--------|-------|
| ✅ Deployed | ${deployed_count} |
| ❌ Blocked | ${blocked_count} |
| ⚠️ Rolled Back | ${rolledback_count} |
| ⏸️ Up to Date | ${unchanged_count} |
| ⏭️ Skipped (System Load) | ${skipped_count} |

## Deployed Containers

${deployed:-"None"}

## Blocked Containers (Vulnerability Issues)

${blocked:-"None"}

## Rolled Back Containers (Health Check Failures)

${rolledback:-"None"}

## Skipped Containers (System Overloaded)

${skipped:-"None"}

## Unchanged Containers

${unchanged:-"None"}

---
*Generated by secure-container-update.sh v1.3*
EOF

    log_info "Report generated: ${report_file}"
    echo "${report_file}"
}

# ============================================
# CLEANUP FUNCTIONS
# ============================================

cleanup_old_reports() {
    log_info "Cleaning up reports older than ${REPORT_RETENTION_DAYS} days"
    
    find "${SCAN_REPORTS_DIR}" -type d -mtime +${REPORT_RETENTION_DAYS} -exec rm -rf {} \; 2>/dev/null || true
    find "${REPORTS_DIR}" -type f -mtime +${REPORT_RETENTION_DAYS} -delete 2>/dev/null || true
    find "${LOG_DIR}" -type f -mtime +${REPORT_RETENTION_DAYS} -delete 2>/dev/null || true
}

# ============================================
# MAIN FUNCTIONS
# ============================================

weekly_scan() {
    log_info "=========================================="
    log_info "WEEKLY SCAN STARTING"
    log_info "=========================================="
    
    # v1.2: Initial system health check
    log_info "Performing initial system health check"
    if ! check_system_health; then
        log_warn "System is overloaded at start, waiting for recovery"
        if ! wait_for_system_recovery; then
            log_error "System did not recover, aborting weekly scan"
            send_notification \
                "🚨 Weekly Scan Aborted" \
                "System overloaded, weekly scan aborted on bender" \
                "high" \
                "warning"
            return 1
        fi
    fi
    
    send_notification \
        "📦 Weekly Container Scan Starting" \
        "Checking all containers for updates on bender" \
        "low" \
        "hourglass"
    
    local deployed=""
    local blocked=""
    local rolledback=""
    local unchanged=""
    local skipped=""
    local containers_processed=0
    
    for container in $(get_running_containers); do
        local image=$(get_current_image "${container}")
        
        # Skip containers without proper image info
        if [[ -z "${image}" ]]; then
            continue
        fi
        
        # Skip infrastructure containers that shouldn't be auto-updated
        if [[ "${container}" == "diun" || "${container}" == "trivy" ]]; then
            unchanged="${unchanged}- ⏸️ ${container} (infrastructure)\n"
            continue
        fi
        
        # v1.2: Check system health before each container (after first one)
        if [[ ${containers_processed} -gt 0 ]]; then
            log_info "Waiting ${THROTTLE_DELAY}s before next container (throttling)"
            sleep "${THROTTLE_DELAY}"
            
            if ! check_system_health; then
                log_warn "System overloaded, waiting for recovery before ${container}"
                if ! wait_for_system_recovery; then
                    log_warn "System did not recover, skipping remaining containers"
                    skipped="${skipped}- ⏭️ ${container} (system overloaded)\n"
                    
                    # Add remaining containers to skipped list
                    continue
                fi
            fi
        fi
        
        log_info "Checking: ${container}"
        
        if is_update_available "${container}"; then
            log_info "Update available for ${container}"
            
            local result=0
            update_container "${container}" || result=$?
            
            case ${result} in
                0)
                    deployed="${deployed}- ✅ ${container}\n"
                    ;;
                1)
                    rolledback="${rolledback}- ⚠️ ${container} (rolled back)\n"
                    ;;
                2)
                    blocked="${blocked}- ❌ ${container} (vulnerabilities)\n"
                    ;;
            esac
        else
            unchanged="${unchanged}- ⏸️ ${container}\n"
        fi
        
        containers_processed=$((containers_processed + 1))
    done
    
    # Generate report
    generate_report "${deployed}" "${blocked}" "${rolledback}" "${unchanged}" "weekly" "${skipped}"
    
    # Send summary notification
    local deployed_count=$(echo -e "${deployed}" | grep -c "✅" || echo 0)
    local blocked_count=$(echo -e "${blocked}" | grep -c "❌" || echo 0)
    local rolledback_count=$(echo -e "${rolledback}" | grep -c "⚠️" || echo 0)
    local unchanged_count=$(echo -e "${unchanged}" | grep -c "⏸️" || echo 0)
    local skipped_count=$(echo -e "${skipped}" | grep -c "⏭️" || echo 0)
    
    local summary="Deployed: ${deployed_count}, Blocked: ${blocked_count}, Rolled Back: ${rolledback_count}, Unchanged: ${unchanged_count}, Skipped: ${skipped_count}"
    
    send_notification \
        "📦 Weekly Container Update Complete" \
        "${summary}" \
        "default" \
        "white_check_mark"
    
    cleanup_old_reports
    
    log_success "Weekly scan completed"
}

daily_retry() {
    log_info "=========================================="
    log_info "DAILY RETRY SCAN STARTING"
    log_info "=========================================="
    
    local queue=$(get_retry_queue)
    
    if [[ -z "${queue}" ]]; then
        log_info "Retry queue is empty - nothing to do"
        return 0
    fi
    
    # v1.2: Initial system health check
    log_info "Performing initial system health check"
    if ! check_system_health; then
        log_warn "System is overloaded at start, waiting for recovery"
        if ! wait_for_system_recovery; then
            log_error "System did not recover, aborting daily retry"
            send_notification \
                "🚨 Daily Retry Aborted" \
                "System overloaded, daily retry aborted on bender" \
                "high" \
                "warning"
            return 1
        fi
    fi
    
    send_notification \
        "🔄 Daily Retry Scan Starting" \
        "Retrying blocked containers on bender" \
        "low" \
        "arrows_counterclockwise"
    
    local deployed=""
    local still_blocked=""
    local skipped=""
    local containers_processed=0
    
    for container in ${queue}; do
        # v1.2: Check system health before each container (after first one)
        if [[ ${containers_processed} -gt 0 ]]; then
            log_info "Waiting ${THROTTLE_DELAY}s before next container (throttling)"
            sleep "${THROTTLE_DELAY}"
            
            if ! check_system_health; then
                log_warn "System overloaded, waiting for recovery before ${container}"
                if ! wait_for_system_recovery; then
                    log_warn "System did not recover, skipping ${container}"
                    skipped="${skipped}- ⏭️ ${container} (system overloaded)\n"
                    continue
                fi
            fi
        fi
        
        log_info "Retrying: ${container}"
        
        local result=0
        update_container "${container}" || result=$?
        
        case ${result} in
            0)
                deployed="${deployed}- ✅ ${container} (now clean)\n"
                ;;
            *)
                still_blocked="${still_blocked}- ❌ ${container} (still blocked)\n"
                ;;
        esac
        
        containers_processed=$((containers_processed + 1))
    done
    
    # Generate report
    generate_report "${deployed}" "${still_blocked}" "" "" "retry" "${skipped}"
    
    # Send summary
    local deployed_count=$(echo -e "${deployed}" | grep -c "✅" || echo 0)
    local blocked_count=$(echo -e "${still_blocked}" | grep -c "❌" || echo 0)
    local skipped_count=$(echo -e "${skipped}" | grep -c "⏭️" || echo 0)
    
    local summary="Deployed: ${deployed_count}, Still Blocked: ${blocked_count}, Skipped: ${skipped_count}"
    
    send_notification \
        "🔄 Daily Retry Complete" \
        "${summary}" \
        "default" \
        "arrows_counterclockwise"
    
    log_success "Daily retry scan completed"
}

show_usage() {
    cat << EOF
Usage: $0 <command>

Commands:
    weekly      Run weekly full scan of all containers
    retry       Run daily retry scan of blocked containers
    scan        Scan a specific container: $0 scan <container_name>
    status      Show current status and retry queue
    health      Check current system health (v1.2)
    help        Show this help message

Examples:
    $0 weekly           # Run weekly scan
    $0 retry            # Run daily retry
    $0 scan postgres    # Scan and update postgres only
    $0 status           # Show current status
    $0 health           # Check system health

Note: Due to TrueNAS execution restrictions, run with:
    cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh weekly && rm /tmp/secure-container-update.sh

v1.2 Throttling Configuration:
    THROTTLE_DELAY=${THROTTLE_DELAY}s between container updates
    MAX_LOAD=${MAX_LOAD} (skip if 1-min load average exceeds)
    MAX_IOWAIT=${MAX_IOWAIT}% (skip if I/O wait exceeds)
    RECOVERY_WAIT=${RECOVERY_WAIT}s (wait time for system recovery)
    MAX_RECOVERY_ATTEMPTS=${MAX_RECOVERY_ATTEMPTS} (max recovery wait cycles)
EOF
}

show_status() {
    echo "=========================================="
    echo "Secure Container Update Status (v1.3)"
    echo "=========================================="
    echo ""
    echo "System Health:"
    local current_load=$(get_load_average)
    local current_iowait=$(get_iowait)
    echo "  Load Average (1min): ${current_load} (threshold: ${MAX_LOAD})"
    echo "  I/O Wait: ${current_iowait}% (threshold: ${MAX_IOWAIT}%)"
    if check_system_health 2>/dev/null; then
        echo "  Status: ✅ Healthy"
    else
        echo "  Status: ⚠️ Overloaded"
    fi
    echo ""
    echo "Throttling Configuration:"
    echo "  Delay between updates: ${THROTTLE_DELAY}s"
    echo "  Recovery wait time: ${RECOVERY_WAIT}s"
    echo "  Max recovery attempts: ${MAX_RECOVERY_ATTEMPTS}"
    echo ""
    echo "Retry Queue:"
    local queue=$(get_retry_queue)
    if [[ -z "${queue}" ]]; then
        echo "  (empty)"
    else
        for container in ${queue}; do
            echo "  - ${container}"
        done
    fi
    echo ""
    echo "Critical Containers:"
    jq -r '.critical[].name' "${CRITICAL_CONTAINERS}" 2>/dev/null | while read name; do
        echo "  - ${name}"
    done
    echo ""
    echo "Recent Logs:"
    if [[ -f "${LOG_FILE}" ]]; then
        tail -5 "${LOG_FILE}" 2>/dev/null
    else
        echo "  (no logs)"
    fi
}

show_health() {
    echo "=========================================="
    echo "System Health Check"
    echo "=========================================="
    echo ""
    local current_load=$(get_load_average)
    local current_iowait=$(get_iowait)
    echo "Current Metrics:"
    echo "  Load Average (1min): ${current_load}"
    echo "  I/O Wait: ${current_iowait}%"
    echo ""
    echo "Thresholds:"
    echo "  Max Load: ${MAX_LOAD}"
    echo "  Max I/O Wait: ${MAX_IOWAIT}%"
    echo ""
    if check_system_health; then
        echo "Result: ✅ System is healthy - safe to run updates"
    else
        echo "Result: ⚠️ System is overloaded - updates would be skipped"
    fi
}

# ============================================
# MAIN ENTRY POINT
# ============================================

main() {
    local command="${1:-help}"
    
    case "${command}" in
        weekly)
            weekly_scan
            ;;
        retry)
            daily_retry
            ;;
        scan)
            if [[ -z "${2:-}" ]]; then
                log_error "Container name required"
                exit 1
            fi
            # v1.2: Check system health before single container scan
            if ! check_system_health; then
                log_warn "System is overloaded"
                read -p "Continue anyway? (y/N) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_info "Scan aborted by user"
                    exit 0
                fi
            fi
            update_container "$2"
            ;;
        status)
            show_status
            ;;
        health)
            show_health
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
