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

# Constants
readonly CONTAINER_NGINX="veriscope-nginx"
readonly CONTAINER_TUNNEL="veriscope-tunnel"
readonly CONTAINER_POSTGRES="veriscope-postgres"
readonly CONTAINER_REDIS="veriscope-redis"
readonly CONTAINER_NETHERMIND="veriscope-nethermind"
readonly CONTAINER_APP="veriscope-app"
readonly CONTAINER_TA_NODE="veriscope-ta-node"
readonly CONTAINER_CERTBOT="veriscope-certbot"

readonly RESETTABLE_VOLUMES="postgres_data redis_data app_data artifacts"
readonly ALL_VOLUMES="postgres_data redis_data app_data artifacts nethermind_data certbot_conf certbot_www"

readonly TUNNEL_STARTUP_WAIT=5
readonly SERVICE_STARTUP_WAIT=15
readonly SERVICE_READY_TIMEOUT=120

# Load .env file if it exists to override defaults
if [ -f ".env" ]; then
    set -o allexport
    source .env
    set +o allexport
fi

# ============================================================================
# SOURCE MODULAR COMPONENTS
# ============================================================================
# Load all modularized functions from docker-scripts/modules/
# Modules provide organized, maintainable functions following CODE_QUALITY.md standards

MODULES_DIR="${PROJECT_ROOT}/docker-scripts/modules"

# Core modules (must be loaded first)
source "${MODULES_DIR}/helpers.sh"
source "${MODULES_DIR}/validators.sh"

# Operational modules
source "${MODULES_DIR}/docker-ops.sh"
source "${MODULES_DIR}/database.sh"
source "${MODULES_DIR}/ssl.sh"
source "${MODULES_DIR}/chain.sh"
source "${MODULES_DIR}/secrets.sh"
source "${MODULES_DIR}/services.sh"

# ============================================================================
# SCRIPT-SPECIFIC FUNCTIONS
# ============================================================================
# Functions specific to this main script (not in modules)

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
    load_env_file ".env"

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
tunnel_start() {
    echo_info "Starting ngrok tunnel for remote access..."

    # Check if NGROK_AUTHTOKEN is set in .env
    if [ -z "$(get_env_var "NGROK_AUTHTOKEN")" ]; then
        echo_error "NGROK_AUTHTOKEN is not set in .env file"
        echo ""
        echo "Ngrok requires authentication. To use the tunnel:"
        echo "  1. Sign up for a free account at: https://dashboard.ngrok.com/signup"
        echo "  2. Get your authtoken from: https://dashboard.ngrok.com/get-started/your-authtoken"
        echo "  3. Add it to .env file: NGROK_AUTHTOKEN=your_token_here"
        echo ""
        return 1
    fi

    # Check if tunnel is already running
    if is_named_container_running "$CONTAINER_TUNNEL"; then
        echo_warn "Ngrok tunnel is already running"
        tunnel_url
        return
    fi

    # Check if nginx is running (required for tunnel)
    if ! is_named_container_running "$CONTAINER_NGINX" "running"; then
        echo_error "Nginx is not running. Please start the main services first with: $0 start"
        return 1
    fi

    # Start only the tunnel container without starting other services
    docker compose --profile tunnel up -d --no-deps tunnel

    echo_info "Waiting for tunnel to establish connection..."
    sleep $TUNNEL_STARTUP_WAIT

    tunnel_url
}

# Stop ngrok tunnel
tunnel_stop() {
    echo_info "Stopping ngrok tunnel..."
    docker compose --profile tunnel stop tunnel
    docker compose --profile tunnel rm -f tunnel
    echo -e "${GREEN}[SUCCESS]${NC} Ngrok tunnel stopped"
}

