#!/bin/bash
# Backup and Restore utilities for Veriscope Docker deployment

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
mkdir -p "$BACKUP_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Operation logging
LOG_FILE="$BACKUP_DIR/backup-restore.log"

log_operation() {
    local operation="$1"
    local status="$2"
    local details="$3"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$status] $operation - $details" >> "$LOG_FILE"
}

# Helper function to check if a container is running
is_container_running() {
    local container_name="$1"

    if [ -z "$container_name" ]; then
        echo_error "is_container_running: No container name provided"
        return 1
    fi

    if docker-compose -f "$COMPOSE_FILE" ps "$container_name" 2>/dev/null | grep -q "Up"; then
        return 0
    else
        return 1
    fi
}

# Wait for PostgreSQL to be ready
wait_for_postgres_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for PostgreSQL to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "${POSTGRES_USER:-trustanchor}" >/dev/null 2>&1; then
            echo_info "PostgreSQL is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for PostgreSQL to be ready"
    return 1
}

# Wait for Redis to be ready
wait_for_redis_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for Redis to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if docker-compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping >/dev/null 2>&1; then
            echo_info "Redis is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for Redis to be ready"
    return 1
}

# Check available disk space
check_disk_space() {
    local required_mb=${1:-100}
    local available_mb=$(df -m "$BACKUP_DIR" | awk 'NR==2 {print $4}')

    if [ "$available_mb" -lt "$required_mb" ]; then
        echo_error "Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB"
        return 1
    fi

    echo_info "Disk space check passed: ${available_mb}MB available"
    return 0
}

# Validate backup directory is writable
validate_backup_directory() {
    if [ ! -d "$BACKUP_DIR" ]; then
        echo_error "Backup directory does not exist: $BACKUP_DIR"
        return 1
    fi

    if [ ! -w "$BACKUP_DIR" ]; then
        echo_error "Backup directory not writable: $BACKUP_DIR"
        return 1
    fi

    return 0
}

# Verify backup file integrity
verify_backup_file() {
    local backup_file="$1"
    local backup_type="$2"

    if [ ! -f "$backup_file" ]; then
        echo_error "Backup file not created: $backup_file"
        return 1
    fi

    if [ ! -s "$backup_file" ]; then
        echo_error "Backup file is empty: $backup_file"
        return 1
    fi

    # For gzipped files, verify integrity
    if [[ "$backup_file" == *.gz ]]; then
        if ! gunzip -t "$backup_file" 2>/dev/null; then
            echo_error "Backup file is corrupted: $backup_file"
            return 1
        fi
    fi

    local size=$(du -h "$backup_file" | cut -f1)
    echo_info "Backup verified: $backup_file ($size)"
    log_operation "${backup_type}_BACKUP" "SUCCESS" "$backup_file ($size)"
    return 0
}

# Validate backup file path is safe
validate_backup_path() {
    local file="$1"

    if [ -z "$file" ]; then
        echo_error "No backup file specified"
        return 1
    fi

    if [ ! -f "$file" ]; then
        echo_error "Backup file not found: $file"
        return 1
    fi

    # Get real paths for comparison
    local real_backup_dir="$(cd "$BACKUP_DIR" 2>/dev/null && pwd)" || {
        echo_error "Cannot access backup directory: $BACKUP_DIR"
        return 1
    }

    local file_dir="$(dirname "$file")"
    local real_file_dir="$(cd "$file_dir" 2>/dev/null && pwd)" || {
        echo_error "Cannot access file directory: $file_dir"
        return 1
    }

    # Allow files from backup directory or current directory
    if [[ "$real_file_dir" != "$real_backup_dir"* ]] && [[ "$real_file_dir" != "$PROJECT_ROOT"* ]]; then
        echo_warn "Backup file is outside the standard backup directory"
        echo_warn "File location: $real_file_dir"
        read -p "Continue anyway? (yes/no): " -r confirm
        if [ "$confirm" != "yes" ]; then
            echo_info "Operation cancelled"
            return 1
        fi
    fi

    return 0
}

