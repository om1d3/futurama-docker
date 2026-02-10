#!/bin/bash
# ============================================
# Health Checks Script
# Version: 1.2
# Host: bender (TrueNAS Scale)
# ============================================
# Standalone health check script for manual testing
# and integration with secure-container-update.sh
# ============================================
# v1.1: Removed bc dependency for TrueNAS compatibility
# v1.2: Fixed immich table name (user not users)
# ============================================
# USAGE: Due to TrueNAS execution restrictions, run with:
# cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/ && bash /tmp/health-checks.sh postgres && rm /tmp/health-checks.sh
# ============================================

set -uo pipefail

# Configuration
TIMEOUT=10
RETRIES=3
RETRY_DELAY=5

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================
# UTILITY FUNCTIONS
# ============================================

print_result() {
    local test_name="$1"
    local result="$2"
    local duration="${3:-0}"
    local details="${4:-}"
    
    if [[ "${result}" == "PASS" ]]; then
        echo -e "${GREEN}✅ PASS${NC} | ${test_name} | ${duration}s | ${details}"
    elif [[ "${result}" == "WARN" ]]; then
        echo -e "${YELLOW}⚠️  WARN${NC} | ${test_name} | ${duration}s | ${details}"
    else
        echo -e "${RED}❌ FAIL${NC} | ${test_name} | ${duration}s | ${details}"
    fi
}

run_with_retry() {
    local cmd="$1"
    local attempt=1
    
    while [[ ${attempt} -le ${RETRIES} ]]; do
        if eval "${cmd}"; then
            return 0
        fi
        
        if [[ ${attempt} -lt ${RETRIES} ]]; then
            sleep ${RETRY_DELAY}
        fi
        
        attempt=$((attempt + 1))
    done
    
    return 1
}

# ============================================
# CONTAINER HEALTH CHECKS
# ============================================

check_container_running() {
    local container="$1"
    local start=$(date +%s)
    
    if docker ps --filter "name=^${container}$" --filter "status=running" -q | grep -q .; then
        local end=$(date +%s)
        local duration=$((end - start))
        print_result "Container Running" "PASS" "${duration}" "Container ${container} is running"
        return 0
    else
        print_result "Container Running" "FAIL" "0" "Container ${container} is NOT running"
        return 1
    fi
}

check_container_healthy() {
    local container="$1"
    local start=$(date +%s)
    
    local health=$(docker inspect "${container}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "none")
    local end=$(date +%s)
    local duration=$((end - start))
    
    case "${health}" in
        healthy)
            print_result "Docker Healthcheck" "PASS" "${duration}" "Status: ${health}"
            return 0
            ;;
        unhealthy)
            print_result "Docker Healthcheck" "FAIL" "${duration}" "Status: ${health}"
            return 1
            ;;
        starting)
            print_result "Docker Healthcheck" "WARN" "${duration}" "Status: ${health} (still starting)"
            return 0
            ;;
        *)
            print_result "Docker Healthcheck" "WARN" "${duration}" "No healthcheck defined"
            return 0
            ;;
    esac
}

check_container_not_restarting() {
    local container="$1"
    local start=$(date +%s)
    
    local restart_count=$(docker inspect "${container}" --format '{{.RestartCount}}' 2>/dev/null || echo "0")
    local end=$(date +%s)
    local duration=$((end - start))
    
    if [[ ${restart_count} -lt 3 ]]; then
        print_result "Restart Count" "PASS" "${duration}" "Restart count: ${restart_count}"
        return 0
    else
        print_result "Restart Count" "FAIL" "${duration}" "Restart count: ${restart_count} (too high)"
        return 1
    fi
}

