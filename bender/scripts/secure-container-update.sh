#!/bin/bash
# ============================================
# Secure Container Update Script
# Version: 1.2
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
# Due to TrueNAS execution restrictions, run with:
#   cp /mnt/BIG/filme/docker-compose/scripts/secure-container-update.sh /tmp/ && \
#      bash /tmp/secure-container-update.sh <command> && \
#      rm /tmp/secure-container-update.sh
# ============================================

set -uo pipefail

# ============================================
# CONFIGURATION
# ============================================

# Paths
BASE_DIR="/mnt/BIG/filme/docker-compose"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yaml"
ENV_FILE="${BASE_DIR}/.env"
CONFIG_DIR="${BASE_DIR}/configs/secure-update"
SCRIPTS_DIR="${BASE_DIR}/scripts"
REPORTS_DIR="${BASE_DIR}/reports/weekly-reports"
LOG_DIR="${CONFIG_DIR}/logs"
SCAN_REPORTS_DIR="${CONFIG_DIR}/scan-reports"
BACKUP_DIR="${BASE_DIR}/backups/postgres/pre-upgrade"

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

# Load environment
source "${ENV_FILE}" 2>/dev/null || true
NTFY_ENDPOINT="http://${NTFY_ADDRESS:-192.168.21.130:8888}"
NTFY_TOPIC="${DIUN_NTFY_TOPIC:-container-updates-bender}"

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
    echo '["postgres"]' > "${CRITICAL_CONTAINERS}"
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
        -d "${message}" > /dev/null 2>&1 || true
}

# ============================================
# RETRY QUEUE MANAGEMENT
# ============================================

add_to_retry_queue() {
    local container="$1"
    local reason="$2"
    local timestamp=$(date -Iseconds)
    
    # Read current queue
    local queue=$(cat "${RETRY_QUEUE}")
    
    # Check if already in queue
    if echo "${queue}" | grep -q "\"name\": \"${container}\""; then
        log_info "Container ${container} already in retry queue"
        return
    fi
    
    # Add to queue
    local new_entry="{\"name\": \"${container}\", \"reason\": \"${reason}\", \"added\": \"${timestamp}\", \"attempts\": 0}"
    echo "${queue}" | jq ".containers += [${new_entry}]" > "${RETRY_QUEUE}"
    log_info "Added ${container} to retry queue: ${reason}"
}

remove_from_retry_queue() {
    local container="$1"
    local queue=$(cat "${RETRY_QUEUE}")
    echo "${queue}" | jq "del(.containers[] | select(.name == \"${container}\"))" > "${RETRY_QUEUE}"
    log_info "Removed ${container} from retry queue"
}

increment_retry_attempts() {
    local container="$1"
    local queue=$(cat "${RETRY_QUEUE}")
    echo "${queue}" | jq "(.containers[] | select(.name == \"${container}\") | .attempts) += 1" > "${RETRY_QUEUE}"
}

get_retry_containers() {
    cat "${RETRY_QUEUE}" | jq -r '.containers[].name'
}

# ============================================
# IMAGE MANAGEMENT
# ============================================

get_current_image() {
    local container="$1"
    docker inspect "${container}" --format='{{.Config.Image}}' 2>/dev/null
}

get_image_id() {
    local image="$1"
    docker inspect "${image}" --format='{{.Id}}' 2>/dev/null
}

rotate_backup_images() {
    local container="$1"
    local image=$(get_current_image "${container}")
    local base_image=$(echo "${image}" | cut -d: -f1)
    
    log_info "Rotating backup images for ${container}"
    
    # Delete oldest backup
    docker rmi "${base_image}:backup-${IMAGE_BACKUP_COUNT}" 2>/dev/null || true
    
    # Shift backups
    for ((i=IMAGE_BACKUP_COUNT-1; i>=1; i--)); do
        local next=$((i+1))
        if docker image inspect "${base_image}:backup-${i}" > /dev/null 2>&1; then
            docker tag "${base_image}:backup-${i}" "${base_image}:backup-${next}" 2>/dev/null || true
            docker rmi "${base_image}:backup-${i}" 2>/dev/null || true
        fi
    done
    
    # Tag current as backup-1
    if docker image inspect "${image}" > /dev/null 2>&1; then
        docker tag "${image}" "${base_image}:backup-1"
        log_info "Tagged current image as ${base_image}:backup-1"
    fi
}

