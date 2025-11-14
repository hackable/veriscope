#!/bin/bash
# Veriscope Docker Scripts - Application Services Module
# This module provides high-level application service operations
#
# Functions:
# - Laravel setup: full_laravel_setup, generate_app_key, clear_cache
# - Laravel packages: install_horizon, install_passport, install_passport_env
# - Dependencies: install_node_deps, install_laravel_deps
# - User management: create_admin
# - Optional features: install_address_proofs
# - Health checking: health_check

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"
source "${SCRIPT_DIR}/docker-ops.sh"

# ============================================================================
# LARAVEL SETUP AND CONFIGURATION
# ============================================================================

# Full Laravel setup (similar to install_or_update_laravel)
# Comprehensive setup including dependencies, migrations, seeding, and asset building
# Returns: 0 on success, 1 on failure
full_laravel_setup() {
    echo_info "Running full Laravel setup..."

    echo_info "Installing Composer dependencies..."
    if ! docker compose -f "$COMPOSE_FILE" exec app composer install; then
        echo_error "Composer install failed"
        return 1
    fi

    echo_info "Running database migrations..."
    if ! docker compose -f "$COMPOSE_FILE" exec app php artisan migrate --force; then
        echo_warn "Database migrations failed or already up to date"
    fi

    echo_info "Seeding database..."
    if docker compose -f "$COMPOSE_FILE" exec app php artisan db:seed --force; then
        echo_info "Database seeded successfully"
    else
        echo_warn "Database seeding failed (may already be seeded)"
    fi

    echo_info "Generating application key..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan key:generate --force

    echo_info "Installing Passport..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan passport:install --force

    echo_info "Generating encryption key..."
    # Check if encryption keys already exist by looking for ENCRYPTION_KEY in .env
    if docker compose -f "$COMPOSE_FILE" exec -T app grep -q "^ENCRYPTION_KEY=" .env 2>/dev/null; then
        echo_info "Encryption keys already exist, skipping..."
    else
        docker compose -f "$COMPOSE_FILE" exec -T app php artisan encrypt:generate
    fi

    echo_info "Installing Node.js dependencies..."
    docker compose -f "$COMPOSE_FILE" exec app npm install --legacy-peer-deps

    echo_info "Building frontend assets..."
    if docker compose -f "$COMPOSE_FILE" exec app npm run development; then
        echo_info "Frontend assets built successfully"
    else
        echo_warn "Frontend build failed or completed with warnings"
        echo_info "You can rebuild later with: docker compose exec app npm run development"
    fi

    echo_info "Full Laravel setup completed"
}

# Generate Laravel app key
# Returns: 0 on success
generate_app_key() {
    echo_info "Generating Laravel application key..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan key:generate --force
    echo_info "Application key generated"
}

# Clear Laravel cache
# Clears application, config, route, and view caches
# Returns: 0 on success, 1 on failure
clear_cache() {
    echo_info "Clearing Laravel cache..."

    if ! is_container_running "app"; then
        echo_error "Laravel app container is not running"
        return 1
    fi

    local failed=false

    if ! docker compose -f "$COMPOSE_FILE" exec app php artisan cache:clear; then
        echo_warn "Failed to clear application cache"
        failed=true
    fi

    if ! docker compose -f "$COMPOSE_FILE" exec app php artisan config:clear; then
        echo_warn "Failed to clear config cache"
        failed=true
    fi

    if ! docker compose -f "$COMPOSE_FILE" exec app php artisan route:clear; then
        echo_warn "Failed to clear route cache"
        failed=true
    fi

    if ! docker compose -f "$COMPOSE_FILE" exec app php artisan view:clear; then
        echo_warn "Failed to clear view cache"
        failed=true
    fi

    if [ "$failed" = true ]; then
        echo_error "Some cache clear operations failed"
        return 1
    fi

    echo_info "Cache cleared"
}

# ============================================================================
# LARAVEL PACKAGES
# ============================================================================

