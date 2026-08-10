#!/bin/bash
# ============================================
# AMY Migration Script - Step 1: Copy Data
# Version: 81
# ============================================
# This script copies data from /portainer to /docker
# Run this BEFORE deploying the new docker-compose.yaml
# ============================================

set -e  # Exit on any error

echo "============================================"
echo "AMY Migration - Step 1: Copy /portainer to /docker"
echo "============================================"
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to copy with verification
copy_with_verify() {
    local src="$1"
    local dest="$2"
    local name="$3"
    
    if [ -d "$src" ]; then
        echo -e "${YELLOW}Copying ${name}...${NC}"
        mkdir -p "$dest"
        cp -a "$src"/* "$dest"/ 2>/dev/null || true
        
        # Verify copy
        local src_count=$(find "$src" -type f 2>/dev/null | wc -l)
        local dest_count=$(find "$dest" -type f 2>/dev/null | wc -l)
        
        if [ "$src_count" -eq "$dest_count" ]; then
            echo -e "${GREEN}  ✅ ${name}: ${src_count} files copied${NC}"
        else
            echo -e "${RED}  ⚠️  ${name}: Source has ${src_count} files, destination has ${dest_count}${NC}"
        fi
    else
        echo -e "${YELLOW}  ⏭️  ${name}: Source not found at ${src}, skipping${NC}"
    fi
}

# Pre-flight checks
echo "Pre-flight checks..."
echo ""

if [ ! -d "/portainer" ]; then
    echo -e "${RED}ERROR: /portainer directory not found!${NC}"
    exit 1
fi

if [ ! -d "/docker" ]; then
    echo "Creating /docker directory..."
    mkdir -p /docker
fi

# Check disk space
REQUIRED_SPACE=$(du -sm /portainer 2>/dev/null | cut -f1)
AVAILABLE_SPACE=$(df -m /docker | tail -1 | awk '{print $4}')

echo "Required space: ${REQUIRED_SPACE}MB"
echo "Available space: ${AVAILABLE_SPACE}MB"
echo ""

if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    echo -e "${RED}ERROR: Not enough disk space!${NC}"
    exit 1
fi

echo -e "${GREEN}Disk space check passed${NC}"
echo ""

# Stop all containers to ensure data consistency
echo "============================================"
echo "Stopping containers for safe migration..."
echo "============================================"
cd /docker-compose
docker compose down 2>/dev/null || true
echo ""

# Wait for containers to fully stop
sleep 5

echo "============================================"
echo "Copying data from /portainer to /docker..."
echo "============================================"
echo ""

# Copy each service's data
# Based on the ls -la /portainer output you provided

copy_with_verify "/portainer/argus" "/docker/argus" "Argus"
copy_with_verify "/portainer/atuin" "/docker/atuin" "Atuin"
copy_with_verify "/portainer/beszel" "/docker/beszel" "Beszel"
copy_with_verify "/portainer/diun" "/docker/diun" "Diun"
copy_with_verify "/portainer/dockwatch" "/docker/dockwatch" "Dockwatch"
copy_with_verify "/portainer/it-tools" "/docker/it-tools" "IT-Tools"
copy_with_verify "/portainer/lubelogger" "/docker/lubelogger" "LubeLogger"
copy_with_verify "/portainer/mealie" "/docker/mealie" "Mealie"
copy_with_verify "/portainer/metube" "/docker/metube" "MeTube"
copy_with_verify "/portainer/netalertx" "/docker/netalertx" "NetAlertX"
copy_with_verify "/portainer/ntfy" "/docker/ntfy" "ntfy"
copy_with_verify "/portainer/postgresql" "/docker/postgresql" "PostgreSQL"
copy_with_verify "/portainer/trivy" "/docker/trivy" "Trivy"
copy_with_verify "/portainer/tsdproxy" "/docker/tsdproxy" "TSDProxy"
copy_with_verify "/portainer/limdius" "/docker/limdius" "Limdius"
copy_with_verify "/portainer/changedetection" "/docker/changedetection" "ChangeDetection"

# SpendSpentSpent has a special path structure
if [ -d "/portainer/jellyfin/spendspentspent" ]; then
    echo -e "${YELLOW}Copying SpendSpentSpent (from /portainer/jellyfin/spendspentspent)...${NC}"
    mkdir -p /docker/spendspentspent
    cp -a /portainer/jellyfin/spendspentspent/* /docker/spendspentspent/ 2>/dev/null || true
    echo -e "${GREEN}  ✅ SpendSpentSpent: copied${NC}"
elif [ -d "/portainer/spendspentspent" ]; then
    copy_with_verify "/portainer/spendspentspent" "/docker/spendspentspent" "SpendSpentSpent"
else
    echo -e "${YELLOW}  ⏭️  SpendSpentSpent: not found, skipping${NC}"
fi

# Create directories that don't exist in /portainer but are needed
echo ""
echo "Creating additional required directories..."

mkdir -p /docker/stirling-pdf/{training,configs}
mkdir -p /docker/homepage
mkdir -p /docker/filebrowser
mkdir -p /docker/wallos
mkdir -p /docker/vaultwarden
mkdir -p /docker/valkey

echo -e "${GREEN}  ✅ Created additional directories${NC}"

# Set ownership
echo ""
echo "Setting ownership to 1000:1000..."
chown -R 1000:1000 /docker/
echo -e "${GREEN}  ✅ Ownership set${NC}"

echo ""
echo "============================================"
echo -e "${GREEN}Step 1 Complete: Data copied to /docker${NC}"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Review the copy results above for any warnings"
echo "  2. Run: ./02-amy-migration-verify.sh"
echo "  3. Deploy: docker compose up -d"
echo "  4. Run: ./03-amy-migration-test.sh"
echo "  5. If all tests pass, run: ./04-amy-migration-cleanup.sh"
echo ""
