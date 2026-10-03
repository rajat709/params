########### execute this command manually to install the certificates ############
# apt-get update && apt-get install --reinstall -y ca-certificates curl && update-ca-certificates

#!/bin/bash
set -Eeuo pipefail

# ============================================================
# DATAOORTS PostgreSQL FULL BACKUP
# Retention: 7 x 24 hours
# ============================================================

# ------------------------------------------------------------
# PostgreSQL configuration
# ------------------------------------------------------------
PGHOST="127.0.0.1"
PGPORT="5432"
PGDATABASE="dataoorts"
PGUSER="dataoorts"

# ------------------------------------------------------------
# Tigris configuration
# ------------------------------------------------------------
TIGRIS_BUCKET="dataoorts-backup"
TIGRIS_PREFIX="postgresql"

TIGRIS_ENDPOINT="https://t3.storage.dev"
TIGRIS_REGION="auto"
TIGRIS_SERVICE="s3"

# ------------------------------------------------------------
# Persistent backup directory
# ------------------------------------------------------------
BACKUP_DIR="/var/lib/postgresql/backups"

# 7 days exactly = 10080 minutes
RETENTION_MINUTES=10080

# ------------------------------------------------------------
# Required secrets
# ------------------------------------------------------------
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
: "${TIGRIS_ACCESS_KEY_ID:?TIGRIS_ACCESS_KEY_ID is not set}"
: "${TIGRIS_SECRET_ACCESS_KEY:?TIGRIS_SECRET_ACCESS_KEY is not set}"

# ------------------------------------------------------------
# Timestamp UTC is used deliberately so local and Tigris retention behave consistently
# ------------------------------------------------------------
TIMESTAMP="$(date -u '+%Y-%m-%d_%H-%M-%S')"

BACKUP_NAME="dataoorts_${TIMESTAMP}.dump"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Virtual-hosted-style Tigris URL
# Tigris uses virtual-hosted-style addressing by default
TIGRIS_HOST="${TIGRIS_BUCKET}.t3.storage.dev"
TIGRIS_OBJECT_URL="https://${TIGRIS_HOST}/${TIGRIS_PREFIX}/${BACKUP_NAME}"

# ------------------------------------------------------------
# Lock Prevent two job runs at the same time
# ------------------------------------------------------------
LOCK_DIR="/var/run/dataoorts-backup.lock"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another backup is already running."
    exit 0
fi

cleanup_lock() {
    rm -rf "$LOCK_DIR"
}

trap cleanup_lock EXIT

echo
echo "============================================================"
echo " DATAOORTS POSTGRESQL BACKUP"
echo "============================================================"
echo "Started   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Database  : ${PGDATABASE}"
echo "Backup    : ${BACKUP_NAME}"
echo "Local     : ${BACKUP_PATH}"
echo "Tigris    : ${TIGRIS_OBJECT_URL}"
echo "Retention : 7 days"
echo "============================================================"
echo

# ------------------------------------------------------------
# 1. Check / create persistent backup directory
# ------------------------------------------------------------
echo "[1/7] Checking persistent backup storage..."

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Ensure backup directory and PostgreSQL data are on the same
# Fly persistent volume.
PG_VOLUME_DEVICE="$(
    df -P /var/lib/postgresql/18/docker |
    awk 'NR==2 {print $1}'
)"

BACKUP_VOLUME_DEVICE="$(
    df -P "$BACKUP_DIR" |
    awk 'NR==2 {print $1}'
)"

if [[ "$PG_VOLUME_DEVICE" != "$BACKUP_VOLUME_DEVICE" ]]; then
    echo "ERROR: Backup directory is not on the PostgreSQL volume."
    echo "PostgreSQL volume: $PG_VOLUME_DEVICE"
    echo "Backup volume    : $BACKUP_VOLUME_DEVICE"
    exit 1
fi

echo "Persistent storage: OK"
echo

# ------------------------------------------------------------
# 2. Check curl + SigV4 support
# ------------------------------------------------------------
echo "[2/7] Checking HTTP client..."

if ! command -v curl >/dev/null 2>&1; then

    echo "curl not found."
    echo "Installing curl..."

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl
    rm -rf /var/lib/apt/lists/

fi

if ! curl --help all 2>/dev/null | grep -q -- '--aws-sigv4'; then
    echo "ERROR: Installed curl does not support --aws-sigv4."
    echo "Need curl >= 7.75."
    exit 1
fi

echo "curl with AWS SigV4 support: OK"
echo

# ------------------------------------------------------------
# 3. PostgreSQL connection test
# ------------------------------------------------------------
echo "[3/7] Testing PostgreSQL connection..."

