#!/bin/bash
# Veriscope Docker Scripts - SSL Certificate Module
# This module provides SSL certificate management for Let's Encrypt
#
# Functions:
# - Certificate checking: check_certificate_expiry
# - Certificate operations: obtain_ssl_certificate, renew_ssl_certificate
# - Automated renewal: setup_auto_renewal

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"
source "${SCRIPT_DIR}/validators.sh"

# ============================================================================
# CERTIFICATE CHECKING
# ============================================================================

# Check if SSL certificates exist in the certbot volume
# Usage: check_ssl_cert_exists [domain] [check_both]
# Returns: 0 if certificates exist, 1 if not
check_ssl_cert_exists() {
    local domain="${1:-$VERISCOPE_SERVICE_HOST}"
    local check_both="${2:-true}"  # Check both cert and key, or just cert

    local ssl_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/${domain}/privkey.pem"

    if [ "$check_both" = "true" ]; then
        docker compose -f "${COMPOSE_FILE:-docker-compose.yml}" run --rm --entrypoint sh certbot -c "test -f '$ssl_cert' && test -f '$ssl_key'" 2>/dev/null
    else
        docker compose -f "${COMPOSE_FILE:-docker-compose.yml}" run --rm --entrypoint sh certbot -c "test -f '$ssl_cert'" 2>/dev/null
    fi

    return $?
}

# Get SSL certificate path
# Usage: get_ssl_cert_path [domain]
# Returns: path to SSL certificate
get_ssl_cert_path() {
    local domain="${1:-$VERISCOPE_SERVICE_HOST}"
    echo "/etc/letsencrypt/live/${domain}/fullchain.pem"
}

# Get SSL certificate key path
# Usage: get_ssl_key_path [domain]
# Returns: path to SSL certificate key
get_ssl_key_path() {
    local domain="${1:-$VERISCOPE_SERVICE_HOST}"
    echo "/etc/letsencrypt/live/${domain}/privkey.pem"
}

# Check SSL certificate expiry
# Displays certificate information and expiration status
check_certificate_expiry() {
    # Check if certbot volume exists and has certificates
    local project_name=$(get_project_name)

    if ! docker volume ls --format "{{.Name}}" | grep -q "${project_name}_certbot_conf"; then
        echo_info "ℹ No SSL certificates (certbot volume not found)"
        return
    fi

    # Load service host from .env
    local service_host=$(get_env_var "VERISCOPE_SERVICE_HOST")

    if [ -z "$service_host" ] || [ "$service_host" = "localhost" ] || [ "$service_host" = "127.0.0.1" ]; then
        echo_info "ℹ No SSL certificates configured (localhost deployment)"
        return
    fi

    # Check certificate using certbot
    local cert_info=$(docker compose -f "$COMPOSE_FILE" run --rm --no-deps certbot certificates 2>/dev/null | grep -A 10 "Certificate Name: $service_host")

    if [ -z "$cert_info" ]; then
        echo_warn "⚠ No certificate found for $service_host"
        return
    fi

    # Extract expiry date
    local expiry_date=$(echo "$cert_info" | grep "Expiry Date:" | sed 's/.*Expiry Date: \([^ ]*\).*/\1/')

    if [ -z "$expiry_date" ]; then
        echo_warn "⚠ Unable to parse certificate expiry date"
        return
    fi

    # Calculate days until expiry
    local expiry_epoch=$(date -j -f "%Y-%m-%d" "$expiry_date" "+%s" 2>/dev/null || date -d "$expiry_date" "+%s" 2>/dev/null)
    local current_epoch=$(date "+%s")
    local days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))

    echo_info "Certificate for: $service_host"
    echo_info "Expires on: $expiry_date"
    echo_info "Days until expiry: $days_until_expiry"

    if [ "$days_until_expiry" -lt 0 ]; then
        echo_error "✗ Certificate has EXPIRED"
    elif [ "$days_until_expiry" -lt 30 ]; then
        echo_warn "⚠ Certificate expires in less than 30 days"
    else
        echo_info "✓ Certificate is valid"
    fi
}

# ============================================================================
# CERTIFICATE OPERATIONS
# ============================================================================