# Get tunnel URL
tunnel_url() {
    if ! is_named_container_running "$CONTAINER_TUNNEL"; then
        echo_error "Ngrok tunnel is not running. Start it with: $0 tunnel-start"
        return 1
    fi

    echo_info "Retrieving tunnel URL..."
    echo ""

    # Get the tunnel URL from logs (ngrok format: url=https://xxxx.ngrok-free.app or url=https://xxxx.ngrok.io)
    local tunnel_url=$(docker logs veriscope-tunnel 2>&1 | grep -o 'url=https://[^[:space:]]*' | tail -1 | cut -d= -f2)

    if [ -n "$tunnel_url" ]; then
        echo "🌐 Ngrok Tunnel URL: $tunnel_url"
        echo ""
        echo "You can access your Veriscope instance at:"
        echo "  $tunnel_url"
        echo ""
        echo "To update VERISCOPE_SERVICE_HOST in .env, run:"
        echo "  sed -i '' 's|^VERISCOPE_SERVICE_HOST=.*|VERISCOPE_SERVICE_HOST=$(echo $tunnel_url | sed 's#https://##')|' .env"
        echo ""
        echo "Note: Upgrade your free ngrok account to get:"
        echo "  - No interstitial warning page for visitors"
        echo "  - Static domains that work with certbot"
        echo "  - More concurrent tunnels and bandwidth"
    else
        echo -e "${YELLOW}[WARNING]${NC} Tunnel URL not found yet. The tunnel may still be establishing connection."
        echo "Check logs with: docker logs veriscope-tunnel"
    fi
}

# View tunnel logs
tunnel_logs() {
    if ! is_named_container_running "$CONTAINER_TUNNEL"; then
        echo_error "Ngrok tunnel is not running. Start it with: $0 tunnel-start"
        return 1
    fi

    echo_info "Showing ngrok tunnel logs (Ctrl+C to exit)..."
    docker logs -f veriscope-tunnel
}
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
setup_nginx_config() {
    echo_info "Setting up Nginx configuration..."
    echo_info "Nginx will auto-detect SSL certificates and configure itself automatically"

    # Load environment
    if [ ! -f ".env" ]; then
        echo_error ".env file not found"
        return 1
    fi

    load_env_file ".env"

    if [ -z "$VERISCOPE_SERVICE_HOST" ] || [ "$VERISCOPE_SERVICE_HOST" = "unset" ]; then
        echo_error "VERISCOPE_SERVICE_HOST not set in .env"
        echo_info "Please set VERISCOPE_SERVICE_HOST to your domain (e.g., ta.example.com)"
        return 1
    fi

    # Determine certificate paths
    local ssl_cert=$(get_ssl_cert_path "$VERISCOPE_SERVICE_HOST")
    local ssl_key=$(get_ssl_key_path "$VERISCOPE_SERVICE_HOST")

    # Check if SSL certificates exist in certbot Docker volume
    local cert_check_result=0
    check_ssl_cert_exists "$VERISCOPE_SERVICE_HOST" true || cert_check_result=$?

    if [ $cert_check_result -ne 0 ]; then
        echo_info "SSL certificates not found - Nginx will run in HTTP-only mode"
        show_service_urls "$VERISCOPE_SERVICE_HOST" "configured"
        echo_info ""
        echo_info "To enable HTTPS, run: ./docker-scripts/setup-docker.sh obtain-ssl"
    else
        echo_info "✓ SSL certificates found - Nginx will enable HTTPS automatically"
        echo_info "  Certificate: $ssl_cert"
        echo_info "  Key: $ssl_key"
    fi

    # Restart nginx to pick up any certificate changes
    echo_info "Restarting nginx..."
    if docker compose -f "$COMPOSE_FILE" restart nginx; then
        echo_info "✓ Nginx restarted successfully"
        echo_info ""

        # Display appropriate URLs based on certificate availability
        show_service_urls "$VERISCOPE_SERVICE_HOST" "available"
    else
        echo_warn "Failed to restart nginx. Restart manually with:"
        echo_warn "  docker compose -f $COMPOSE_FILE restart nginx"
    fi
}

# ============================================================================
# UNIFIED FULL INSTALLATION
# ============================================================================

