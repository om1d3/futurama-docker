#!/bin/bash
# ============================================
# AMY - Health Checks Script
# Version: 1.0
# ============================================
# Comprehensive health checks for critical services
# ============================================

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# ============================================
# HELPER FUNCTIONS
# ============================================

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED++))
}

check_warn() {
    echo -e "${YELLOW}!${NC} $1"
    ((WARNINGS++))
}

# ============================================
# POSTGRES CHECKS
# ============================================

check_postgres() {
    echo "=== PostgreSQL Health Checks ==="
    echo ""
    
    # Check container running
    if docker ps --format '{{.Names}}' | grep -q '^postgres$'; then
        check_pass "PostgreSQL container is running"
    else
        check_fail "PostgreSQL container is NOT running"
        return 1
    fi
    
    # Check health status
    local health=$(docker inspect --format='{{.State.Health.Status}}' postgres 2>/dev/null || echo "unknown")
    if [[ "${health}" == "healthy" ]]; then
        check_pass "PostgreSQL health status: healthy"
    else
        check_fail "PostgreSQL health status: ${health}"
    fi
    
    # Check pg_isready
    if docker exec postgres pg_isready -U postgres > /dev/null 2>&1; then
        check_pass "PostgreSQL is accepting connections"
    else
        check_fail "PostgreSQL is NOT accepting connections"
    fi
    
    # Check databases exist
    for db in atuin miniflux sss; do
        if docker exec postgres psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "${db}"; then
            check_pass "Database '${db}' exists"
        else
            check_fail "Database '${db}' does NOT exist"
        fi
    done
    
    # Check SELECT 1
    if docker exec postgres psql -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
        check_pass "PostgreSQL can execute queries"
    else
        check_fail "PostgreSQL cannot execute queries"
    fi
    
    # Check connections to each database
    for db in atuin miniflux sss; do
        if docker exec postgres psql -U postgres -d "${db}" -c "SELECT 1;" > /dev/null 2>&1; then
            check_pass "Can connect to '${db}' database"
        else
            check_fail "Cannot connect to '${db}' database"
        fi
    done
    
    echo ""
}

# ============================================
# NTFY CHECKS
# ============================================

check_ntfy() {
    echo "=== ntfy Health Checks ==="
    echo ""
    
    # Check container running
    if docker ps --format '{{.Names}}' | grep -q '^ntfy$'; then
        check_pass "ntfy container is running"
    else
        check_fail "ntfy container is NOT running"
        return 1
    fi
    
    # Check HTTP response
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8888 | grep -q "200\|301\|302"; then
        check_pass "ntfy HTTP endpoint responding"
    else
        check_fail "ntfy HTTP endpoint NOT responding"
    fi
    
    # Check can publish test message (dry run)
    if curl -s -X POST "http://localhost:8888/health-check-test" \
        -H "Title: Health Check" \
        -d "Test message from health-checks.sh" > /dev/null 2>&1; then
        check_pass "ntfy can receive messages"
    else
        check_warn "ntfy message test inconclusive"
    fi
    
    echo ""
}

# ============================================
# PIHOLE CHECKS
# ============================================

check_pihole() {
    echo "=== Pi-hole Health Checks ==="
    echo ""
    
    # Check container running
    if docker ps --format '{{.Names}}' | grep -q '^pihole$'; then
        check_pass "Pi-hole container is running"
    else
        check_fail "Pi-hole container is NOT running"
        return 1
    fi
    
    # Check health status
    local health=$(docker inspect --format='{{.State.Health.Status}}' pihole 2>/dev/null || echo "unknown")
    if [[ "${health}" == "healthy" ]]; then
        check_pass "Pi-hole health status: healthy"
    else
        check_warn "Pi-hole health status: ${health}"
    fi
    
    # Check DNS resolution
    if dig @localhost google.com +short > /dev/null 2>&1; then
        check_pass "Pi-hole DNS resolution working"
    else
        check_fail "Pi-hole DNS resolution NOT working"
    fi
    
    # Check web interface
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8053/admin/ | grep -q "200\|301\|302"; then
        check_pass "Pi-hole web interface accessible"
    else
        check_warn "Pi-hole web interface not accessible"
    fi
    
    echo ""
}

# ============================================
# TRIVY CHECKS
# ============================================

