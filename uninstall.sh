#!/usr/bin/env bash
# ============================================================
# uninstall.sh — Remove MySQL Backup Service
# ============================================================
set -euo pipefail

SERVICE_NAME="mysql-backup"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[FAIL]${NC} Run as root or with sudo." >&2
    exit 1
fi

echo -e "${CYAN}Removing MySQL Backup Service...${NC}"

# Stop and disable
systemctl stop ${SERVICE_NAME}.timer 2>/dev/null || true
systemctl disable ${SERVICE_NAME}.timer 2>/dev/null || true
systemctl stop ${SERVICE_NAME}.service 2>/dev/null || true

# Remove unit files
rm -f /etc/systemd/system/${SERVICE_NAME}.service
rm -f /etc/systemd/system/${SERVICE_NAME}.timer
systemctl daemon-reload

echo -e "${GREEN}[OK]${NC} Systemd timer and service removed."
echo ""
echo -e "  ${CYAN}Note:${NC} The backup script, .env, and logs were NOT deleted."
echo -e "  Remove them manually if you no longer need them."