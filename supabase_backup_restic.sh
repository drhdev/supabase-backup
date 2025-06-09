#!/bin/bash
set -euo pipefail

# === Configuration ===
SCRIPT_DIR="/opt/supabase-backups"
LOCK_FILE="$SCRIPT_DIR/backup.lock"
LOG_FILE="$SCRIPT_DIR/backup.log"
ENV_FILE="$SCRIPT_DIR/restic.env"

# === Error Handling ===
handle_error() {
    local line_no=$1
    local error_code=$2
    echo "Error occurred in line $line_no (exit code: $error_code)" >> "$LOG_FILE"
    cleanup
    exit "$error_code"
}

trap 'handle_error ${LINENO} $?' ERR

# === Lock File Management ===
if [ -f "$LOCK_FILE" ]; then
    echo "Another backup is already running. Lock file: $LOCK_FILE" | tee -a "$LOG_FILE"
    exit 1
fi

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit' EXIT

# === Environment Validation ===
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Environment file not found: $ENV_FILE" | tee -a "$LOG_FILE"
    exit 1
fi

source "$ENV_FILE"

# Validate required environment variables
if [ -z "${RESTIC_REPOSITORY:-}" ]; then
    echo "Error: RESTIC_REPOSITORY not set" | tee -a "$LOG_FILE"
    exit 1
fi

if [ -z "${RESTIC_PASSWORD:-}" ]; then
    echo "Error: RESTIC_PASSWORD not set" | tee -a "$LOG_FILE"
    exit 1
fi

# === Storage Provider Validation ===
if [[ "$RESTIC_REPOSITORY" == *"hetzner.com"* ]]; then
    if [ -z "${RESTIC_S3_SSE_C_KEY:-}" ]; then
        echo "Error: RESTIC_S3_SSE_C_KEY is required for Hetzner Object Storage" | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Using Hetzner Object Storage with SSE-C encryption" | tee -a "$LOG_FILE"
elif [[ "$RESTIC_REPOSITORY" == *"digitaloceanspaces.com"* ]]; then
    echo "Using DigitalOcean Spaces with default encryption" | tee -a "$LOG_FILE"
elif [[ "$RESTIC_REPOSITORY" == *"amazonaws.com"* ]]; then
    echo "Using Amazon S3 with default encryption" | tee -a "$LOG_FILE"
else
    echo "Warning: Unknown storage provider, please verify configuration" | tee -a "$LOG_FILE"
fi

# === Disk Space Check ===
required_space=1073741824  # 1GB in bytes
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: df -k gives KB, so multiply by 1024
    available_space=$(df -k "$SCRIPT_DIR" | awk 'NR==2 {print $4 * 1024}')
else
    # Linux: df -B1 gives bytes
    available_space=$(df -B1 "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
fi
if [ "$available_space" -lt "$required_space" ]; then
    echo "Error: Insufficient disk space. Required: 1GB, Available: $((available_space/1024/1024))MB" | tee -a "$LOG_FILE"
    exit 1
fi

# === Setup ===
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
TEMP_DIR="/tmp/supabase-backup-$TIMESTAMP"
DB_CONTAINER="supabase-db"
CONFIG_DIR="/opt/supabase-automated-self-host"

# List of MinIO buckets to backup
MINIO_BUCKETS=("media" "public")  # Adjust according to your buckets
RCLONE_REMOTE="minio"             # Must be configured with rclone first

# Create temporary directory
mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"; rm -f "$LOCK_FILE"; exit' EXIT

# === Start Logging ===
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== [$TIMESTAMP] Starting Supabase Backup ==="

# === [1/5] PostgreSQL Dump ===
echo "[1/5] Creating PostgreSQL Dump..."
if ! docker ps | grep -q "$DB_CONTAINER"; then
    echo "Error: Database container not running" | tee -a "$LOG_FILE"
    exit 1
fi

if ! docker exec "$DB_CONTAINER" pg_dump -U postgres -F c -b -v -f "/var/lib/postgresql/data/db_$TIMESTAMP.backup" postgres; then
    echo "Error: Database dump failed" | tee -a "$LOG_FILE"
    exit 1
fi

if ! docker cp "$DB_CONTAINER:/var/lib/postgresql/data/db_$TIMESTAMP.backup" "$TEMP_DIR/"; then
    echo "Error: Failed to copy database dump" | tee -a "$LOG_FILE"
    exit 1
fi

# === [2/5] Backup Supabase Configuration ===
echo "[2/5] Backing up configuration..."
if [ ! -d "$CONFIG_DIR" ]; then
    echo "Error: Configuration directory not found" | tee -a "$LOG_FILE"
    exit 1
fi

if ! cp -r "$CONFIG_DIR"/{.env,authelia,caddy,docker-compose.yml} "$TEMP_DIR/config" 2>/dev/null; then
    echo "Error: Failed to copy configuration files" | tee -a "$LOG_FILE"
    exit 1
fi

# === [3/5] Backup MinIO Buckets ===
echo "[3/5] Backing up MinIO Buckets..."
for bucket in "${MINIO_BUCKETS[@]}"; do
    echo "  → Syncing bucket \"$bucket\"..."
    mkdir -p "$TEMP_DIR/buckets/$bucket"
    if ! rclone sync "$RCLONE_REMOTE:$bucket" "$TEMP_DIR/buckets/$bucket" --progress; then
        echo "Error: Failed to sync bucket $bucket" | tee -a "$LOG_FILE"
        exit 1
    fi
done

# === [4/5] Backup with restic ===
echo "[4/5] Uploading backup to storage (encrypted)..."
if [[ "$RESTIC_REPOSITORY" == *"hetzner.com"* ]]; then
    echo "  → Using SSE-C encryption for Hetzner Object Storage"
fi

if ! restic backup "$TEMP_DIR" --tag supabase; then
    echo "Error: Restic backup failed" | tee -a "$LOG_FILE"
    exit 1
fi

# === [5/5] Apply Retention Policy ===
echo "[5/5] Cleaning up old backups (restic forget)..."
if ! restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune; then
    echo "Error: Restic forget/prune failed" | tee -a "$LOG_FILE"
    exit 1
fi

# === Cleanup ===
rm -rf "$TEMP_DIR"
echo "✅ [$TIMESTAMP] Backup completed successfully." 