# ============================================
# VULNERABILITY SCANNING
# ============================================

scan_image() {
    local image="$1"
    local container="$2"
    local report_file="${SCAN_REPORTS_DIR}/${container}_${DATETIME}.json"
    
    log_info "Scanning ${image} for vulnerabilities..."
    
    # Run Trivy scan
    local scan_result
    scan_result=$(curl -s -X POST "${TRIVY_SERVER}/image" \
        -H "Content-Type: application/json" \
        -d "{\"image\": \"${image}\"}" 2>/dev/null)
    
    if [[ -z "${scan_result}" ]]; then
        # Fallback to CLI if server fails
        scan_result=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:latest image --format json "${image}" 2>/dev/null)
    fi
    
    echo "${scan_result}" > "${report_file}"
    
    # Count vulnerabilities
    local critical_count=$(echo "${scan_result}" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
    local high_count=$(echo "${scan_result}" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo "0")
    
    log_info "Scan results for ${container}: CRITICAL=${critical_count}, HIGH=${high_count}"
    
    # Check thresholds
    if [[ "${critical_count}" -gt "${MAX_CRITICAL}" ]] || [[ "${high_count}" -gt "${MAX_HIGH}" ]]; then
        log_error "Vulnerability threshold exceeded for ${container}"
        return 1
    fi
    
    log_success "Scan passed for ${container}"
    return 0
}

# ============================================
# HEALTH CHECKS
# ============================================

