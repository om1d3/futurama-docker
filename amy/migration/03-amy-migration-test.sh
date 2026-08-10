#!/bin/bash
# ============================================
# AMY Migration Script - Step 3: Test Services
# Version: 81
# ============================================
# This script tests that all services are working
# Run this AFTER deploying docker-compose.yaml
# ============================================

echo "============================================"
echo "AMY Migration - Step 3: Test Services"
echo "============================================"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

# Function to test HTTP endpoint
test_http() {
    local url="$1"
    local name="$2"
    local expected_code="${3:-200}"
    
    local response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null)
    
    if [ "$response" = "$expected_code" ] || [ "$response" = "302" ] || [ "$response" = "301" ]; then
        echo -e "${GREEN}✅ ${name}: HTTP ${response}${NC}"
    else
        echo -e "${RED}❌ ${name}: Expected ${expected_code}, got ${response}${NC}"
        ERRORS=$((ERRORS + 1))
    fi
}

# Function to test container is running
test_container() {
    local name="$1"
    
    if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        local status=$(docker inspect "$name" --format='{{.State.Status}}')
        if [ "$status" = "running" ]; then
            echo -e "${GREEN}✅ ${name}: running${NC}"
        else
            echo -e "${RED}❌ ${name}: status is ${status}${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo -e "${RED}❌ ${name}: container not found${NC}"
        ERRORS=$((ERRORS + 1))
    fi
}

# Function to test database connectivity
test_postgres() {
    echo "Testing PostgreSQL databases..."
    
    # Test postgres is accepting connections
    if docker exec postgres pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${GREEN}✅ PostgreSQL: accepting connections${NC}"
    else
        echo -e "${RED}❌ PostgreSQL: not accepting connections${NC}"
        ERRORS=$((ERRORS + 1))
        return
    fi
    
    # Test each database exists
    for db in atuin miniflux sss; do
        if docker exec postgres psql -U postgres -lqt | cut -d \| -f 1 | grep -qw "$db"; then
            echo -e "${GREEN}✅ Database '${db}': exists${NC}"
        else
            echo -e "${YELLOW}⚠️  Database '${db}': not found (may need to be created)${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
    done
}

echo "============================================"
echo "Testing Container Status..."
echo "============================================"
echo ""

test_container "tsdproxy"
test_container "dockwatch"
test_container "pihole"
test_container "keepalived"
test_container "postgres"
test_container "valkey"
test_container "ntfy"
test_container "stirling"
test_container "homepage"
test_container "atuin"
test_container "miniflux"
test_container "it-tools"
test_container "filebrowser"
test_container "wallos"
test_container "vaultwarden"
test_container "mealie"
test_container "argus"
test_container "lubelogger"
test_container "spendspentspent"
test_container "dozzle"
test_container "beszel"
test_container "cadvisor"
test_container "diun"
test_container "trivy"

echo ""
echo "============================================"
echo "Testing HTTP Endpoints..."
echo "============================================"
echo ""

test_http "http://localhost:8085" "TSDProxy"
test_http "http://localhost:9999" "Dockwatch"
test_http "http://localhost:8053/admin/" "Pi-hole"
test_http "http://localhost:8888" "ntfy"
test_http "http://localhost:8080" "Stirling-PDF"
test_http "http://localhost:3003" "Homepage"
test_http "http://localhost:8385" "Miniflux"
test_http "http://localhost:8181" "IT-Tools"
test_http "http://localhost:8082" "FileBrowser"
test_http "http://localhost:8283" "Wallos"
test_http "http://localhost:8484" "Vaultwarden"
test_http "http://localhost:8456" "Mealie"
test_http "http://localhost:8282" "Argus"
test_http "http://localhost:8989" "LubeLogger"
test_http "http://localhost:9021" "SpendSpentSpent"
test_http "http://localhost:8182" "Dozzle"
test_http "http://localhost:8090" "Beszel"
test_http "http://localhost:9099" "cAdvisor"

echo ""
echo "============================================"
echo "Testing Database..."
echo "============================================"
echo ""

test_postgres

echo ""
echo "============================================"
echo "Testing DNS (Pi-hole)..."
echo "============================================"
echo ""

if dig @127.0.0.1 google.com +short > /dev/null 2>&1; then
    echo -e "${GREEN}✅ DNS resolution: working${NC}"
else
    echo -e "${RED}❌ DNS resolution: failed${NC}"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "============================================"
echo "Summary"
echo "============================================"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}All tests passed! Migration successful.${NC}"
    echo ""
    echo "Next step:"
    echo "  Run: ./04-amy-migration-cleanup.sh"
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}Tests passed with ${WARNINGS} warnings.${NC}"
    echo "Review warnings before proceeding with cleanup."
else
    echo -e "${RED}Tests failed: ${ERRORS} errors, ${WARNINGS} warnings${NC}"
    echo ""
    echo "DO NOT proceed with cleanup until all errors are resolved!"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check container logs: docker logs <container_name>"
    echo "  - Check docker-compose: docker compose logs"
    echo "  - Verify .env file has all required variables"
    exit 1
fi