# Load database credentials from .env
load_db_credentials() {
    if [ -f ".env" ]; then
        source .env
    fi

    POSTGRES_USER="${POSTGRES_USER:-trustanchor}"
    POSTGRES_DB="${POSTGRES_DB:-trustanchor}"
}

# Backup database
backup_database() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/postgres-$timestamp.sql"

    echo_info "Backing up PostgreSQL database..."

    # Load database credentials
    load_db_credentials

    # Validate prerequisites
    if ! validate_backup_directory; then
        log_operation "DATABASE_BACKUP" "FAILED" "Backup directory validation failed"
        return 1
    fi

    if ! check_disk_space 100; then
        log_operation "DATABASE_BACKUP" "FAILED" "Insufficient disk space"
        return 1
    fi

    # Check if postgres container is running
    if ! is_container_running "postgres"; then
        echo_error "PostgreSQL container is not running"
        echo_info "Start containers with: docker-compose -f $COMPOSE_FILE up -d"
        log_operation "DATABASE_BACKUP" "FAILED" "PostgreSQL container not running"
        return 1
    fi

    # Wait for PostgreSQL to be ready
    if ! wait_for_postgres_ready 30; then
        log_operation "DATABASE_BACKUP" "FAILED" "PostgreSQL not ready"
        return 1
    fi

    # Perform backup
    if ! docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "$backup_file" 2>/dev/null; then
        echo_error "Database backup failed"
        rm -f "$backup_file"
        log_operation "DATABASE_BACKUP" "FAILED" "pg_dump command failed"
        return 1
    fi

    # Verify backup file was created and is not empty
    if [ ! -s "$backup_file" ]; then
        echo_error "Backup file is empty or was not created"
        rm -f "$backup_file"
        log_operation "DATABASE_BACKUP" "FAILED" "Empty backup file"
        return 1
    fi

    echo_info "Database backed up to: $backup_file"

    # Compress backup
    if ! gzip "$backup_file"; then
        echo_error "Failed to compress backup file"
        log_operation "DATABASE_BACKUP" "PARTIAL" "$backup_file (uncompressed)"
        return 1
    fi

    # Verify compressed backup
    if ! verify_backup_file "$backup_file.gz" "DATABASE"; then
        return 1
    fi

    echo_info "Backup completed successfully: $backup_file.gz"
    return 0
}

