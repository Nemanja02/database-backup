#!/usr/bin/env bash
# ============================================================
# install.sh — Set up MySQL Backup Service on any Linux server
# Run as root or with sudo.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="mysql-backup"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ── Root check ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (or with sudo)."
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     MySQL Backup Service — Installer         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Check .env ───────────────────────────────────────────────
if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
    info ".env not found — launching interactive setup..."
    echo ""
    bash "${SCRIPT_DIR}/generate-env.sh"
    if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
        fail ".env was not generated. Aborting."
    fi
fi

source "${SCRIPT_DIR}/.env"
info "Loaded configuration from .env"

# ── Detect package manager ───────────────────────────────────
install_pkg() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "$@"
    elif command -v yum &>/dev/null; then
        yum install -y -q "$@"
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$@"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$@"
    elif command -v zypper &>/dev/null; then
        zypper install -y "$@"
    elif command -v apk &>/dev/null; then
        apk add --no-cache "$@"
    else
        fail "No supported package manager found."
    fi
}

# ── Install dependencies ────────────────────────────────────
info "Checking dependencies..."

# MySQL client
if ! command -v mysqldump &>/dev/null; then
    info "Installing MySQL client tools..."
    if command -v apt-get &>/dev/null; then
        install_pkg default-mysql-client 2>/dev/null || install_pkg mysql-client
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        install_pkg mysql
    elif command -v apk &>/dev/null; then
        install_pkg mysql-client
    else
        install_pkg mysql-client
    fi
fi
ok "mysqldump available: $(command -v mysqldump)"

# gzip
if ! command -v gzip &>/dev/null; then
    info "Installing gzip..."
    install_pkg gzip
fi
ok "gzip available"

# AWS CLI
if ! command -v aws &>/dev/null; then
    info "Installing AWS CLI v2..."
    TMP=$(mktemp -d)
    if command -v curl &>/dev/null; then
        DOWNLOADER="curl -fsSL -o"
    elif command -v wget &>/dev/null; then
        DOWNLOADER="wget -q -O"
    else
        install_pkg curl
        DOWNLOADER="curl -fsSL -o"
    fi

    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    else
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    fi

    $DOWNLOADER "${TMP}/awscliv2.zip" "$AWS_URL"

    if ! command -v unzip &>/dev/null; then
        install_pkg unzip
    fi

    unzip -q "${TMP}/awscliv2.zip" -d "${TMP}"
    "${TMP}/aws/install" --update 2>/dev/null || "${TMP}/aws/install"
    rm -rf "$TMP"
fi
ok "AWS CLI available: $(aws --version 2>&1 | head -1)"

# ── Test MySQL connection ────────────────────────────────────
info "Testing MySQL connection..."
if mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
    --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" \
    -e "SELECT 1;" &>/dev/null; then
    ok "MySQL connection successful"
else
    warn "Could not connect to MySQL. Verify credentials in .env."
    warn "Continuing with installation anyway..."
fi

# ── Test S3 access ───────────────────────────────────────────
info "Testing S3 access..."
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION

S3_EP_FLAG=""
if [[ -n "${S3_ENDPOINT:-}" && "$S3_ENDPOINT" != "https://s3.amazonaws.com" ]]; then
    S3_EP_FLAG="--endpoint-url=$S3_ENDPOINT"
fi

if aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" $S3_EP_FLAG &>/dev/null; then
    ok "S3 bucket accessible"
else
    warn "Could not list S3 bucket. Verify S3 settings in .env."
    warn "Continuing with installation anyway..."
fi

# ── Set permissions ──────────────────────────────────────────
chmod 700 "${SCRIPT_DIR}/mysql-backup.sh"
chmod 600 "${SCRIPT_DIR}/.env"
ok "File permissions set (script: 700, .env: 600)"

# ── Create log file ──────────────────────────────────────────
LOG_FILE="${LOG_FILE:-/var/log/mysql-backup-service.log}"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"
ok "Log file: $LOG_FILE"

# ── Install systemd timer ───────────────────────────────────
INTERVAL="${BACKUP_INTERVAL_HOURS:-24}"

info "Setting up systemd timer (every ${INTERVAL}h)..."

cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MySQL Backup Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/mysql-backup.sh
WorkingDirectory=${SCRIPT_DIR}
# Security hardening
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${SCRIPT_DIR} /tmp ${LOG_FILE}
EOF

cat > /etc/systemd/system/${SERVICE_NAME}.timer <<EOF
[Unit]
Description=MySQL Backup Timer (every ${INTERVAL}h)

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}h
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.timer
ok "Systemd timer enabled and started"

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Installation Complete!               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Config:     ${CYAN}${SCRIPT_DIR}/.env${NC}"
echo -e "  Script:     ${CYAN}${SCRIPT_DIR}/mysql-backup.sh${NC}"
echo -e "  Log:        ${CYAN}${LOG_FILE}${NC}"
echo -e "  Schedule:   ${CYAN}Every ${INTERVAL} hour(s)${NC}"
echo -e "  Retention:  ${CYAN}${BACKUP_RETENTION_COUNT:-7} backups per database${NC}"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo -e "    Run now:      ${CYAN}sudo ${SCRIPT_DIR}/mysql-backup.sh${NC}"
echo -e "    Timer status: ${CYAN}systemctl status ${SERVICE_NAME}.timer${NC}"
echo -e "    View logs:    ${CYAN}tail -f ${LOG_FILE}${NC}"
echo -e "    Stop timer:   ${CYAN}sudo systemctl stop ${SERVICE_NAME}.timer${NC}"
echo -e "    Uninstall:    ${CYAN}sudo ${SCRIPT_DIR}/uninstall.sh${NC}"
echo ""