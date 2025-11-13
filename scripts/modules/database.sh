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