check_no_oom_kill() {
    local container="$1"
    local start=$(date +%s)
    
    local oom=$(docker inspect "${container}" --format '{{.State.OOMKilled}}' 2>/dev/null || echo "false")
    local end=$(date +%s)
    local duration=$((end - start))
    
    if [[ "${oom}" == "false" ]]; then
        print_result "OOM Kill Check" "PASS" "${duration}" "OOMKilled: false"
        return 0
    else
        print_result "OOM Kill Check" "FAIL" "${duration}" "Container was OOM killed!"
        return 1
    fi
}

# ============================================
# POSTGRESQL HEALTH CHECKS
# ============================================

check_postgres_ready() {
    local start=$(date +%s)
    
    if run_with_retry "docker exec postgres pg_isready -U postgres >/dev/null 2>&1"; then
        local end=$(date +%s)
        local duration=$((end - start))
        print_result "PG Ready (pg_isready)" "PASS" "${duration}" "PostgreSQL accepting connections"
        return 0
    else
        print_result "PG Ready (pg_isready)" "FAIL" "0" "PostgreSQL not ready"
        return 1
    fi
}

check_postgres_connect() {
    local start=$(date +%s)
    
    if run_with_retry "docker exec postgres psql -U postgres -c 'SELECT 1' >/dev/null 2>&1"; then
        local end=$(date +%s)
        local duration=$((end - start))
        print_result "PG Connect (SELECT 1)" "PASS" "${duration}" "Can execute queries"
        return 0
    else
        print_result "PG Connect (SELECT 1)" "FAIL" "0" "Cannot connect to PostgreSQL"
        return 1
    fi
}

check_postgres_databases() {
    local start=$(date +%s)
    
    local databases=$(docker exec postgres psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false" 2>/dev/null | tr -d ' ' | grep -v '^$')
    local end=$(date +%s)
    local duration=$((end - start))
    
    if echo "${databases}" | grep -q "immich"; then
        local db_list=$(echo ${databases} | tr '\n' ', ')
        print_result "PG Databases" "PASS" "${duration}" "Found: ${db_list}"
        return 0
    else
        print_result "PG Databases" "FAIL" "${duration}" "immich database not found"
        return 1
    fi
}

check_postgres_immich_access() {
    local start=$(date +%s)
    
    if docker exec postgres psql -U postgres -d immich -c 'SELECT COUNT(*) FROM "user"' >/dev/null 2>&1; then
        local end=$(date +%s)
        local duration=$((end - start))
        local count=$(docker exec postgres psql -U postgres -d immich -t -c 'SELECT COUNT(*) FROM "user"' 2>/dev/null | tr -d ' ')
        print_result "Immich DB Access" "PASS" "${duration}" "User count: ${count}"
        return 0
    else
        print_result "Immich DB Access" "FAIL" "0" "Cannot access immich database"
        return 1
    fi
}

check_postgres_hedgedoc_access() {
    local start=$(date +%s)
    
    if run_with_retry "docker exec postgres psql -U postgres -d hedgedoc -c 'SELECT 1' >/dev/null 2>&1"; then
        local end=$(date +%s)
        local duration=$((end - start))
        print_result "HedgeDoc DB Access" "PASS" "${duration}" "Can access hedgedoc database"
        return 0
    else
        print_result "HedgeDoc DB Access" "FAIL" "0" "Cannot access hedgedoc database"
        return 1
    fi
}

check_postgres_write_test() {
    local start=$(date +%s)
    
    if docker exec postgres psql -U postgres -d immich -c "CREATE TEMP TABLE _healthcheck (id INT); DROP TABLE _healthcheck;" >/dev/null 2>&1; then
        local end=$(date +%s)
        local duration=$((end - start))
        print_result "PG Write Test" "PASS" "${duration}" "Can create/drop temp tables"
        return 0
    else
        print_result "PG Write Test" "FAIL" "0" "Cannot write to database"
        return 1
    fi
}

# ============================================
# INTEGRATION TESTS
# ============================================

check_immich_api() {
    local start=$(date +%s)
    
    if run_with_retry "curl -s -f http://localhost:2283/api/server/ping 2>/dev/null | grep -q pong"; then
        local end=$(date +%s)
        local duration=$((end - start))
        print_result "Immich API Ping" "PASS" "${duration}" "API returned pong"
        return 0
    else
        print_result "Immich API Ping" "FAIL" "0" "Cannot reach Immich API"
        return 1
    fi
}

check_hedgedoc_http() {
    local start=$(date +%s)
    
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 2>/dev/null || echo "000")
    local end=$(date +%s)
    local duration=$((end - start))
    
    if [[ "${http_code}" =~ ^(200|302|301)$ ]]; then
        print_result "HedgeDoc HTTP" "PASS" "${duration}" "HTTP ${http_code}"
        return 0
    else
        print_result "HedgeDoc HTTP" "FAIL" "${duration}" "HTTP ${http_code}"
        return 1
    fi
}

