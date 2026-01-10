#!/bin/bash
# ============================================
# AMY - Secure Container Update Script
# Version: 1.0
# ============================================
# This script orchestrates container updates with:
# 1. Vulnerability scanning via Trivy
# 2. Health checks before/after updates
# 3. Automatic rollback on failure
# 4. ntfy notifications
# ============================================
# Schedule: Wednesday 04:30 AM (weekly)
# ============================================

set -uo pipefail

# ============================================
# CONFIGURATION
# ============================================

# Paths - Amy uses /docker/ (not /mnt/BIG/filme/ like bender)
BASE_DIR="/docker-compose"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yaml"
ENV_FILE="${BASE_DIR}/.env"
CONFIG_DIR="${BASE_DIR}/configs/secure-update"
SCRIPTS_DIR="${BASE_DIR}/scripts"
REPORTS_DIR="${BASE_DIR}/reports/weekly-reports"
LOG_DIR="${CONFIG_DIR}/logs"
SCAN_REPORTS_DIR="${CONFIG_DIR}/scan-reports"
BACKUP_DIR="/docker/backups/postgres/pre-upgrade"

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

# Trivy server - Amy uses port 8083
TRIVY_SERVER="http://localhost:8083"

# Load environment
source "${ENV_FILE}" 2>/dev/null || true

# ntfy - Amy runs ntfy locally
NTFY_ENDPOINT="http://localhost:8888"
NTFY_TOPIC="${DIUN_NTFY_TOPIC:-container-updates-amy}"

# Timestamps
DATE=$(date +%Y-%m-%d)
DATETIME=$(date +%Y-%m-%d_%H-%M-%S)
LOG_FILE="${LOG_DIR}/${DATE}.log"

# ============================================
# INITIALIZATION
# ============================================

mkdir -p "${CONFIG_DIR}" "${LOG_DIR}" "${SCAN_REPORTS_DIR}" "${REPORTS_DIR}" "${BACKUP_DIR}"

# Initialize retry queue if not exists
if [[ ! -f "${RETRY_QUEUE}" ]]; then
    echo '{"containers": []}' > "${RETRY_QUEUE}"
fi

# Initialize critical containers list if not exists
if [[ ! -f "${CRITICAL_CONTAINERS}" ]]; then
    echo '["postgres", "ntfy"]' > "${CRITICAL_CONTAINERS}"
fi

# ============================================
# LOGGING
# ============================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }

# ============================================
# NOTIFICATIONS
# ============================================

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-package}"
    
    curl -s -X POST "${NTFY_ENDPOINT}/${NTFY_TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "${message}" > /dev/null 2>&1 || log_warn "Failed to send notification"
}

# ============================================
# TRIVY SCANNING
# ============================================

scan_image() {
    local image="$1"
    local container="$2"
    local scan_file="${SCAN_REPORTS_DIR}/${container}-${DATETIME}.json"
    
    log_info "Scanning image: ${image}"
    
    # Check if Trivy server is available
    if ! curl -s "${TRIVY_SERVER}/healthz" > /dev/null 2>&1; then
        log_error "Trivy server not available at ${TRIVY_SERVER}"
        return 1
    fi
    
    # Scan with Trivy
    curl -s "${TRIVY_SERVER}/image/${image}" > "${scan_file}" 2>/dev/null
    
    if [[ ! -s "${scan_file}" ]]; then
        log_warn "Empty scan result for ${image}, using docker trivy"
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:latest image --format json "${image}" > "${scan_file}" 2>/dev/null
    fi
    
    # Count vulnerabilities
    local critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "${scan_file}" 2>/dev/null || echo "0")
    local high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "${scan_file}" 2>/dev/null || echo "0")
    
    log_info "Scan results for ${container}: CRITICAL=${critical}, HIGH=${high}"
    
    # Check thresholds
    if [[ "${critical}" -gt "${MAX_CRITICAL}" ]]; then
        log_error "Image ${image} has ${critical} CRITICAL vulnerabilities (max: ${MAX_CRITICAL})"
        return 1
    fi
    
    if [[ "${high}" -gt "${MAX_HIGH}" ]]; then
        log_error "Image ${image} has ${high} HIGH vulnerabilities (max: ${MAX_HIGH})"
        return 1
    fi
    
    log_success "Image ${image} passed vulnerability scan"
    return 0
}