# Restore database
restore_database() {
    local backup_file=$1

    echo_info "Restoring PostgreSQL database..."

    # Load database credentials
    load_db_credentials

    # Validate backup file path
    if ! validate_backup_path "$backup_file"; then
        log_operation "DATABASE_RESTORE" "FAILED" "Invalid backup file path"
        return 1
    fi

    # Verify backup file integrity before restore
    if [[ "$backup_file" == *.gz ]]; then
        echo_info "Verifying backup file integrity..."
        if ! gunzip -t "$backup_file" 2>/dev/null; then
            echo_error "Backup file is corrupted: $backup_file"
            log_operation "DATABASE_RESTORE" "FAILED" "Corrupted backup file: $backup_file"
            return 1
        fi
        echo_info "Backup file integrity verified"
    fi

    # Check if postgres container is running
    if ! is_container_running "postgres"; then
        echo_error "PostgreSQL container is not running"
        echo_info "Start containers with: docker-compose -f $COMPOSE_FILE up -d"
        log_operation "DATABASE_RESTORE" "FAILED" "PostgreSQL container not running"
        return 1
    fi

    # Wait for PostgreSQL to be ready
    if ! wait_for_postgres_ready 30; then
        log_operation "DATABASE_RESTORE" "FAILED" "PostgreSQL not ready"
        return 1
    fi

    # Confirm destructive operation
    echo ""
    echo_warn "⚠️  WARNING: This will OVERWRITE the current database!"
    echo_warn "Database: $POSTGRES_DB"
    echo_warn "Backup file: $backup_file"
    echo ""
    read -p "Are you absolutely sure? Type 'yes' to continue: " -r confirm
    if [ "$confirm" != "yes" ]; then
        echo_info "Restore cancelled"
        log_operation "DATABASE_RESTORE" "CANCELLED" "$backup_file"
        return 0
    fi

    echo_info "Restoring database from: $backup_file"

    # Handle gzipped files
    if [[ "$backup_file" == *.gz ]]; then
        if ! gunzip -c "$backup_file" | docker-compose -f "$COMPOSE_FILE" exec -T postgres psql -U "$POSTGRES_USER" "$POSTGRES_DB" 2>/dev/null; then
            echo_error "Database restore failed"
            log_operation "DATABASE_RESTORE" "FAILED" "$backup_file - psql command failed"
            return 1
        fi
    else
        if ! docker-compose -f "$COMPOSE_FILE" exec -T postgres psql -U "$POSTGRES_USER" "$POSTGRES_DB" < "$backup_file" 2>/dev/null; then
            echo_error "Database restore failed"
            log_operation "DATABASE_RESTORE" "FAILED" "$backup_file - psql command failed"
            return 1
        fi
    fi

    echo_info "Database restored successfully"
    log_operation "DATABASE_RESTORE" "SUCCESS" "$backup_file"
    return 0
}

# Backup Redis data
backup_redis() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/redis-$timestamp.rdb"

    echo_info "Backing up Redis data..."

    # Validate prerequisites
    if ! validate_backup_directory; then
        log_operation "REDIS_BACKUP" "FAILED" "Backup directory validation failed"
        return 1
    fi

    if ! check_disk_space 50; then
        log_operation "REDIS_BACKUP" "FAILED" "Insufficient disk space"
        return 1
    fi

    # Check if redis container is running
    if ! is_container_running "redis"; then
        echo_error "Redis container is not running"
        echo_info "Start containers with: docker-compose -f $COMPOSE_FILE up -d"
        log_operation "REDIS_BACKUP" "FAILED" "Redis container not running"
        return 1
    fi

    # Wait for Redis to be ready
    if ! wait_for_redis_ready 30; then
        log_operation "REDIS_BACKUP" "FAILED" "Redis not ready"
        return 1
    fi

    # Trigger Redis SAVE
    echo_info "Triggering Redis SAVE..."
    if ! docker-compose -f "$COMPOSE_FILE" exec -T redis redis-cli SAVE >/dev/null 2>&1; then
        echo_error "Redis SAVE command failed"
        log_operation "REDIS_BACKUP" "FAILED" "SAVE command failed"
        return 1
    fi

    # Get redis container ID
    local redis_container=$(docker-compose -f "$COMPOSE_FILE" ps -q redis)
    if [ -z "$redis_container" ]; then
        echo_error "Redis container not found"
        log_operation "REDIS_BACKUP" "FAILED" "Container ID not found"
        return 1
    fi

    # Verify only one container
    if [ $(echo "$redis_container" | wc -l) -gt 1 ]; then
        echo_error "Multiple redis containers found"
        log_operation "REDIS_BACKUP" "FAILED" "Multiple containers found"
        return 1
    fi

    # Copy the dump.rdb file
    if ! docker cp "$redis_container:/data/dump.rdb" "$backup_file" 2>/dev/null; then
        echo_error "Failed to copy Redis dump file"
        log_operation "REDIS_BACKUP" "FAILED" "docker cp failed"
        return 1
    fi

    # Verify backup file was created
    if [ ! -s "$backup_file" ]; then
        echo_error "Backup file is empty or was not created"
        rm -f "$backup_file"
        log_operation "REDIS_BACKUP" "FAILED" "Empty backup file"
        return 1
    fi

    echo_info "Redis backed up to: $backup_file"

    # Compress backup
    if ! gzip "$backup_file"; then
        echo_error "Failed to compress backup file"
        log_operation "REDIS_BACKUP" "PARTIAL" "$backup_file (uncompressed)"
        return 1
    fi

    # Verify compressed backup
    if ! verify_backup_file "$backup_file.gz" "REDIS"; then
        return 1
    fi

    echo_info "Backup completed successfully: $backup_file.gz"
    return 0
}

