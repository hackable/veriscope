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
tunnel_start() {
    echo_info "Starting ngrok tunnel for remote access..."

    # Check if NGROK_AUTHTOKEN is set in .env
    if ! grep -q "^NGROK_AUTHTOKEN=" .env 2>/dev/null || [ -z "$(grep "^NGROK_AUTHTOKEN=" .env | cut -d= -f2)" ]; then
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
    if docker ps --filter "name=veriscope-tunnel" --format "{{.Names}}" | grep -q "veriscope-tunnel"; then
        echo -e "${YELLOW}[WARNING]${NC} Ngrok tunnel is already running"
        tunnel_url
        return
    fi

    # Check if nginx is running (required for tunnel)
    if ! docker ps --filter "name=veriscope-nginx" --filter "status=running" --format "{{.Names}}" | grep -q "veriscope-nginx"; then
        echo_error "Nginx is not running. Please start the main services first with: $0 start"
        return 1
    fi

    # Start only the tunnel container without starting other services
    docker compose --profile tunnel up -d --no-deps tunnel

    echo_info "Waiting for tunnel to establish connection..."
    sleep 5

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
    if ! docker ps --filter "name=veriscope-tunnel" --format "{{.Names}}" | grep -q "veriscope-tunnel"; then
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
    if ! docker ps --filter "name=veriscope-tunnel" --format "{{.Names}}" | grep -q "veriscope-tunnel"; then
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
            echo_info ""
            echo_info "Continuing with HTTP-only setup..."
            return 0
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
    echo_info "  docker compose -f $COMPOSE_FILE restart nginx"
    echo_info ""
    echo_info "Your services will be available at:"
    echo_info "  Laravel: https://$VERISCOPE_SERVICE_HOST"
    echo_info "  Arena:   https://$VERISCOPE_SERVICE_HOST/arena"
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
            FULL_INSTALL_MODE=true

            echo_info "========================================="
            echo_info "  Veriscope Full Installation"
            echo_info "========================================="
            echo ""

            # Step 1: Pre-flight checks
            echo_info "Step 1/11: Running pre-flight checks..."

            # Check host dependencies first
            if ! check_host_dependencies; then
                echo_error "Host dependencies check failed - aborting installation"
                echo_info "Please install missing dependencies and try again"
                exit 1
            fi

            if ! check_docker; then
                echo_error "Docker check failed - aborting installation"
                exit 1
            fi

            if ! check_env; then
                echo_error "Environment check failed - aborting installation"
                exit 1
            fi

            # Step 2: Generate credentials
            echo_info "Step 2/11: Generating PostgreSQL credentials..."
            if ! generate_postgres_credentials; then
                echo_error "Failed to generate credentials - aborting installation"
                exit 1
            fi

            # Step 3: Build images
            echo_info "Step 3/11: Building Docker images..."
            if ! build_images; then
                echo_error "Failed to build images - aborting installation"
                exit 1
            fi

            # Step 4: Create sealer keypair
            echo_info "Step 4/11: Creating sealer keypair..."
            if ! create_sealer_keypair; then
                echo_error "Failed to create sealer keypair - aborting installation"
                exit 1
            fi

            # Step 5: SSL certificate (optional - may fail in dev mode)
            echo_info "Step 5/11: Obtaining SSL certificate..."
            if ! obtain_ssl_certificate; then
                echo_warn "SSL certificate setup skipped or failed (continuing...)"
            fi

            # Step 6: Setup nginx config
            echo_info "Step 6/11: Setting up Nginx configuration..."
            if ! setup_nginx_config; then
                echo_error "Failed to setup Nginx config - aborting installation"
                exit 1
            fi

            # Step 7: Reset volumes to ensure clean state with new credentials
            echo_info "Step 7/11: Resetting database and cache volumes..."
            if ! stop_services; then
                echo_warn "Failed to stop services cleanly - continuing..."
            fi

            # Get the project name from docker compose config
            project_name=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')

            if [ -z "$project_name" ]; then
                echo_error "Failed to determine project name - aborting installation"
                exit 1
            fi

            # Remove only postgres and redis volumes (preserve Nethermind blockchain data)
            local removed=0
            for volume in postgres_data redis_data app_data artifacts; do
                local volume_name="${project_name}_${volume}"
                if docker volume inspect "$volume_name" >/dev/null 2>&1; then
                    if docker volume rm "$volume_name" 2>/dev/null; then
                        echo_info "✓ Removed volume: $volume_name"
                        removed=$((removed + 1))
                    else
                        echo_warn "✗ Failed to remove volume: $volume_name (may not exist)"
                    fi
                fi
            done
            echo_info "Removed $removed volume(s) (Nethermind data preserved)"

            # Ensure veriscope_ta_node/.env exists as a FILE before starting services
            # Otherwise Docker will create it as a DIRECTORY when mounting volumes
            echo_info "Creating placeholder .env files for Docker volume mounts..."
            mkdir -p veriscope_ta_node
            touch veriscope_ta_node/.env
            echo_info "Placeholder .env file created (will be configured in next step)"

            # Step 8: Start services and wait for readiness
            echo_info "Step 8/11: Starting services..."
            if ! start_services; then
                echo_error "Failed to start services - aborting installation"
                exit 1
            fi

            echo_info "Waiting for services to be ready..."
            if ! wait_for_services_ready 120; then
                echo_error "Services failed to become ready - aborting installation"
                echo_info "Check service logs: docker compose -f $COMPOSE_FILE logs"
                exit 1
            fi

            # Step 9: Setup chain config AFTER volumes are reset and services are started
            echo_info "Step 9/11: Setting up chain configuration..."
            if ! setup_chain_config; then
                echo_error "Failed to setup chain config - aborting installation"
                exit 1
            fi

            # Restart ta-node to pick up artifacts
            echo_info "Restarting ta-node to load chain artifacts..."
            if ! docker compose -f "$COMPOSE_FILE" restart ta-node; then
                echo_error "Failed to restart ta-node - aborting installation"
                exit 1
            fi

            # Wait for ta-node to be ready after restart
            if ! wait_for_ta_node_ready 60; then
                echo_error "TA Node failed to restart - aborting installation"
                exit 1
            fi

            # Step 10: Laravel setup
            echo_info "Step 10/11: Running Laravel setup..."
            if ! full_laravel_setup; then
                echo_error "Laravel setup failed - aborting installation"
                exit 1
            fi

            # Step 11: Install additional components
            echo_info "Step 11/11: Installing additional components..."

            if ! install_horizon; then
                echo_warn "Horizon installation failed (continuing...)"
            fi

            if ! install_passport_env; then
                echo_warn "Passport environment setup failed (continuing...)"
            fi

            if ! install_address_proofs; then
                echo_warn "Address proofs installation failed (continuing...)"
            fi

            # Create admin (optional - interactive)
            create_admin

            echo ""
            echo_info "========================================="
            echo_info "  Full Installation Completed!"
            echo_info "========================================="
            echo ""
            echo_info "Post-installation steps:"
            echo_info "  1. Create admin user: ./docker-scripts/setup-docker.sh create-admin"
            echo_info "  2. (Optional) Download address proofs: ./docker-scripts/setup-docker.sh install-address-proofs"
            echo ""

            # Get service host from .env
            local service_host=$(grep "^VERISCOPE_SERVICE_HOST=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "localhost")
            service_host=${service_host:-localhost}

            echo_info "Access your Veriscope instance at:"
            echo_info "  - Dashboard: http://${service_host}"
            echo_info "  - Arena: http://${service_host}/arena"
            echo ""
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
            # Check host dependencies first
            if ! check_host_dependencies; then
                echo_error "Host dependencies check failed - aborting installation"
                echo_info "Please install missing dependencies and try again"
                exit 1
            fi

            check_docker
            check_env

            # Run pre-flight checks
            echo ""
            echo_info "Running pre-flight checks before installation..."
            if ! preflight_checks; then
                exit 1
            fi
            echo ""

            # Ensure veriscope_ta_node directory exists before setup_chain_config
            # Otherwise setup_chain_config will fail when trying to copy .env template
            echo_info "Creating veriscope_ta_node directory..."
            mkdir -p veriscope_ta_node

            generate_postgres_credentials
            setup_chain_config
            build_images
            create_sealer_keypair

            # Reset volumes to ensure clean state with new credentials
            echo_info "Ensuring clean database and cache volumes..."
            docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true

            # Get the project name from docker compose config
            project_name=$(docker compose -f "$COMPOSE_FILE" config --format json | jq -r '.name // "veriscope"')

            # Remove only postgres and redis volumes (preserve Nethermind blockchain data)
            docker volume rm "${project_name}_postgres_data" 2>/dev/null || true
            docker volume rm "${project_name}_redis_data" 2>/dev/null || true
            docker volume rm "${project_name}_app_data" 2>/dev/null || true
            docker volume rm "${project_name}_artifacts" 2>/dev/null || true
            echo_info "PostgreSQL, Redis, app, and artifacts volumes reset (Nethermind data preserved)"

            # Ensure veriscope_ta_node/.env exists as a FILE before starting services
            # Otherwise Docker will create it as a DIRECTORY when mounting volumes
            if [ ! -f "veriscope_ta_node/.env" ]; then
                echo_info "Creating placeholder .env file for Docker volume mount..."
                mkdir -p veriscope_ta_node
                touch veriscope_ta_node/.env
            fi

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