run_health_checks() {
    local container="$1"
    
    log_info "Running health checks for ${container}..."
    
    # Use external health check script if available
    if [[ -f "${SCRIPTS_DIR}/health-checks.sh" ]]; then
        cp "${SCRIPTS_DIR}/health-checks.sh" /tmp/health-checks.sh
        if bash /tmp/health-checks.sh "${container}" > /dev/null 2>&1; then
            rm /tmp/health-checks.sh
            log_success "Health checks passed for ${container}"
            return 0
        else
            rm /tmp/health-checks.sh
            log_error "Health checks failed for ${container}"
            return 1
        fi
    fi
    
    # Fallback to basic checks
    sleep 30
    
    # Check container is running
    if ! docker ps --filter "name=${container}" --filter "status=running" -q | grep -q .; then
        log_error "Container ${container} is not running"
        return 1
    fi
    
    # Check container health status
    local health=$(docker inspect "${container}" --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
    if [[ "${health}" == "unhealthy" ]]; then
        log_error "Container ${container} is unhealthy"
        return 1
    fi
    
    log_success "Basic health checks passed for ${container}"
    return 0
}

# ============================================
# POSTGRES SPECIAL HANDLING
# ============================================

is_critical_container() {
    local container="$1"
    cat "${CRITICAL_CONTAINERS}" | jq -e "index(\"${container}\")" > /dev/null 2>&1
}

backup_postgres() {
    log_info "Creating PostgreSQL backup before upgrade..."
    
    local backup_file="${BACKUP_DIR}/pre-upgrade_${DATETIME}.sql"
    
    if docker exec postgres pg_dumpall -U postgres > "${backup_file}" 2>/dev/null; then
        gzip "${backup_file}"
        log_success "PostgreSQL backup created: ${backup_file}.gz"
        return 0
    else
        log_error "PostgreSQL backup failed"
        return 1
    fi
}

update_postgres() {
    local image=$(get_current_image "postgres")
    
    log_info "Starting PostgreSQL upgrade process..."
    
    # Phase 1: Pre-upgrade (BEFORE stopping anything)
    log_info "Phase 1: Pulling and scanning new image..."
    
    if ! docker pull "${image}" > /dev/null 2>&1; then
        log_error "Failed to pull new postgres image"
        return 1
    fi
    
    if ! scan_image "${image}" "postgres"; then
        add_to_retry_queue "postgres" "Vulnerability scan failed"
        return 1
    fi
    
    # Phase 2: Backup
    log_info "Phase 2: Creating backup..."
    
    if ! backup_postgres; then
        log_error "Backup failed, aborting upgrade"
        return 1
    fi
    
    rotate_backup_images "postgres"
    
    # Phase 3: Upgrade
    log_info "Phase 3: Stopping and upgrading..."
    
    cd "${BASE_DIR}"
    docker compose stop postgres
    docker compose up -d postgres
    
    # Wait for postgres to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    local max_wait=60
    local waited=0
    while ! docker exec postgres pg_isready -U postgres > /dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
        if [[ ${waited} -ge ${max_wait} ]]; then
            log_error "PostgreSQL failed to start within ${max_wait} seconds"
            rollback_postgres
            return 1
        fi
    done
    
    # Phase 4: Verification
    log_info "Phase 4: Running verification..."
    
    if ! run_health_checks "postgres"; then
        log_error "Health checks failed, rolling back..."
        rollback_postgres
        return 1
    fi
    
    log_success "PostgreSQL upgrade completed successfully"
    send_notification "PostgreSQL Updated" "PostgreSQL has been successfully updated on bender" "default" "white_check_mark"
    return 0
}

rollback_postgres() {
    local image=$(get_current_image "postgres")
    local base_image=$(echo "${image}" | cut -d: -f1)
    
    log_warn "Rolling back PostgreSQL..."
    
    cd "${BASE_DIR}"
    
    # Stop postgres
    docker compose stop postgres
    
    # Restore backup image
    if docker image inspect "${base_image}:backup-1" > /dev/null 2>&1; then
        docker tag "${base_image}:backup-1" "${image}"
        log_info "Restored backup-1 image"
    fi
    
    # Start postgres
    docker compose up -d postgres
    
    # Wait for recovery
    sleep 30
    
    if docker exec postgres pg_isready -U postgres > /dev/null 2>&1; then
        log_success "PostgreSQL rollback completed"
        send_notification "PostgreSQL Rollback" "PostgreSQL was rolled back due to upgrade failure" "high" "warning"
    else
        log_error "PostgreSQL rollback may have failed - manual intervention required"
        send_notification "PostgreSQL CRITICAL" "PostgreSQL rollback failed - manual intervention required" "urgent" "rotating_light"
    fi
}

# ============================================
# CONTAINER UPDATE
# ============================================

update_container() {
    local container="$1"
    
    log_info "Processing update for ${container}..."
    
    # Special handling for postgres
    if [[ "${container}" == "postgres" ]]; then
        update_postgres
        return $?
    fi
    
    local image=$(get_current_image "${container}")
    if [[ -z "${image}" ]]; then
        log_error "Could not get image for ${container}"
        return 1
    fi
    
    local old_id=$(get_image_id "${image}")
    
    # Pull new image
    log_info "Pulling ${image}..."
    if ! docker pull "${image}" > /dev/null 2>&1; then
        log_error "Failed to pull ${image}"
        return 1
    fi
    
    local new_id=$(get_image_id "${image}")
    
    # Check if image actually changed
    if [[ "${old_id}" == "${new_id}" ]]; then
        log_info "No update available for ${container}"
        return 0
    fi
    
    log_info "New image available for ${container}"
    
    # Scan new image
    if ! scan_image "${image}" "${container}"; then
        add_to_retry_queue "${container}" "Vulnerability scan failed"
        # Restore old image
        docker pull "${image}@${old_id}" > /dev/null 2>&1 || true
        return 1
    fi
    
    # Rotate backups
    rotate_backup_images "${container}"
    
    # Deploy new container
    log_info "Deploying new ${container}..."
    cd "${BASE_DIR}"
    docker compose up -d --force-recreate "${container}"
    
    # Run health checks
    if ! run_health_checks "${container}"; then
        log_error "Health checks failed for ${container}, rolling back..."
        
        # Rollback
        local base_image=$(echo "${image}" | cut -d: -f1)
        docker tag "${base_image}:backup-1" "${image}"
        docker compose up -d --force-recreate "${container}"
        
        add_to_retry_queue "${container}" "Health check failed after update"
        send_notification "Update Failed" "${container} update failed and was rolled back" "high" "x"
        return 1
    fi
    
    # Success
    remove_from_retry_queue "${container}"
    log_success "Successfully updated ${container}"
    send_notification "Container Updated" "${container} has been successfully updated" "default" "white_check_mark"
    return 0
}

# ============================================
# MAIN WORKFLOWS
# ============================================

weekly_scan() {
    log_info "Starting weekly container update scan..."
    send_notification "Weekly Scan Started" "Starting weekly container security scan on bender" "low" "mag"
    
    local updated=0
    local failed=0
    local skipped=0
    
    # Get all running containers
    local containers=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.Name}}' 2>/dev/null)
    
    for container in ${containers}; do
        # Skip infrastructure containers
        if [[ "${container}" =~ ^(tsdproxy|diun|trivy)$ ]]; then
            log_info "Skipping infrastructure container: ${container}"
            ((skipped++))
            continue
        fi
        
        if update_container "${container}"; then
            ((updated++))
        else
            ((failed++))
        fi
    done
    
    # Generate report
    local report="Weekly Update Report - ${DATE}\n"
    report+="Updated: ${updated}\n"
    report+="Failed: ${failed}\n"
    report+="Skipped: ${skipped}\n"
    
    echo -e "${report}" > "${REPORTS_DIR}/weekly_${DATE}.txt"
    
    log_info "Weekly scan complete: ${updated} updated, ${failed} failed, ${skipped} skipped"
    send_notification "Weekly Scan Complete" "Updated: ${updated}, Failed: ${failed}, Skipped: ${skipped}" "default" "chart_with_upwards_trend"
    
    # Cleanup old reports
    find "${REPORTS_DIR}" -type f -mtime +${REPORT_RETENTION_DAYS} -delete
    find "${SCAN_REPORTS_DIR}" -type f -mtime +${REPORT_RETENTION_DAYS} -delete
}