# ============================================
# MAIN FUNCTIONS
# ============================================

run_postgres_checks() {
    echo "=========================================="
    echo "PostgreSQL Health Checks"
    echo "=========================================="
    echo ""
    
    local all_passed=true
    
    # Container checks
    check_container_running "postgres" || all_passed=false
    check_container_healthy "postgres" || all_passed=false
    check_container_not_restarting "postgres" || all_passed=false
    check_no_oom_kill "postgres" || all_passed=false
    
    echo ""
    
    # Service checks
    check_postgres_ready || all_passed=false
    check_postgres_connect || all_passed=false
    check_postgres_databases || all_passed=false
    
    echo ""
    
    # Functional tests
    check_postgres_immich_access || all_passed=false
    check_postgres_hedgedoc_access || all_passed=false
    check_postgres_write_test || all_passed=false
    
    echo ""
    
    # Integration tests
    check_immich_api || all_passed=false
    check_hedgedoc_http || all_passed=false
    
    echo ""
    echo "=========================================="
    
    if ${all_passed}; then
        echo -e "${GREEN}ALL CHECKS PASSED${NC}"
        return 0
    else
        echo -e "${RED}SOME CHECKS FAILED${NC}"
        return 1
    fi
}

run_container_checks() {
    local container="$1"
    
    echo "=========================================="
    echo "Container Health Checks: ${container}"
    echo "=========================================="
    echo ""
    
    local all_passed=true
    
    check_container_running "${container}" || all_passed=false
    check_container_healthy "${container}" || all_passed=false
    check_container_not_restarting "${container}" || all_passed=false
    check_no_oom_kill "${container}" || all_passed=false
    
    echo ""
    echo "=========================================="
    
    if ${all_passed}; then
        echo -e "${GREEN}ALL CHECKS PASSED${NC}"
        return 0
    else
        echo -e "${RED}SOME CHECKS FAILED${NC}"
        return 1
    fi
}

show_usage() {
    cat << EOF
Usage: $0 <command> [container_name]

Commands:
    postgres        Run full PostgreSQL health check suite
    container       Run basic container health checks
    all             Run all health checks for all containers
    help            Show this help message

Examples:
    $0 postgres                 # Full PostgreSQL health checks
    $0 container jellyfin       # Basic checks for jellyfin
    $0 all                      # Check all running containers

Note: Due to TrueNAS execution restrictions, run with:
    cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/ && bash /tmp/health-checks.sh postgres && rm /tmp/health-checks.sh
EOF
}

main() {
    local command="${1:-help}"
    
    case "${command}" in
        postgres)
            run_postgres_checks
            ;;
        container)
            if [[ -z "${2:-}" ]]; then
                echo "Error: Container name required"
                exit 1
            fi
            run_container_checks "$2"
            ;;
        all)
            echo "Checking all running containers..."
            echo ""
            for container in $(docker ps --format '{{.Names}}' | sort); do
                run_container_checks "${container}"
                echo ""
            done
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            echo "Unknown command: ${command}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
