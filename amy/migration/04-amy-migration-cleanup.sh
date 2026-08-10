#!/bin/bash
# ============================================
# AMY Migration Script - Step 4: Cleanup
# Version: 81
# ============================================
# This script removes old data from /portainer
# ONLY run this AFTER all tests pass!
# ============================================

echo "============================================"
echo "AMY Migration - Step 4: Cleanup /portainer"
echo "============================================"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Safety check - require confirmation
echo -e "${YELLOW}⚠️  WARNING: This will DELETE data from /portainer!${NC}"
echo ""
echo "This script will remove the following directories that have been"
echo "migrated to /docker:"
echo ""

# List what will be deleted
DIRS_TO_DELETE=(
    "/portainer/argus"
    "/portainer/atuin"
    "/portainer/beszel"
    "/portainer/diun"
    "/portainer/dockwatch"
    "/portainer/it-tools"
    "/portainer/lubelogger"
    "/portainer/mealie"
    "/portainer/metube"
    "/portainer/netalertx"
    "/portainer/ntfy"
    "/portainer/postgresql"
    "/portainer/trivy"
    "/portainer/tsdproxy"
    "/portainer/limdius"
    "/portainer/changedetection"
    "/portainer/jellyfin/spendspentspent"
)

TOTAL_SIZE=0
for dir in "${DIRS_TO_DELETE[@]}"; do
    if [ -d "$dir" ]; then
        size=$(du -sm "$dir" 2>/dev/null | cut -f1)
        TOTAL_SIZE=$((TOTAL_SIZE + size))
        echo "  $dir (${size}MB)"
    fi
done

echo ""
echo "Total space to be freed: ${TOTAL_SIZE}MB"
echo ""

# Directories that will NOT be deleted (still in use or not migrated)
echo "The following directories will be PRESERVED:"
echo "  /portainer/jellyfin (NFS mount data, used by spendspentspent)"
echo "  /portainer/miniflux-db (old database - manual review needed)"
echo "  /portainer/postgres (old database - manual review needed)"
echo "  Any other directories not listed above"
echo ""

read -p "Have you verified all tests passed? (yes/no): " CONFIRM1
if [ "$CONFIRM1" != "yes" ]; then
    echo -e "${RED}Aborted. Please run ./03-amy-migration-test.sh first.${NC}"
    exit 1
fi

read -p "Are you sure you want to delete the old data? (DELETE/no): " CONFIRM2
if [ "$CONFIRM2" != "DELETE" ]; then
    echo -e "${YELLOW}Aborted. No changes made.${NC}"
    exit 0
fi

echo ""
echo "============================================"
echo "Deleting old directories..."
echo "============================================"
echo ""

for dir in "${DIRS_TO_DELETE[@]}"; do
    if [ -d "$dir" ]; then
        echo -e "${YELLOW}Deleting ${dir}...${NC}"
        rm -rf "$dir"
        if [ ! -d "$dir" ]; then
            echo -e "${GREEN}  ✅ Deleted${NC}"
        else
            echo -e "${RED}  ❌ Failed to delete${NC}"
        fi
    fi
done

echo ""
echo "============================================"
echo -e "${GREEN}Cleanup Complete!${NC}"
echo "============================================"
echo ""
echo "Space freed: approximately ${TOTAL_SIZE}MB"
echo ""
echo "Remaining in /portainer (preserved):"
ls -la /portainer/ 2>/dev/null || echo "  (directory may be empty)"
echo ""
echo "============================================"
echo "Migration Finished Successfully!"
echo "============================================"
echo ""
echo "Your services are now running from /docker/"
echo ""
echo "Note: The following old database directories were preserved"
echo "for manual review (can be deleted after 48 hours if not needed):"
echo "  - /portainer/miniflux-db"
echo "  - /portainer/postgres"
echo ""
