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

# Backup database
backup_database() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/postgres-$timestamp.sql"

    echo_info "Backing up PostgreSQL database..."
    docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_dump -U trustanchor trustanchor > "$backup_file"

    if [ $? -eq 0 ]; then
        echo_info "Database backed up to: $backup_file"
        gzip "$backup_file"
        echo_info "Compressed to: $backup_file.gz"
    else
        echo_error "Database backup failed"
        return 1
    fi
}

# Restore database
restore_database() {
    local backup_file=$1

    if [ -z "$backup_file" ]; then
        echo_error "Please specify a backup file"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        echo_error "Backup file not found: $backup_file"
        return 1
    fi

    echo_warn "This will OVERWRITE the current database. Are you sure? (yes/no)"
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        echo_info "Restore cancelled"
        return 0
    fi

    echo_info "Restoring database from: $backup_file"

    # Handle gzipped files
    if [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" | docker-compose -f "$COMPOSE_FILE" exec -T postgres psql -U trustanchor trustanchor
    else
        docker-compose -f "$COMPOSE_FILE" exec -T postgres psql -U trustanchor trustanchor < "$backup_file"
    fi

    if [ $? -eq 0 ]; then
        echo_info "Database restored successfully"
    else
        echo_error "Database restore failed"
        return 1
    fi
}

# Backup Redis data
backup_redis() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/redis-$timestamp.rdb"

    echo_info "Backing up Redis data..."

    # Trigger Redis SAVE
    docker-compose -f "$COMPOSE_FILE" exec redis redis-cli SAVE

    # Copy the dump.rdb file
    docker cp $(docker-compose -f "$COMPOSE_FILE" ps -q redis):/data/dump.rdb "$backup_file"

    if [ $? -eq 0 ]; then
        echo_info "Redis backed up to: $backup_file"
        gzip "$backup_file"
        echo_info "Compressed to: $backup_file.gz"
    else
        echo_error "Redis backup failed"
        return 1
    fi
}

# Backup application files
backup_app_files() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/app-files-$timestamp.tar.gz"

    echo_info "Backing up application files..."

    tar -czf "$backup_file" \
        --exclude='veriscope_ta_dashboard/node_modules' \
        --exclude='veriscope_ta_dashboard/vendor' \
        --exclude='veriscope_ta_node/node_modules' \
        veriscope_ta_dashboard/.env \
        veriscope_ta_node/.env \
        .env 2>/dev/null

    if [ $? -eq 0 ]; then
        echo_info "Application files backed up to: $backup_file"
    else
        echo_warn "Application files backup completed with warnings"
    fi
}

# Full backup
full_backup() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    echo_info "Starting full backup..."
    echo ""

    backup_database
    echo ""
    backup_redis
    echo ""
    backup_app_files
    echo ""

    echo_info "Full backup completed!"
    echo_info "Backup location: $BACKUP_DIR"
}

# List backups
list_backups() {
    echo_info "Available backups in $BACKUP_DIR:"
    echo ""
    ls -lh "$BACKUP_DIR" | grep -v "^total" | awk '{print $9, "(" $5 ")"}'
}

# Clean old backups
clean_old_backups() {
    local days=${1:-30}
    echo_warn "This will delete backups older than $days days. Continue? (yes/no)"
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        echo_info "Cleanup cancelled"
        return 0
    fi

    echo_info "Cleaning backups older than $days days..."
    find "$BACKUP_DIR" -name "*.sql.gz" -mtime +$days -delete
    find "$BACKUP_DIR" -name "*.rdb.gz" -mtime +$days -delete
    find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$days -delete
    echo_info "Cleanup completed"
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
    echo ""
    echo "Maintenance:"
    echo "  6) List backups"
    echo "  7) Clean old backups"
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
            echo "Enter backup file path:"
            read -r backup_file
            restore_database "$backup_file"
            ;;
        6)
            list_backups
            ;;
        7)
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
        list)
            list_backups
            ;;
        clean)
            clean_old_backups "$2"
            ;;
        *)
            echo "Usage: $0 {backup-db|backup-redis|backup-files|backup-full|restore-db <file>|list|clean [days]}"
            exit 1
            ;;
    esac
fi