# Backup application files
backup_app_files() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/app-files-$timestamp.tar.gz"

    echo_info "Backing up application files..."

    # Validate prerequisites
    if ! validate_backup_directory; then
        log_operation "APP_FILES_BACKUP" "FAILED" "Backup directory validation failed"
        return 1
    fi

    if ! check_disk_space 50; then
        log_operation "APP_FILES_BACKUP" "FAILED" "Insufficient disk space"
        return 1
    fi

    # Check which .env files exist
    local env_files=()
    [ -f ".env" ] && env_files+=(".env")
    [ -f "veriscope_ta_dashboard/.env" ] && env_files+=("veriscope_ta_dashboard/.env")
    [ -f "veriscope_ta_node/.env" ] && env_files+=("veriscope_ta_node/.env")

    if [ ${#env_files[@]} -eq 0 ]; then
        echo_warn "No .env files found to backup"
        log_operation "APP_FILES_BACKUP" "SKIPPED" "No .env files found"
        return 0
    fi

    echo_info "Backing up ${#env_files[@]} .env file(s)..."

    # Create backup
    if ! tar -czf "$backup_file" \
        --exclude='veriscope_ta_dashboard/node_modules' \
        --exclude='veriscope_ta_dashboard/vendor' \
        --exclude='veriscope_ta_node/node_modules' \
        "${env_files[@]}" 2>/dev/null; then
        echo_error "Application files backup failed"
        rm -f "$backup_file"
        log_operation "APP_FILES_BACKUP" "FAILED" "tar command failed"
        return 1
    fi

    # Verify backup file was created
    if [ ! -s "$backup_file" ]; then
        echo_error "Backup file is empty or was not created"
        rm -f "$backup_file"
        log_operation "APP_FILES_BACKUP" "FAILED" "Empty backup file"
        return 1
    fi

    # Verify compressed backup (tar.gz is already compressed, just check integrity)
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        echo_error "Backup file is corrupted"
        rm -f "$backup_file"
        log_operation "APP_FILES_BACKUP" "FAILED" "Corrupted tar.gz file"
        return 1
    fi

    local size=$(du -h "$backup_file" | cut -f1)
    echo_info "Application files backed up to: $backup_file ($size)"
    log_operation "APP_FILES_BACKUP" "SUCCESS" "$backup_file ($size)"
    return 0
}

# Full backup
full_backup() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local failed=0
    local failed_operations=()

    echo_info "========================================="
    echo_info "  Starting Full Backup"
    echo_info "========================================="
    echo ""

    # Backup database
    echo_info "Step 1/3: Backing up PostgreSQL database..."
    if ! backup_database; then
        echo_error "Database backup failed"
        failed=1
        failed_operations+=("DATABASE")
    fi
    echo ""

    # Backup Redis
    echo_info "Step 2/3: Backing up Redis data..."
    if ! backup_redis; then
        echo_error "Redis backup failed"
        failed=1
        failed_operations+=("REDIS")
    fi
    echo ""

    # Backup app files
    echo_info "Step 3/3: Backing up application files..."
    if ! backup_app_files; then
        echo_error "Application files backup failed"
        failed=1
        failed_operations+=("APP_FILES")
    fi
    echo ""

    # Summary
    echo_info "========================================="
    if [ $failed -eq 0 ]; then
        echo_info "✅ Full backup completed successfully!"
        echo_info "Backup location: $BACKUP_DIR"
        log_operation "FULL_BACKUP" "SUCCESS" "All components backed up to $BACKUP_DIR"
        return 0
    else
        echo_error "⚠️  Full backup completed with errors"
        echo_error "Failed operations: ${failed_operations[*]}"
        echo_info "Backup location: $BACKUP_DIR"
        log_operation "FULL_BACKUP" "PARTIAL" "Failed: ${failed_operations[*]}"
        return 1
    fi
}

