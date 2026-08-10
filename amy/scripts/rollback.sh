#!/bin/bash
# ============================================
# AMY - Rollback Script
# Version: 1.0
# ============================================
# Manual rollback helper for containers and PostgreSQL
# ============================================

set -uo pipefail

# Configuration
BASE_DIR="/docker-compose"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yaml"
BACKUP_DIR="/docker/backups/postgres"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================
# HELPER FUNCTIONS
# ============================================

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ============================================
# CONTAINER ROLLBACK
# ============================================

list_container_backups() {
    local container="$1"
    local current_image=$(docker inspect --format='{{.Config.Image}}' "${container}" 2>/dev/null)
    local base_image="${current_image%%:*}"
    
    echo "Available backup images for ${container}:"
    docker images --format='table {{.Repository}}:{{.Tag}}\t{{.CreatedAt}}\t{{.Size}}' | \
        grep "^${base_image}:backup-" | head -10
}

rollback_container() {
    local container="$1"
    local backup_num="${2:-1}"
    
    local current_image=$(docker inspect --format='{{.Config.Image}}' "${container}" 2>/dev/null)
    if [[ -z "${current_image}" ]]; then
        log_error "Container ${container} not found"
        return 1
    fi
    
    local base_image="${current_image%%:*}"
    
    # Get backup image
    local backup_image=$(docker images --format='{{.Repository}}:{{.Tag}}' | \
        grep "^${base_image}:backup-" | sort -r | sed -n "${backup_num}p")
    
    if [[ -z "${backup_image}" ]]; then
        log_error "No backup image found for ${container}"
        list_container_backups "${container}"
        return 1
    fi
    
    log_info "Rolling back ${container} to ${backup_image}"
    
    # Tag backup as current
    docker tag "${backup_image}" "${current_image}"
    
    # Recreate container
    docker compose -f "${COMPOSE_FILE}" up -d --force-recreate "${container}"
    
    # Wait and check
    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_info "Rollback successful for ${container}"
    else
        log_error "Rollback may have failed - container not running"
        return 1
    fi
}

# ============================================
# POSTGRES ROLLBACK
# ============================================

list_postgres_backups() {
    echo "Available PostgreSQL backups:"
    echo ""
    echo "=== Pre-upgrade backups ==="
    ls -lh "${BACKUP_DIR}/pre-upgrade/"*.sql.gz 2>/dev/null | tail -10 || echo "  None found"
    echo ""
    echo "=== Daily backups ==="
    ls -lh "${BACKUP_DIR}/daily/"*.sql.gz 2>/dev/null | tail -10 || echo "  None found"
    echo ""
    echo "=== Latest backups ==="
    ls -lh "${BACKUP_DIR}/last/"*.sql.gz 2>/dev/null | tail -5 || echo "  None found"
}

restore_postgres_backup() {
    local backup_file="$1"
    
    if [[ ! -f "${backup_file}" ]]; then
        log_error "Backup file not found: ${backup_file}"
        return 1
    fi
    
    log_warn "This will restore PostgreSQL from: ${backup_file}"
    log_warn "All current data will be OVERWRITTEN!"
    echo ""
    read -p "Are you sure? (type 'yes' to confirm): " confirm
    
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Rollback cancelled"
        return 0
    fi
    
    log_info "Stopping dependent services..."
    docker compose -f "${COMPOSE_FILE}" stop atuin miniflux spendspentspent 2>/dev/null
    
    log_info "Restoring PostgreSQL backup..."
    if [[ "${backup_file}" == *.gz ]]; then
        gunzip -c "${backup_file}" | docker exec -i postgres psql -U postgres
    else
        docker exec -i postgres psql -U postgres < "${backup_file}"
    fi
    
    log_info "Starting dependent services..."
    docker compose -f "${COMPOSE_FILE}" start atuin miniflux spendspentspent 2>/dev/null
    
    log_info "PostgreSQL restore complete"
}

restore_single_database() {
    local db_name="$1"
    local backup_file="$2"
    
    if [[ ! -f "${backup_file}" ]]; then
        log_error "Backup file not found: ${backup_file}"
        return 1
    fi
    
    log_warn "This will restore database '${db_name}' from: ${backup_file}"
    log_warn "All current data in '${db_name}' will be OVERWRITTEN!"
    echo ""
    read -p "Are you sure? (type 'yes' to confirm): " confirm
    
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Rollback cancelled"
        return 0
    fi
    
    log_info "Restoring ${db_name} database..."
    
    # Drop and recreate database
    docker exec postgres psql -U postgres -c "DROP DATABASE IF EXISTS ${db_name};"
    docker exec postgres psql -U postgres -c "CREATE DATABASE ${db_name};"
    
    # Restore
    if [[ "${backup_file}" == *.gz ]]; then
        gunzip -c "${backup_file}" | docker exec -i postgres psql -U postgres -d "${db_name}"
    else
        docker exec -i postgres psql -U postgres -d "${db_name}" < "${backup_file}"
    fi
    
    log_info "Database ${db_name} restore complete"
}

# ============================================
# USAGE
# ============================================

show_usage() {
    cat << EOF
Amy Rollback Script

Usage: $0 <command> [options]

Commands:
  container <name> [n]     Rollback container to nth backup (default: 1)
  list-containers <name>   List available container backups
  
  postgres <file>          Restore full PostgreSQL backup
  database <name> <file>   Restore single database
  list-postgres            List available PostgreSQL backups

Examples:
  $0 container ntfy          # Rollback ntfy to most recent backup
  $0 container ntfy 2        # Rollback ntfy to 2nd most recent backup
  $0 list-containers ntfy    # List available ntfy backups
  
  $0 list-postgres                                    # List PostgreSQL backups
  $0 postgres /docker/backups/postgres/last/atuin-latest.sql.gz
  $0 database atuin /docker/backups/postgres/daily/atuin-20260110.sql.gz

EOF
}

# ============================================
# MAIN
# ============================================

main() {
    local command="${1:-help}"
    
    case "${command}" in
        container)
            if [[ -z "${2:-}" ]]; then
                log_error "Container name required"
                exit 1
            fi
            rollback_container "$2" "${3:-1}"
            ;;
        list-containers)
            if [[ -z "${2:-}" ]]; then
                log_error "Container name required"
                exit 1
            fi
            list_container_backups "$2"
            ;;
        postgres)
            if [[ -z "${2:-}" ]]; then
                log_error "Backup file required"
                exit 1
            fi
            restore_postgres_backup "$2"
            ;;
        database)
            if [[ -z "${2:-}" ]] || [[ -z "${3:-}" ]]; then
                log_error "Database name and backup file required"
                exit 1
            fi
            restore_single_database "$2" "$3"
            ;;
        list-postgres)
            list_postgres_backups
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