# Obtain or renew SSL certificates
# Uses Let's Encrypt via certbot with webroot mode
# Returns: 0 on success, 1 on failure
obtain_ssl_certificate() {
    echo_info "Setting up SSL certificate..."

    # Load environment first to check domain
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

    # Validate domain is suitable for Let's Encrypt BEFORE any other checks
    if ! is_valid_ssl_domain "$VERISCOPE_SERVICE_HOST"; then
        echo_error "INVALID DOMAIN: '$VERISCOPE_SERVICE_HOST' cannot be used with Let's Encrypt"
        echo ""
        echo_info "Let's Encrypt SSL certificates cannot be issued for:"
        echo "  ✗ localhost or 127.0.0.1 (loopback addresses)"
        echo "  ✗ .local domains (mDNS/Bonjour)"
        echo "  ✗ .test domains (reserved for testing)"
        echo "  ✗ .example domains (documentation only)"
        echo "  ✗ .invalid or .localhost domains"
        echo "  ✗ IP addresses (e.g., 192.168.1.1)"
        echo "  ✗ Single-word hostnames without a TLD"
        echo ""
        echo_info "You need a publicly accessible domain name for SSL certificates."
        echo_info "Valid examples:"
        echo "  ✓ ta.yourdomain.com"
        echo "  ✓ veriscope.example.org"
        echo "  ✓ trustanchor.company.net"
        echo ""
        echo_info "Update VERISCOPE_SERVICE_HOST in .env and try again."
        return 1
    fi

    # Always prompt user during installation (both dev and production)
    echo_info "SSL Certificate Setup"
    echo_info "Domain: $VERISCOPE_SERVICE_HOST"
    echo ""

    if is_dev_mode; then
        echo_warn "Development mode detected - SSL is optional"
    else
        echo_info "Production mode - SSL is recommended but optional"
    fi

    echo ""
    read -p "Do you want to obtain an SSL certificate for $VERISCOPE_SERVICE_HOST? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo_info "Skipping SSL certificate setup."
        echo_info "You can obtain SSL certificates later with: ./docker-scripts/setup-docker.sh obtain-ssl"
        return 0
    fi

    # Clean up any stuck certbot containers first
    echo_info "Cleaning up any existing certbot containers..."
    docker ps -a --filter "name=certbot-run" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true

    # Ensure nginx is running to serve ACME challenges
    echo_info "Ensuring nginx container is running..."
    # Use --no-deps to avoid starting dependencies (nethermind, postgres, redis)
    if ! docker compose -f "$COMPOSE_FILE" up -d --no-deps nginx; then
        echo_error "Failed to start nginx container"
        return 1
    fi

    # Wait a moment for nginx to be ready
    sleep 2

    # Use certbot via Docker with webroot mode
    echo_info "Obtaining certificate for $VERISCOPE_SERVICE_HOST using Docker..."
    echo_warn "Make sure port 80 is accessible from the internet"

    if ! docker compose -f "$COMPOSE_FILE" run --rm \
        --entrypoint certbot \
        certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --preferred-challenges http \
        -d "$VERISCOPE_SERVICE_HOST"; then
        echo_error "Failed to obtain certificate"
        echo_info "Please ensure:"
        echo "  1. Port 80 is open and accessible"
        echo "  2. Domain $VERISCOPE_SERVICE_HOST points to this server"
        echo "  3. No other web server is using port 80"

        # Clean up any containers that might have been left
        docker ps -a --filter "name=certbot-run" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
        return 1
    fi

    # Clean up any containers that might have been left
    docker ps -a --filter "name=certbot-run" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true

    echo_info "Certificate obtained successfully"

    # Set certificate paths in .env
    local cert_dir="/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST"

    if grep -q "^SSL_CERT_PATH=" .env; then
        if ! portable_sed "s#^SSL_CERT_PATH=.*#SSL_CERT_PATH=$cert_dir/fullchain.pem#" .env; then
            echo_error "Failed to update SSL_CERT_PATH in .env"
            return 1
        fi
    else
        if ! echo "SSL_CERT_PATH=$cert_dir/fullchain.pem" >> .env; then
            echo_error "Failed to add SSL_CERT_PATH to .env"
            return 1
        fi
    fi

    if grep -q "^SSL_KEY_PATH=" .env; then
        if ! portable_sed "s#^SSL_KEY_PATH=.*#SSL_KEY_PATH=$cert_dir/privkey.pem#" .env; then
            echo_error "Failed to update SSL_KEY_PATH in .env"
            return 1
        fi
    else
        if ! echo "SSL_KEY_PATH=$cert_dir/privkey.pem" >> .env; then
            echo_error "Failed to add SSL_KEY_PATH to .env"
            return 1
        fi
    fi

    echo_info "Certificate paths saved to .env"
    echo_info "  Certificate: $cert_dir/fullchain.pem"
    echo_info "  Private Key: $cert_dir/privkey.pem"
}