# List backups
list_backups() {
    echo_info "Available backups in $BACKUP_DIR:"
    echo ""

    if [ ! -d "$BACKUP_DIR" ]; then
        echo_warn "Backup directory does not exist: $BACKUP_DIR"
        return 1
    fi

    # Count backups by type
    local db_count=$(find "$BACKUP_DIR" -name "postgres-*.sql.gz" -type f 2>/dev/null | wc -l)
    local redis_count=$(find "$BACKUP_DIR" -name "redis-*.rdb.gz" -type f 2>/dev/null | wc -l)
    local app_count=$(find "$BACKUP_DIR" -name "app-files-*.tar.gz" -type f 2>/dev/null | wc -l)

    echo "Database backups: $db_count"
    echo "Redis backups: $redis_count"
    echo "App files backups: $app_count"
    echo ""

    # List all backups with details
    find "$BACKUP_DIR" -type f \( -name "postgres-*.sql.gz" -o -name "redis-*.rdb.gz" -o -name "app-files-*.tar.gz" \) \
        -exec ls -lh {} \; 2>/dev/null | \
        awk '{printf "%-50s %10s %s %s\n", $9, $5, $6, $7}' | \
        sort -r

    if [ $db_count -eq 0 ] && [ $redis_count -eq 0 ] && [ $app_count -eq 0 ]; then
        echo_warn "No backups found"
        return 0
    fi
}

# Clean old backups
clean_old_backups() {
    local days=${1:-30}

    if [ ! -d "$BACKUP_DIR" ]; then
        echo_error "Backup directory does not exist: $BACKUP_DIR"
        return 1
    fi

    echo_info "Finding backups older than $days days..."
    echo ""

    # Find files to delete
    local db_files=$(find "$BACKUP_DIR" -name "postgres-*.sql.gz" -type f -mtime +$days 2>/dev/null)
    local redis_files=$(find "$BACKUP_DIR" -name "redis-*.rdb.gz" -type f -mtime +$days 2>/dev/null)
    local app_files=$(find "$BACKUP_DIR" -name "app-files-*.tar.gz" -type f -mtime +$days 2>/dev/null)

    local db_count=$(echo "$db_files" | grep -c "postgres-" || echo "0")
    local redis_count=$(echo "$redis_files" | grep -c "redis-" || echo "0")
    local app_count=$(echo "$app_files" | grep -c "app-files-" || echo "0")
    local total_count=$((db_count + redis_count + app_count))

    if [ $total_count -eq 0 ]; then
        echo_info "No backups older than $days days found"
        return 0
    fi

    echo_warn "⚠️  The following backups will be DELETED:"
    echo ""
    echo "Database backups: $db_count"
    [ $db_count -gt 0 ] && echo "$db_files" | while read -r file; do
        [ -n "$file" ] && echo "  - $(basename "$file")"
    done
    echo ""
    echo "Redis backups: $redis_count"
    [ $redis_count -gt 0 ] && echo "$redis_files" | while read -r file; do
        [ -n "$file" ] && echo "  - $(basename "$file")"
    done
    echo ""
    echo "App files backups: $app_count"
    [ $app_count -gt 0 ] && echo "$app_files" | while read -r file; do
        [ -n "$file" ] && echo "  - $(basename "$file")"
    done
    echo ""
    echo_warn "Total files to delete: $total_count"
    echo ""

    read -p "Type 'DELETE' to confirm deletion: " -r confirm
    if [ "$confirm" != "DELETE" ]; then
        echo_info "Cleanup cancelled"
        log_operation "CLEANUP" "CANCELLED" "User cancelled deletion of $total_count file(s)"
        return 0
    fi

    echo_info "Deleting old backups..."
    local deleted=0
    local failed=0

    # Delete database backups
    if [ $db_count -gt 0 ]; then
        echo "$db_files" | while read -r file; do
            if [ -n "$file" ] && [ -f "$file" ]; then
                if rm -f "$file" 2>/dev/null; then
                    echo_info "Deleted: $(basename "$file")"
                    deleted=$((deleted + 1))
                else
                    echo_error "Failed to delete: $(basename "$file")"
                    failed=$((failed + 1))
                fi
            fi
        done
    fi

    # Delete Redis backups
    if [ $redis_count -gt 0 ]; then
        echo "$redis_files" | while read -r file; do
            if [ -n "$file" ] && [ -f "$file" ]; then
                if rm -f "$file" 2>/dev/null; then
                    echo_info "Deleted: $(basename "$file")"
                    deleted=$((deleted + 1))
                else
                    echo_error "Failed to delete: $(basename "$file")"
                    failed=$((failed + 1))
                fi
            fi
        done
    fi

    # Delete app files backups
    if [ $app_count -gt 0 ]; then
        echo "$app_files" | while read -r file; do
            if [ -n "$file" ] && [ -f "$file" ]; then
                if rm -f "$file" 2>/dev/null; then
                    echo_info "Deleted: $(basename "$file")"
                    deleted=$((deleted + 1))
                else
                    echo_error "Failed to delete: $(basename "$file")"
                    failed=$((failed + 1))
                fi
            fi
        done
    fi

    echo ""
    if [ $failed -eq 0 ]; then
        echo_info "✅ Cleanup completed: $total_count file(s) deleted"
        log_operation "CLEANUP" "SUCCESS" "Deleted $total_count file(s) older than $days days"
        return 0
    else
        echo_warn "⚠️  Cleanup completed with errors: $failed failed"
        log_operation "CLEANUP" "PARTIAL" "Deleted some files, $failed failed"
        return 1
    fi
}