# Install Horizon
# Laravel queue monitoring dashboard
# Returns: 0 on success
install_horizon() {
    echo_info "Installing Laravel Horizon..."

    docker compose -f "$COMPOSE_FILE" exec app php artisan horizon:install
    docker compose -f "$COMPOSE_FILE" exec app php artisan migrate --force

    echo_info "Horizon installed successfully"
    echo_info "Note: Horizon will run automatically via Laravel's queue worker"
}

# Install Passport
# Laravel OAuth2 server
# Returns: 0 on success
install_passport() {
    echo_info "Installing Laravel Passport..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan passport:install --force
    echo_info "Passport installed"
}

# Install Passport Client Environment Variables
# Links Passport client credentials to environment
# Returns: 0 on success
install_passport_env() {
    echo_info "Installing Passport client environment variables..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan passportenv:link
    echo_info "Passport environment variables linked"
}

# ============================================================================
# OPTIONAL FEATURES
# ============================================================================

# Install Address Proofs
# Downloads address proof data from GitHub (requires GITHUB_TOKEN)
# Returns: 0 on success, 1 on skip/failure
install_address_proofs() {
    # In full install mode, skip by default (user can run manually later)
    if [ "$FULL_INSTALL_MODE" = true ]; then
        echo_info "Skipping address proofs download in automated install"
        echo_warn "Address proofs are optional and require a GitHub token"
        echo_info "To download address proofs later, run: ./docker-scripts/setup-docker.sh install-address-proofs"

        # Still create the directory even if skipping download
        docker compose -f "$COMPOSE_FILE" exec -T app mkdir -p /opt/veriscope/veriscope_addressproof 2>/dev/null || true
        return 0
    fi

    echo_info "Address proofs are optional and require a GitHub token"
    echo_warn "This step can be skipped and run later if needed"
    echo ""
    read -p "Do you want to download address proofs now? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo_info "Skipping address proofs download"
        echo_info "To download later, run: ./docker-scripts/setup-docker.sh install-address-proofs"
        return 0
    fi

    echo_info "Downloading address proofs..."

    # Create the directory that the Laravel app expects (bare-metal path)
    echo_info "Creating address proof directory..."
    docker compose -f "$COMPOSE_FILE" exec -T app mkdir -p /opt/veriscope/veriscope_addressproof

    if docker compose -f "$COMPOSE_FILE" exec app php artisan download:addressproof; then
        echo_info "Address proofs downloaded successfully"
    else
        echo_warn "Failed to download address proofs - you can download them manually later"
        echo_info "To retry: ./docker-scripts/setup-docker.sh install-address-proofs"
    fi
}

# ============================================================================
# USER MANAGEMENT
# ============================================================================

# Create admin user
# Interactive admin user creation
# Returns: 0 on success/skip
create_admin() {
    # In full install mode, skip by default (user can run manually later)
    if [ "$FULL_INSTALL_MODE" = true ]; then
        echo_info "Skipping admin user creation in automated install"
        echo_warn "Admin user creation requires interactive input"
        echo_info "To create an admin user, run: ./docker-scripts/setup-docker.sh create-admin"
        return 0
    fi

    echo_info "Admin user creation is required for first login"
    echo_warn "This command is interactive and requires user input"
    echo ""
    read -p "Do you want to create an admin user now? (Y/n): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo_info "Skipping admin user creation"
        echo_info "To create an admin user later, run: ./docker-scripts/setup-docker.sh create-admin"
        return 0
    fi

    echo_info "Creating admin user..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan createuser:admin
    if [ $? -ne 0 ]; then
        echo_warn "Admin user creation cancelled or failed"
        echo_info "You can create an admin user later by running:"
        echo_info "  ./docker-scripts/setup-docker.sh create-admin"
    fi
}

# ============================================================================
# DEPENDENCY MANAGEMENT
# ============================================================================