PGPASSWORD="$POSTGRES_PASSWORD" psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d "$PGDATABASE" \
    -v ON_ERROR_STOP=1 \
    -c "
        SELECT
            current_database() AS database,
            current_user AS user,
            pg_size_pretty(
                pg_database_size(current_database())
            ) AS database_size;
    "

echo
echo "PostgreSQL connection: OK"
echo

# ------------------------------------------------------------
# 4. FULL PostgreSQL dump
# ------------------------------------------------------------
echo "[4/7] Creating FULL PostgreSQL backup..."

rm -f "$BACKUP_PATH"

PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d "$PGDATABASE" \
    --format=custom \
    --compress=9 \
    --no-owner \
    --no-acl \
    --blobs \
    --verbose \
    --file="$BACKUP_PATH"

if [[ ! -s "$BACKUP_PATH" ]]; then
    echo "ERROR: Backup file was not created correctly."
    exit 1
fi

echo
echo "Backup created:"
ls -lh "$BACKUP_PATH"
echo

# ------------------------------------------------------------
# Validate archive before uploading
# ------------------------------------------------------------
echo "Validating PostgreSQL backup archive..."

pg_restore \
    --list \
    "$BACKUP_PATH" >/dev/null

echo "Archive validation: OK"
echo

# ------------------------------------------------------------
# Calculate SHA-256
# ------------------------------------------------------------
SHA256="$(
    sha256sum "$BACKUP_PATH" |
    awk '{print $1}'
)"

FILE_SIZE="$(
    stat -c '%s' "$BACKUP_PATH"
)"

echo "Backup size : ${FILE_SIZE} bytes"
echo "SHA-256     : ${SHA256}"
echo

# ------------------------------------------------------------
# 5. Upload to Tigris REST/S3 API
# ------------------------------------------------------------
echo "[5/7] Uploading backup to Tigris..."

curl \
    --fail-with-body \
    --silent \
    --show-error \
    --retry 5 \
    --retry-delay 5 \
    --retry-all-errors \
    --aws-sigv4 "aws:amz:auto:s3" \
    --user "${TIGRIS_ACCESS_KEY_ID}:${TIGRIS_SECRET_ACCESS_KEY}" \
    --request PUT \
    --header "Content-Type: application/octet-stream" \
    --header "x-amz-meta-sha256: ${SHA256}" \
    --upload-file "$BACKUP_PATH" \
    "$TIGRIS_OBJECT_URL"

echo
echo "Tigris upload: OK"
echo

# ------------------------------------------------------------
# Verify uploaded object with HEAD request
# ------------------------------------------------------------
echo "Verifying Tigris backup..."

HEADERS_FILE="/tmp/dataoorts_tigris_head.txt"

rm -f "$HEADERS_FILE"

HTTP_CODE="$(
    curl \
        --silent \
        --show-error \
        --retry 5 \
        --retry-delay 3 \
        --retry-all-errors \
        --aws-sigv4 "aws:amz:auto:s3" \
        --user "${TIGRIS_ACCESS_KEY_ID}:${TIGRIS_SECRET_ACCESS_KEY}" \
        --head \
        --dump-header "$HEADERS_FILE" \
        --output /dev/null \
        --write-out '%{http_code}' \
        "$TIGRIS_OBJECT_URL"
)"

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "ERROR: Tigris HEAD verification failed."
    echo "HTTP status: $HTTP_CODE"
    cat "$HEADERS_FILE"
    rm -f "$HEADERS_FILE"
    exit 1
fi

REMOTE_SIZE="$(
    awk 'BEGIN{IGNORECASE=1}
         /^Content-Length:/ {
             gsub("\r","",$2);
             print $2
         }' "$HEADERS_FILE"
)"

REMOTE_SHA256="$(
    awk 'BEGIN{IGNORECASE=1}
         /^x-amz-meta-sha256:/ {
             gsub("\r","",$2);
             print $2
         }' "$HEADERS_FILE"
)"

rm -f "$HEADERS_FILE"

if [[ "$REMOTE_SIZE" != "$FILE_SIZE" ]]; then
    echo "ERROR: Tigris size mismatch."
    echo "Local : $FILE_SIZE"
    echo "Remote: $REMOTE_SIZE"
    exit 1
fi

if [[ -n "$REMOTE_SHA256" && "$REMOTE_SHA256" != "$SHA256" ]]; then
    echo "ERROR: Tigris SHA-256 mismatch."
    echo "Local : $SHA256"
    echo "Remote: $REMOTE_SHA256"
    exit 1
fi

echo "Tigris object: VERIFIED"
echo "Size         : ${REMOTE_SIZE} bytes"