# Restore Redis data
restore_redis() {
    local backup_file=$1

    echo_info "Restoring Redis data..."

    # Validate backup file path
    if ! validate_backup_path "$backup_file"; then
        log_operation "REDIS_RESTORE" "FAILED" "Invalid backup file path"
        return 1
    fi

    # Verify backup file integrity before restore
    if [[ "$backup_file" == *.gz ]]; then
        echo_info "Verifying backup file integrity..."
        if ! gunzip -t "$backup_file" 2>/dev/null; then
            echo_error "Backup file is corrupted: $backup_file"
            log_operation "REDIS_RESTORE" "FAILED" "Corrupted backup file: $backup_file"
            return 1
        fi
        echo_info "Backup file integrity verified"
    fi

    # Check if redis container is running
    if ! is_container_running "redis"; then
        echo_error "Redis container is not running"
        echo_info "Start containers with: docker-compose -f $COMPOSE_FILE up -d"
        log_operation "REDIS_RESTORE" "FAILED" "Redis container not running"
        return 1
    fi

    # Confirm destructive operation
    echo ""
    echo_warn "⚠️  WARNING: This will OVERWRITE the current Redis data!"
    echo_warn "Backup file: $backup_file"
    echo ""
    read -p "Are you absolutely sure? Type 'yes' to continue: " -r confirm
    if [ "$confirm" != "yes" ]; then
        echo_info "Restore cancelled"
        log_operation "REDIS_RESTORE" "CANCELLED" "$backup_file"
        return 0
    fi

    echo_info "Stopping Redis to restore data..."

    # Stop Redis container
    if ! docker-compose -f "$COMPOSE_FILE" stop redis 2>/dev/null; then
        echo_error "Failed to stop Redis container"
        log_operation "REDIS_RESTORE" "FAILED" "Could not stop Redis container"
        return 1
    fi

    # Get redis container ID
    local redis_container=$(docker-compose -f "$COMPOSE_FILE" ps -aq redis)
    if [ -z "$redis_container" ]; then
        echo_error "Redis container not found"
        log_operation "REDIS_RESTORE" "FAILED" "Container ID not found"
        return 1
    fi

    # Restore the dump.rdb file
    local temp_rdb="/tmp/restore_dump.rdb"

    # Decompress if needed
    if [[ "$backup_file" == *.gz ]]; then
        if ! gunzip -c "$backup_file" > "$temp_rdb" 2>/dev/null; then
            echo_error "Failed to decompress backup file"
            docker-compose -f "$COMPOSE_FILE" start redis 2>/dev/null
            rm -f "$temp_rdb"
            log_operation "REDIS_RESTORE" "FAILED" "Decompression failed"
            return 1
        fi
    else
        cp "$backup_file" "$temp_rdb"
    fi

    # Copy to container
    if ! docker cp "$temp_rdb" "$redis_container:/data/dump.rdb" 2>/dev/null; then
        echo_error "Failed to copy backup file to container"
        docker-compose -f "$COMPOSE_FILE" start redis 2>/dev/null
        rm -f "$temp_rdb"
        log_operation "REDIS_RESTORE" "FAILED" "docker cp failed"
        return 1
    fi

    rm -f "$temp_rdb"

    # Start Redis
    echo_info "Starting Redis with restored data..."
    if ! docker-compose -f "$COMPOSE_FILE" start redis 2>/dev/null; then
        echo_error "Failed to start Redis container"
        log_operation "REDIS_RESTORE" "FAILED" "Could not start Redis container"
        return 1
    fi

    # Wait for Redis to be ready
    if ! wait_for_redis_ready 30; then
        echo_error "Redis did not become ready after restore"
        log_operation "REDIS_RESTORE" "FAILED" "Redis not ready after restore"
        return 1
    fi

    echo_info "Redis data restored successfully"
    log_operation "REDIS_RESTORE" "SUCCESS" "$backup_file"
    return 0
}

