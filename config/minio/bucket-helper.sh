#!/bin/sh

# ===================================================================
# MinIO Bucket Helper Script
# ===================================================================
# This script watches the buckets.conf file and creates buckets that
# do not already exist on the MinIO instance. It also sets the access
# policy for each bucket based on what is defined in the config file.
# ===================================================================

# Allow enviroment variables to override the default values.
BUCKETS_FILE="${BUCKETS_FILE:-/config/buckets.conf}"
BUCKETS_EXAMPLE_FILE="${BUCKETS_EXAMPLE_FILE:-/config/buckets.example.conf}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

should_stop=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

shutdown() {
    log "Received shutdown signal, stopping..."
    should_stop=1
}

# Set signal handlers for graceful shutdown.
trap shutdown TERM INT

# Initialize the buckets.conf file from the example if it doesn't exist.
init_buckets_file() {
    if [ ! -f "$BUCKETS_FILE" ]; then
        if [ -f "$BUCKETS_EXAMPLE_FILE" ]; then
            log "Creating $BUCKETS_FILE from example file..."
            cp "$BUCKETS_EXAMPLE_FILE" "$BUCKETS_FILE"
            log "Created buckets.conf from example file"
        else
          # Just in case the user removed the example file.
            log "Warning: Neither $BUCKETS_FILE nor $BUCKETS_EXAMPLE_FILE found"
        fi
    fi
}

# MinIO needs to be in a ready state before commands can be issued.
# Ensure that it is ready before we start processing everything.
wait_for_minio() {
    log "Waiting for MinIO to be ready at $MINIO_ENDPOINT..."
    max_attempts=30
    attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if mc alias set local "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; then
            log "MinIO is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        log "MinIO not ready yet, attempt $attempt/$max_attempts..."
        sleep 2
    done

    log "Error: MinIO did not become ready during the specified timeframe"

    return 1
}

create_bucket() {
    bucket_name="$1"
    access_policy="${2:-private}"

    # Validate bucket name using MinIO's rules.
    case "$bucket_name" in
        ''|*[!a-z0-9.-]*)
            log "Error: Invalid bucket name: $bucket_name (must be lowercase alphanumeric, dots, or hyphens)"

            return 1
            ;;
    esac

    # Check if bucket already exists.
    if mc ls "local/$bucket_name" >/dev/null 2>&1; then
        log "Bucket already exists: $bucket_name"

        return 0
    fi

    # Create the bucket.
    log "Creating bucket: $bucket_name"
    if ! mc mb "local/$bucket_name" --ignore-existing 2>&1; then
        log "ERROR: Failed to create bucket: $bucket_name"
        return 1
    fi

    # Set the access policy on the bucket.
    case "$access_policy" in
        public)
            log "Setting public access policy for: $bucket_name"
            mc anonymous set public "local/$bucket_name"
            ;;
        download)
            log "Setting download access policy for: $bucket_name"
            mc anonymous set download "local/$bucket_name"
            ;;
        private|*)
            # Private is the default, we don't need to do anything here.
            log "Bucket $bucket_name is private (default)"
            ;;
    esac

    log "Successfully created bucket: $bucket_name with policy: $access_policy"
}

process_buckets() {
    if [ ! -f "$BUCKETS_FILE" ]; then
        log "Buckets file not found: $BUCKETS_FILE"

        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        case "$line" in
            ''|\#*) continue ;;
        esac

        # Trim only the leading and trailing whitespace.
        # Parameter expantion is used due to issues with
        # the available tooling wihin the container.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        if [ -n "$line" ]; then
            # Parse the bucket name and optional policy.
            # Use the default private policy if undefined.
            set -- $line
            bucket_name="$1"
            access_policy="${2:-private}"

            create_bucket "$bucket_name" "$access_policy"
        fi
    done < "$BUCKETS_FILE"
}

display_config() {
    log "Configuration:"
    log "  BUCKETS_FILE: $BUCKETS_FILE"
    log "  MINIO_ENDPOINT: $MINIO_ENDPOINT"
    log "  MINIO_ROOT_USER: $MINIO_ROOT_USER"
    log "  CHECK_INTERVAL: ${CHECK_INTERVAL}s"
}

# Initialize the script.
# ----------------------
# We want to create the buckets file from the example if it doesn't exist.
# Then we want to showcase what the config setup looks like on stdout.
# Finally, wait for the MinIO server to start so that we can issue commands.
init_buckets_file
display_config

if ! wait_for_minio; then
    log "Exiting due to MinIO unavailability"
    exit 1
fi

process_buckets

last_checksum=""

log "Watching for changes to $BUCKETS_FILE..."

while [ "$should_stop" -eq 0 ]; do
    if [ -f "$BUCKETS_FILE" ]; then
        current_checksum=$(md5sum "$BUCKETS_FILE" 2>/dev/null | cut -d' ' -f1)

        if [ "$current_checksum" != "$last_checksum" ]; then
            log "Buckets file changed, processing..."
            process_buckets
            last_checksum="$current_checksum"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done

log "MinIO Bucket Helper stopped"