#!/bin/bash
# Veriscope Docker Scripts - Database Module
# This module provides database management functions
#
# Functions:
# - Environment: init_dashboard_env
# - Credentials: generate_postgres_credentials
# - Initialization: init_database, run_migrations, seed_database
# - Backup/Restore: backup_database, restore_database

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"
source "${SCRIPT_DIR}/validators.sh"

# ============================================================================
# ENVIRONMENT INITIALIZATION
# ============================================================================

# Initialize dashboard .env file from template
# Creates veriscope_ta_dashboard/.env from .env.example if it doesn't exist
# Returns: 0 on success, 1 on failure
init_dashboard_env() {
    local dashboard_dir="veriscope_ta_dashboard"
    local env_file="$dashboard_dir/.env"
    local env_example="$dashboard_dir/.env.example"

    echo_info "Initializing dashboard environment file..."

    # Check if dashboard directory exists
    if [ ! -d "$dashboard_dir" ]; then
        echo_error "Dashboard directory not found: $dashboard_dir"
        return 1
    fi

    # Check if .env.example exists
    if [ ! -f "$env_example" ]; then
        echo_error "Dashboard .env.example not found: $env_example"
        return 1
    fi

    # Create .env from .env.example if it doesn't exist
    if [ ! -f "$env_file" ]; then
        echo_info "Creating dashboard .env from template..."
        cp "$env_example" "$env_file"
        echo_info "✓ Dashboard .env created from .env.example"
    else
        echo_info "Dashboard .env already exists"
    fi

    return 0
}

# ============================================================================
# CREDENTIALS MANAGEMENT
# ============================================================================