# ============================================
# CONTAINER MANAGEMENT
# ============================================

get_current_image() {
    local container="$1"
    docker inspect --format='{{.Config.Image}}' "${container}" 2>/dev/null
}

get_image_id() {
    local image="$1"
    docker images --format='{{.ID}}' "${image}" 2>/dev/null | head -1
}

backup_image() {
    local container="$1"
    local current_image=$(get_current_image "${container}")
    local image_id=$(get_image_id "${current_image}")
    
    if [[ -n "${image_id}" ]]; then
        local backup_tag="${current_image%%:*}:backup-${DATETIME}"
        docker tag "${image_id}" "${backup_tag}" 2>/dev/null
        log_info "Created backup image: ${backup_tag}"
        
        # Cleanup old backups
        cleanup_old_backups "${container}"
    fi
}

cleanup_old_backups() {
    local container="$1"
    local current_image=$(get_current_image "${container}")
    local base_image="${current_image%%:*}"
    
    # Get backup images sorted by date, keep only IMAGE_BACKUP_COUNT
    docker images --format='{{.Repository}}:{{.Tag}}' | \
        grep "^${base_image}:backup-" | \
        sort -r | \
        tail -n +$((IMAGE_BACKUP_COUNT + 1)) | \
        xargs -r docker rmi 2>/dev/null || true
}

is_critical_container() {
    local container="$1"
    jq -e ".[] | select(. == \"${container}\")" "${CRITICAL_CONTAINERS}" > /dev/null 2>&1
}

# ============================================
# POSTGRES SPECIFIC
# ============================================

backup_postgres() {
    log_info "Creating PostgreSQL backup before upgrade..."
    local backup_file="${BACKUP_DIR}/pre-upgrade-${DATETIME}.sql.gz"
    
    # Backup all databases
    docker exec postgres pg_dumpall -U postgres 2>/dev/null | gzip > "${backup_file}"
    
    if [[ -s "${backup_file}" ]]; then
        log_success "PostgreSQL backup created: ${backup_file}"
        return 0
    else
        log_error "PostgreSQL backup failed"
        rm -f "${backup_file}"
        return 1
    fi
}

# ============================================
# HEALTH CHECKS
# ============================================

run_health_check() {
    local container="$1"
    local max_attempts=30
    local attempt=0
    
    log_info "Running health check for ${container}..."
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        local status=$(docker inspect --format='{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "none")
        
        case "${status}" in
            "healthy")
                log_success "Container ${container} is healthy"
                return 0
                ;;
            "unhealthy")
                log_error "Container ${container} is unhealthy"
                return 1
                ;;
            "none")
                # No health check defined, check if running
                if docker ps --format='{{.Names}}' | grep -q "^${container}$"; then
                    log_info "Container ${container} is running (no health check defined)"
                    return 0
                fi
                ;;
        esac
        
        ((attempt++))
        sleep 2
    done
    
    log_error "Health check timed out for ${container}"
    return 1
}

# ============================================
# UPDATE LOGIC
# ============================================

