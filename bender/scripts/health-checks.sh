#!/bin/bash
# ============================================
# Health Check Script
# Version: 1.0
# Host: bender (TrueNAS Scale)
# ============================================
# Comprehensive health checks for containers
# with special PostgreSQL testing suite
# ============================================
# Due to TrueNAS execution restrictions, run with:
#   cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/ && \
#      bash /tmp/health-checks.sh <container> && \
#      rm /tmp/health-checks.sh
# ============================================

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================
# UTILITIES
# ============================================

print_result() {
    local test_name="$1"
    local result="$2"
    local duration="$3"
    local details="${4:-}"
    
    if [[ "${result}" == "PASS" ]]; then
        echo -e "${GREEN}✅ PASS${NC} | ${test_name} | ${duration}s | ${details}"
    else
        echo -e "${RED}❌ FAIL${NC} | ${test_name} | ${duration}s | ${details}"
    fi
}

run_with_retry() {
    local cmd="$1"
    local max_attempts="${2:-3}"
    local delay="${3:-2}"
    
    for ((i=1; i<=max_attempts; i++)); do
        if eval "${cmd}"; then
            return 0
        fi
        sleep "${delay}"
    done
    return 1
}

# ============================================
# CONTAINER CHECKS
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
        print_result "Container Running" "FAIL" "0" "Container ${container} is not running"
        return 1
    fi
}

