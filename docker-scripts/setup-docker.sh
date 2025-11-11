#!/bin/bash
set -e

# Veriscope Docker Setup Script
# This script helps set up and manage Veriscope using Docker Compose
#
# ARCHITECTURE NOTES:
# - WebSocket port 6001 is NOT exposed to host (matches bare metal setup)
# - All WebSocket traffic MUST go through nginx proxy at /app/websocketkey
# - This ensures consistent routing and security between dev and production
# - Browser connects: http://localhost/app/websocketkey (not ws://localhost:6001)

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FULL_INSTALL_MODE=false

cd "$PROJECT_ROOT"

# Initialize environment variables with defaults
VERISCOPE_SERVICE_HOST="${VERISCOPE_SERVICE_HOST:=unset}"
VERISCOPE_COMMON_NAME="${VERISCOPE_COMMON_NAME:=unset}"
VERISCOPE_TARGET="${VERISCOPE_TARGET:=unset}"

# Load .env file if it exists to override defaults
if [ -f ".env" ]; then
    set -o allexport
    source .env
    set +o allexport
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect if running in development mode
is_dev_mode() {
    # Check if using dev compose file
    if [[ "$COMPOSE_FILE" == *"dev"* ]]; then
        return 0
    fi

    # Check if APP_ENV is local/development
    if [ "$APP_ENV" = "local" ] || [ "$APP_ENV" = "development" ]; then
        return 0
    fi

    # Check if host is localhost or similar
    if [[ "$VERISCOPE_SERVICE_HOST" =~ ^(localhost|127\.0\.0\.1|.*\.local|.*\.test)$ ]]; then
        return 0
    fi

    return 1
}

# Validate environment variables
validate_env_vars() {
    local has_error=false

    # Check VERISCOPE_SERVICE_HOST
    if [ "$VERISCOPE_SERVICE_HOST" = "unset" ]; then
        echo_error "VERISCOPE_SERVICE_HOST is not set in .env"
        echo_info "Please set VERISCOPE_SERVICE_HOST to your domain or 'localhost' for development"
        has_error=true
    fi

    # Check VERISCOPE_COMMON_NAME
    if [ "$VERISCOPE_COMMON_NAME" = "unset" ]; then
        echo_error "VERISCOPE_COMMON_NAME is not set in .env"
        echo_info "Please set VERISCOPE_COMMON_NAME to your organization name"
        has_error=true
    fi

    # Check VERISCOPE_TARGET
    if [ "$VERISCOPE_TARGET" = "unset" ]; then
        echo_error "VERISCOPE_TARGET is not set in .env"
        echo_info "Please set VERISCOPE_TARGET to: veriscope_testnet, fed_testnet, or fed_mainnet"
        has_error=true
    else
        # Validate VERISCOPE_TARGET is a valid network
        case "$VERISCOPE_TARGET" in
            "veriscope_testnet"|"fed_testnet"|"fed_mainnet")
                # Valid target
                ;;
            *)
                echo_error "Invalid VERISCOPE_TARGET: $VERISCOPE_TARGET"
                echo_info "VERISCOPE_TARGET must be one of: veriscope_testnet, fed_testnet, fed_mainnet"
                has_error=true
                ;;
        esac
    fi

    if [ "$has_error" = true ]; then
        return 1
    fi

    return 0
}

# Check if Docker is installed
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo_error "Docker is not installed. Please install Docker first."
        exit 1
    fi

    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        echo_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi

    echo_info "Docker is installed: $(docker --version)"
}

# Generate random string for secrets
generate_secret() {
    if command -v pwgen &> /dev/null; then
        pwgen -B 20 1
    else
        openssl rand -base64 20 | tr -d "=+/" | cut -c1-20
    fi
}

# Generate PostgreSQL credentials
# Sets Docker Compose environment variables in root .env:
#   POSTGRES_PASSWORD - PostgreSQL database password
#   POSTGRES_USER - PostgreSQL database username (default: trustanchor)
#   POSTGRES_DB - PostgreSQL database name (default: trustanchor)
generate_postgres_credentials() {
    local env_file=".env"
    local pgpass=""
    local pguser="trustanchor"
    local pgdb="trustanchor"

    # Check if postgres password is already set in root .env
    if [ -f "$env_file" ] && grep -q "^POSTGRES_PASSWORD=" "$env_file"; then
        local existing_pass=$(grep "^POSTGRES_PASSWORD=" "$env_file" | cut -d'=' -f2)
        if [ ! -z "$existing_pass" ] && [ "$existing_pass" != "trustanchor_dev" ]; then
            echo_info "PostgreSQL credentials already exist in root .env"
            # Use existing credentials instead of generating new ones
            pgpass="$existing_pass"
            pguser=$(grep "^POSTGRES_USER=" "$env_file" | cut -d'=' -f2 || echo "trustanchor")
            pgdb=$(grep "^POSTGRES_DB=" "$env_file" | cut -d'=' -f2 || echo "trustanchor")
            # Continue to update Laravel .env (don't return early!)
        else
            # Generate new credentials
            echo_info "Generating new PostgreSQL credentials..."
            pgpass=$(generate_secret)
        fi
    else
        # Generate new credentials
        echo_info "Generating PostgreSQL credentials..."
        pgpass=$(generate_secret)
    fi

    # Update root .env file
    if [ -f "$env_file" ]; then
        # Update or add POSTGRES_PASSWORD
        if grep -q "^POSTGRES_PASSWORD=" "$env_file"; then
            sed -i.bak "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pgpass/" "$env_file"
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
                sed -i.bak "/^POSTGRES_PASSWORD=/a\\
POSTGRES_USER=$pguser" "$env_file"
            fi
            if ! grep -q "^POSTGRES_DB=" "$env_file"; then
                sed -i.bak "/^POSTGRES_USER=/a\\
POSTGRES_DB=$pgdb" "$env_file"
            fi
        fi
    fi

    # Update Laravel .env file for Docker networking
    local laravel_env="veriscope_ta_dashboard/.env"
    if [ -f "$laravel_env" ]; then
        echo_info "Updating Laravel configuration for Docker..."

        # First update on host filesystem
        sed -i.bak "s#^DB_CONNECTION=.*#DB_CONNECTION=pgsql#" "$laravel_env"
        sed -i.bak "s#^DB_HOST=.*#DB_HOST=postgres#" "$laravel_env"
        sed -i.bak "s#^DB_PORT=.*#DB_PORT=5432#" "$laravel_env"
        sed -i.bak "s#^DB_DATABASE=.*#DB_DATABASE=$pgdb#" "$laravel_env"
        sed -i.bak "s#^DB_USERNAME=.*#DB_USERNAME=$pguser#" "$laravel_env"
        sed -i.bak "s#^DB_PASSWORD=.*#DB_PASSWORD=$pgpass#" "$laravel_env"

        # Redis configuration (Docker service names)
        sed -i.bak 's|^REDIS_HOST=127\.0\.0\.1|REDIS_HOST=redis|g' "$laravel_env"
        sed -i.bak 's|^REDIS_HOST=localhost|REDIS_HOST=redis|g' "$laravel_env"

        # Pusher/WebSocket configuration (Docker service names)
        sed -i.bak 's|^PUSHER_APP_HOST=127\.0\.0\.1|PUSHER_APP_HOST=app|g' "$laravel_env"
        sed -i.bak 's|^PUSHER_APP_HOST=localhost|PUSHER_APP_HOST=app|g' "$laravel_env"

        # TA Node API URLs (Docker service names)
        sed -i.bak 's|^HTTP_API_URL=http://localhost:8080|HTTP_API_URL=http://ta-node:8080|g' "$laravel_env"
        sed -i.bak 's|^SHYFT_TEMPLATE_HELPER_URL=http://localhost:8090|SHYFT_TEMPLATE_HELPER_URL=http://ta-node:8090|g' "$laravel_env"

        rm -f "$laravel_env.bak"
        echo_info "Laravel .env configured (changes are immediately visible in container via bind mount)"
    fi

    echo_info "PostgreSQL Docker Compose environment variables configured in .env:"
    echo_info "  POSTGRES_DB=$pgdb"
    echo_info "  POSTGRES_USER=$pguser"
    echo_info "  POSTGRES_PASSWORD=$pgpass"
    echo_warn "These environment variables are used by Docker Compose services"
    echo_warn "Store these credentials securely!"
}

