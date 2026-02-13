#!/usr/bin/env bash
# ============================================================
# mysql-backup.sh — Dump, compress, upload to S3, enforce retention
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Load config ──────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    echo "[FATAL] .env file not found at $ENV_FILE" >&2
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

LOG_FILE="${LOG_FILE:-/var/log/mysql-backup-service.log}"
LOCK_FILE="/tmp/mysql-backup-service.lock"

# ── Helpers ──────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

notify_failure() {
    local message="$1"
    [[ -z "${NOTIFY_WEBHOOK_URL:-}" ]] && return 0

    local payload
    if [[ "${NOTIFY_TYPE:-slack}" == "discord" ]]; then
        payload=$(printf '{"content":"%s"}' "$message")
    else
        payload=$(printf '{"text":"%s"}' "$message")
    fi

    curl -sf -X POST -H 'Content-Type: application/json' \
        -d "$payload" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || true
}

TMP_DIR=""
cleanup() {
    rm -f "$LOCK_FILE"
    [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Locking (prevent overlapping runs) ───────────────────────
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log "WARN" "Another backup is still running (PID $LOCK_PID). Skipping."
        exit 0
    fi
    log "WARN" "Stale lock file found. Removing."
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# ── Pre-flight checks ───────────────────────────────────────
for cmd in mysqldump gzip aws; do
    if ! command -v "$cmd" &>/dev/null; then
        log "FATAL" "'$cmd' not found. Run install.sh first."
        notify_failure "MySQL Backup FAILED on $(hostname): '$cmd' not installed."
        exit 1
    fi
done

# ── Resolve database list ───────────────────────────────────
if [[ "${MYSQL_DATABASES}" == "ALL" ]]; then
    DATABASES=$(mysql \
        --host="$MYSQL_HOST" \
        --port="$MYSQL_PORT" \
        --user="$MYSQL_USER" \
        --password="$MYSQL_PASSWORD" \
        --batch --skip-column-names \
        -e "SHOW DATABASES;" 2>/dev/null \
        | grep -Ev '^(information_schema|performance_schema|sys|mysql)$')
else
    IFS=',' read -ra DATABASES <<< "$MYSQL_DATABASES"
fi

if [[ -z "${DATABASES[*]:-}" ]]; then
    log "FATAL" "No databases found to back up."
    notify_failure "MySQL Backup FAILED on $(hostname): no databases found."
    exit 1
fi

# ── Configure S3 endpoint ───────────────────────────────────
S3_ENDPOINT_FLAG=""
if [[ -n "${S3_ENDPOINT:-}" && "$S3_ENDPOINT" != "https://s3.amazonaws.com" ]]; then
    S3_ENDPOINT_FLAG="--endpoint-url=$S3_ENDPOINT"
fi

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION

# ── Build filename from pattern ──────────────────────────────
resolve_name() {
    local db="$1"
    local pattern="${BACKUP_NAME_PATTERN}"
    pattern="${pattern//\{db\}/$db}"
    pattern="${pattern//\{date\}/$(date '+%Y-%m-%d')}"
    pattern="${pattern//\{time\}/$(date '+%H-%M-%S')}"
    pattern="${pattern//\{timestamp\}/$(date '+%s')}"
    pattern="${pattern//\{hostname\}/$(hostname -s)}"
    echo "${pattern}.sql.gz"
}

# ── Temporary work directory ─────────────────────────────────
TMP_DIR=$(mktemp -d /tmp/mysql-backup.XXXXXX)

# ── Backup loop ──────────────────────────────────────────────
TOTAL=0
FAILED=0

for db in $DATABASES; do
    db=$(echo "$db" | xargs)   # trim whitespace
    [[ -z "$db" ]] && continue

    FILENAME=$(resolve_name "$db")
    LOCAL_PATH="${TMP_DIR}/${FILENAME}"
    S3_KEY="${S3_PATH}/${db}/${FILENAME}"

    log "INFO" "Backing up database: $db → s3://${S3_BUCKET}/${S3_KEY}"
    TOTAL=$((TOTAL + 1))

    # Dump + compress
    GTID_FLAG=""
    if mysqldump --help 2>&1 | grep -q 'set-gtid-purged'; then
        GTID_FLAG="--set-gtid-purged=OFF"
    fi

    if ! mysqldump \
        --host="$MYSQL_HOST" \
        --port="$MYSQL_PORT" \
        --user="$MYSQL_USER" \
        --password="$MYSQL_PASSWORD" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        $GTID_FLAG \
        "$db" 2>>"$LOG_FILE" | gzip > "$LOCAL_PATH"; then

        log "ERROR" "mysqldump failed for $db"
        FAILED=$((FAILED + 1))
        rm -f "$LOCAL_PATH"
        continue
    fi

    SIZE=$(du -h "$LOCAL_PATH" | cut -f1)
    log "INFO" "Dump complete: $FILENAME ($SIZE)"

    # Upload to S3
    if ! aws s3 cp "$LOCAL_PATH" "s3://${S3_BUCKET}/${S3_KEY}" \
        $S3_ENDPOINT_FLAG --only-show-errors 2>>"$LOG_FILE"; then
        log "ERROR" "S3 upload failed for $db"
        FAILED=$((FAILED + 1))
        rm -f "$LOCAL_PATH"
        continue
    fi

    log "INFO" "Uploaded to s3://${S3_BUCKET}/${S3_KEY}"
    rm -f "$LOCAL_PATH"

    # ── Retention: prune old backups ─────────────────────────
    RETENTION=${BACKUP_RETENTION_COUNT:-7}
    EXISTING=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/${db}/" \
        $S3_ENDPOINT_FLAG 2>/dev/null \
        | awk '{print $4}' \
        | grep '\.sql\.gz$' \
        | sort)

    COUNT=$(echo "$EXISTING" | grep -c '.' || true)

    if [[ "$COUNT" -gt "$RETENTION" ]]; then
        DELETE_COUNT=$((COUNT - RETENTION))
        TO_DELETE=$(echo "$EXISTING" | head -n "$DELETE_COUNT")

        for old_file in $TO_DELETE; do
            log "INFO" "Pruning old backup: $old_file"
            aws s3 rm "s3://${S3_BUCKET}/${S3_PATH}/${db}/${old_file}" \
                $S3_ENDPOINT_FLAG --only-show-errors 2>>"$LOG_FILE" || true
        done
        log "INFO" "Pruned $DELETE_COUNT old backup(s) for $db (keeping $RETENTION)"
    fi
done

# ── Summary ──────────────────────────────────────────────────
if [[ "$FAILED" -gt 0 ]]; then
    log "WARN" "Backup finished with errors: $((TOTAL - FAILED))/$TOTAL succeeded."
    notify_failure "MySQL Backup on $(hostname): $FAILED/$TOTAL databases FAILED. Check $LOG_FILE."
    exit 1
else
    log "INFO" "All backups completed successfully: $TOTAL/$TOTAL databases."
    exit 0
fi