check_container_health() {
    local container="$1"
    local start=$(date +%s)
    
    local health=$(docker inspect "${container}" --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
    local end=$(date +%s)
    local duration=$((end - start))
    
    if [[ "${health}" == "healthy" ]] || [[ "${health}" == "none" ]]; then
        print_result "Docker Healthcheck" "PASS" "${duration}" "Status: ${health}"
        return 0
    else
        print_result "Docker Healthcheck" "FAIL" "${duration}" "Status: ${health}"
        return 1
    fi
}

check_container_restart_count() {
    local container="$1"
    local start=$(date +%s)
    
    local restart_count=$(docker inspect "${container}" --format='{{.RestartCount}}' 2>/dev/null || echo "999")
    local end=$(date +%s)
    local duration=$((end - start))
    
    if [[ "${restart_count}" -lt 3 ]]; then
        print_result "Restart Count" "PASS" "${duration}" "Restart count: ${restart_count}"
        return 0
    else
        print_result "Restart Count" "FAIL" "${duration}" "Restart count: ${restart_count}"
        return 1
    fi
}

check_container_oom() {
    local container="$1"
    local start=$(date +%s)
    
    local oom_killed=$(docker inspect "${container}" --format='{{.State.OOMKilled}}' 2>/dev/null || echo "true")
    local end=$(date +%s)
    local duration=$((end - start))
    
    if [[ "${oom_killed}" == "false" ]]; then
        print_result "OOM Kill Check" "PASS" "${duration}" "OOMKilled: ${oom_killed}"
        return 0
    else
        print_result "OOM Kill Check" "FAIL" "${duration}" "OOMKilled: ${oom_killed}"
        return 1
    fi
}

# ============================================
# POSTGRESQL CHECKS
# ============================================

check_postgres_ready() {
    local start=$(date +%s)
    
    if run_with_retry "docker exec postgres pg_isready -U postgres > /dev/null 2>&1"; then
        local end=$(date +%s)
        local duration=$((end - start))
        print_result "PG Ready (pg_isready)" "PASS" "${duration}" "PostgreSQL accepting connections"
        return 0
    else
        print_result "PG Ready (pg_isready)" "FAIL" "0" "PostgreSQL not accepting connections"
        return 1
    fi
}

check_postgres_connect() {
    local start=$(date +%s)
    
    if run_with_retry "docker exec postgres psql -U postgres -c 'SELECT 1' > /dev/null 2>&1"; then
        local end=$(date +%s)
        local duration=$((end - start))
        print_result "PG Connect (SELECT 1)" "PASS" "${duration}" "Can execute queries"
        return 0
    else
        print_result "PG Connect (SELECT 1)" "FAIL" "0" "Cannot execute queries"
        return 1
    fi
}

check_postgres_databases() {
    local start=$(date +%s)
    
    local databases=$(docker exec postgres psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false" 2>/dev/null | tr -d ' ' | tr '\n' ',' || echo "")
    local end=$(date +%s)
    local duration=$((end - start))
    
    if [[ -n "${databases}" ]]; then
        print_result "PG Databases" "PASS" "${duration}" "Found: ${databases}"
        return 0
    else
        print_result "PG Databases" "FAIL" "${duration}" "No databases found"
        return 1
    fi
}

check_postgres_immich_access() {
    local start=$(date +%s)
    
    if run_with_retry "docker exec postgres psql -U postgres -d immich -c 'SELECT 1' > /dev/null 2>&1"; then
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
    
    if run_with_retry "docker exec postgres psql -U postgres -d hedgedoc -c 'SELECT 1' > /dev/null 2>&1"; then
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
    
    if docker exec postgres psql -U postgres -d immich -c "CREATE TEMP TABLE _healthcheck (id INT); DROP TABLE _healthcheck;" > /dev/null 2>&1; then
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
    
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3000" 2>/dev/null || echo "000")
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
# TEST SUITES
# ============================================

run_postgres_checks() {
    local failed=0
    
    echo "=========================================="
    echo "PostgreSQL Health Checks"
    echo "=========================================="
    echo ""
    
    # Container checks
    check_container_running "postgres" || ((failed++))
    check_container_health "postgres" || ((failed++))
    check_container_restart_count "postgres" || ((failed++))
    check_container_oom "postgres" || ((failed++))
    
    echo ""
    
    # PostgreSQL specific checks
    check_postgres_ready || ((failed++))
    check_postgres_connect || ((failed++))
    check_postgres_databases || ((failed++))
    
    echo ""
    
    # Functional tests
    check_postgres_immich_access || ((failed++))
    check_postgres_hedgedoc_access || ((failed++))
    check_postgres_write_test || ((failed++))
    
    echo ""
    
    # Integration tests
    check_immich_api || ((failed++))
    check_hedgedoc_http || ((failed++))
    
    echo ""
    echo "=========================================="
    
    if [[ ${failed} -eq 0 ]]; then
        echo -e "${GREEN}ALL CHECKS PASSED${NC}"
        return 0
    else
        echo -e "${RED}${failed} CHECKS FAILED${NC}"
        return 1
    fi
}

run_container_checks() {
    local container="$1"
    local failed=0
    
    echo "=========================================="
    echo "Container Health Checks: ${container}"
    echo "=========================================="
    echo ""
    
    check_container_running "${container}" || ((failed++))
    check_container_health "${container}" || ((failed++))
    check_container_restart_count "${container}" || ((failed++))
    check_container_oom "${container}" || ((failed++))
    
    echo ""
    echo "=========================================="
    
    if [[ ${failed} -eq 0 ]]; then
        echo -e "${GREEN}ALL CHECKS PASSED${NC}"
        return 0
    else
        echo -e "${RED}${failed} CHECKS FAILED${NC}"
        return 1
    fi
}

# ============================================
# MAIN
# ============================================

show_usage() {
    cat << EOF
Health Check Script v1.0

Usage: $0 <container|postgres>

Examples:
    $0 postgres     # Run full PostgreSQL health check suite
    $0 jellyfin     # Run generic container health checks

PostgreSQL Suite includes:
    - Container running/healthy
    - Restart count and OOM checks
    - pg_isready connectivity
    - SELECT 1 query test
    - Database enumeration
    - Immich database access
    - HedgeDoc database access
    - Write test (temp table)
    - Immich API integration
    - HedgeDoc HTTP integration

Due to TrueNAS execution restrictions, run with:
    cp /mnt/BIG/filme/docker-compose/scripts/health-checks.sh /tmp/ && \\
       bash /tmp/health-checks.sh <container> && \\
       rm /tmp/health-checks.sh
EOF
}

main() {
    local target="${1:-}"
    
    if [[ -z "${target}" ]]; then
        show_usage
        exit 1
    fi
    
    case "${target}" in
        postgres)
            run_postgres_checks
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            run_container_checks "${target}"
            ;;
    esac
}

main "$@"
