#!/bin/bash
# ============================================
# Rollback Script
# Version: 1.0
# Host: bender (TrueNAS Scale)
# ============================================
# Manual rollback helper for container images
# Supports both standard containers and special
# PostgreSQL handling with dependent services
# ============================================
# Due to TrueNAS execution restrictions, run with:
#   cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/ && \
#      bash /tmp/rollback.sh <command> && \
#      rm /tmp/rollback.sh
# ============================================

set -uo pipefail

# Configuration
BASE_DIR="/mnt/BIG/filme/docker-compose"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================
# LOGGING
# ============================================

log_info() { echo -e "[INFO] $*"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
log_error() { echo -e "${RED}[ERROR] $*${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $*${NC}"; }

# ============================================
# UTILITIES
# ============================================

get_current_image() {
    local container="$1"
    docker inspect "${container}" --format='{{.Config.Image}}' 2>/dev/null
}

list_backups() {
    local container="$1"
    local image=$(get_current_image "${container}")
    
    if [[ -z "${image}" ]]; then
        log_error "Container '${container}' not found"
        return 1
    fi
    
    local base_image=$(echo "${image}" | cut -d: -f1)
    
    echo "=========================================="
    echo "Available backups for ${container}"
    echo "=========================================="
    echo ""
    echo "Current image: ${image}"
    echo ""
    echo "Backup images:"
    
    for i in 1 2 3; do
        local backup_tag="${base_image}:backup-${i}"
        if docker image inspect "${backup_tag}" > /dev/null 2>&1; then
            local created=$(docker inspect "${backup_tag}" --format='{{.Created}}' 2>/dev/null | cut -d'T' -f1)
            echo "  backup-${i}: ${backup_tag} (created: ${created})"
        else
            echo "  backup-${i}: (not available)"
        fi
    done
    echo ""
}

# ============================================
# ROLLBACK FUNCTIONS
# ============================================

rollback_container() {
    local container="$1"
    local backup_number="${2:-1}"
    
    local image=$(get_current_image "${container}")
    if [[ -z "${image}" ]]; then
        log_error "Container '${container}' not found"
        return 1
    fi
    
    local base_image=$(echo "${image}" | cut -d: -f1)
    local backup_tag="${base_image}:backup-${backup_number}"
    
    if ! docker image inspect "${backup_tag}" > /dev/null 2>&1; then
        log_error "Backup '${backup_tag}' not found"
        return 1
    fi
    
    echo ""
    log_info "Rolling back ${container} to backup-${backup_number}"
    echo ""
    
    # Confirm
    echo "This will:"
    echo "  1. Stop container: ${container}"
    echo "  2. Tag ${backup_tag} as ${image}"
    echo "  3. Start container with previous version"
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Rollback cancelled"
        return 0
    fi
    
    # Stop container
    log_info "Stopping ${container}..."
    docker stop "${container}"
    
    # Tag backup as current
    log_info "Restoring backup-${backup_number}..."
    docker tag "${backup_tag}" "${image}"
    
    # Start container
    log_info "Starting ${container}..."
    cd "${BASE_DIR}"
    docker compose up -d --force-recreate "${container}"
    
    # Wait and verify
    sleep 10
    
    if docker ps --filter "name=${container}" --filter "status=running" -q | grep -q .; then
        log_success "Rollback complete! ${container} is running with backup-${backup_number}"
    else
        log_error "Container failed to start after rollback"
        return 1
    fi
}

rollback_postgres() {
    local backup_number="${1:-1}"
    
    log_warn "PostgreSQL rollback requires special handling!"
    echo ""
    echo "This will:"
    echo "  1. Stop postgres and all dependent services"
    echo "  2. Restore postgres to backup-${backup_number}"
    echo "  3. Restart postgres and dependent services"
    echo ""
    echo "Dependent services:"
    echo "  - immich_server"
    echo "  - immich_machine_learning"
    echo "  - hedgedoc"
    echo "  - postgres-backup"
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Rollback cancelled"
        return 0
    fi
    
    local image=$(get_current_image "postgres")
    local base_image=$(echo "${image}" | cut -d: -f1)
    local backup_tag="${base_image}:backup-${backup_number}"
    
    if ! docker image inspect "${backup_tag}" > /dev/null 2>&1; then
        log_error "Backup '${backup_tag}' not found"
        return 1
    fi
    
    cd "${BASE_DIR}"
    
    # Stop dependent services
    log_info "Stopping dependent services..."
    docker compose stop immich_server immich_machine_learning hedgedoc postgres-backup
    
    # Stop postgres
    log_info "Stopping postgres..."
    docker compose stop postgres
    
    # Restore backup
    log_info "Restoring backup-${backup_number}..."
    docker tag "${backup_tag}" "${image}"
    
    # Start postgres
    log_info "Starting postgres..."
    docker compose up -d postgres
    
    # Wait for postgres
    log_info "Waiting for postgres to be ready..."
    sleep 30
    
    # Check postgres
    if docker exec postgres pg_isready -U postgres > /dev/null 2>&1; then
        log_success "PostgreSQL is ready"
    else
        log_error "PostgreSQL failed to start!"
        return 1
    fi
    
    # Start dependent services
    log_info "Starting dependent services..."
    docker compose up -d immich_server immich_machine_learning hedgedoc postgres-backup
    
    sleep 30
    
    # Verify
    log_info "Verifying services..."
    
    if curl -s -f "http://localhost:2283/api/server/ping" 2>/dev/null | grep -q "pong"; then
        log_success "Immich API is responding"
    else
        log_warn "Immich API not responding (may still be starting)"
    fi
    
    log_success "PostgreSQL rollback complete!"
}

# ============================================
# CLI
# ============================================

show_usage() {
    cat << EOF
Rollback Script v1.0

Usage: $0 <command> [options]

Commands:
    list <container>              List available backups for a container
    rollback <container> [N]      Rollback container to backup-N (default: 1)
    postgres [N]                  Special PostgreSQL rollback with dependent services
    help                          Show this help message

Examples:
    $0 list jellyfin              # Show available backups for jellyfin
    $0 rollback jellyfin          # Rollback jellyfin to backup-1
    $0 rollback sonarr 2          # Rollback sonarr to backup-2
    $0 postgres                   # Rollback postgres and restart dependents

Backup Versions:
    - backup-1: Most recent previous version
    - backup-2: Older version
    - backup-3: Oldest available backup

PostgreSQL Rollback:
    PostgreSQL rollback automatically handles dependent services:
    - immich_server
    - immich_machine_learning
    - hedgedoc
    - postgres-backup

Due to TrueNAS execution restrictions, run with:
    cp /mnt/BIG/filme/docker-compose/scripts/rollback.sh /tmp/ && \\
       bash /tmp/rollback.sh <command> && \\
       rm /tmp/rollback.sh
EOF
}

# ============================================
# MAIN
# ============================================

main() {
    local command="${1:-help}"
    
    case "${command}" in
        list)
            if [[ -z "${2:-}" ]]; then
                log_error "Container name required"
                exit 1
            fi
            list_backups "$2"
            ;;
        rollback)
            if [[ -z "${2:-}" ]]; then
                log_error "Container name required"
                exit 1
            fi
            rollback_container "$2" "${3:-1}"
            ;;
        postgres)
            rollback_postgres "${2:-1}"
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