# Install Node.js dependencies
# Returns: 0 on success, 1 on failure
install_node_deps() {
    echo_info "Installing Node.js dependencies..."

    if ! is_container_running "ta-node"; then
        echo_error "TA Node container is not running"
        return 1
    fi

    if ! docker compose -f "$COMPOSE_FILE" exec ta-node sh -c "cd /app && npm install --legacy-peer-deps"; then
        echo_error "Failed to install Node.js dependencies"
        return 1
    fi

    echo_info "Node.js dependencies installed"
}

# Install Laravel dependencies
# Returns: 0 on success, 1 on failure
install_laravel_deps() {
    echo_info "Installing Laravel dependencies..."

    if ! is_container_running "app"; then
        echo_error "Laravel app container is not running"
        return 1
    fi

    if ! docker compose -f "$COMPOSE_FILE" exec app composer install; then
        echo_error "Failed to install Laravel dependencies"
        return 1
    fi

    echo_info "Laravel dependencies installed"
}

# ============================================================================
# HEALTH CHECKING
# ============================================================================

# Health check
# Comprehensive health check of all services
# Returns: 0 if all healthy
health_check() {
    echo_info "Running comprehensive health check..."
    echo ""

    local all_healthy=true

    # 1. Container Status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1. Container Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local containers=("postgres" "redis" "app" "ta-node" "nginx" "nethermind")
    local container_names=("PostgreSQL" "Redis" "Laravel App" "TA Node" "Nginx" "Nethermind")

    for i in "${!containers[@]}"; do
        local container="${containers[$i]}"
        local name="${container_names[$i]}"

        if docker compose -f "$COMPOSE_FILE" ps "$container" 2>/dev/null | grep -q "Up"; then
            echo_info "✓ $name is running"
        else
            echo_error "✗ $name is not running"
            all_healthy=false
        fi
    done
    echo ""

    # 2. Service Health
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "2. Service Health"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # PostgreSQL
    if docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U trustanchor >/dev/null 2>&1; then
        echo_info "✓ PostgreSQL is accepting connections"
    else
        echo_error "✗ PostgreSQL is not ready"
        all_healthy=false
    fi

    # Redis
    if docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        echo_info "✓ Redis is responding"
    else
        echo_error "✗ Redis is not responding"
        all_healthy=false
    fi

    # Laravel
    if docker compose -f "$COMPOSE_FILE" exec -T app php artisan --version >/dev/null 2>&1; then
        echo_info "✓ Laravel app is functional"
    else
        echo_error "✗ Laravel app is not functional"
        all_healthy=false
    fi

    # TA Node
    if docker compose -f "$COMPOSE_FILE" exec -T ta-node node --version >/dev/null 2>&1; then
        echo_info "✓ TA Node is functional"
    else
        echo_error "✗ TA Node is not functional"
        all_healthy=false
    fi

    # Nginx
    if docker compose -f "$COMPOSE_FILE" exec -T nginx nginx -t >/dev/null 2>&1; then
        echo_info "✓ Nginx configuration is valid"
    else
        echo_error "✗ Nginx configuration has errors"
        all_healthy=false
    fi
    echo ""

    # 3. Network Connectivity
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "3. Network Connectivity"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Test database connection from app
    if docker compose -f "$COMPOSE_FILE" exec -T app php artisan db:show >/dev/null 2>&1; then
        echo_info "✓ App can connect to database"
    else
        echo_error "✗ App cannot connect to database"
        all_healthy=false
    fi

    # Test Redis connection from app
    if docker compose -f "$COMPOSE_FILE" exec -T app sh -c "php -r \"(new Redis())->connect('redis', 6379);\"" >/dev/null 2>&1; then
        echo_info "✓ App can connect to Redis"
    else
        echo_error "✗ App cannot connect to Redis"
        all_healthy=false
    fi
    echo ""

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Health Check Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$all_healthy" = true ]; then
        echo_info "✅ All services are healthy!"
        echo ""
        return 0
    else
        echo_error "❌ Some services are unhealthy"
        echo_info "Use 'docker compose logs <service>' to investigate issues"
        echo ""
        return 1
    fi
}