# Renew SSL certificate
# Returns: 0 on success, 1 on failure
renew_ssl_certificate() {
    echo_info "Renewing SSL certificates using Docker..."

    # Check if in development mode
    if is_dev_mode; then
        echo_warn "Development mode detected - skipping SSL renewal."
        echo_info "SSL certificates are typically not used in development."
        return 0
    fi

    # Clean up any stuck certbot containers first
    echo_info "Cleaning up any existing certbot containers..."
    docker ps -a --filter "name=certbot-run" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true

    # Ensure nginx is running for webroot challenge
    echo_info "Ensuring nginx container is running..."
    if ! docker compose -f "$COMPOSE_FILE" up -d nginx; then
        echo_error "Failed to start nginx container"
        return 1
    fi

    # Wait a moment for nginx to be ready
    sleep 2

    # Run certbot renew via Docker (uses webroot mode)
    if docker compose -f "$COMPOSE_FILE" run --rm --entrypoint certbot certbot renew; then
        echo_info "Certificates renewed successfully"
        echo_info "Reloading nginx to pick up new certificates..."
        if ! docker compose -f "$COMPOSE_FILE" exec nginx nginx -s reload; then
            echo_warn "Failed to reload nginx - restart it manually if needed"

            # Clean up any containers that might have been left
            docker ps -a --filter "name=certbot-run" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
            return 1
        fi
    else
        echo_warn "Certificate renewal failed or certificates not due for renewal"
        echo_info "Certificates are typically renewed when they have 30 days or less remaining"

        # Clean up any containers that might have been left
        docker ps -a --filter "name=certbot-run" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
        return 1
    fi

    # Clean up any containers that might have been left
    docker ps -a --filter "name=certbot-run" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
}

# ============================================================================
# AUTOMATED RENEWAL
# ============================================================================

# Setup automated certificate renewal (container-based)
# Starts the certbot container with 12-hour renewal checks
# Returns: 0 on success, 1 on failure
setup_auto_renewal() {
    echo_info "Setting up automated SSL certificate renewal..."
    echo ""

    # Check if in development mode
    if is_dev_mode; then
        echo_warn "Development mode detected!"
        echo_info "Auto-renewal is typically not needed in development."
        echo ""
        read -p "Do you still want to setup auto-renewal? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo_info "Skipping auto-renewal setup."
            return 0
        fi
    fi

    echo_info "Enabling certbot auto-renewal container..."
    echo ""

    # Check if certbot container is already running
    if docker ps --filter "name=veriscope-certbot" --format "{{.Names}}" | grep -q "veriscope-certbot"; then
        echo_warn "Certbot container is already running"
        echo ""
        read -p "Do you want to restart it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo_info "Restarting certbot container..."
            docker compose -f "$COMPOSE_FILE" --profile production restart certbot
        fi
    else
        # Start certbot container with auto-renewal
        echo_info "Starting certbot container with 12-hour renewal check..."

        if docker compose -f "$COMPOSE_FILE" --profile production up -d certbot; then
            echo_info "✅ Certbot auto-renewal container started successfully"
        else
            echo_error "Failed to start certbot container"
            echo_info "Make sure nginx is running and certificates exist"
            return 1
        fi
    fi

    echo ""
    echo_info "=========================================="
    echo_info "Auto-renewal setup completed!"
    echo_info "=========================================="
    echo ""
    echo_info "Certbot Configuration:"
    echo_info "  - Renewal check interval: Every 12 hours"
    echo_info "  - Auto-renews when: < 30 days until expiry"
    echo_info "  - Certificate validity: 90 days (Let's Encrypt)"
    echo_info "  - Container name: veriscope-certbot"
    echo ""
    echo_info "Monitoring:"
    echo_info "  - View logs: docker logs veriscope-certbot"
    echo_info "  - Follow logs: docker logs -f veriscope-certbot"
    echo_info "  - Container status: docker ps --filter name=certbot"
    echo ""
    echo_info "Manual Operations:"
    echo_info "  - Force renewal: docker compose run --rm certbot renew --force-renewal"
    echo_info "  - Check expiry: docker compose run --rm certbot certificates"
    echo_info "  - Stop auto-renewal: docker compose stop certbot"
    echo ""
}