update_container() {
    local container="$1"
    local current_image=$(get_current_image "${container}")
    
    if [[ -z "${current_image}" ]]; then
        log_error "Could not get current image for ${container}"
        return 1
    fi
    
    log_info "Processing update for ${container} (${current_image})"
    
    # Step 1: Pull new image
    log_info "Pulling latest image for ${container}..."
    if ! docker compose -f "${COMPOSE_FILE}" pull "${container}" 2>/dev/null; then
        log_warn "No update available for ${container}"
        return 0
    fi
    
    # Check if image actually changed
    local new_image_id=$(docker images --format='{{.ID}}' "${current_image}" 2>/dev/null | head -1)
    local old_image_id=$(docker inspect --format='{{.Image}}' "${container}" 2>/dev/null | cut -d: -f2 | cut -c1-12)
    
    if [[ "${new_image_id:0:12}" == "${old_image_id}" ]]; then
        log_info "No new image available for ${container}"
        return 0
    fi
    
    # Step 2: Scan with Trivy
    if ! scan_image "${current_image}" "${container}"; then
        log_error "Vulnerability scan failed for ${container}, adding to retry queue"
        add_to_retry_queue "${container}"
        return 1
    fi
    
    # Step 3: For critical containers, extra precautions
    if is_critical_container "${container}"; then
        log_info "Critical container detected: ${container}"
        
        if [[ "${container}" == "postgres" ]]; then
            if ! backup_postgres; then
                log_error "PostgreSQL backup failed, aborting update"
                return 1
            fi
        fi
    fi
    
    # Step 4: Backup current image
    backup_image "${container}"
    
    # Step 5: Stop and update
    log_info "Updating container ${container}..."
    docker compose -f "${COMPOSE_FILE}" up -d --force-recreate "${container}"
    
    # Step 6: Health check
    sleep 5
    if ! run_health_check "${container}"; then
        log_error "Health check failed for ${container}, initiating rollback"
        rollback_container "${container}"
        return 1
    fi
    
    log_success "Successfully updated ${container}"
    return 0
}

rollback_container() {
    local container="$1"
    local current_image=$(get_current_image "${container}")
    local base_image="${current_image%%:*}"
    
    log_warn "Rolling back ${container}..."
    
    # Find most recent backup
    local backup_image=$(docker images --format='{{.Repository}}:{{.Tag}}' | \
        grep "^${base_image}:backup-" | sort -r | head -1)
    
    if [[ -n "${backup_image}" ]]; then
        # Tag backup as latest
        docker tag "${backup_image}" "${current_image}"
        docker compose -f "${COMPOSE_FILE}" up -d --force-recreate "${container}"
        
        if run_health_check "${container}"; then
            log_success "Rollback successful for ${container}"
            send_notification "⚠️ Rollback: ${container}" "Container was rolled back after failed update" "high" "warning"
        else
            log_error "Rollback failed for ${container}"
            send_notification "🚨 CRITICAL: ${container}" "Rollback failed! Manual intervention required" "urgent" "rotating_light"
        fi
    else
        log_error "No backup image found for ${container}"
        send_notification "🚨 CRITICAL: ${container}" "No backup available for rollback" "urgent" "rotating_light"
    fi
}

# ============================================
# RETRY QUEUE
# ============================================

add_to_retry_queue() {
    local container="$1"
    local timestamp=$(date -Iseconds)
    
    local tmp=$(mktemp)
    jq ".containers += [{\"name\": \"${container}\", \"added\": \"${timestamp}\", \"attempts\": 1}]" \
        "${RETRY_QUEUE}" > "${tmp}" && mv "${tmp}" "${RETRY_QUEUE}"
    
    log_info "Added ${container} to retry queue"
}

process_retry_queue() {
    log_info "Processing retry queue..."
    
    local containers=$(jq -r '.containers[].name' "${RETRY_QUEUE}" 2>/dev/null)
    
    if [[ -z "${containers}" ]]; then
        log_info "Retry queue is empty"
        return 0
    fi
    
    local success_count=0
    local fail_count=0
    
    for container in ${containers}; do
        if update_container "${container}"; then
            # Remove from queue
            local tmp=$(mktemp)
            jq "del(.containers[] | select(.name == \"${container}\"))" \
                "${RETRY_QUEUE}" > "${tmp}" && mv "${tmp}" "${RETRY_QUEUE}"
            ((success_count++))
        else
            # Increment attempt counter
            local tmp=$(mktemp)
            jq "(.containers[] | select(.name == \"${container}\")).attempts += 1" \
                "${RETRY_QUEUE}" > "${tmp}" && mv "${tmp}" "${RETRY_QUEUE}"
            ((fail_count++))
        fi
    done
    
    log_info "Retry queue processed: ${success_count} success, ${fail_count} failed"
}