# Restore application files
restore_app_files() {
    local backup_file=$1

    echo_info "Restoring application files..."

    # Validate backup file path
    if ! validate_backup_path "$backup_file"; then
        log_operation "APP_FILES_RESTORE" "FAILED" "Invalid backup file path"
        return 1
    fi

    # Verify backup file is a valid tar.gz
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        echo_error "Backup file is corrupted or not a valid tar.gz: $backup_file"
        log_operation "APP_FILES_RESTORE" "FAILED" "Invalid tar.gz file: $backup_file"
        return 1
    fi

    # Show what will be restored
    echo_info "Backup contains the following files:"
    tar -tzf "$backup_file" 2>/dev/null

    # Confirm destructive operation
    echo ""
    echo_warn "⚠️  WARNING: This will OVERWRITE existing .env files!"
    echo_warn "Backup file: $backup_file"
    echo ""
    read -p "Are you absolutely sure? Type 'yes' to continue: " -r confirm
    if [ "$confirm" != "yes" ]; then
        echo_info "Restore cancelled"
        log_operation "APP_FILES_RESTORE" "CANCELLED" "$backup_file"
        return 0
    fi

    # Create backup of current .env files before restoring
    local current_backup="$BACKUP_DIR/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
    echo_info "Creating backup of current .env files to: $current_backup"

    local current_env_files=()
    [ -f ".env" ] && current_env_files+=(".env")
    [ -f "veriscope_ta_dashboard/.env" ] && current_env_files+=("veriscope_ta_dashboard/.env")
    [ -f "veriscope_ta_node/.env" ] && current_env_files+=("veriscope_ta_node/.env")

    if [ ${#current_env_files[@]} -gt 0 ]; then
        if ! tar -czf "$current_backup" "${current_env_files[@]}" 2>/dev/null; then
            echo_warn "Warning: Could not create backup of current .env files"
        else
            echo_info "Current .env files backed up to: $current_backup"
        fi
    fi

    # Restore files
    echo_info "Restoring files from: $backup_file"
    if ! tar -xzf "$backup_file" 2>/dev/null; then
        echo_error "Failed to extract backup file"
        log_operation "APP_FILES_RESTORE" "FAILED" "tar extraction failed"
        return 1
    fi

    echo_info "Application files restored successfully"
    echo_warn "IMPORTANT: You may need to restart services for changes to take effect"
    echo_info "Run: docker-compose -f $COMPOSE_FILE restart"
    log_operation "APP_FILES_RESTORE" "SUCCESS" "$backup_file"
    return 0
}

# Menu
menu() {
    echo ""
    echo "================================"
    echo "Veriscope Backup & Restore"
    echo "================================"
    echo ""
    echo "Backup:"
    echo "  1) Backup database only"
    echo "  2) Backup Redis only"
    echo "  3) Backup app files (.env)"
    echo "  4) Full backup (all of the above)"
    echo ""
    echo "Restore:"
    echo "  5) Restore database"
    echo "  6) Restore Redis"
    echo "  7) Restore app files"
    echo ""
    echo "Maintenance:"
    echo "  8) List backups"
    echo "  9) Clean old backups"
    echo ""
    echo "  x) Exit"
    echo ""
    echo -n "Select an option: "
    read -r choice

    case $choice in
        1)
            backup_database
            ;;
        2)
            backup_redis
            ;;
        3)
            backup_app_files
            ;;
        4)
            full_backup
            ;;
        5)
            list_backups
            echo ""
            echo "Enter database backup file path:"
            read -r backup_file
            restore_database "$backup_file"
            ;;
        6)
            list_backups
            echo ""
            echo "Enter Redis backup file path:"
            read -r backup_file
            restore_redis "$backup_file"
            ;;
        7)
            list_backups
            echo ""
            echo "Enter app files backup path:"
            read -r backup_file
            restore_app_files "$backup_file"
            ;;
        8)
            list_backups
            ;;
        9)
            echo "Delete backups older than how many days? (default: 30)"
            read -r days
            clean_old_backups "${days:-30}"
            ;;
        x)
            echo_info "Exiting..."
            exit 0
            ;;
        *)
            echo_error "Invalid option"
            ;;
    esac

    echo ""
    echo "Press Enter to continue..."
    read -r
    menu
}