# Generate PostgreSQL credentials
# Sets Docker Compose environment variables in root .env:
#   POSTGRES_PASSWORD - PostgreSQL database password
#   POSTGRES_USER - PostgreSQL database username (default: trustanchor)
#   POSTGRES_DB - PostgreSQL database name (default: trustanchor)
# Also updates Laravel .env with Docker networking configuration
# Returns: 0 on success, 1 on failure
generate_postgres_credentials() {
    local env_file=".env"
    local pgpass=""
    local pguser="trustanchor"
    local pgdb="trustanchor"

    # Check if postgres password is already set in root .env
    if [ -f "$env_file" ] && grep -q "^POSTGRES_PASSWORD=" "$env_file"; then
        local existing_pass=$(grep "^POSTGRES_PASSWORD=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")

        if [ ! -z "$existing_pass" ]; then
            # Validate existing password
            if validate_postgres_password "$existing_pass"; then
                echo_info "PostgreSQL credentials already exist in root .env"
                # Use existing credentials
                pgpass="$existing_pass"
                pguser=$(grep "^POSTGRES_USER=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "trustanchor")
                pgdb=$(grep "^POSTGRES_DB=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "trustanchor")
                # Continue to update Laravel .env (don't return early!)
            else
                # Existing password is weak or invalid - regenerate
                echo_warn "Existing PostgreSQL password is weak or invalid"
                echo_info "Generating new secure PostgreSQL credentials..."
                pgpass=$(generate_secret)

                # Validate generated password
                if ! validate_postgres_password "$pgpass"; then
                    echo_error "Failed to generate valid password - this should not happen"
                    return 1
                fi
            fi
        else
            # Empty password - generate new
            echo_info "Generating new PostgreSQL credentials..."
            pgpass=$(generate_secret)

            # Validate generated password
            if ! validate_postgres_password "$pgpass"; then
                echo_error "Failed to generate valid password - this should not happen"
                return 1
            fi
        fi
    else
        # Generate new credentials
        echo_info "Generating PostgreSQL credentials..."
        pgpass=$(generate_secret)

        # Validate generated password
        if ! validate_postgres_password "$pgpass"; then
            echo_error "Failed to generate valid password - this should not happen"
            return 1
        fi
    fi

    # Update root .env file
    if [ -f "$env_file" ]; then
        # Update or add POSTGRES_PASSWORD
        if grep -q "^POSTGRES_PASSWORD=" "$env_file"; then
            portable_sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pgpass/" "$env_file"
        else
            # Add PostgreSQL section with proper formatting
            cat >> "$env_file" <<EOF

# PostgreSQL Database Configuration
# Used by the Trust Anchor Dashboard application
POSTGRES_PASSWORD=$pgpass
POSTGRES_USER=$pguser
POSTGRES_DB=$pgdb
EOF
        fi

        # Ensure POSTGRES_USER and POSTGRES_DB are set if POSTGRES_PASSWORD already existed
        if grep -q "^POSTGRES_PASSWORD=" "$env_file"; then
            if ! grep -q "^POSTGRES_USER=" "$env_file"; then
                portable_sed "/^POSTGRES_PASSWORD=/a\\
POSTGRES_USER=$pguser" "$env_file"
            fi
            if ! grep -q "^POSTGRES_DB=" "$env_file"; then
                portable_sed "/^POSTGRES_USER=/a\\
POSTGRES_DB=$pgdb" "$env_file"
            fi
        fi
    fi

    # Update Laravel .env file for Docker networking
    local laravel_env="veriscope_ta_dashboard/.env"
    if [ -f "$laravel_env" ]; then
        echo_info "Updating Laravel configuration for Docker..."

        # First update on host filesystem
        portable_sed "s#^DB_CONNECTION=.*#DB_CONNECTION=pgsql#" "$laravel_env"
        portable_sed "s#^DB_HOST=.*#DB_HOST=postgres#" "$laravel_env"
        portable_sed "s#^DB_PORT=.*#DB_PORT=5432#" "$laravel_env"
        portable_sed "s#^DB_DATABASE=.*#DB_DATABASE=$pgdb#" "$laravel_env"
        portable_sed "s#^DB_USERNAME=.*#DB_USERNAME=$pguser#" "$laravel_env"
        portable_sed "s#^DB_PASSWORD=.*#DB_PASSWORD=$pgpass#" "$laravel_env"

        # Redis configuration (Docker service names)
        portable_sed 's|^REDIS_HOST=127\.0\.0\.1|REDIS_HOST=redis|g' "$laravel_env"
        portable_sed 's|^REDIS_HOST=localhost|REDIS_HOST=redis|g' "$laravel_env"

        # Pusher/WebSocket configuration (Docker service names)
        portable_sed 's|^PUSHER_APP_HOST=127\.0\.0\.1|PUSHER_APP_HOST=app|g' "$laravel_env"
        portable_sed 's|^PUSHER_APP_HOST=localhost|PUSHER_APP_HOST=app|g' "$laravel_env"

        # TA Node API URLs (Docker service names)
        portable_sed 's|^HTTP_API_URL=http://localhost:8080|HTTP_API_URL=http://ta-node:8080|g' "$laravel_env"
        portable_sed 's|^SHYFT_TEMPLATE_HELPER_URL=http://localhost:8090|SHYFT_TEMPLATE_HELPER_URL=http://ta-node:8090|g' "$laravel_env"

        # Set APP_URL from VERISCOPE_SERVICE_HOST
        local service_host="${VERISCOPE_SERVICE_HOST:-localhost}"
        local app_url="https://$service_host"
        if [ "$service_host" = "localhost" ] || [ "$service_host" = "127.0.0.1" ]; then
            app_url="http://$service_host"
        fi
        portable_sed "s|^APP_URL=.*|APP_URL=$app_url|g" "$laravel_env"
        echo_info "Set APP_URL=$app_url"

        echo_info "Laravel .env configured (changes are immediately visible in container via bind mount)"
    fi

    echo_info "PostgreSQL Docker Compose environment variables configured in .env:"
    echo_info "  POSTGRES_DB=$pgdb"
    echo_info "  POSTGRES_USER=$pguser"
    echo_info "  POSTGRES_PASSWORD=$pgpass"
    echo_warn "These environment variables are used by Docker Compose services"
    echo_warn "Store these credentials securely!"
}

# ============================================================================
# DATABASE INITIALIZATION
# ============================================================================

# Initialize database
# Runs Laravel migrations to create database schema
# Returns: 0 on success, 1 on failure
init_database() {
    echo_info "Initializing Laravel database..."
    if ! docker compose -f "$COMPOSE_FILE" exec app php artisan migrate --force; then
        echo_error "Failed to initialize database"
        return 1
    fi
    echo_info "Database initialized"
}

# Run Laravel migrations
# Returns: 0 on success, 1 on failure
run_migrations() {
    echo_info "Running Laravel migrations..."
    if ! docker compose -f "$COMPOSE_FILE" exec app php artisan migrate --force; then
        echo_error "Failed to run migrations"
        return 1
    fi
    echo_info "Migrations completed"
}

# Seed database
# Populates database with initial data
# Returns: 0 on success, 1 on failure
seed_database() {
    echo_info "Seeding database..."
    if ! docker compose -f "$COMPOSE_FILE" exec app php artisan db:seed --force; then
        echo_error "Failed to seed database"
        return 1
    fi
    echo_info "Database seeded"
}

# ============================================================================
# BACKUP AND RESTORE
# ============================================================================

# Backup database
# Delegates to modules/backup-restore.sh
backup_database() {
    "$PROJECT_ROOT/docker-scripts/modules/backup-restore.sh" backup-db
}

# Restore database
# Delegates to modules/backup-restore.sh
# Usage: restore_database <backup_file>
# Returns: 1 if backup file not specified
restore_database() {
    local backup_file=$1
    if [ -z "$backup_file" ]; then
        echo_error "Backup file not specified"
        return 1
    fi
    "$PROJECT_ROOT/docker-scripts/modules/backup-restore.sh" restore-db "$backup_file"
}
