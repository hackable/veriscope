#!/bin/bash
# Veriscope Bare-Metal Scripts - Database Module
# PostgreSQL database setup and management

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# POSTGRESQL SETUP
# ============================================================================

create_postgres_trustanchor_db() {
    echo_info "Setting up PostgreSQL database for Trust Anchor..."

    if su postgres -c "psql -t -c '\du'" | cut -d \| -f 1 | grep -qw trustanchor; then
        echo_warn "Postgres user trustanchor already exists"
        return 0
    fi

    local PGPASS=$(generate_password 20)
    local PGDATABASE=trustanchor
    local PGUSER=trustanchor

    sudo -u postgres psql -c "create user $PGUSER with createdb login password '$PGPASS'" || {
        echo_error "Postgres user creation failed"
        return 1
    }

    sudo -u postgres psql -c "create database $PGDATABASE owner $PGUSER" || {
        echo_error "Postgres database creation failed"
        return 1
    }

    local ENVDEST=$INSTALL_ROOT/veriscope_ta_dashboard/.env
    portable_sed "s#DB_CONNECTION=.*#DB_CONNECTION=pgsql#g" $ENVDEST
    portable_sed "s#DB_HOST=.*#DB_HOST=localhost#g" $ENVDEST
    portable_sed "s#DB_PORT=.*#DB_PORT=5432#g" $ENVDEST
    portable_sed "s#DB_DATABASE=.*#DB_DATABASE=$PGDATABASE#g" $ENVDEST
    portable_sed "s#DB_USERNAME=.*#DB_USERNAME=$PGUSER#g" $ENVDEST
    portable_sed "s#DB_PASSWORD=.*#DB_PASSWORD=$PGPASS#g" $ENVDEST

    echo_info "Database created: $PGDATABASE"
    echo_info "User: $PGUSER / Password: $PGPASS"
    echo_warn "Save these credentials securely!"

    return 0
}

# ============================================================================
# BACKUP AND RESTORE
# ============================================================================

backup_database() {
    echo_info "Backing up PostgreSQL database..."

    local backup_dir="/opt/veriscope/backups/database"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/trustanchor_${timestamp}.sql.gz"

    # Create backup directory if it doesn't exist
    mkdir -p "$backup_dir"

    # Perform backup
    if su postgres -c "pg_dump trustanchor | gzip > $backup_file"; then
        local size=$(du -h "$backup_file" | cut -f1)
        echo_info "✓ Database backup completed: $backup_file ($size)"
        echo_info "Backup location: $backup_file"
        return 0
    else
        echo_error "Database backup failed"
        return 1
    fi
}

restore_database() {
    local backup_file=$1

    if [ -z "$backup_file" ]; then
        echo_error "Backup file not specified"
        echo_info "Usage: restore_database <backup_file>"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        echo_error "Backup file not found: $backup_file"
        return 1
    fi

    echo_warn "This will restore the database from: $backup_file"
    echo_warn "All current data will be replaced!"
    echo -n "Are you sure you want to continue? (yes/no): "
    read -r confirm

    if [ "$confirm" != "yes" ]; then
        echo_info "Restore cancelled"
        return 1
    fi

    echo_info "Restoring database from backup..."

    # Stop services that use the database
    echo_info "Stopping services..."
    systemctl stop ta ta-wss ta-schedule horizon 2>/dev/null || true

    # Drop and recreate database
    echo_info "Recreating database..."
    su postgres -c "psql -c 'DROP DATABASE IF EXISTS trustanchor'"
    su postgres -c "psql -c 'CREATE DATABASE trustanchor OWNER trustanchor'"

    # Restore backup
    if zcat "$backup_file" | su postgres -c "psql trustanchor" >/dev/null 2>&1; then
        echo_info "✓ Database restored successfully"

        # Restart services
        echo_info "Restarting services..."
        systemctl start ta ta-wss ta-schedule horizon 2>/dev/null || true

        return 0
    else
        echo_error "Database restore failed"
        return 1
    fi
}

# ============================================================================
# UNINSTALL POSTGRESQL
# ============================================================================

uninstall_postgresql() {
    echo_warn "This will completely remove PostgreSQL and all databases"
    echo_warn "This action cannot be undone!"
    echo ""

    # Check if running interactively
    if [ -t 0 ]; then
        read -p "Are you sure you want to continue? (yes/no): " -r confirm
        echo
        if [ "$confirm" != "yes" ]; then
            echo_info "Uninstall cancelled"
            return 1
        fi
    fi

    echo_info "Stopping PostgreSQL services..."
    systemctl stop postgresql@17-main 2>/dev/null || true
    systemctl stop postgresql 2>/dev/null || true

    echo_info "Removing PostgreSQL packages..."
    apt-get remove --purge -y postgresql postgresql-17 postgresql-client-17 \
        postgresql-client-common postgresql-common postgresql-common-dev 2>/dev/null || true

    echo_info "Removing data directories..."
    rm -rf /var/lib/postgresql /etc/postgresql /var/run/postgresql

    systemctl daemon-reload

    echo_info "✓ PostgreSQL uninstalled successfully"
    return 0
}