# Main
if [ $# -eq 0 ]; then
    menu
else
    case "$1" in
        backup-db)
            backup_database
            ;;
        backup-redis)
            backup_redis
            ;;
        backup-files)
            backup_app_files
            ;;
        backup-full)
            full_backup
            ;;
        restore-db)
            restore_database "$2"
            ;;
        restore-redis)
            restore_redis "$2"
            ;;
        restore-files)
            restore_app_files "$2"
            ;;
        list)
            list_backups
            ;;
        clean)
            clean_old_backups "$2"
            ;;
        *)
            echo "Usage: $0 {backup-db|backup-redis|backup-files|backup-full|restore-db|restore-redis|restore-files|list|clean [days]}"
            echo ""
            echo "Backup commands:"
            echo "  backup-db                  - Backup PostgreSQL database"
            echo "  backup-redis               - Backup Redis data"
            echo "  backup-files               - Backup application .env files"
            echo "  backup-full                - Full backup (all of the above)"
            echo ""
            echo "Restore commands:"
            echo "  restore-db <file>          - Restore PostgreSQL database from backup"
            echo "  restore-redis <file>       - Restore Redis data from backup"
            echo "  restore-files <file>       - Restore application files from backup"
            echo ""
            echo "Maintenance commands:"
            echo "  list                       - List all available backups"
            echo "  clean [days]               - Delete backups older than N days (default: 30)"
            exit 1
            ;;
    esac
fi