check_trivy() {
    echo "=== Trivy Health Checks ==="
    echo ""
    
    # Check container running
    if docker ps --format '{{.Names}}' | grep -q '^trivy$'; then
        check_pass "Trivy container is running"
    else
        check_fail "Trivy container is NOT running"
        return 1
    fi
    
    # Check health status
    local health=$(docker inspect --format='{{.State.Health.Status}}' trivy 2>/dev/null || echo "unknown")
    if [[ "${health}" == "healthy" ]]; then
        check_pass "Trivy health status: healthy"
    else
        check_warn "Trivy health status: ${health}"
    fi
    
    # Check healthz endpoint
    if curl -s http://localhost:8083/healthz > /dev/null 2>&1; then
        check_pass "Trivy healthz endpoint responding"
    else
        check_fail "Trivy healthz endpoint NOT responding"
    fi
    
    echo ""
}

# ============================================
# DIUN CHECKS
# ============================================

check_diun() {
    echo "=== Diun Health Checks ==="
    echo ""
    
    # Check container running
    if docker ps --format '{{.Names}}' | grep -q '^diun$'; then
        check_pass "Diun container is running"
    else
        check_fail "Diun container is NOT running"
        return 1
    fi
    
    # Check logs for errors
    local errors=$(docker logs diun 2>&1 | tail -50 | grep -c "ERR" || echo "0")
    if [[ "${errors}" -eq 0 ]]; then
        check_pass "No recent errors in Diun logs"
    else
        check_warn "Found ${errors} errors in recent Diun logs"
    fi
    
    # Check configuration loaded
    if docker logs diun 2>&1 | grep -q "Configuration loaded"; then
        check_pass "Diun configuration loaded successfully"
    else
        check_warn "Diun configuration status unclear"
    fi
    
    echo ""
}

# ============================================
# VAULTWARDEN CHECKS
# ============================================

check_vaultwarden() {
    echo "=== Vaultwarden Health Checks ==="
    echo ""
    
    # Check container running
    if docker ps --format '{{.Names}}' | grep -q '^vaultwarden$'; then
        check_pass "Vaultwarden container is running"
    else
        check_fail "Vaultwarden container is NOT running"
        return 1
    fi
    
    # Check HTTP response
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8484 | grep -q "200\|301\|302"; then
        check_pass "Vaultwarden HTTP endpoint responding"
    else
        check_fail "Vaultwarden HTTP endpoint NOT responding"
    fi
    
    echo ""
}

# ============================================
# ALL CONTAINERS CHECK
# ============================================

check_all_containers() {
    echo "=== All Containers Status ==="
    echo ""
    
    local total=$(docker compose -f /docker-compose/docker-compose.yaml ps --format '{{.Names}}' 2>/dev/null | wc -l)
    local running=$(docker compose -f /docker-compose/docker-compose.yaml ps --format '{{.Names}}' --filter "status=running" 2>/dev/null | wc -l)
    
    echo "Total containers: ${total}"
    echo "Running containers: ${running}"
    echo ""
    
    if [[ "${running}" -eq "${total}" ]]; then
        check_pass "All containers are running"
    else
        check_warn "Some containers are not running"
        docker compose -f /docker-compose/docker-compose.yaml ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | grep -v "Up"
    fi
    
    echo ""
}

# ============================================
# SUMMARY
# ============================================

print_summary() {
    echo "=========================================="
    echo "Health Check Summary"
    echo "=========================================="
    echo -e "Passed:   ${GREEN}${PASSED}${NC}"
    echo -e "Failed:   ${RED}${FAILED}${NC}"
    echo -e "Warnings: ${YELLOW}${WARNINGS}${NC}"
    echo "=========================================="
    
    if [[ ${FAILED} -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ============================================
# MAIN
# ============================================

main() {
    local target="${1:-all}"
    
    echo "=========================================="
    echo "Amy Health Checks - $(date)"
    echo "=========================================="
    echo ""
    
    case "${target}" in
        postgres)
            check_postgres
            ;;
        ntfy)
            check_ntfy
            ;;
        pihole)
            check_pihole
            ;;
        trivy)
            check_trivy
            ;;
        diun)
            check_diun
            ;;
        vaultwarden)
            check_vaultwarden
            ;;
        all)
            check_all_containers
            check_postgres
            check_ntfy
            check_pihole
            check_trivy
            check_diun
            check_vaultwarden
            ;;
        *)
            echo "Usage: $0 [postgres|ntfy|pihole|trivy|diun|vaultwarden|all]"
            exit 1
            ;;
    esac
    
    print_summary
}

main "$@"