# Check if .env file exists
check_env() {
    if [ ! -f ".env" ]; then
        echo_warn ".env file not found. Creating from .env.example..."
        if [ -f ".env.example" ]; then
            cp .env.example .env
            echo_info ".env file created. Please edit it with your configuration."
        else
            echo_error ".env.example not found."
            return 1
        fi
    else
        echo_info ".env file exists"
    fi

    # Reload .env file to get latest values
    if [ -f ".env" ]; then
        set -o allexport
        source .env
        set +o allexport
    fi

    # Validate required environment variables
    if ! validate_env_vars; then
        echo ""
        echo_error "Environment validation failed. Please fix the .env file and try again."
        return 1
    fi

    echo_info "Environment variables validated successfully"

    # Generate postgres credentials if needed
    generate_postgres_credentials
}

# Build Docker images
build_images() {
    echo_info "Building Docker images..."
    docker-compose -f "$COMPOSE_FILE" build
    echo_info "Docker images built successfully"
}

# Start all services
start_services() {
    echo_info "Starting Veriscope services..."
    docker-compose -f "$COMPOSE_FILE" up -d
    echo_info "Services started. Use 'docker-compose -f $COMPOSE_FILE ps' to check status"
}

# Stop all services
stop_services() {
    echo_info "Stopping Veriscope services..."
    docker-compose -f "$COMPOSE_FILE" down
    echo_info "Services stopped"
}

# Reset database and cache volumes
# This is necessary when database credentials change, as PostgreSQL
# initializes with credentials on first run and stores them in the volume
# Note: This does NOT delete Nethermind volume (blockchain sync data)
reset_volumes() {
    echo_info "Resetting database and cache volumes..."
    echo_warn "This will delete all data in PostgreSQL and Redis!"
    echo_info "Nethermind blockchain data will be preserved"

    # Stop services first
    docker-compose -f "$COMPOSE_FILE" down 2>/dev/null || true

    # Get the project name from docker-compose config
    local project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json | jq -r '.name // "veriscope"')

    # Remove only postgres and redis volumes (keep Nethermind)
    docker volume rm "${project_name}_postgres_data" 2>/dev/null || true
    docker volume rm "${project_name}_redis_data" 2>/dev/null || true

    echo_info "Database and Redis volumes reset."
    echo_warn "You will need to run migrations and seed the database again"
}

# Destroy all services, containers, volumes, and networks
# This is a destructive operation that removes everything
destroy_services() {
    echo ""
    echo_error "==================== DANGER ===================="
    echo_warn "This will completely DESTROY your Veriscope installation:"
    echo_warn "  - Stop all running containers"
    echo_warn "  - Remove all containers"
    echo_warn "  - Remove all networks"
    echo ""

    # Ask about volumes
    echo_info "Volume removal options:"
    echo "  1) Remove ALL volumes (PostgreSQL, Redis, Nethermind)"
    echo "  2) Remove only PostgreSQL and Redis (preserve Nethermind blockchain)"
    echo "  3) Keep all volumes (only remove containers and networks)"
    echo ""
    read -p "Select option (1/2/3): " -n 1 -r volume_option
    echo ""
    echo ""

    if [[ ! $volume_option =~ ^[123]$ ]]; then
        echo_error "Invalid option. Aborting."
        return 1
    fi

    # Final confirmation
    echo_error "This action CANNOT be undone!"
    read -p "Type 'DESTROY' to confirm: " confirmation
    echo ""

    if [ "$confirmation" != "DESTROY" ]; then
        echo_info "Destroy operation cancelled."
        return 0
    fi

    echo_info "Beginning destroy sequence..."

    # Get the project name from docker-compose config
    local project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')

    # Stop and remove containers, networks
    echo_info "Stopping and removing containers and networks..."
    docker-compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true

    # Handle volumes based on user selection
    case $volume_option in
        1)
            echo_warn "Removing ALL volumes including Nethermind blockchain data..."
            docker volume rm "${project_name}_postgres_data" 2>/dev/null || true
            docker volume rm "${project_name}_redis_data" 2>/dev/null || true
            docker volume rm "${project_name}_nethermind_data" 2>/dev/null || true
            docker volume rm "${project_name}_certbot_certs" 2>/dev/null || true
            docker volume rm "${project_name}_certbot_www" 2>/dev/null || true
            echo_info "All volumes removed"
            ;;
        2)
            echo_warn "Removing PostgreSQL and Redis volumes (preserving Nethermind)..."
            docker volume rm "${project_name}_postgres_data" 2>/dev/null || true
            docker volume rm "${project_name}_redis_data" 2>/dev/null || true
            echo_info "Database and Redis volumes removed (Nethermind preserved)"
            ;;
        3)
            echo_info "Keeping all volumes intact"
            ;;
    esac

    # Remove any dangling volumes from this project
    echo_info "Cleaning up any dangling volumes..."
    docker volume ls -q --filter "name=${project_name}" | while read vol; do
        case $volume_option in
            1)
                docker volume rm "$vol" 2>/dev/null || true
                ;;
            2)
                # Only remove if not nethermind or certbot
                if [[ ! "$vol" =~ nethermind ]] && [[ ! "$vol" =~ certbot ]]; then
                    docker volume rm "$vol" 2>/dev/null || true
                fi
                ;;
            3)
                # Keep all volumes
                ;;
        esac
    done

    echo ""
    echo_info "=========================================="
    echo_info "Destroy operation completed successfully!"
    echo_info "=========================================="
    echo ""

    if [ "$volume_option" = "2" ] || [ "$volume_option" = "3" ]; then
        echo_info "Preserved data:"
        [ "$volume_option" = "2" ] || [ "$volume_option" = "3" ] && echo "  - Nethermind blockchain sync data"
        [ "$volume_option" = "3" ] && echo "  - PostgreSQL database"
        [ "$volume_option" = "3" ] && echo "  - Redis cache"
        echo ""
    fi

    echo_info "To rebuild your installation, run:"
    echo "  ./docker-scripts/setup-docker.sh full-install"
}

# Restart all services
restart_services() {
    echo_info "Restarting Veriscope services..."
    docker-compose -f "$COMPOSE_FILE" restart

    echo_info "Services restarted"
}

# Show service status
show_status() {
    echo_info "Veriscope service status:"
    docker-compose -f "$COMPOSE_FILE" ps
}

# Show logs
show_logs() {
    local service=$1
    if [ -z "$service" ]; then
        docker-compose -f "$COMPOSE_FILE" logs --tail=100 -f
    else
        docker-compose -f "$COMPOSE_FILE" logs --tail=100 -f "$service"
    fi
}