daily_retry() {
    log_info "Starting daily retry of failed updates..."
    
    local containers=$(get_retry_containers)
    
    if [[ -z "${containers}" ]]; then
        log_info "No containers in retry queue"
        return 0
    fi
    
    for container in ${containers}; do
        log_info "Retrying update for ${container}..."
        increment_retry_attempts "${container}"
        
        if update_container "${container}"; then
            remove_from_retry_queue "${container}"
        fi
    done
}

# ============================================
# CLI
# ============================================

show_usage() {
    cat << EOF
Secure Container Update Script v1.2

Usage: $0 <command> [options]

Commands:
    weekly              Run weekly update scan (all containers)
    retry               Retry failed updates from queue
    scan <container>    Scan and update specific container
    status              Show current status and retry queue
    help                Show this help message

Examples:
    $0 weekly                    # Run full weekly scan
    $0 retry                     # Retry failed updates
    $0 scan jellyfin             # Update specific container
    $0 status                    # Show status

Schedule (crontab):
    # Weekly scan (Saturday 04:30 AM)
    30 4 * * 6 cp ${SCRIPTS_DIR}/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh weekly && rm /tmp/secure-container-update.sh
    
    # Daily retry (every day 04:30 AM)
    30 4 * * * cp ${SCRIPTS_DIR}/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh retry && rm /tmp/secure-container-update.sh

Due to TrueNAS execution restrictions, always run via:
    cp ${SCRIPTS_DIR}/secure-container-update.sh /tmp/ && bash /tmp/secure-container-update.sh <command> && rm /tmp/secure-container-update.sh
EOF
}

show_status() {
    echo "=========================================="
    echo "Secure Container Update Status"
    echo "=========================================="
    echo ""
    echo "Retry Queue:"
    local queue=$(cat "${RETRY_QUEUE}" 2>/dev/null)
    local count=$(echo "${queue}" | jq '.containers | length' 2>/dev/null || echo "0")
    if [[ "${count}" -eq 0 ]]; then
        echo "  (empty)"
    else
        echo "${queue}" | jq -r '.containers[] | "  - \(.name): \(.reason) (attempts: \(.attempts))"'
    fi
    echo ""
    echo "Critical Containers:"
    cat "${CRITICAL_CONTAINERS}" | jq -r '.[] | "  - \(.)"'
    echo ""
    echo "Recent Logs:"
    if [[ -f "${LOG_FILE}" ]]; then
        tail -10 "${LOG_FILE}" 2>/dev/null
    else
        echo "  (no logs)"
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
            update_container "$2"
            ;;
        status)
            show_status
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
        