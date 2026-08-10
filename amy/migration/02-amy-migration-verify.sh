#!/bin/bash
# ============================================
# AMY Migration Script - Step 2: Verify Copy
# Version: 81
# ============================================
# This script verifies the data was copied correctly
# Run this AFTER 01-amy-migration-copy.sh
# ============================================

set -e

echo "============================================"
echo "AMY Migration - Step 2: Verify Data Copy"
echo "============================================"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0

verify_directory() {
    local src="$1"
    local dest="$2"
    local name="$3"
    
    if [ -d "$src" ]; then
        local src_size=$(du -sm "$src" 2>/dev/null | cut -f1)
        local dest_size=$(du -sm "$dest" 2>/dev/null | cut -f1)
        local src_files=$(find "$src" -type f 2>/dev/null | wc -l)
        local dest_files=$(find "$dest" -type f 2>/dev/null | wc -l)
        
        if [ "$src_files" -eq "$dest_files" ]; then
            echo -e "${GREEN}✅ ${name}: ${src_files} files, ${dest_size}MB${NC}"
        else
            echo -e "${RED}❌ ${name}: Source ${src_files} files vs Dest ${dest_files} files${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    fi
}

echo "Comparing /portainer vs /docker..."
echo ""

verify_directory "/portainer/argus" "/docker/argus" "Argus"
verify_directory "/portainer/atuin" "/docker/atuin" "Atuin"
verify_directory "/portainer/beszel" "/docker/beszel" "Beszel"
verify_directory "/portainer/diun" "/docker/diun" "Diun"
verify_directory "/portainer/dockwatch" "/docker/dockwatch" "Dockwatch"
verify_directory "/portainer/it-tools" "/docker/it-tools" "IT-Tools"
verify_directory "/portainer/lubelogger" "/docker/lubelogger" "LubeLogger"
verify_directory "/portainer/mealie" "/docker/mealie" "Mealie"
verify_directory "/portainer/netalertx" "/docker/netalertx" "NetAlertX"
verify_directory "/portainer/ntfy" "/docker/ntfy" "ntfy"
verify_directory "/portainer/postgresql" "/docker/postgresql" "PostgreSQL"
verify_directory "/portainer/trivy" "/docker/trivy" "Trivy"
verify_directory "/portainer/tsdproxy" "/docker/tsdproxy" "TSDProxy"
verify_directory "/portainer/limdius" "/docker/limdius" "Limdius"
verify_directory "/portainer/spendspentspent" "/docker/spendspentspent" "SpendSpentSpent"

echo ""
echo "============================================"

if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}Step 2 Complete: All data verified successfully!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy: cd /docker-compose && docker compose up -d"
    echo "  2. Wait for services to start: sleep 60"
    echo "  3. Run tests: ./03-amy-migration-test.sh"
else
    echo -e "${RED}Step 2 Failed: ${ERRORS} verification errors found!${NC}"
    echo ""
    echo "Please review the errors above before proceeding."
    exit 1
fi