# Show supervisord logs from the app container
show_supervisord_logs() {
    echo_info "Available supervisord logs:"
    echo "  1) supervisord (main)"
    echo "  2) websocket"
    echo "  3) worker"
    echo "  4) horizon"
    echo "  5) scheduler"
    echo "  6) cron"
    echo "  a) all (combined)"
    echo ""
    read -p "Select log to view (1-6/a): " -n 1 -r log_choice
    echo ""
    echo ""

    case $log_choice in
        1)
            echo_info "Viewing supervisord main log..."
            docker-compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/supervisord.log
            ;;
        2)
            echo_info "Viewing websocket log..."
            docker-compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/websocket.log
            ;;
        3)
            echo_info "Viewing worker log..."
            docker-compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/worker.log
            ;;
        4)
            echo_info "Viewing horizon log..."
            docker-compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/horizon.log
            ;;
        5)
            echo_info "Viewing scheduler log..."
            docker-compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/scheduler.log
            ;;
        6)
            echo_info "Viewing cron log..."
            docker-compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/cron.log
            ;;
        a)
            echo_info "Viewing all supervisord logs (combined)..."
            docker-compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/*.log
            ;;
        *)
            echo_error "Invalid option"
            ;;
    esac
}

# Initialize database
init_database() {
    echo_info "Initializing Laravel database..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan migrate --force
    echo_info "Database initialized"
}

# Create admin user
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
    docker-compose -f "$COMPOSE_FILE" exec app php artisan createuser:admin
    if [ $? -ne 0 ]; then
        echo_warn "Admin user creation cancelled or failed"
        echo_info "You can create an admin user later by running:"
        echo_info "  ./docker-scripts/setup-docker.sh create-admin"
    fi
}

# Run Laravel migrations
run_migrations() {
    echo_info "Running Laravel migrations..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan migrate --force
    echo_info "Migrations completed"
}

# Clear Laravel cache
clear_cache() {
    echo_info "Clearing Laravel cache..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan cache:clear
    docker-compose -f "$COMPOSE_FILE" exec app php artisan config:clear
    docker-compose -f "$COMPOSE_FILE" exec app php artisan route:clear
    docker-compose -f "$COMPOSE_FILE" exec app php artisan view:clear
    echo_info "Cache cleared"
}

# Install Node.js dependencies
install_node_deps() {
    echo_info "Installing Node.js dependencies..."
    docker-compose -f "$COMPOSE_FILE" exec ta-node sh -c "cd /app && npm install --legacy-peer-deps"
    echo_info "Node.js dependencies installed"
}

# Install Laravel dependencies
install_laravel_deps() {
    echo_info "Installing Laravel dependencies..."
    docker-compose -f "$COMPOSE_FILE" exec app composer install
    echo_info "Laravel dependencies installed"
}

# Health check
health_check() {
    echo_info "Running health check..."

    echo ""
    echo "PostgreSQL:"
    docker-compose -f "$COMPOSE_FILE" exec postgres pg_isready -U trustanchor || echo_error "PostgreSQL is not healthy"

    echo ""
    echo "Redis:"
    docker-compose -f "$COMPOSE_FILE" exec redis redis-cli ping || echo_error "Redis is not healthy"

    echo ""
    echo "Laravel App:"
    docker-compose -f "$COMPOSE_FILE" exec app php artisan --version || echo_error "Laravel app is not healthy"

    echo ""
    echo "Node.js Service:"
    docker-compose -f "$COMPOSE_FILE" exec ta-node node --version || echo_error "Node.js service is not healthy"

    echo ""
    echo "Arena (Bull Queue UI):"
    curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:8080/arena/ || echo_error "Arena is not accessible"
}

# Backup database
backup_database() {
    local backup_file="backup-$(date +%Y%m%d-%H%M%S).sql"
    echo_info "Backing up database to $backup_file..."
    docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_dump -U trustanchor trustanchor > "$backup_file"
    echo_info "Database backed up to $backup_file"
}

# Restore database
restore_database() {
    local backup_file=$1
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        echo_error "Backup file not specified or doesn't exist"
        return 1
    fi

    echo_warn "This will restore the database from $backup_file. Are you sure? (y/N)"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo_info "Restore cancelled"
        return 0
    fi

    echo_info "Restoring database from $backup_file..."
    docker-compose -f "$COMPOSE_FILE" exec -T postgres psql -U trustanchor trustanchor < "$backup_file"
    echo_info "Database restored from $backup_file"
}

# Full Laravel setup (similar to install_or_update_laravel)
full_laravel_setup() {
    echo_info "Running full Laravel setup..."

    echo_info "Installing Composer dependencies..."
    if ! docker-compose -f "$COMPOSE_FILE" exec app composer install; then
        echo_error "Composer install failed"
        return 1
    fi

    echo_info "Running database migrations..."
    if ! docker-compose -f "$COMPOSE_FILE" exec app php artisan migrate --force; then
        echo_warn "Database migrations failed or already up to date"
    fi

    echo_info "Seeding database..."
    if docker-compose -f "$COMPOSE_FILE" exec app php artisan db:seed --force; then
        echo_info "Database seeded successfully"
    else
        echo_warn "Database seeding failed (may already be seeded)"
    fi

    echo_info "Generating application key..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan key:generate --force

    echo_info "Installing Passport..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan passport:install --force

    echo_info "Generating encryption key..."
    # Check if encryption keys already exist by looking for ENCRYPTION_KEY in .env
    if docker-compose -f "$COMPOSE_FILE" exec -T app grep -q "^ENCRYPTION_KEY=" .env 2>/dev/null; then
        echo_info "Encryption keys already exist, skipping..."
    else
        docker-compose -f "$COMPOSE_FILE" exec -T app php artisan encrypt:generate
    fi

    echo_info "Installing Node.js dependencies..."
    docker-compose -f "$COMPOSE_FILE" exec app npm install --legacy-peer-deps

    echo_info "Building frontend assets..."
    if docker-compose -f "$COMPOSE_FILE" exec app npm run development; then
        echo_info "Frontend assets built successfully"
    else
        echo_warn "Frontend build failed or completed with warnings"
        echo_info "You can rebuild later with: docker-compose exec app npm run development"
    fi

    echo_info "Full Laravel setup completed"
}

# Install Horizon
install_horizon() {
    echo_info "Installing Laravel Horizon..."

    docker-compose -f "$COMPOSE_FILE" exec app composer require laravel/horizon || echo_warn "Horizon may already be installed"
    docker-compose -f "$COMPOSE_FILE" exec app php artisan horizon:install
    docker-compose -f "$COMPOSE_FILE" exec app php artisan migrate --force

    echo_info "Horizon installed successfully"
    echo_info "Note: Horizon will run automatically via Laravel's queue worker"
}

# Install Passport Client Environment Variables
install_passport_env() {
    echo_info "Installing Passport client environment variables..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan passportenv:link
    echo_info "Passport environment variables linked"
}

# Install Address Proofs
install_address_proofs() {
    # In full install mode, skip by default (user can run manually later)
    if [ "$FULL_INSTALL_MODE" = true ]; then
        echo_info "Skipping address proofs download in automated install"
        echo_warn "Address proofs are optional and require a GitHub token"
        echo_info "To download address proofs later, run: ./docker-scripts/setup-docker.sh install-address-proofs"

        # Still create the directory even if skipping download
        docker-compose -f "$COMPOSE_FILE" exec -T app mkdir -p /opt/veriscope/veriscope_addressproof 2>/dev/null || true
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
    docker-compose -f "$COMPOSE_FILE" exec -T app mkdir -p /opt/veriscope/veriscope_addressproof

    if docker-compose -f "$COMPOSE_FILE" exec app php artisan download:addressproof; then
        echo_info "Address proofs downloaded successfully"
    else
        echo_warn "Failed to download address proofs - you can download them manually later"
        echo_info "To retry: ./docker-scripts/setup-docker.sh install-address-proofs"
    fi
}

# Regenerate encryption secret
regenerate_encrypt_secret() {
    echo_info "Generating new encryption secret..."
    echo_warn "This will reset your encryption keys and you will lose access to encrypted data!"
    # Use 'yes' to automatically answer the prompt
    echo "yes" | docker-compose -f "$COMPOSE_FILE" exec -T app php artisan encrypt:generate
    echo_info "Encryption secret regenerated"
}

# Install Redis Bloom Filter
install_redis_bloom() {
    echo_info "RedisBloom is already included in the Redis container!"
    echo_info ""
    echo_info "docker-compose.yml uses redis/redis-stack which includes:"
    echo "  - RedisBloom (bloom filters)"
    echo "  - RedisJSON (JSON document storage)"
    echo "  - RedisSearch (full-text search)"
    echo "  - RedisGraph (graph database)"
    echo "  - RedisTimeSeries (time series data)"
    echo ""
    echo_info "RedisInsight UI available at: http://localhost:8001"
    echo_info "No additional installation needed!"
}

# Database seed
seed_database() {
    echo_info "Seeding database..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan db:seed --force
    echo_info "Database seeded"
}

# Generate Laravel app key
generate_app_key() {
    echo_info "Generating Laravel application key..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan key:generate --force
    echo_info "Application key generated"
}

# Install Passport
install_passport() {
    echo_info "Installing Laravel Passport..."
    docker-compose -f "$COMPOSE_FILE" exec app php artisan passport:install --force
    echo_info "Passport installed"
}

# Generate Ethereum sealer keypair for Trust Anchor
create_sealer_keypair() {
    echo_info "Generating Ethereum keypair for Trust Anchor..."

    # Generate keypair using ethers.js in a one-off container (no need for ta-node to be running)
    local output=$(docker-compose -f "$COMPOSE_FILE" run --rm --no-deps -T ta-node node -e "
    const ethers = require('ethers');
    const wallet = ethers.Wallet.createRandom();
    console.log(JSON.stringify({
        address: wallet.address,
        privateKey: wallet.privateKey.substring(2)
    }));
    " 2>/dev/null)

    if [ -z "$output" ]; then
        echo_error "Failed to generate keypair"
        return 1
    fi

    local address=$(echo "$output" | grep -o '"address":"[^"]*"' | cut -d'"' -f4)
    local privatekey=$(echo "$output" | grep -o '"privateKey":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$address" ] || [ -z "$privatekey" ]; then
        echo_error "Failed to parse generated keypair"
        return 1
    fi

    echo_info "Generated Ethereum keypair:"
    echo_info "  Address: $address"
    echo_info "  Private Key: $privatekey"
    echo_warn "SAVE THESE CREDENTIALS SECURELY!"

    # Update veriscope_ta_node/.env
    if [ -f "veriscope_ta_node/.env" ]; then
        echo_info "Updating veriscope_ta_node/.env with keypair..."

        # Backup first
        cp veriscope_ta_node/.env veriscope_ta_node/.env.bak

        # Update or add TRUST_ANCHOR_ACCOUNT
        if grep -q "^TRUST_ANCHOR_ACCOUNT=" veriscope_ta_node/.env; then
            sed -i.tmp "s#^TRUST_ANCHOR_ACCOUNT=.*#TRUST_ANCHOR_ACCOUNT=$address#" veriscope_ta_node/.env
        else
            echo "TRUST_ANCHOR_ACCOUNT=$address" >> veriscope_ta_node/.env
        fi

        # Update or add TRUST_ANCHOR_PK
        if grep -q "^TRUST_ANCHOR_PK=" veriscope_ta_node/.env; then
            sed -i.tmp "s#^TRUST_ANCHOR_PK=.*#TRUST_ANCHOR_PK=$privatekey#" veriscope_ta_node/.env
        else
            echo "TRUST_ANCHOR_PK=$privatekey" >> veriscope_ta_node/.env
        fi

        # Update or add TRUST_ANCHOR_PREFNAME from VERISCOPE_COMMON_NAME
        if [ ! -z "$VERISCOPE_COMMON_NAME" ] && [ "$VERISCOPE_COMMON_NAME" != "unset" ]; then
            if grep -q "^TRUST_ANCHOR_PREFNAME=" veriscope_ta_node/.env; then
                sed -i.tmp "s#^TRUST_ANCHOR_PREFNAME=.*#TRUST_ANCHOR_PREFNAME=\"$VERISCOPE_COMMON_NAME\"#" veriscope_ta_node/.env
            else
                echo "TRUST_ANCHOR_PREFNAME=\"$VERISCOPE_COMMON_NAME\"" >> veriscope_ta_node/.env
            fi
            echo_info "Set TRUST_ANCHOR_PREFNAME to: $VERISCOPE_COMMON_NAME"
        else
            echo_warn "VERISCOPE_COMMON_NAME not set - please manually set TRUST_ANCHOR_PREFNAME in veriscope_ta_node/.env"
        fi

        rm -f veriscope_ta_node/.env.tmp

        echo_info "Trust Anchor credentials saved (visible in container via bind mount)"

        # Generate WEBHOOK_CLIENT_SECRET if not already set
        if grep -q "^WEBHOOK_CLIENT_SECRET=$" veriscope_ta_node/.env || ! grep -q "^WEBHOOK_CLIENT_SECRET=" veriscope_ta_node/.env; then
            echo_info "Generating webhook secret..."
            local webhook_secret=$(openssl rand -hex 32 2>/dev/null || xxd -l 32 -p /dev/urandom | tr -d '\n')

            # Update veriscope_ta_node/.env on host
            if grep -q "^WEBHOOK_CLIENT_SECRET=" veriscope_ta_node/.env; then
                sed -i.tmp "s#^WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=\"$webhook_secret\"#" veriscope_ta_node/.env
            else
                echo "WEBHOOK_CLIENT_SECRET=\"$webhook_secret\"" >> veriscope_ta_node/.env
            fi
            rm -f veriscope_ta_node/.env.tmp

            # Also update veriscope_ta_dashboard/.env to keep them in sync
            local laravel_env="veriscope_ta_dashboard/.env"
            if [ -f "$laravel_env" ]; then
                if grep -q "^WEBHOOK_CLIENT_SECRET=" "$laravel_env"; then
                    sed -i.tmp "s#^WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=\"$webhook_secret\"#" "$laravel_env"
                else
                    echo "WEBHOOK_CLIENT_SECRET=\"$webhook_secret\"" >> "$laravel_env"
                fi
                rm -f "${laravel_env}.tmp"

                echo_info "Webhook secret synchronized (visible in containers via bind mount)"
            else
                echo_warn "Laravel .env not found at $laravel_env - webhook secret only set in veriscope_ta_node"
            fi
        fi
    else
        echo_warn "veriscope_ta_node/.env not found. Please run setup-chain first."
    fi
}

# Obtain or renew SSL certificates
obtain_ssl_certificate() {
    echo_info "Setting up SSL certificate..."

    # Check if in development mode
    if is_dev_mode; then
        echo_warn "Development mode detected!"
        echo_info "Current settings:"
        echo "  - Compose file: $COMPOSE_FILE"
        echo "  - Host: $VERISCOPE_SERVICE_HOST"
        echo "  - APP_ENV: ${APP_ENV:-not set}"
        echo ""
        echo_warn "SSL certificates are typically not needed in development."
        echo_warn "Let's Encrypt will not issue certificates for localhost or .local/.test domains."
        echo ""
        read -p "Do you still want to obtain an SSL certificate? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo_info "Skipping SSL certificate setup."
            return 0
        fi
    fi

    # Load environment
    if [ ! -f ".env" ]; then
        echo_error ".env file not found"
        return 1
    fi

    source .env

    if [ -z "$VERISCOPE_SERVICE_HOST" ] || [ "$VERISCOPE_SERVICE_HOST" = "unset" ]; then
        echo_error "VERISCOPE_SERVICE_HOST not set in .env file"
        echo_info "Please set VERISCOPE_SERVICE_HOST to your domain (e.g., ta.example.com)"
        return 1
    fi

    echo_info "Domain: $VERISCOPE_SERVICE_HOST"

    # Ensure nginx is running to serve ACME challenges
    echo_info "Ensuring nginx container is running..."
    docker-compose -f "$COMPOSE_FILE" up -d nginx

    # Use certbot via Docker with webroot mode
    echo_info "Obtaining certificate for $VERISCOPE_SERVICE_HOST using Docker..."
    echo_warn "Make sure port 80 is accessible from the internet"

    docker-compose -f "$COMPOSE_FILE" run --rm \
        certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --preferred-challenges http \
        -d "$VERISCOPE_SERVICE_HOST"

    if [ $? -eq 0 ]; then
        echo_info "Certificate obtained successfully"

        # Set certificate paths in .env
        local cert_dir="/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST"

        if grep -q "^SSL_CERT_PATH=" .env; then
            sed -i.bak "s#^SSL_CERT_PATH=.*#SSL_CERT_PATH=$cert_dir/fullchain.pem#" .env
        else
            echo "SSL_CERT_PATH=$cert_dir/fullchain.pem" >> .env
        fi

        if grep -q "^SSL_KEY_PATH=" .env; then
            sed -i.bak "s#^SSL_KEY_PATH=.*#SSL_KEY_PATH=$cert_dir/privkey.pem#" .env
        else
            echo "SSL_KEY_PATH=$cert_dir/privkey.pem" >> .env
        fi

        rm -f .env.bak

        echo_info "Certificate paths saved to .env"
        echo_info "  Certificate: $cert_dir/fullchain.pem"
        echo_info "  Private Key: $cert_dir/privkey.pem"
    else
        echo_error "Failed to obtain certificate"
        echo_info "Please ensure:"
        echo "  1. Port 80 is open and accessible"
        echo "  2. Domain $VERISCOPE_SERVICE_HOST points to this server"
        echo "  3. No other web server is using port 80"
        return 1
    fi
}

# Renew SSL certificate
renew_ssl_certificate() {
    echo_info "Renewing SSL certificates using Docker..."

    # Check if in development mode
    if is_dev_mode; then
        echo_warn "Development mode detected - skipping SSL renewal."
        echo_info "SSL certificates are typically not used in development."
        return 0
    fi

    # Ensure nginx is running for webroot challenge
    docker-compose -f "$COMPOSE_FILE" up -d nginx

    # Run certbot renew via Docker (uses webroot mode)
    docker-compose -f "$COMPOSE_FILE" run --rm certbot renew

    if [ $? -eq 0 ]; then
        echo_info "Certificates renewed successfully"
        echo_info "Reloading nginx to pick up new certificates..."
        docker-compose -f "$COMPOSE_FILE" exec nginx nginx -s reload
    else
        echo_warn "Certificate renewal failed or certificates not due for renewal"
    fi
}

# Setup Nginx configuration
setup_nginx_config() {
    echo_info "Setting up Nginx SSL configuration..."

    # Load environment
    if [ ! -f ".env" ]; then
        echo_error ".env file not found"
        return 1
    fi

    source .env

    if [ -z "$VERISCOPE_SERVICE_HOST" ] || [ "$VERISCOPE_SERVICE_HOST" = "unset" ]; then
        echo_error "VERISCOPE_SERVICE_HOST not set in .env"
        echo_info "Please set VERISCOPE_SERVICE_HOST to your domain (e.g., ta.example.com)"
        return 1
    fi

    # Determine certificate paths
    local ssl_cert="${SSL_CERT_PATH:-/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/fullchain.pem}"
    local ssl_key="${SSL_KEY_PATH:-/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/privkey.pem}"

    # Verify SSL certificates exist
    if [ ! -f "$ssl_cert" ] || [ ! -f "$ssl_key" ]; then
        echo_warn "SSL certificates not found at:"
        echo_warn "  Certificate: $ssl_cert"
        echo_warn "  Key: $ssl_key"

        if is_dev_mode; then
            echo_info ""
            echo_info "Development mode - Nginx will serve HTTP only on port 80"
            echo_info "  Laravel: http://$VERISCOPE_SERVICE_HOST"
            echo_info "  Arena:   http://$VERISCOPE_SERVICE_HOST/arena"
            echo_info ""
            echo_info "Continuing with setup..."
            return 0
        else
            echo_info "Please run: ./docker-scripts/setup-docker.sh obtain-ssl"
            echo_info ""
            echo_info "For now, Nginx will serve HTTP only on port 80"
            echo_info "  Laravel: http://$VERISCOPE_SERVICE_HOST"
            echo_info "  Arena:   http://$VERISCOPE_SERVICE_HOST/arena"
            return 1
        fi
    fi

    echo_info "SSL certificates found"
    echo_info "  Certificate: $ssl_cert"
    echo_info "  Key: $ssl_key"

    # Update .env with SSL paths if not already set
    if ! grep -q "^SSL_CERT_PATH=" .env; then
        echo "SSL_CERT_PATH=$ssl_cert" >> .env
        echo_info "Added SSL_CERT_PATH to .env"
    fi

    if ! grep -q "^SSL_KEY_PATH=" .env; then
        echo "SSL_KEY_PATH=$ssl_key" >> .env
        echo_info "Added SSL_KEY_PATH to .env"
    fi

    # Create SSL-enabled nginx configuration
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local nginx_dir="$script_dir/nginx"
    mkdir -p "$nginx_dir"

    echo_info "Creating SSL-enabled Nginx configuration..."

    cat > "$nginx_dir/nginx-ssl.conf" <<EOF
# HTTP server - redirect to HTTPS
server {
    listen 80;
    server_name $VERISCOPE_SERVICE_HOST;

    # Redirect all HTTP traffic to HTTPS
    return 301 https://\$server_name\$request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name $VERISCOPE_SERVICE_HOST;

    # SSL certificates
    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Client settings
    client_max_body_size 128M;
    client_body_buffer_size 128k;

    # Logging
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss;

    # Laravel application (main site)
    location / {
        proxy_pass http://app:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Bull Arena queue UI
    location /arena {
        proxy_pass http://ta-node:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }


    # WebSocket key endpoint for Laravel
    location /app/websocketkey {
        proxy_pass http://app:6001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-VerifiedViaNginx yes;
        proxy_read_timeout 60;
        proxy_connect_timeout 60;
        proxy_redirect off;

        # Allow the use of websockets
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
    }

    # Health check endpoint
    location /nginx-health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

    echo_info "SSL configuration created: docker-scripts/nginx/nginx-ssl.conf"
    echo_info ""
    echo_info "To enable SSL, update docker-compose.yml nginx volumes to:"
    echo_info "  - ./docker-scripts/nginx/nginx-ssl.conf:/etc/nginx/conf.d/default.conf:ro"
    echo_info "  - $ssl_cert:/etc/nginx/ssl/cert.pem:ro"
    echo_info "  - $ssl_key:/etc/nginx/ssl/key.pem:ro"
    echo_info ""
    echo_info "Then restart nginx:"
    echo_info "  docker-compose -f $COMPOSE_FILE restart nginx"
    echo_info ""
    echo_info "Your services will be available at:"
    echo_info "  Laravel: https://$VERISCOPE_SERVICE_HOST"
    echo_info "  Arena:   https://$VERISCOPE_SERVICE_HOST/arena"
}

# Configure Nethermind for selected network
# Sets Docker Compose environment variables in root .env:
#   NETHERMIND_ETHSTATS_SERVER - WebSocket URL for ethstats server
#   NETHERMIND_ETHSTATS_SECRET - Authentication secret for ethstats
#   NETHERMIND_ETHSTATS_ENABLED - Enable/disable ethstats reporting (true/false)
configure_nethermind() {
    local network="$1"

    echo_info "Configuring Nethermind for network: $network"

    # Set network-specific ethstats configuration
    local ethstats_server
    local ethstats_secret
    local ethstats_enabled="true"

    case "$network" in
        "veriscope_testnet")
            ethstats_server="wss://fedstats.veriscope.network/api"
            ethstats_secret="Oogongi4"
            ;;
        "fed_testnet")
            ethstats_server="wss://stats.testnet.shyft.network/api"
            ethstats_secret="Ish9phieph"
            ;;
        "fed_mainnet")
            ethstats_server="wss://stats.shyft.network/api"
            ethstats_secret="uL4tohChia"
            ;;
        *)
            echo_warn "Unknown network, using default ethstats configuration"
            ethstats_server="wss://fedstats.veriscope.network/api"
            ethstats_secret="Oogongi4"
            ;;
    esac

    # Update .env with Nethermind configuration
    # Check if any Nethermind variables exist
    local nethermind_exists=false
    if grep -q "^NETHERMIND_ETHSTATS_SERVER=" .env || \
       grep -q "^NETHERMIND_ETHSTATS_SECRET=" .env || \
       grep -q "^NETHERMIND_ETHSTATS_ENABLED=" .env; then
        nethermind_exists=true
    fi

    if [ "$nethermind_exists" = false ]; then
        # Add Nethermind section with proper formatting
        cat >> .env <<EOF

# Nethermind Ethereum Client Configuration
# Connect to the Veriscope network stats server
NETHERMIND_ETHSTATS_SERVER=$ethstats_server
NETHERMIND_ETHSTATS_SECRET=$ethstats_secret
NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled
EOF
    else
        # Update existing values
        if grep -q "^NETHERMIND_ETHSTATS_SERVER=" .env; then
            sed -i.bak "s#^NETHERMIND_ETHSTATS_SERVER=.*#NETHERMIND_ETHSTATS_SERVER=$ethstats_server#" .env
        else
            echo "NETHERMIND_ETHSTATS_SERVER=$ethstats_server" >> .env
        fi

        if grep -q "^NETHERMIND_ETHSTATS_SECRET=" .env; then
            sed -i.bak "s#^NETHERMIND_ETHSTATS_SECRET=.*#NETHERMIND_ETHSTATS_SECRET=$ethstats_secret#" .env
        else
            echo "NETHERMIND_ETHSTATS_SECRET=$ethstats_secret" >> .env
        fi

        if grep -q "^NETHERMIND_ETHSTATS_ENABLED=" .env; then
            sed -i.bak "s#^NETHERMIND_ETHSTATS_ENABLED=.*#NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled#" .env
        else
            echo "NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled" >> .env
        fi
    fi

    echo_info "Nethermind configuration added to .env for $network network:"
    echo_info "  NETHERMIND_ETHSTATS_SERVER=$ethstats_server"
    echo_info "  NETHERMIND_ETHSTATS_SECRET=$ethstats_secret"
    echo_info "  NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled"
}

# Setup chain-specific configuration
setup_chain_config() {
    echo_info "Setting up chain-specific configuration..."

    # Load VERISCOPE_TARGET from .env
    if [ ! -f ".env" ]; then
        echo_error ".env file not found. Please run check command first."
        return 1
    fi

    source .env

    if [ -z "$VERISCOPE_TARGET" ] || [ "$VERISCOPE_TARGET" = "unset" ]; then
        echo_error "VERISCOPE_TARGET not set in .env file"
        echo_info "Please set VERISCOPE_TARGET to: veriscope_testnet, fed_testnet, or fed_mainnet"
        return 1
    fi

    case "$VERISCOPE_TARGET" in
        "veriscope_testnet"|"fed_testnet"|"fed_mainnet")
            echo_info "Target network: $VERISCOPE_TARGET"
            ;;
        *)
            echo_error "Invalid VERISCOPE_TARGET: $VERISCOPE_TARGET"
            echo_info "Must be one of: veriscope_testnet, fed_testnet, fed_mainnet"
            return 1
            ;;
    esac

    local chain_dir="chains/$VERISCOPE_TARGET"

    if [ ! -d "$chain_dir" ]; then
        echo_error "Chain directory not found: $chain_dir"
        return 1
    fi

    # Configure Nethermind for this network
    configure_nethermind "$VERISCOPE_TARGET"

    # Copy artifacts directory to Docker volume for ta-node
    if [ -d "$chain_dir/artifacts" ]; then
        echo_info "Copying chain artifacts for $VERISCOPE_TARGET to Docker volume..."

        # Get the project name from docker-compose config
        local project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json | jq -r '.name // "veriscope"')
        local volume_name="${project_name}_veriscope_artifacts"

        # Create volume if it doesn't exist
        docker volume create "$volume_name" >/dev/null 2>&1 || true

        # Copy artifacts from chains/$VERISCOPE_TARGET/artifacts to volume
        # Using alpine container to perform the copy
        docker run --rm \
            -v "$(pwd)/$chain_dir:/source:ro" \
            -v "$volume_name:/target" \
            alpine sh -c "rm -rf /target/* && cp -r /source/artifacts/. /target/"

        echo_info "Artifacts copied to Docker volume: $volume_name"
        echo_info "Network: $VERISCOPE_TARGET"
    else
        echo_warn "No artifacts directory found in $chain_dir"
    fi

    # Copy ta-node-env if veriscope_ta_node/.env doesn't exist
    if [ ! -f "veriscope_ta_node/.env" ]; then
        if [ -f "$chain_dir/ta-node-env" ]; then
            echo_info "Creating veriscope_ta_node/.env from chain template..."
            cp "$chain_dir/ta-node-env" veriscope_ta_node/.env

            # Update localhost URLs to Docker service names on host
            echo_info "Updating .env for Docker networking on host..."
            sed -i.bak 's|http://localhost:8545|http://nethermind:8545|g' veriscope_ta_node/.env
            sed -i.bak 's|ws://localhost:8545|ws://nethermind:8545|g' veriscope_ta_node/.env
            sed -i.bak 's|http://localhost:8000|http://app:80|g' veriscope_ta_node/.env
            sed -i.bak 's|redis://127.0.0.1:6379|redis://redis:6379|g' veriscope_ta_node/.env
            sed -i.bak 's|/opt/veriscope/veriscope_ta_node/artifacts/|/app/artifacts/|g' veriscope_ta_node/.env
            rm -f veriscope_ta_node/.env.bak

            echo_info "TA node .env configured (changes are immediately visible in container via bind mount)"
            echo_warn "Remember to run 'create-sealer' to generate Trust Anchor keypair"
        else
            echo_warn "No ta-node-env template found in $chain_dir"
        fi
    else
        echo_info "veriscope_ta_node/.env already exists (not overwriting)"
    fi

    # Setup Nethermind configuration if nethermind directory exists
    if [ -d "nethermind" ] || [ -d "/opt/nm" ]; then
        echo_info "Setting up Nethermind configuration for $VERISCOPE_TARGET..."

        local nm_dir="${NETHERMIND_DIR:-./nethermind}"
        mkdir -p "$nm_dir"

        # Copy chain spec
        if [ -f "$chain_dir/shyftchainspec.json" ]; then
            echo_info "Copying chain specification..."
            cp "$chain_dir/shyftchainspec.json" "$nm_dir/"
            echo_info "Chain spec copied to $nm_dir/shyftchainspec.json"
        fi

        # Copy static nodes
        if [ -f "$chain_dir/static-nodes.json" ]; then
            echo_info "Copying static node list..."
            cp "$chain_dir/static-nodes.json" "$nm_dir/"
            echo_info "Static nodes copied to $nm_dir/static-nodes.json"
        fi

        echo_info "Nethermind configuration updated"
        echo_warn "Restart Nethermind container to apply changes"
    else
        echo_info "Nethermind directory not found (skipping Nethermind config)"
    fi

    echo_info "Chain configuration completed for $VERISCOPE_TARGET"
}

# Refresh static nodes from ethstats
refresh_static_nodes() {
    echo_info "Refreshing static nodes from ethstats..."

    # Load environment
    if [ ! -f ".env" ]; then
        echo_error ".env file not found"
        return 1
    fi

    source .env

    if [ -z "$VERISCOPE_TARGET" ]; then
        echo_error "VERISCOPE_TARGET not set in .env. Please run setup-chain first."
        return 1
    fi

    # Determine ethstats enodes endpoint based on network
    local ethstats_get_enodes
    case "$VERISCOPE_TARGET" in
        "veriscope_testnet")
            ethstats_get_enodes="wss://fedstats.veriscope.network/primus/?_primuscb=1627594389337-0"
            ;;
        "fed_testnet")
            ethstats_get_enodes="wss://stats.testnet.shyft.network/primus/?_primuscb=1627594389337-0"
            ;;
        "fed_mainnet")
            ethstats_get_enodes="wss://stats.shyft.network/primus/?_primuscb=1627594389337-0"
            ;;
        *)
            echo_error "Invalid VERISCOPE_TARGET: $VERISCOPE_TARGET"
            return 1
            ;;
    esac

    echo_info "Querying ethstats at $ethstats_get_enodes..."

    # Check if wscat is available
    if ! command -v wscat &> /dev/null; then
        echo_warn "wscat not found. Installing..."
        if command -v npm &> /dev/null; then
            npm install -g wscat
        else
            echo_error "npm not found. Cannot install wscat."
            echo_info "Please install Node.js/npm or wscat manually"
            return 1
        fi
    fi

    # Create temporary file for static nodes
    local temp_file=$(mktemp)
    local static_nodes_file="chains/$VERISCOPE_TARGET/static-nodes.json"

    echo_info "Fetching current enode list from ethstats..."

    # Query ethstats for current nodes
    echo '[' > "$temp_file"
    wscat -x '{"emit":["ready"]}' --connect "$ethstats_get_enodes" 2>/dev/null | \
        grep enode | \
        jq '.emit[1].nodes' 2>/dev/null | \
        grep -oP '"enode://.*?"' | \
        sed '$!s/$/,/' >> "$temp_file"
    echo ']' >> "$temp_file"

    # Validate the generated JSON
    if jq empty "$temp_file" 2>/dev/null; then
        echo_info "Successfully retrieved static nodes"

        # Backup existing static-nodes.json
        if [ -f "$static_nodes_file" ]; then
            cp "$static_nodes_file" "${static_nodes_file}.bak"
            echo_info "Backed up existing static-nodes.json"
        fi

        # Update static-nodes.json
        cp "$temp_file" "$static_nodes_file"
        echo_info "Updated $static_nodes_file"

        # Display the nodes
        echo_info "Current static nodes:"
        cat "$static_nodes_file"
    else
        echo_error "Failed to retrieve valid static nodes"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"

    # Get this node's enode information from Nethermind
    echo ""
    echo_info "Retrieving this node's enode information..."

    # Check if Nethermind is running
    if ! docker-compose -f "$COMPOSE_FILE" ps nethermind | grep -q "Up"; then
        echo_warn "Nethermind container not running"
        echo_info "Start services and run this command again to update enode contact info"
        return 0
    fi

    # Query Nethermind for node info
    local enode=$(curl -s -X POST -d '{"jsonrpc":"2.0","id":1, "method":"admin_nodeInfo", "params":[]}' http://localhost:8545/ | jq -r '.result.enode' 2>/dev/null)

    if [ ! -z "$enode" ] && [ "$enode" != "null" ]; then
        echo_info "This node's enode: $enode"

        # Update .env with enode contact info
        if grep -q "^NETHERMIND_ETHSTATS_CONTACT=" .env; then
            sed -i.bak "s#^NETHERMIND_ETHSTATS_CONTACT=.*#NETHERMIND_ETHSTATS_CONTACT=$enode#" .env
        else
            echo "NETHERMIND_ETHSTATS_CONTACT=$enode" >> .env
        fi

        echo_info "Updated NETHERMIND_ETHSTATS_CONTACT in .env"
    else
        echo_warn "Could not retrieve enode information from Nethermind"
    fi

    # Ask user if they want to restart Nethermind and clear peer database
    echo ""
    echo_warn "To apply changes, Nethermind needs to restart with cleared peer database"
    echo_warn "This will remove cached peer information and force reconnection"
    echo -n "Restart Nethermind and clear peer cache? (y/N): "
    read -r confirm

    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo_info "Stopping Nethermind..."
        docker-compose -f "$COMPOSE_FILE" stop nethermind

        echo_info "Clearing peer database..."
        # Clear discovery and peer databases from volume
        docker-compose -f "$COMPOSE_FILE" run --rm nethermind sh -c "rm -f /nethermind/db/discoveryNodes/SimpleFileDb.db /nethermind/db/peers/SimpleFileDb.db" 2>/dev/null || true

        echo_info "Starting Nethermind with fresh peer database..."
        docker-compose -f "$COMPOSE_FILE" up -d nethermind
        echo_info "Nethermind restarted successfully"
    else
        echo_info "Skipping Nethermind restart. Changes will apply on next restart."
    fi

    echo_info "Static nodes refresh completed"
}

# Regenerate webhook shared secret
regenerate_webhook_secret() {
    echo_info "Regenerating webhook shared secret..."

    # Generate new secret
    local new_secret=$(generate_secret)

    echo_info "Generated new secret: $new_secret"

    # Update Laravel .env on host
    local laravel_env="veriscope_ta_dashboard/.env"
    if [ -f "$laravel_env" ]; then
        if grep -q "^WEBHOOK_CLIENT_SECRET=" "$laravel_env"; then
            sed -i.bak "s#^WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=\"$new_secret\"#" "$laravel_env"
            echo_info "Updated host $laravel_env"
        else
            echo "WEBHOOK_CLIENT_SECRET=\"$new_secret\"" >> "$laravel_env"
            echo_info "Added WEBHOOK_CLIENT_SECRET to host $laravel_env"
        fi
        rm -f "${laravel_env}.bak"
    else
        echo_warn "Laravel .env not found at $laravel_env"
    fi

    # Update Node.js .env on host
    local node_env="veriscope_ta_node/.env"
    if [ -f "$node_env" ]; then
        if grep -q "^WEBHOOK_CLIENT_SECRET=" "$node_env"; then
            sed -i.bak "s#^WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=\"$new_secret\"#" "$node_env"
            echo_info "Updated host $node_env"
        else
            echo "WEBHOOK_CLIENT_SECRET=\"$new_secret\"" >> "$node_env"
            echo_info "Added WEBHOOK_CLIENT_SECRET to host $node_env"
        fi
        rm -f "${node_env}.bak"
    else
        echo_warn "Node.js .env not found at $node_env"
    fi

    # Restart affected services to reload updated .env
    echo_info "Restarting services to reload configuration..."

    if docker-compose -f "$COMPOSE_FILE" ps app 2>/dev/null | grep -q "Up"; then
        docker-compose -f "$COMPOSE_FILE" restart app
        echo_info "Restarted Laravel app service"
    fi

    if docker-compose -f "$COMPOSE_FILE" ps ta-node 2>/dev/null | grep -q "Up"; then
        docker-compose -f "$COMPOSE_FILE" restart ta-node
        echo_info "Restarted Node.js ta-node service"
    fi

    echo_info "Webhook secret regenerated successfully"
    echo_warn "New secret: $new_secret (save this securely!)"
}

# Menu
menu() {
    echo ""
    echo "================================"
    echo "Veriscope Docker Management"
    echo "================================"
    echo ""
    echo "Setup & Installation:"
    echo "  1) Check requirements"
    echo "  2) Build Docker images"
    echo "  3) Generate PostgreSQL credentials"
    echo "  4) Setup chain configuration (copy artifacts)"
    echo "  5) Generate Trust Anchor keypair (sealer)"
    echo "  6) Obtain SSL certificate (Let's Encrypt)"
    echo "  7) Setup Nginx configuration"
    echo "  8) Start all services"
    echo "  9) Full Laravel setup (install + migrations + seed)"
    echo "  10) Create admin user"
    echo "  11) Install Horizon"
    echo "  12) Install Passport environment"
    echo "  13) Install address proofs"
    echo "  14) Install Redis Bloom filter"
    echo "  15) Refresh static nodes from ethstats"
    echo "  16) Regenerate webhook secret"
    echo "  i) Full Install (all of the above)"
    echo ""
    echo "Service Management:"
    echo "  s) Show service status"
    echo "  r) Restart services"
    echo "  q) Stop services"
    echo "  l) Show logs (docker-compose)"
    echo "  L) Show supervisord logs"
    echo ""
    echo "SSL Management:"
    echo "  u) Renew SSL certificate"
    echo ""
    echo "Laravel Maintenance:"
    echo "  m) Run migrations"
    echo "  d) Seed database"
    echo "  k) Generate app key"
    echo "  o) Install/regenerate Passport"
    echo "  e) Regenerate encryption secret"
    echo "  c) Clear Laravel cache"
    echo "  n) Install Node.js dependencies"
    echo "  p) Install Laravel (PHP) dependencies"
    echo ""
    echo "Health & Monitoring:"
    echo "  h) Health check"
    echo ""
    echo "Backup & Restore:"
    echo "  b) Backup database"
    echo "  t) Restore database"
    echo ""
    echo "Dangerous Operations:"
    echo "  v) Reset volumes (PostgreSQL & Redis)"
    echo "  D) DESTROY all services (containers, volumes, networks)"
    echo ""
    echo "  x) Exit"
    echo ""
    echo -n "Select an option: "
    read -r choice

    case $choice in
        1)
            check_docker
            check_env
            ;;
        2)
            build_images
            ;;
        3)
            generate_postgres_credentials
            ;;
        4)
            setup_chain_config
            ;;
        5)
            create_sealer_keypair
            ;;
        6)
            obtain_ssl_certificate
            ;;
        7)
            setup_nginx_config
            ;;
        8)
            start_services
            ;;
        9)
            full_laravel_setup
            ;;
        10)
            create_admin
            ;;
        11)
            install_horizon
            ;;
        12)
            install_passport_env
            ;;
        13)
            install_address_proofs
            ;;
        14)
            install_redis_bloom
            ;;
        15)
            refresh_static_nodes
            ;;
        16)
            regenerate_webhook_secret
            ;;
        i)
            FULL_INSTALL_MODE=true
            check_docker
            check_env
            generate_postgres_credentials
            setup_chain_config
            build_images
            create_sealer_keypair
            obtain_ssl_certificate
            setup_nginx_config

            # Reset volumes to ensure clean state with new credentials
            echo_info "Ensuring clean database and cache volumes..."
            docker-compose -f "$COMPOSE_FILE" down 2>/dev/null || true

            # Get the project name from docker-compose config
            project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json | jq -r '.name // "veriscope"')

            # Remove only postgres and redis volumes (preserve Nethermind blockchain data)
            docker volume rm "${project_name}_postgres_data" 2>/dev/null || true
            docker volume rm "${project_name}_redis_data" 2>/dev/null || true
            echo_info "PostgreSQL and Redis volumes reset (Nethermind data preserved)"

            start_services
            sleep 15
            full_laravel_setup
            install_horizon
            install_passport_env
            install_address_proofs
            create_admin
            echo_info "Full installation completed!"
            echo ""
            echo_info "Post-installation steps:"
            echo_info "  1. Create admin user: ./docker-scripts/setup-docker.sh create-admin"
            echo_info "  2. (Optional) Download address proofs: ./docker-scripts/setup-docker.sh install-address-proofs"
            echo ""
            echo_info "Access your Veriscope instance at:"
            echo_info "  - Dashboard: http://localhost"
            echo_info "  - Arena: http://localhost/arena"
            ;;
        s)
            show_status
            ;;
        r)
            restart_services
            ;;
        q)
            stop_services
            ;;
        l)
            echo "Which service? (press Enter for all services)"
            read -r service
            show_logs "$service"
            ;;
        L)
            show_supervisord_logs
            ;;
        u)
            renew_ssl_certificate
            ;;
        m)
            run_migrations
            ;;
        d)
            seed_database
            ;;
        k)
            generate_app_key
            ;;
        o)
            install_passport
            ;;
        e)
            regenerate_encrypt_secret
            ;;
        c)
            clear_cache
            ;;
        n)
            install_node_deps
            ;;
        p)
            install_laravel_deps
            ;;
        h)
            health_check
            ;;
        b)
            backup_database
            ;;
        t)
            echo "Enter backup file path:"
            read -r backup_file
            restore_database "$backup_file"
            ;;
        v)
            reset_volumes
            ;;
        D)
            destroy_services
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

# Main execution
if [ $# -eq 0 ]; then
    # Interactive mode
    menu
else
    # Command line mode
    case "$1" in
        check)
            check_docker
            check_env
            ;;
        build)
            build_images
            ;;
        start)
            start_services
            ;;
        stop)
            stop_services
            ;;
        restart)
            restart_services
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs "$2"
            ;;
        supervisord-logs)
            show_supervisord_logs
            ;;
        init-db)
            init_database
            ;;
        create-admin)
            create_admin
            ;;
        migrate)
            run_migrations
            ;;
        clear-cache)
            clear_cache
            ;;
        install-node)
            install_node_deps
            ;;
        install-php)
            install_laravel_deps
            ;;
        health)
            health_check
            ;;
        gen-postgres)
            generate_postgres_credentials
            ;;
        setup-chain)
            setup_chain_config
            ;;
        create-sealer)
            create_sealer_keypair
            ;;
        obtain-ssl)
            obtain_ssl_certificate
            ;;
        setup-nginx)
            setup_nginx_config
            ;;
        renew-ssl)
            renew_ssl_certificate
            ;;
        full-laravel-setup)
            full_laravel_setup
            ;;
        install-horizon)
            install_horizon
            ;;
        install-passport-env)
            install_passport_env
            ;;
        install-address-proofs)
            install_address_proofs
            ;;
        install-redis-bloom)
            install_redis_bloom
            ;;
        refresh-static-nodes)
            refresh_static_nodes
            ;;
        regenerate-webhook-secret)
            regenerate_webhook_secret
            ;;
        seed)
            seed_database
            ;;
        gen-app-key)
            generate_app_key
            ;;
        install-passport)
            install_passport
            ;;
        gen-encrypt-secret)
            regenerate_encrypt_secret
            ;;
        full-install)
            check_docker
            check_env
            generate_postgres_credentials
            setup_chain_config
            build_images
            create_sealer_keypair

            # Reset volumes to ensure clean state with new credentials
            echo_info "Ensuring clean database and cache volumes..."
            docker-compose -f "$COMPOSE_FILE" down 2>/dev/null || true

            # Get the project name from docker-compose config
            project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json | jq -r '.name // "veriscope"')

            # Remove only postgres and redis volumes (preserve Nethermind blockchain data)
            docker volume rm "${project_name}_postgres_data" 2>/dev/null || true
            docker volume rm "${project_name}_redis_data" 2>/dev/null || true
            echo_info "PostgreSQL and Redis volumes reset (Nethermind data preserved)"

            start_services
            sleep 15
            full_laravel_setup
            install_horizon
            install_passport_env
            install_address_proofs
            create_admin
            echo_info "Full installation completed!"
            ;;
        backup)
            backup_database
            ;;
        restore)
            restore_database "$2"
            ;;
        reset-volumes)
            reset_volumes
            ;;
        destroy)
            destroy_services
            ;;
        *)
            echo "Usage: $0 <command>"
            echo ""
            echo "Commands:"
            echo "  check                      - Check Docker requirements"
            echo "  build                      - Build Docker images"
            echo "  start                      - Start all services"
            echo "  stop                       - Stop all services"
            echo "  restart                    - Restart all services"
            echo "  status                     - Show service status"
            echo "  logs [service]             - Show docker-compose logs"
            echo "  supervisord-logs           - Show supervisord logs (interactive)"
            echo "  init-db                    - Initialize database"
            echo "  create-admin               - Create admin user"
            echo "  migrate                    - Run Laravel migrations"
            echo "  seed                       - Seed database"
            echo "  clear-cache                - Clear Laravel cache"
            echo "  install-node               - Install Node.js dependencies"
            echo "  install-php                - Install Laravel dependencies"
            echo "  health                     - Run health check"
            echo "  gen-postgres               - Generate PostgreSQL credentials"
            echo "  setup-chain                - Setup chain-specific configuration"
            echo "  create-sealer              - Generate Trust Anchor Ethereum keypair"
            echo "  obtain-ssl                 - Obtain SSL certificate (Let's Encrypt)"
            echo "  setup-nginx                - Setup Nginx reverse proxy configuration"
            echo "  renew-ssl                  - Renew SSL certificates"
            echo "  full-laravel-setup         - Full Laravel setup (install + migrate + seed)"
            echo "  install-horizon            - Install Laravel Horizon"
            echo "  install-passport-env       - Install Passport environment"
            echo "  install-address-proofs     - Install address proofs"
            echo "  install-redis-bloom        - Install Redis Bloom filter"
            echo "  refresh-static-nodes       - Refresh static nodes from ethstats"
            echo "  regenerate-webhook-secret  - Regenerate webhook shared secret"
            echo "  gen-app-key                - Generate Laravel app key"
            echo "  install-passport           - Install/regenerate Passport"
            echo "  gen-encrypt-secret         - Regenerate encryption secret"
            echo "  full-install               - Full installation (all of the above)"
            echo "  backup                     - Backup database"
            echo "  restore <file>             - Restore database"
            echo "  reset-volumes              - Reset PostgreSQL and Redis volumes (keeps Nethermind)"
            echo "  destroy                    - DESTROY all services (containers, volumes, networks)"
            exit 1
            ;;
    esac
fi