# Perform full Veriscope installation
# Usage: perform_full_install [interactive_mode]
# Parameters:
#   interactive_mode: "true" for menu-driven install with step numbers and detailed output
#                     "false" for CLI install with minimal output (default)
perform_full_install() {
    local interactive="${1:-false}"
    local step_num=0
    local total_steps=11

    # Set installation mode flag
    if [ "$interactive" = "true" ]; then
        FULL_INSTALL_MODE=true
        echo_info "========================================="
        echo_info "  Veriscope Full Installation"
        echo_info "========================================="
        echo ""
    fi

    # Helper function to show step numbers in interactive mode
    step_info() {
        if [ "$interactive" = "true" ]; then
            step_num=$((step_num + 1))
            echo_info "Step $step_num/$total_steps: $1"
        else
            echo_info "$1"
        fi
    }

    # Step 1: Pre-flight checks
    step_info "Running pre-flight checks..."

    if ! check_host_dependencies; then
        abort_install "Host dependencies check failed" "Please install missing dependencies and try again"
    fi

    if ! check_docker; then
        abort_install "Docker check failed"
    fi

    if ! check_env; then
        abort_install "Environment check failed"
    fi

    # Run preflight checks (for CLI mode - menu mode already did this)
    if [ "$interactive" = "false" ]; then
        echo ""
        echo_info "Running system pre-flight checks..."
        if ! preflight_checks; then
            exit 1
        fi
        echo ""
    fi

    # Step 2: Create directory
    step_info "Creating veriscope_ta_node directory..."
    mkdir -p veriscope_ta_node

    # Step 3: Generate credentials
    step_info "Generating PostgreSQL credentials..."
    if ! generate_postgres_credentials; then
        abort_install "Failed to generate credentials"
    fi

    # Step 4: Build images
    step_info "Building Docker images..."
    if ! build_images; then
        abort_install "Failed to build images"
    fi

    # Step 5: Create sealer keypair
    step_info "Creating sealer keypair..."
    if ! create_sealer_keypair; then
        abort_install "Failed to create sealer keypair"
    fi

    # Step 6: SSL certificate (optional)
    if [ "$interactive" = "true" ]; then
        step_info "Obtaining SSL certificate..."
        if ! obtain_ssl_certificate; then
            echo_warn "SSL certificate setup skipped or failed (continuing...)"
        fi

        # Step 7: Setup nginx config
        step_info "Setting up Nginx configuration..."
        if ! setup_nginx_config; then
            abort_install "Failed to setup Nginx config"
        fi
    fi

    # Step 8: Reset volumes
    step_info "Resetting database and cache volumes..."
    if ! stop_services; then
        echo_warn "Failed to stop services cleanly - continuing..."
    fi

    project_name=$(get_project_name)
    if [ -z "$project_name" ]; then
        abort_install "Failed to determine project name"
    fi

    # Remove volumes (verbose in interactive mode)
    local verbose="false"
    [ "$interactive" = "true" ] && verbose="true"
    remove_data_volumes "$project_name" "$RESETTABLE_VOLUMES" "$verbose"
    echo_info "Data volumes removed (Nethermind data preserved)"

    # Step 9: Setup chain config
    step_info "Setting up chain configuration..."
    if ! setup_chain_config; then
        abort_install "Failed to setup chain config"
    fi

    # Step 10: Start services
    step_info "Starting services..."
    if ! start_services; then
        abort_install "Failed to start services"
    fi

    # Wait for services to be ready (different methods for interactive vs CLI)
    if [ "$interactive" = "true" ]; then
        echo_info "Waiting for services to be ready..."
        if ! wait_for_services_ready $SERVICE_READY_TIMEOUT; then
            abort_install "Services failed to become ready" "Check service logs: docker compose -f $COMPOSE_FILE logs"
        fi
    else
        # CLI mode uses simple sleep
        sleep $SERVICE_STARTUP_WAIT
    fi

    # Step 11: Laravel setup
    step_info "Running Laravel setup..."
    if ! full_laravel_setup; then
        abort_install "Laravel setup failed"
    fi

    # Install additional components
    echo_info "Installing additional components..."

    if [ "$interactive" = "true" ]; then
        # Interactive mode: handle errors gracefully
        if ! install_horizon; then
            echo_warn "Horizon installation failed (continuing...)"
        fi

        if ! install_passport_env; then
            echo_warn "Passport environment setup failed (continuing...)"
        fi

        if ! install_address_proofs; then
            echo_warn "Address proofs installation failed (continuing...)"
        fi
    else
        # CLI mode: run without error handling
        install_horizon
        install_passport_env
        install_address_proofs
    fi

    # Create admin user
    create_admin

    # Show completion message
    if [ "$interactive" = "true" ]; then
        echo ""
        echo_info "========================================="
        echo_info "  Full Installation Completed!"
        echo_info "========================================="
        echo ""
        echo_info "Post-installation steps:"
        echo_info "  1. Create admin user: ./docker-scripts/setup-docker.sh create-admin"
        echo_info "  2. (Optional) Download address proofs: ./docker-scripts/setup-docker.sh install-address-proofs"
        echo ""

        # Show service URLs
        local service_host=$(get_env_var "VERISCOPE_SERVICE_HOST" "localhost" true)
        show_service_urls "$service_host" "access"
        echo ""
    else
        echo_info "Full installation completed!"
    fi
}

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
    echo "  17) Update chainspec from remote URL"
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
    echo "  a) Setup automated certificate renewal"
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
    echo "Remote Access (Ngrok):"
    echo "  T) Start tunnel"
    echo "  S) Stop tunnel"
    echo "  U) Show tunnel URL"
    echo "  G) Show tunnel logs"
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
            check_host_dependencies
            check_docker
            check_env
            preflight_checks
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
        17)
            update_chainspec
            ;;
        i)
            # Run full installation in interactive mode
            perform_full_install "true"
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
        a)
            setup_auto_renewal
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
        T)
            tunnel_start
            ;;
        S)
            tunnel_stop
            ;;
        U)
            tunnel_url
            ;;
        G)
            tunnel_logs
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
            check_host_dependencies
            check_docker
            check_env
            ;;
        preflight)
            preflight_checks
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
        tunnel-start)
            tunnel_start
            ;;
        tunnel-stop)
            tunnel_stop
            ;;
        tunnel-url)
            tunnel_url
            ;;
        tunnel-logs)
            tunnel_logs
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
        setup-auto-renewal)
            setup_auto_renewal
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
        update-chainspec)
            update_chainspec
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
            # Run full installation in CLI mode
            perform_full_install "false"
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
            echo "  preflight                  - Run pre-flight system checks (ports, disk, network)"
            echo "  build                      - Build Docker images"
            echo "  start                      - Start all services"
            echo "  stop                       - Stop all services"
            echo "  restart                    - Restart all services"
            echo "  status                     - Show service status"
            echo "  logs [service]             - Show docker compose logs"
            echo "  supervisord-logs           - Show supervisord logs (interactive)"
            echo "  init-db                    - Initialize database"
            echo "  create-admin               - Create admin user"
            echo "  migrate                    - Run Laravel migrations"
            echo "  seed                       - Seed database"
            echo "  clear-cache                - Clear Laravel cache"
            echo "  install-node               - Install Node.js dependencies"
            echo "  install-php                - Install Laravel dependencies"
            echo "  health                     - Run health check"
            echo "  tunnel-start               - Start ngrok tunnel for remote access"
            echo "  tunnel-stop                - Stop ngrok tunnel"
            echo "  tunnel-url                 - Get ngrok tunnel URL"
            echo "  tunnel-logs                - View ngrok tunnel logs"
            echo "  gen-postgres               - Generate PostgreSQL credentials"
            echo "  setup-chain                - Setup chain-specific configuration"
            echo "  create-sealer              - Generate Trust Anchor Ethereum keypair"
            echo "  obtain-ssl                 - Obtain SSL certificate (Let's Encrypt)"
            echo "  setup-nginx                - Setup Nginx reverse proxy configuration"
            echo "  renew-ssl                  - Renew SSL certificates"
            echo "  setup-auto-renewal         - Setup automated certificate renewal"
            echo "  full-laravel-setup         - Full Laravel setup (install + migrate + seed)"
            echo "  install-horizon            - Install Laravel Horizon"
            echo "  install-passport-env       - Install Passport environment"
            echo "  install-address-proofs     - Install address proofs"
            echo "  install-redis-bloom        - Install Redis Bloom filter"
            echo "  refresh-static-nodes       - Refresh static nodes from ethstats"
            echo "  regenerate-webhook-secret  - Regenerate webhook shared secret"
            echo "  update-chainspec           - Update chainspec from remote URL"
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