# ============================================
# WEEKLY UPDATE
# ============================================

run_weekly_update() {
    log_info "=========================================="
    log_info "Starting weekly container update - AMY"
    log_info "=========================================="
    
    send_notification "🔄 Amy Update Started" "Weekly container update process initiated" "default" "arrows_counterclockwise"
    
    local updated=0
    local failed=0
    local skipped=0
    
    # Get list of containers
    local containers=$(docker compose -f "${COMPOSE_FILE}" ps --format='{{.Names}}' 2>/dev/null)
    
    for container in ${containers}; do
        # Skip certain containers
        case "${container}" in
            postgres-backup|trivy|diun)
                log_info "Skipping ${container} (infrastructure)"
                ((skipped++))
                continue
                ;;
        esac
        
        if update_container "${container}"; then
            ((updated++))
        else
            ((failed++))
        fi
    done
    
    # Generate report
    local report="Weekly Update Report - Amy
Date: ${DATE}
Updated: ${updated}
Failed: ${failed}
Skipped: ${skipped}
Retry Queue: $(jq '.containers | length' "${RETRY_QUEUE}")"
    
    echo "${report}" > "${REPORTS_DIR}/amy-${DATE}.txt"
    
    # Send summary
    if [[ ${failed} -eq 0 ]]; then
        send_notification "✅ Amy Update Complete" "${report}" "default" "white_check_mark"
    else
        send_notification "⚠️ Amy Update Complete (with failures)" "${report}" "high" "warning"
    fi
    
    log_info "Weekly update complete: ${updated} updated, ${failed} failed, ${skipped} skipped"
}

# ============================================
# STATUS
# ============================================

show_status() {
    echo "=== Amy Secure Container Update Status ==="
    echo ""
    echo "Configuration:"
    echo "  Base Dir: ${BASE_DIR}"
    echo "  Trivy Server: ${TRIVY_SERVER}"
    echo "  ntfy Endpoint: ${NTFY_ENDPOINT}/${NTFY_TOPIC}"
    echo ""
    echo "Retry Queue:"
    jq -r '.containers[] | "  - \(.name) (attempts: \(.attempts), added: \(.added))"' "${RETRY_QUEUE}" 2>/dev/null || echo "  Empty"
    echo ""
    echo "Critical Containers:"
    jq -r '.[]' "${CRITICAL_CONTAINERS}" 2>/dev/null | sed 's/^/  - /'
    echo ""
    echo "Recent Logs:"
    tail -20 "${LOG_FILE}" 2>/dev/null || echo "  No logs yet"
}

# ============================================
# USAGE
# ============================================

show_usage() {
    cat << EOF
Usage: $0 <command>

Commands:
  weekly      Run weekly container update
  retry       Process retry queue only
  status      Show current status
  scan <c>    Scan specific container
  update <c>  Update specific container
  help        Show this help

Examples:
  $0 weekly           # Run full weekly update
  $0 retry            # Retry failed containers
  $0 scan postgres    # Scan postgres container
  $0 update ntfy      # Update ntfy container
EOF
}

# ============================================
# MAIN
# ============================================

main() {
    local command="${1:-help}"
    
    case "${command}" in
        weekly)
            run_weekly_update
            ;;
        retry)
            process_retry_queue
            ;;
        status)
            show_status
            ;;
        scan)
            if [[ -z "${2:-}" ]]; then
                log_error "Container name required"
                exit 1
            fi
            local image=$(get_current_image "$2")
            scan_image "${image}" "$2"
            ;;
        update)
            if [[ -z "${2:-}" ]]; then
                log_error "Container name required"
                exit 1
            fi
            update_container "$2"
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
