#!/usr/bin/env bash
# ============================================================
# generate-env.sh — Interactive .env generator
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   MySQL Backup Service — Configuration       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

if [[ -f "$ENV_FILE" ]]; then
    echo -e "${YELLOW}[WARN]${NC} .env already exists at ${ENV_FILE}"
    read -rp "Overwrite? (y/N): " OVERWRITE
    if [[ "${OVERWRITE,,}" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# Helper: prompt with a default value
ask() {
    local var_name="$1"
    local prompt="$2"
    local default="${3:-}"
    local secret="${4:-false}"

    if [[ -n "$default" ]]; then
        prompt="${prompt} ${DIM}[${default}]${NC}"
    fi

    if [[ "$secret" == "true" ]]; then
        echo -en "  ${prompt}: "
        read -rs VALUE
        echo ""
    else
        read -rp "$(echo -e "  ${prompt}: ")" VALUE
    fi

    VALUE="${VALUE:-$default}"
    eval "$var_name=\"\$VALUE\""
}

# ── MySQL ────────────────────────────────────────────────────
echo -e "${GREEN}── MySQL Connection ──${NC}"
ask MYSQL_HOST      "Host"                    "localhost"
ask MYSQL_PORT      "Port"                    "3306"
ask MYSQL_USER      "User"                    "root"
ask MYSQL_PASSWORD  "Password"                ""          true
ask MYSQL_DATABASES "Databases (comma-separated, or ALL)" "ALL"
echo ""

# ── Naming ───────────────────────────────────────────────────
echo -e "${GREEN}── Backup Naming ──${NC}"
echo -e "  ${DIM}Placeholders: {db} {date} {time} {timestamp} {hostname}${NC}"
ask BACKUP_NAME_PATTERN "Name pattern" "{hostname}_{db}_{date}_{time}"
echo ""

# ── S3 ───────────────────────────────────────────────────────
echo -e "${GREEN}── S3 Storage ──${NC}"
echo -e "  ${DIM}Works with AWS, DigitalOcean Spaces, MinIO, Backblaze B2, etc.${NC}"
ask S3_BUCKET              "Bucket name"      ""
ask S3_PATH                "Path prefix"      "backups/mysql"
ask S3_ENDPOINT            "Endpoint URL"     "https://s3.amazonaws.com"
ask AWS_ACCESS_KEY_ID      "Access key ID"    ""
ask AWS_SECRET_ACCESS_KEY  "Secret access key" ""         true
ask AWS_DEFAULT_REGION     "Region"           "us-east-1"
echo ""

# ── Schedule & Retention ─────────────────────────────────────
echo -e "${GREEN}── Schedule & Retention ──${NC}"
ask BACKUP_INTERVAL_HOURS  "Backup interval (hours)"     "24"
ask BACKUP_RETENTION_COUNT "Backups to keep per database" "7"
echo ""

# ── Notifications ────────────────────────────────────────────
echo -e "${GREEN}── Notifications (optional) ──${NC}"
ask NOTIFY_WEBHOOK_URL "Webhook URL (leave empty to skip)" ""
if [[ -n "$NOTIFY_WEBHOOK_URL" ]]; then
    ask NOTIFY_TYPE "Type (slack/discord)" "slack"
else
    NOTIFY_TYPE="slack"
fi
echo ""

# ── Logging ──────────────────────────────────────────────────
echo -e "${GREEN}── Logging ──${NC}"
ask LOG_FILE "Log file path" "/var/log/mysql-backup-service.log"
echo ""

# ── Write .env ───────────────────────────────────────────────
cat > "$ENV_FILE" <<EOF
# ============================================================
# MySQL Backup Service — Configuration
# Generated on $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# --- MySQL Connection ---
MYSQL_HOST=${MYSQL_HOST}
MYSQL_PORT=${MYSQL_PORT}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_DATABASES=${MYSQL_DATABASES}

# --- Backup Naming ---
# Placeholders: {db} {date} {time} {timestamp} {hostname}
BACKUP_NAME_PATTERN=${BACKUP_NAME_PATTERN}

# --- S3 Storage ---
S3_BUCKET=${S3_BUCKET}
S3_PATH=${S3_PATH}
S3_ENDPOINT=${S3_ENDPOINT}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}

# --- Schedule ---
BACKUP_INTERVAL_HOURS=${BACKUP_INTERVAL_HOURS}

# --- Retention ---
BACKUP_RETENTION_COUNT=${BACKUP_RETENTION_COUNT}

# --- Notifications ---
NOTIFY_WEBHOOK_URL=${NOTIFY_WEBHOOK_URL}
NOTIFY_TYPE=${NOTIFY_TYPE}

# --- Logging ---
LOG_FILE=${LOG_FILE}
EOF

chmod 600 "$ENV_FILE"

echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        .env generated successfully!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Saved to: ${CYAN}${ENV_FILE}${NC}"
echo -e "  Next step: ${CYAN}sudo bash install.sh${NC}"
echo ""