if [[ -n "$REMOTE_SHA256" ]]; then
    echo "SHA-256      : VERIFIED"
else
    echo "SHA-256      : metadata not returned; size verified."
fi

echo

# ------------------------------------------------------------
# 6. Delete local backups older than 7 days
# ------------------------------------------------------------
echo "[6/7] Removing local backups older than 7 days..."

while IFS= read -r -d '' OLD_FILE; do

    # Never delete the current backup.
    if [[ "$OLD_FILE" == "$BACKUP_PATH" ]]; then
        continue
    fi

    echo "Deleting:"
    echo "  $OLD_FILE"

    rm -f -- "$OLD_FILE"

done < <(
    find "$BACKUP_DIR" \
        -type f \
        -name 'dataoorts_*.dump' \
        -mmin +"$RETENTION_MINUTES" \
        -print0
)

echo "Local retention cleanup: OK"
echo

# ------------------------------------------------------------
# 7. Delete Tigris backups older than 7 days
# ------------------------------------------------------------
echo "[7/7] Removing Tigris backups older than 7 days..."

LIST_FILE="/tmp/dataoorts_tigris_list.xml"

rm -f "$LIST_FILE"

curl \
    --fail-with-body \
    --silent \
    --show-error \
    --retry 5 \
    --retry-delay 3 \
    --retry-all-errors \
    --aws-sigv4 "aws:amz:auto:s3" \
    --user "${TIGRIS_ACCESS_KEY_ID}:${TIGRIS_SECRET_ACCESS_KEY}" \
    --request GET \
    --get \
    --data-urlencode "list-type=2" \
    --data-urlencode "prefix=${TIGRIS_PREFIX}/" \
    --output "$LIST_FILE" \
    "https://${TIGRIS_HOST}/"

CUTOFF_EPOCH="$(
    date -u -d '7 days ago' '+%s'
)"

# We deliberately use the timestamp embedded in our own backup
# filename. That makes retention independent of Tigris's
# LastModified formatting/time zone.
grep -oP '(?<=<Key>)[^<]+' "$LIST_FILE" |
while IFS= read -r OBJECT_KEY; do

    # Only process our backup files.
    if [[ ! "$OBJECT_KEY" =~ ^${TIGRIS_PREFIX}/dataoorts_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.dump$ ]]; then
        continue
    fi

    FILE_NAME="${OBJECT_KEY##*/}"

    TIMESTAMP_PART="${FILE_NAME#dataoorts_}"
    TIMESTAMP_PART="${TIMESTAMP_PART%.dump}"

    # Convert:
    # 2026-10-03_12-30-00
    # to:
    # 2026-10-03 12:30:00
    DATE_PART="${TIMESTAMP_PART%_*}"
    TIME_PART="${TIMESTAMP_PART#*_}"

    OBJECT_EPOCH="$(
        date -u -d \
            "${DATE_PART} ${TIME_PART//-/:}" \
            '+%s' 2>/dev/null || echo 0
    )"

    if [[ "$OBJECT_EPOCH" -eq 0 ]]; then
        echo "Skipping object with invalid timestamp:"
        echo "  $OBJECT_KEY"
        continue
    fi

    # Current backup should never be deleted.
    if [[ "$OBJECT_KEY" == "${S3_KEY:-}" ]]; then
        continue
    fi

    if (( OBJECT_EPOCH < CUTOFF_EPOCH )); then

        # URL encode only the object key by using curl's --path-as-is with the known safe backup filename
        DELETE_URL="https://${TIGRIS_HOST}/${OBJECT_KEY}"

        echo "Deleting old Tigris backup:"
        echo "  $OBJECT_KEY"

        curl \
            --fail-with-body \
            --silent \
            --show-error \
            --retry 5 \
            --retry-delay 3 \
            --retry-all-errors \
            --aws-sigv4 "aws:amz:auto:s3" \
            --user "${TIGRIS_ACCESS_KEY_ID}:${TIGRIS_SECRET_ACCESS_KEY}" \
            --request DELETE \
            --output /dev/null \
            "$DELETE_URL"

        echo "  Deleted."
    fi

done

rm -f "$LIST_FILE"

echo "Tigris retention cleanup: OK"
echo

# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------
echo "============================================================"
echo " BACKUP SUCCESS"
echo "============================================================"
echo
echo "Backup file:"
echo "  ${BACKUP_PATH}"
echo
echo "Tigris object:"
echo "  ${TIGRIS_OBJECT_URL}"
echo
echo "SHA-256:"
echo "  ${SHA256}"
echo
echo "Retention:"
echo "  7 days"
echo
echo "Finished:"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
echo
