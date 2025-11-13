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

# List of known weak/common passwords to reject
is_weak_password() {
    local password="$1"

    # List of known weak passwords
    local weak_passwords=(
        "trustanchor_dev"
        "password"
        "Password123"
        "admin"
        "trustanchor"
        "postgres"
        "root"
        "123456"
        "password123"
        "admin123"
    )

    # Check against known weak passwords
    for weak in "${weak_passwords[@]}"; do
        if [ "$password" = "$weak" ]; then
            return 0  # Is weak
        fi
    done

    return 1  # Not weak
}

# Validate password strength
# Usage: validate_password_strength "password" [min_length]
# Returns: 0 if strong enough, 1 if weak
validate_password_strength() {
    local password="$1"
    local min_length=${2:-16}

    # Check if password is empty
    if [ -z "$password" ]; then
        echo_error "Password cannot be empty"
        return 1
    fi

    # Check against known weak passwords
    if is_weak_password "$password"; then
        echo_error "Password is a commonly used weak password"
        return 1
    fi

    # Check minimum length
    if [ ${#password} -lt $min_length ]; then
        echo_error "Password must be at least $min_length characters (got ${#password})"
        return 1
    fi

    # Check for at least one number (optional but recommended)
    if ! [[ "$password" =~ [0-9] ]]; then
        echo_warn "Password should contain at least one number"
    fi

    # Check for at least one letter (optional but recommended)
    if ! [[ "$password" =~ [a-zA-Z] ]]; then
        echo_warn "Password should contain at least one letter"
    fi

    return 0
}

# Validate PostgreSQL password with environment-aware rules
# Usage: validate_postgres_password "password"
# Returns: 0 if valid, 1 if invalid
validate_postgres_password() {
    local password="$1"

    # In production, enforce strict password requirements
    if ! is_dev_mode; then
        echo_info "Production mode detected - enforcing strict password requirements"

        # Check for weak passwords
        if is_weak_password "$password"; then
            echo_error "SECURITY: Weak password detected in production mode"
            echo_error "Password '$password' is not allowed in production"
            echo_info "Use: ./docker-scripts/setup-docker.sh to generate a secure password"
            return 1
        fi

        # Enforce minimum 20 characters in production
        if ! validate_password_strength "$password" 20; then
            echo_error "SECURITY: Password does not meet production requirements"
            echo_info "Production passwords must be:"
            echo "  - At least 20 characters long"
            echo "  - Not a common/weak password"
            echo "  - Contain numbers and letters"
            return 1
        fi
    else
        # In development, just warn about weak passwords
        if is_weak_password "$password"; then
            echo_warn "Development mode: Using weak password '$password'"
            echo_warn "This would be rejected in production mode"
        elif ! validate_password_strength "$password" 12; then
            echo_warn "Development mode: Password is weak but allowed"
            echo_warn "This would be rejected in production mode"
        fi
    fi

    return 0
}

# Check if a container is running
# Usage: is_container_running "container_name"
# Returns: 0 if running, 1 if not
is_container_running() {
    local container_name="$1"

    if [ -z "$container_name" ]; then
        return 1
    fi

    if docker-compose -f "$COMPOSE_FILE" ps "$container_name" 2>/dev/null | grep -q "Up"; then
        return 0
    else
        return 1
    fi
}

# Wait for PostgreSQL to be ready to accept connections
# Usage: wait_for_postgres_ready [timeout_seconds]
# Returns: 0 if ready, 1 if timeout
wait_for_postgres_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for PostgreSQL to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U trustanchor >/dev/null 2>&1; then
            echo_info "PostgreSQL is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for PostgreSQL to be ready"
    return 1
}

# Wait for Redis to be ready to accept connections
# Usage: wait_for_redis_ready [timeout_seconds]
# Returns: 0 if ready, 1 if timeout
wait_for_redis_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for Redis to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if docker-compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
            echo_info "Redis is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for Redis to be ready"
    return 1
}

# Wait for Laravel app to be ready
# Usage: wait_for_app_ready [timeout_seconds]
# Returns: 0 if ready, 1 if timeout
wait_for_app_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for Laravel app to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if is_container_running "app"; then
            # Check if artisan is accessible
            if docker-compose -f "$COMPOSE_FILE" exec -T app php artisan --version >/dev/null 2>&1; then
                echo_info "Laravel app is ready"
                return 0
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for Laravel app to be ready"
    return 1
}

# Wait for TA Node to be ready
# Usage: wait_for_ta_node_ready [timeout_seconds]
# Returns: 0 if ready, 1 if timeout
wait_for_ta_node_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for TA Node to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if is_container_running "ta-node"; then
            # Check if node process is running
            if docker-compose -f "$COMPOSE_FILE" exec -T ta-node sh -c "pgrep -f node" >/dev/null 2>&1; then
                echo_info "TA Node is ready"
                return 0
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for TA Node to be ready"
    return 1
}

# Wait for multiple services to be ready
# Usage: wait_for_services_ready [timeout_seconds]
# Returns: 0 if all ready, 1 if any timeout
wait_for_services_ready() {
    local timeout=${1:-120}
    local all_ready=true

    echo_info "Waiting for all services to be ready (timeout: ${timeout}s)..."

    # Wait for each service with individual timeouts
    if ! wait_for_postgres_ready $timeout; then
        all_ready=false
    fi

    if ! wait_for_redis_ready $timeout; then
        all_ready=false
    fi

    if ! wait_for_app_ready $timeout; then
        all_ready=false
    fi

    if ! wait_for_ta_node_ready $timeout; then
        all_ready=false
    fi

    if [ "$all_ready" = false ]; then
        echo_error "Some services failed to become ready"
        return 1
    fi

    echo_info "All services are ready"
    return 0
}

# Validate if a domain is suitable for Let's Encrypt SSL certificates
# Usage: is_valid_ssl_domain "domain.com"
# Returns: 0 if valid, 1 if invalid
is_valid_ssl_domain() {
    local domain="$1"

    # Empty domain
    if [ -z "$domain" ]; then
        return 1
    fi

    # Check for localhost and loopback addresses
    if [[ "$domain" =~ ^(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        return 1
    fi

    # Check for .local domains (mDNS)
    if [[ "$domain" =~ \.local$ ]]; then
        return 1
    fi

    # Check for .test domains (reserved for testing)
    if [[ "$domain" =~ \.test$ ]]; then
        return 1
    fi

    # Check for .example domains (documentation)
    if [[ "$domain" =~ \.example$ ]]; then
        return 1
    fi

    # Check for .invalid domains (RFC 2606)
    if [[ "$domain" =~ \.invalid$ ]]; then
        return 1
    fi

    # Check for .localhost domains
    if [[ "$domain" =~ \.localhost$ ]]; then
        return 1
    fi

    # Check for IP addresses (Let's Encrypt doesn't support IP addresses)
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi

    # Check for basic domain format (must have at least one dot)
    if [[ ! "$domain" =~ \. ]]; then
        return 1
    fi

    # Domain appears valid for Let's Encrypt
    return 0
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

# Pre-flight checks for system readiness
preflight_checks() {
    echo_info "Running pre-flight system checks..."
    echo ""

    local all_checks_passed=true

    # 1. Check Docker daemon
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1. Docker Daemon Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if docker info >/dev/null 2>&1; then
        echo_info "✓ Docker daemon is running"
    else
        echo_error "✗ Docker daemon is not running"
        echo_info "  Start Docker: sudo systemctl start docker (Linux) or Docker Desktop (macOS)"
        all_checks_passed=false
    fi
    echo ""

    # 2. Check required ports
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "2. Port Availability"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local ports=(80 443 5432 6379 8545)
    local port_names=("HTTP" "HTTPS" "PostgreSQL" "Redis" "Nethermind RPC")
    local port_failed=false

    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local name="${port_names[$i]}"

        if check_port_available "$port"; then
            echo_info "✓ Port $port ($name) is available"
        else
            echo_error "✗ Port $port ($name) is already in use"
            echo_info "  Process using port: $(get_port_process $port)"
            port_failed=true
            all_checks_passed=false
        fi
    done

    if [ "$port_failed" = false ]; then
        echo_info "All required ports are available"
    fi
    echo ""

    # 3. Check disk space
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "3. Disk Space"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local available_space_gb=$(get_available_disk_space_gb "$PROJECT_ROOT")
    local min_required_gb=20
    local recommended_gb=50

    echo_info "Available space: ${available_space_gb}GB"

    if [ "$available_space_gb" -lt "$min_required_gb" ]; then
        echo_error "✗ Insufficient disk space (minimum: ${min_required_gb}GB)"
        all_checks_passed=false
    elif [ "$available_space_gb" -lt "$recommended_gb" ]; then
        echo_warn "⚠ Disk space is below recommended (recommended: ${recommended_gb}GB)"
    else
        echo_info "✓ Sufficient disk space available"
    fi
    echo ""

    # 4. Check network connectivity
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "4. Network Connectivity"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check internet connectivity
    if check_internet_connectivity; then
        echo_info "✓ Internet connectivity is available"
    else
        echo_warn "⚠ No internet connectivity detected"
        echo_info "  Some features may not work (SSL certs, Docker pulls, etc.)"
    fi

    # Check DNS resolution
    if check_dns_resolution "github.com"; then
        echo_info "✓ DNS resolution is working"
    else
        echo_error "✗ DNS resolution failed"
        all_checks_passed=false
    fi

    # Check Docker Hub connectivity
    if check_docker_hub_connectivity; then
        echo_info "✓ Docker Hub is reachable"
    else
        echo_warn "⚠ Docker Hub is not reachable"
        echo_info "  Docker image pulls may fail"
    fi
    echo ""

    # 5. Check Docker resources
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "5. Docker Resources"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local docker_disk_usage=$(docker system df --format "{{.Type}}\t{{.Size}}" 2>/dev/null | grep "Total" | awk '{print $2}' || echo "Unknown")
    echo_info "Current Docker disk usage: $docker_disk_usage"

    # Check if Docker has enough memory (if available)
    local docker_memory=$(docker info --format '{{.MemTotal}}' 2>/dev/null)
    if [ ! -z "$docker_memory" ] && [ "$docker_memory" != "0" ]; then
        local memory_gb=$((docker_memory / 1024 / 1024 / 1024))
        echo_info "Docker memory limit: ${memory_gb}GB"
        if [ "$memory_gb" -lt 4 ]; then
            echo_warn "⚠ Docker memory is low (recommended: 4GB+)"
        else
            echo_info "✓ Docker memory is adequate"
        fi
    fi
    echo ""

    # 6. Check for conflicting containers
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "6. Existing Containers"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local running_containers=$(docker ps --filter "name=veriscope-" --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' ')
    local all_containers=$(docker ps -a --filter "name=veriscope-" --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$running_containers" -gt 0 ]; then
        echo_warn "⚠ Found $running_containers running Veriscope container(s)"
        docker ps --filter "name=veriscope-" --format "  - {{.Names}} ({{.Status}})"
    else
        echo_info "✓ No running Veriscope containers"
    fi

    if [ "$all_containers" -gt 0 ] && [ "$running_containers" -eq 0 ]; then
        echo_info "  Found $all_containers stopped container(s) - will be removed on fresh install"
    fi
    echo ""

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Pre-flight Check Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$all_checks_passed" = true ]; then
        echo_info "✅ All critical checks passed - system is ready!"
        echo ""
        return 0
    else
        echo_error "❌ Some critical checks failed"
        echo_warn "Please resolve the issues above before continuing"
        echo ""
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo_info "Installation cancelled"
            return 1
        fi
        return 0
    fi
}

# Check if a port is available
check_port_available() {
    local port=$1

    # Use lsof if available (macOS/Linux)
    if command -v lsof &> /dev/null; then
        ! lsof -iTCP:$port -sTCP:LISTEN -t >/dev/null 2>&1
    # Fallback to netstat (Linux)
    elif command -v netstat &> /dev/null; then
        ! netstat -tuln 2>/dev/null | grep -q ":$port "
    # Fallback to ss (modern Linux)
    elif command -v ss &> /dev/null; then
        ! ss -tuln 2>/dev/null | grep -q ":$port "
    else
        # Can't check, assume available
        return 0
    fi
}

# Get process using a port
get_port_process() {
    local port=$1

    if command -v lsof &> /dev/null; then
        lsof -iTCP:$port -sTCP:LISTEN -n -P 2>/dev/null | tail -n +2 | awk '{print $1 " (PID: " $2 ")"}'
    elif command -v netstat &> /dev/null; then
        netstat -tulnp 2>/dev/null | grep ":$port " | awk '{print $7}'
    else
        echo "Unknown"
    fi
}

# Get available disk space in GB
get_available_disk_space_gb() {
    local path=$1

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        df -Pk "$path" | tail -1 | awk '{print int($4/1024/1024)}'
    else
        # Linux
        df -BG "$path" | tail -1 | awk '{print int($4)}'
    fi
}

# Check internet connectivity
check_internet_connectivity() {
    # Use timeout if available, otherwise use ping timeout flag
    if command -v timeout &> /dev/null; then
        timeout 3 ping -c 1 8.8.8.8 >/dev/null 2>&1 || \
        timeout 3 ping -c 1 1.1.1.1 >/dev/null 2>&1
    else
        # macOS and systems without timeout command
        ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 || \
        ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1
    fi
}

# Check DNS resolution
check_dns_resolution() {
    local host=$1

    # Try nslookup first
    if command -v nslookup &> /dev/null; then
        nslookup "$host" >/dev/null 2>&1
    # Fallback to host
    elif command -v host &> /dev/null; then
        host "$host" >/dev/null 2>&1
    # Fallback to dig
    elif command -v dig &> /dev/null; then
        dig +short "$host" >/dev/null 2>&1
    else
        # Can't check, assume OK
        return 0
    fi
}

# Check Docker Hub connectivity
check_docker_hub_connectivity() {
    if command -v timeout &> /dev/null; then
        timeout 5 curl -s -o /dev/null -w "%{http_code}" https://hub.docker.com/ 2>/dev/null | grep -q "200"
    else
        # macOS and systems without timeout - use curl's max-time
        curl --max-time 5 -s -o /dev/null -w "%{http_code}" https://hub.docker.com/ 2>/dev/null | grep -q "200"
    fi
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
    if ! docker-compose -f "$COMPOSE_FILE" build; then
        echo_error "Failed to build Docker images"
        return 1
    fi
    echo_info "Docker images built successfully"
}

# Start all services
start_services() {
    echo_info "Starting Veriscope services..."
    if ! docker-compose -f "$COMPOSE_FILE" up -d; then
        echo_error "Failed to start services"
        return 1
    fi
    echo_info "Services started. Use 'docker-compose -f $COMPOSE_FILE ps' to check status"
}

# Stop all services
stop_services() {
    echo_info "Stopping Veriscope services..."
    if ! docker-compose -f "$COMPOSE_FILE" down; then
        echo_error "Failed to stop services"
        return 1
    fi
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
    echo_info "Stopping services..."
    if ! docker-compose -f "$COMPOSE_FILE" down; then
        echo_warn "Failed to stop services cleanly, continuing..."
    fi

    # Get the project name from docker-compose config
    local project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')

    if [ -z "$project_name" ]; then
        echo_error "Failed to determine project name"
        return 1
    fi

    # Remove only postgres and redis volumes (keep Nethermind)
    local removed=0
    local failed=0

    for volume in postgres_data redis_data app_data artifacts; do
        local volume_name="${project_name}_${volume}"
        if docker volume inspect "$volume_name" >/dev/null 2>&1; then
            if docker volume rm "$volume_name" 2>/dev/null; then
                echo_info "✓ Removed volume: $volume_name"
                removed=$((removed + 1))
            else
                echo_warn "✗ Failed to remove volume: $volume_name (may be in use)"
                failed=$((failed + 1))
            fi
        else
            echo_info "  Volume does not exist: $volume_name"
        fi
    done

    if [ $failed -gt 0 ]; then
        echo_error "$failed volume(s) could not be removed"
        echo_info "Make sure all containers are stopped: docker-compose -f $COMPOSE_FILE down"
        return 1
    fi

    echo_info "Successfully removed $removed volume(s)"
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
            docker volume rm "${project_name}_certbot_conf" 2>/dev/null || true
            docker volume rm "${project_name}_certbot_www" 2>/dev/null || true
            docker volume rm "${project_name}_app_data" 2>/dev/null || true
            docker volume rm "${project_name}_artifacts" 2>/dev/null || true
            echo_info "All volumes removed"
            ;;
        2)
            echo_warn "Removing PostgreSQL and Redis volumes (preserving Nethermind)..."
            docker volume rm "${project_name}_postgres_data" 2>/dev/null || true
            docker volume rm "${project_name}_redis_data" 2>/dev/null || true
            docker volume rm "${project_name}_app_data" 2>/dev/null || true
            docker volume rm "${project_name}_artifacts" 2>/dev/null || true
            echo_info "Database, Redis, app, and artifacts volumes removed (Nethermind preserved)"
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
    if ! docker-compose -f "$COMPOSE_FILE" restart; then
        echo_error "Failed to restart services"
        return 1
    fi
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
    if ! docker-compose -f "$COMPOSE_FILE" exec app php artisan migrate --force; then
        echo_error "Failed to initialize database"
        return 1
    fi
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
    if ! docker-compose -f "$COMPOSE_FILE" exec app php artisan migrate --force; then
        echo_error "Failed to run migrations"
        return 1
    fi
    echo_info "Migrations completed"
}

# Clear Laravel cache
clear_cache() {
    echo_info "Clearing Laravel cache..."

    if ! is_container_running "app"; then
        echo_error "Laravel app container is not running"
        return 1
    fi

    local failed=false

    if ! docker-compose -f "$COMPOSE_FILE" exec app php artisan cache:clear; then
        echo_warn "Failed to clear application cache"
        failed=true
    fi

    if ! docker-compose -f "$COMPOSE_FILE" exec app php artisan config:clear; then
        echo_warn "Failed to clear config cache"
        failed=true
    fi

    if ! docker-compose -f "$COMPOSE_FILE" exec app php artisan route:clear; then
        echo_warn "Failed to clear route cache"
        failed=true
    fi

    if ! docker-compose -f "$COMPOSE_FILE" exec app php artisan view:clear; then
        echo_warn "Failed to clear view cache"
        failed=true
    fi

    if [ "$failed" = true ]; then
        echo_error "Some cache clear operations failed"
        return 1
    fi

    echo_info "Cache cleared"
}

# Install Node.js dependencies
install_node_deps() {
    echo_info "Installing Node.js dependencies..."

    if ! is_container_running "ta-node"; then
        echo_error "TA Node container is not running"
        return 1
    fi

    if ! docker-compose -f "$COMPOSE_FILE" exec ta-node sh -c "cd /app && npm install --legacy-peer-deps"; then
        echo_error "Failed to install Node.js dependencies"
        return 1
    fi

    echo_info "Node.js dependencies installed"
}

# Install Laravel dependencies
install_laravel_deps() {
    echo_info "Installing Laravel dependencies..."

    if ! is_container_running "app"; then
        echo_error "Laravel app container is not running"
        return 1
    fi

    if ! docker-compose -f "$COMPOSE_FILE" exec app composer install; then
        echo_error "Failed to install Laravel dependencies"
        return 1
    fi

    echo_info "Laravel dependencies installed"
}

# Health check
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

        if docker-compose -f "$COMPOSE_FILE" ps "$container" 2>/dev/null | grep -q "Up"; then
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
    if docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U trustanchor >/dev/null 2>&1; then
        echo_info "✓ PostgreSQL is accepting connections"
    else
        echo_error "✗ PostgreSQL is not ready"
        all_healthy=false
    fi

    # Redis
    if docker-compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        echo_info "✓ Redis is responding"
    else
        echo_error "✗ Redis is not responding"
        all_healthy=false
    fi

    # Laravel
    if docker-compose -f "$COMPOSE_FILE" exec -T app php artisan --version >/dev/null 2>&1; then
        echo_info "✓ Laravel app is functional"
    else
        echo_error "✗ Laravel app is not functional"
        all_healthy=false
    fi

    # TA Node
    if docker-compose -f "$COMPOSE_FILE" exec -T ta-node node --version >/dev/null 2>&1; then
        echo_info "✓ TA Node is functional"
    else
        echo_error "✗ TA Node is not functional"
        all_healthy=false
    fi

    # Nginx
    local nginx_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null || echo "000")
    if [ "$nginx_status" = "200" ] || [ "$nginx_status" = "302" ] || [ "$nginx_status" = "401" ]; then
        echo_info "✓ Nginx is serving (HTTP $nginx_status)"
    else
        echo_error "✗ Nginx is not responding (HTTP $nginx_status)"
        all_healthy=false
    fi
    echo ""

    # 3. Blockchain Sync Status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "3. Blockchain Sync Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    check_blockchain_sync
    echo ""

    # 4. SSL Certificate Status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "4. SSL Certificate Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    check_certificate_expiry
    echo ""

    # 5. Disk Space
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "5. Disk Space"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local available_space=$(get_available_disk_space_gb "$PROJECT_ROOT")
    echo_info "Available disk space: ${available_space}GB"

    if [ "$available_space" -lt 10 ]; then
        echo_error "✗ Critical: Less than 10GB available"
        all_healthy=false
    elif [ "$available_space" -lt 20 ]; then
        echo_warn "⚠ Warning: Less than 20GB available"
    else
        echo_info "✓ Disk space is adequate"
    fi
    echo ""

    # 6. Docker Resources
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "6. Docker Resources"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Docker disk usage
    local docker_usage=$(docker system df --format "{{.Type}}\t{{.Size}}" 2>/dev/null | grep "Total" | awk '{print $2}' || echo "Unknown")
    echo_info "Docker disk usage: $docker_usage"

    # Volume sizes
    local project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')
    echo_info "Volume sizes:"
    docker volume ls --filter "name=${project_name}_" --format "  {{.Name}}" 2>/dev/null | while read vol; do
        if [ ! -z "$vol" ]; then
            local size=$(docker system df -v 2>/dev/null | grep "$vol" | awk '{print $3}' || echo "?")
            echo "    - $vol: $size"
        fi
    done
    echo ""

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Health Check Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$all_healthy" = true ]; then
        echo_info "✅ All critical systems are healthy"
        return 0
    else
        echo_error "❌ Some systems are unhealthy"
        echo_warn "Review the issues above and take corrective action"
        return 1
    fi
}

# Check blockchain synchronization status
check_blockchain_sync() {
    if ! docker-compose -f "$COMPOSE_FILE" ps nethermind 2>/dev/null | grep -q "Up"; then
        echo_warn "⚠ Nethermind is not running"
        return
    fi

    # Get project name and network for Docker networking
    local project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')
    local network_name="${project_name}_veriscope"

    # Query Nethermind RPC - use temporary Alpine container with curl
    # This works even if Nethermind container doesn't have curl installed
    rpc_query() {
        local method=$1
        docker run --rm --network "$network_name" alpine sh -c \
            "apk add -q curl >/dev/null 2>&1 && curl -m 5 -s -X POST -H 'Content-Type: application/json' \
            -d '{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}' \
            http://nethermind:8545" 2>/dev/null
    }

    # Get sync status
    local sync_response=$(rpc_query "eth_syncing")
    local sync_status=$(echo "$sync_response" | grep -o '"result":[^,}]*' | cut -d: -f2)

    # Get peer count
    local peer_response=$(rpc_query "net_peerCount")
    local peer_count=$(echo "$peer_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

    # Convert hex peer count to decimal
    if [ ! -z "$peer_count" ] && [ "$peer_count" != "null" ]; then
        peer_count=$((16#${peer_count#0x}))
    else
        peer_count="?"
    fi

    # Get current block number
    local block_response=$(rpc_query "eth_blockNumber")
    local current_block=$(echo "$block_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

    if [ ! -z "$current_block" ] && [ "$current_block" != "null" ]; then
        current_block=$((16#${current_block#0x}))
    else
        current_block="?"
    fi

    echo_info "Current block: $current_block"
    echo_info "Connected peers: $peer_count"

    # Check if we got valid responses
    if [ "$current_block" = "?" ] && [ "$peer_count" = "?" ]; then
        echo_error "✗ Unable to query Nethermind RPC"
        echo_info "  Possible issues:"
        echo_info "    - Nethermind is still starting up"
        echo_info "    - RPC port 8545 is not accessible"
        echo_info "    - Network connectivity issues"
        return
    fi

    if [ "$sync_status" = "false" ]; then
        echo_info "✓ Blockchain is fully synchronized"
    elif [ -z "$sync_status" ] || [ "$sync_status" = "null" ]; then
        if [ "$current_block" != "?" ]; then
            echo_info "✓ Nethermind is responding (sync status unknown)"
        else
            echo_warn "⚠ Unable to determine sync status"
        fi
    else
        # Parse sync progress if syncing
        echo_warn "⚠ Blockchain is syncing..."

        # Try to extract current and highest block from sync status
        local highest_block=$(echo "$sync_status" | grep -o '"highestBlock":"[^"]*"' | cut -d'"' -f4)
        if [ ! -z "$highest_block" ] && [ "$highest_block" != "null" ]; then
            highest_block=$((16#${highest_block#0x}))
            if [ "$current_block" != "?" ] && [ "$highest_block" -gt 0 ]; then
                local sync_percent=$((current_block * 100 / highest_block))
                echo_info "  Progress: $sync_percent% ($current_block / $highest_block)"
            fi
        fi
    fi

    # Warn if no peers
    if [ "$peer_count" = "0" ]; then
        echo_error "✗ No peers connected - node is isolated"
    elif [ "$peer_count" = "?" ]; then
        echo_warn "⚠ Unable to determine peer count"
    fi
}

# Check SSL certificate expiry
check_certificate_expiry() {
    # Check if certbot volume exists and has certificates
    local project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')

    if ! docker volume ls --format "{{.Name}}" | grep -q "${project_name}_certbot_conf"; then
        echo_info "ℹ No SSL certificates (certbot volume not found)"
        return
    fi

    # Load service host from .env
    local service_host=""
    if [ -f ".env" ]; then
        service_host=$(grep "^VERISCOPE_SERVICE_HOST=" .env 2>/dev/null | cut -d= -f2)
    fi

    if [ -z "$service_host" ] || [ "$service_host" = "localhost" ] || [ "$service_host" = "127.0.0.1" ]; then
        echo_info "ℹ No SSL certificates configured (localhost deployment)"
        return
    fi

    # Check certificate using certbot
    local cert_info=$(docker-compose -f "$COMPOSE_FILE" run --rm --no-deps certbot certificates 2>/dev/null | grep -A 10 "Certificate Name: $service_host")

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
        echo_warn "  Run: ./docker-scripts/setup-docker.sh renew-ssl"
    elif [ "$days_until_expiry" -lt 7 ]; then
        echo_error "✗ Certificate expires in $days_until_expiry days (critical)"
        echo_warn "  Run: ./docker-scripts/setup-docker.sh renew-ssl"
    elif [ "$days_until_expiry" -lt 30 ]; then
        echo_warn "⚠ Certificate expires in $days_until_expiry days"
        echo_info "  Renewal will happen automatically"
    else
        echo_info "✓ Certificate is valid ($days_until_expiry days remaining)"
    fi

    # Check if auto-renewal is enabled
    if docker ps --filter "name=veriscope-certbot" --format "{{.Names}}" | grep -q "veriscope-certbot"; then
        echo_info "✓ Auto-renewal is enabled"
    else
        echo_warn "⚠ Auto-renewal is not running"
        echo_info "  Enable: ./docker-scripts/setup-docker.sh setup-auto-renewal"
    fi
}

# Start ngrok tunnel for remote access
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
    docker-compose --profile tunnel up -d --no-deps tunnel

    echo_info "Waiting for tunnel to establish connection..."
    sleep 5

    tunnel_url
}

# Stop ngrok tunnel
tunnel_stop() {
    echo_info "Stopping ngrok tunnel..."
    docker-compose --profile tunnel stop tunnel
    docker-compose --profile tunnel rm -f tunnel
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

# Backup database (delegates to modules/backup-restore.sh)
backup_database() {
    "$PROJECT_ROOT/docker-scripts/modules/backup-restore.sh" backup-db
}

# Restore database (delegates to modules/backup-restore.sh)
restore_database() {
    local backup_file=$1
    if [ -z "$backup_file" ]; then
        echo_error "Backup file not specified"
        return 1
    fi
    "$PROJECT_ROOT/docker-scripts/modules/backup-restore.sh" restore-db "$backup_file"
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
    if ! docker-compose -f "$COMPOSE_FILE" exec app php artisan db:seed --force; then
        echo_error "Failed to seed database"
        return 1
    fi
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

# Synchronize webhook secret between ta_node and dashboard
# This function ensures both .env files have the same WEBHOOK_CLIENT_SECRET
sync_webhook_secret() {
    echo_info "Synchronizing webhook secret..."

    local node_env="veriscope_ta_node/.env"
    local dashboard_env="veriscope_ta_dashboard/.env"
    local webhook_secret=""
    local source_file=""

    # Check if files exist
    if [ ! -f "$node_env" ]; then
        echo_error "TA Node .env not found: $node_env"
        echo_info "Please run setup-chain first"
        return 1
    fi

    if [ ! -f "$dashboard_env" ]; then
        echo_warn "Dashboard .env not found: $dashboard_env"
        echo_info "Webhook secret will only be set in TA Node"
    fi

    # Step 1: Determine source of truth for the secret
    # Priority: 1) Existing ta_node secret, 2) Existing dashboard secret, 3) Generate new

    # Try to extract from ta_node (supports both quoted and unquoted)
    if grep -q "^WEBHOOK_CLIENT_SECRET=" "$node_env"; then
        webhook_secret=$(grep "^WEBHOOK_CLIENT_SECRET=" "$node_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
        if [ ! -z "$webhook_secret" ]; then
            source_file="ta_node"
            echo_info "Found existing webhook secret in TA Node"
        fi
    fi

    # If empty, try dashboard
    if [ -z "$webhook_secret" ] && [ -f "$dashboard_env" ]; then
        if grep -q "^WEBHOOK_CLIENT_SECRET=" "$dashboard_env"; then
            webhook_secret=$(grep "^WEBHOOK_CLIENT_SECRET=" "$dashboard_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
            if [ ! -z "$webhook_secret" ]; then
                source_file="dashboard"
                echo_info "Found existing webhook secret in Dashboard"
            fi
        fi
    fi

    # If still empty, generate new
    if [ -z "$webhook_secret" ]; then
        webhook_secret=$(openssl rand -hex 32 2>/dev/null || xxd -l 32 -p /dev/urandom | tr -d '\n')
        if [ -z "$webhook_secret" ]; then
            echo_error "Failed to generate webhook secret"
            return 1
        fi
        source_file="generated"
        echo_info "Generated new webhook secret"
    fi

    # Validate secret format (should be hex, at least 32 chars)
    if [ ${#webhook_secret} -lt 32 ]; then
        echo_error "Webhook secret is too short (${#webhook_secret} chars, minimum 32)"
        return 1
    fi

    # Step 2: Update ta_node .env with validation
    echo_info "Updating TA Node .env..."
    if ! update_env_variable "$node_env" "WEBHOOK_CLIENT_SECRET" "$webhook_secret"; then
        echo_error "Failed to update TA Node .env"
        return 1
    fi

    # Verify ta_node update
    local node_verify=$(grep "^WEBHOOK_CLIENT_SECRET=" "$node_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
    if [ "$node_verify" != "$webhook_secret" ]; then
        echo_error "TA Node .env verification failed - secret mismatch"
        return 1
    fi

    # Step 3: Update dashboard .env if it exists
    if [ -f "$dashboard_env" ]; then
        echo_info "Updating Dashboard .env..."
        if ! update_env_variable "$dashboard_env" "WEBHOOK_CLIENT_SECRET" "$webhook_secret"; then
            echo_error "Failed to update Dashboard .env"
            return 1
        fi

        # Verify dashboard update
        local dashboard_verify=$(grep "^WEBHOOK_CLIENT_SECRET=" "$dashboard_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
        if [ "$dashboard_verify" != "$webhook_secret" ]; then
            echo_error "Dashboard .env verification failed - secret mismatch"
            return 1
        fi

        echo_info "✓ Webhook secret synchronized successfully"
        echo_info "  Secret length: ${#webhook_secret} characters"
        echo_info "  Source: $source_file"
    else
        echo_warn "✓ Webhook secret set in TA Node only (Dashboard .env not found)"
    fi

    return 0
}

# Update or add an environment variable in a .env file
# Usage: update_env_variable <file> <key> <value>
update_env_variable() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    if [ ! -f "$env_file" ]; then
        echo_error "Environment file not found: $env_file"
        return 1
    fi

    # Escape special characters in value for sed
    local escaped_value=$(printf '%s\n' "$value" | sed 's/[[\.*^$/]/\\&/g')

    # Check if key exists
    if grep -q "^${key}=" "$env_file"; then
        # Update existing key (supports quoted and unquoted)
        portable_sed "s|^${key}=.*|${key}=\"${escaped_value}\"|" "$env_file"
    else
        # Add new key with quotes
        echo "${key}=\"${value}\"" >> "$env_file"
    fi

    # Verify the update
    if ! grep -q "^${key}=" "$env_file"; then
        echo_error "Failed to update ${key} in ${env_file}"
        return 1
    fi

    return 0
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

        # Update or add TRUST_ANCHOR_ACCOUNT
        if grep -q "^TRUST_ANCHOR_ACCOUNT=" veriscope_ta_node/.env; then
            portable_sed "s#^TRUST_ANCHOR_ACCOUNT=.*#TRUST_ANCHOR_ACCOUNT=$address#" veriscope_ta_node/.env
        else
            echo "TRUST_ANCHOR_ACCOUNT=$address" >> veriscope_ta_node/.env
        fi

        # Update or add TRUST_ANCHOR_PK
        if grep -q "^TRUST_ANCHOR_PK=" veriscope_ta_node/.env; then
            portable_sed "s#^TRUST_ANCHOR_PK=.*#TRUST_ANCHOR_PK=$privatekey#" veriscope_ta_node/.env
        else
            echo "TRUST_ANCHOR_PK=$privatekey" >> veriscope_ta_node/.env
        fi

        # Update or add TRUST_ANCHOR_PREFNAME from VERISCOPE_COMMON_NAME
        if [ ! -z "$VERISCOPE_COMMON_NAME" ] && [ "$VERISCOPE_COMMON_NAME" != "unset" ]; then
            if grep -q "^TRUST_ANCHOR_PREFNAME=" veriscope_ta_node/.env; then
                portable_sed "s#^TRUST_ANCHOR_PREFNAME=.*#TRUST_ANCHOR_PREFNAME=\"$VERISCOPE_COMMON_NAME\"#" veriscope_ta_node/.env
            else
                echo "TRUST_ANCHOR_PREFNAME=\"$VERISCOPE_COMMON_NAME\"" >> veriscope_ta_node/.env
            fi
            echo_info "Set TRUST_ANCHOR_PREFNAME to: $VERISCOPE_COMMON_NAME"
        else
            echo_warn "VERISCOPE_COMMON_NAME not set - please manually set TRUST_ANCHOR_PREFNAME in veriscope_ta_node/.env"
        fi


        echo_info "Trust Anchor credentials saved (visible in container via bind mount)"

        # Synchronize webhook secret between ta_node and dashboard
        sync_webhook_secret
    else
        echo_warn "veriscope_ta_node/.env not found. Please run setup-chain first."
    fi
}

# Obtain or renew SSL certificates
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

    # Check if in development mode (inform but don't block if they have a real domain)
    if is_dev_mode; then
        echo_warn "Development mode detected!"
        echo_info "Current settings:"
        echo "  - Compose file: $COMPOSE_FILE"
        echo "  - Host: $VERISCOPE_SERVICE_HOST"
        echo "  - APP_ENV: ${APP_ENV:-not set}"
        echo ""
        echo_warn "SSL certificates are typically not needed in development."
        echo_info "However, you have a valid domain configured."
        echo ""
        read -p "Do you want to obtain an SSL certificate for $VERISCOPE_SERVICE_HOST? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo_info "Skipping SSL certificate setup."
            return 0
        fi
    fi

    # Ensure nginx is running to serve ACME challenges
    echo_info "Ensuring nginx container is running..."
    if ! docker-compose -f "$COMPOSE_FILE" up -d nginx; then
        echo_error "Failed to start nginx container"
        return 1
    fi

    # Wait a moment for nginx to be ready
    sleep 2

    # Use certbot via Docker with webroot mode
    echo_info "Obtaining certificate for $VERISCOPE_SERVICE_HOST using Docker..."
    echo_warn "Make sure port 80 is accessible from the internet"

    if ! docker-compose -f "$COMPOSE_FILE" run --rm \
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
        return 1
    fi

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
renew_ssl_certificate() {
    echo_info "Renewing SSL certificates using Docker..."

    # Check if in development mode
    if is_dev_mode; then
        echo_warn "Development mode detected - skipping SSL renewal."
        echo_info "SSL certificates are typically not used in development."
        return 0
    fi

    # Ensure nginx is running for webroot challenge
    echo_info "Ensuring nginx container is running..."
    if ! docker-compose -f "$COMPOSE_FILE" up -d nginx; then
        echo_error "Failed to start nginx container"
        return 1
    fi

    # Wait a moment for nginx to be ready
    sleep 2

    # Run certbot renew via Docker (uses webroot mode)
    if docker-compose -f "$COMPOSE_FILE" run --rm certbot renew; then
        echo_info "Certificates renewed successfully"
        echo_info "Reloading nginx to pick up new certificates..."
        if ! docker-compose -f "$COMPOSE_FILE" exec nginx nginx -s reload; then
            echo_warn "Failed to reload nginx - restart it manually if needed"
            return 1
        fi
    else
        echo_warn "Certificate renewal failed or certificates not due for renewal"
        echo_info "Certificates are typically renewed when they have 30 days or less remaining"
        return 1
    fi
}

# Setup automated certificate renewal (container-based)
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
            docker-compose -f "$COMPOSE_FILE" --profile production restart certbot
        fi
    else
        # Start certbot container with auto-renewal
        echo_info "Starting certbot container with 12-hour renewal check..."

        if docker-compose -f "$COMPOSE_FILE" --profile production up -d certbot; then
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
    echo_info "  - Force renewal: docker-compose run --rm certbot renew --force-renewal"
    echo_info "  - Check expiry: docker-compose run --rm certbot certificates"
    echo_info "  - Stop auto-renewal: docker-compose stop certbot"
    echo ""
    echo_warn "Note: The certbot container will automatically reload nginx after renewal"
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
            portable_sed "s#^NETHERMIND_ETHSTATS_SERVER=.*#NETHERMIND_ETHSTATS_SERVER=$ethstats_server#" .env
        else
            echo "NETHERMIND_ETHSTATS_SERVER=$ethstats_server" >> .env
        fi

        if grep -q "^NETHERMIND_ETHSTATS_SECRET=" .env; then
            portable_sed "s#^NETHERMIND_ETHSTATS_SECRET=.*#NETHERMIND_ETHSTATS_SECRET=$ethstats_secret#" .env
        else
            echo "NETHERMIND_ETHSTATS_SECRET=$ethstats_secret" >> .env
        fi

        if grep -q "^NETHERMIND_ETHSTATS_ENABLED=" .env; then
            portable_sed "s#^NETHERMIND_ETHSTATS_ENABLED=.*#NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled#" .env
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
        local volume_name="${project_name}_artifacts"

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
            portable_sed 's|http://localhost:8545|http://nethermind:8545|g' veriscope_ta_node/.env
            portable_sed 's|ws://localhost:8545|ws://nethermind:8545|g' veriscope_ta_node/.env
            portable_sed 's|http://localhost:8000|http://nginx:80|g' veriscope_ta_node/.env
            portable_sed 's|redis://127.0.0.1:6379|redis://redis:6379|g' veriscope_ta_node/.env
            portable_sed 's|/opt/veriscope/veriscope_ta_node/artifacts/|/app/artifacts/|g' veriscope_ta_node/.env

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

    # Query ethstats for current nodes using Alpine container (macOS compatible)
    # This uses wscat + grep approach, running in Alpine where grep -P works
    # Key: Must wait after connecting before sending ready message to receive init response
    local nodes_json=$(docker run --rm node:alpine sh -c "
        npm install -g wscat > /dev/null 2>&1
        apk add --no-cache jq grep coreutils > /dev/null 2>&1

        # Send ready message after brief delay, then wait for response
        (sleep 2 && echo '{\"emit\":[\"ready\"]}' && sleep 5) | timeout 10 wscat --connect '$ethstats_get_enodes' 2>/dev/null | \
            grep enode | \
            jq '.emit[1].nodes' 2>/dev/null | \
            grep -oP '\"enode://[^\"]*\"' | \
            awk 'BEGIN {print \"[\"} {if(NR>1) printf \",\\n\"; printf \"  %s\", \$0} END {print \"\\n]\"}'
    " 2>/dev/null | jq -c '.')

    # Validate the generated JSON and check if not empty
    if [ ! -z "$nodes_json" ] && jq empty <<<"$nodes_json" >/dev/null 2>&1; then
        local enode_count
        enode_count=$(jq -r 'length' <<<"$nodes_json" 2>/dev/null)
        enode_count=${enode_count:-0}

        if [ "$enode_count" -gt 0 ]; then
            printf '%s' "$nodes_json" | jq '.' > "$temp_file"
            echo_info "Successfully retrieved $enode_count static nodes"

            # Update static-nodes.json
            cp "$temp_file" "$static_nodes_file"
            echo_info "Updated $static_nodes_file"

            # Display the nodes
            echo_info "Current static nodes:"
            cat "$static_nodes_file"
        else
            echo_warn "No static nodes retrieved from ethstats"
            echo_info "Keeping existing static-nodes.json unchanged"
            cat "$static_nodes_file"
        fi
    else
        echo_error "Failed to parse static nodes from ethstats output"
        echo_info "Keeping existing static-nodes.json unchanged"
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

    # Get the project name and construct the network name dynamically
    local project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')
    local network_name="${project_name}_veriscope"

    echo_info "Using Docker network: $network_name"

    # Verify network exists
    if ! docker network inspect "$network_name" >/dev/null 2>&1; then
        echo_error "Docker network '$network_name' not found"
        echo_info "Please ensure Docker Compose services are running"
        return 1
    fi

    # Query Nethermind for node info using internal Docker network
    # Run curl from a temporary Alpine container with access to the internal network
    local enode=$(docker run --rm --network "$network_name" alpine sh -c 'apk add -q curl jq && curl -m 10 -s -X POST -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1, \"method\":\"admin_nodeInfo\", \"params\":[]}" http://nethermind:8545/ | jq -r .result.enode' 2>/dev/null)

    if [ ! -z "$enode" ] && [ "$enode" != "null" ]; then
        echo_info "This node's enode: $enode"

        # Update .env with enode contact info
        if grep -q "^NETHERMIND_ETHSTATS_CONTACT=" .env; then
            portable_sed "s#^NETHERMIND_ETHSTATS_CONTACT=.*#NETHERMIND_ETHSTATS_CONTACT=$enode#" .env
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

    # Check if running interactively
    if [ -t 0 ]; then
        echo -n "Restart Nethermind and clear peer cache? (y/N): "
        read -r confirm
    else
        # Non-interactive mode - auto-confirm restart
        confirm="y"
        echo_info "Running in non-interactive mode - automatically restarting Nethermind"
    fi

    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo_info "Stopping Nethermind..."
        docker-compose -f "$COMPOSE_FILE" stop nethermind

        echo_info "Clearing peer database..."
        # Clear discovery and peer databases from volume using temporary alpine container
        docker run --rm -v veriscope_nethermind_data:/data alpine sh -c "rm -f /data/db/discoveryNodes/SimpleFileDb.db /data/db/peers/SimpleFileDb.db" 2>/dev/null || true
        echo_info "Peer cache cleared"

        echo_info "Starting Nethermind with updated configuration..."
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
    echo ""

    # Confirm action
    echo_warn "This will generate a new webhook secret and update both services"
    echo_warn "The old secret will be invalidated"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo_info "Operation cancelled"
        return 0
    fi

    local node_env="veriscope_ta_node/.env"
    local dashboard_env="veriscope_ta_dashboard/.env"

    # Check if files exist
    if [ ! -f "$node_env" ]; then
        echo_error "TA Node .env not found: $node_env"
        return 1
    fi

    # Generate new secret (longer than generate_secret default)
    local new_secret=$(openssl rand -hex 32 2>/dev/null || xxd -l 32 -p /dev/urandom | tr -d '\n')

    if [ -z "$new_secret" ]; then
        echo_error "Failed to generate new secret"
        return 1
    fi

    echo_info "Generated new secret (${#new_secret} characters)"
    echo ""

    # Update TA Node .env
    echo_info "Updating TA Node .env..."
    if ! update_env_variable "$node_env" "WEBHOOK_CLIENT_SECRET" "$new_secret"; then
        echo_error "Failed to update TA Node .env"
        return 1
    fi

    # Verify TA Node update
    local node_verify=$(grep "^WEBHOOK_CLIENT_SECRET=" "$node_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
    if [ "$node_verify" != "$new_secret" ]; then
        echo_error "TA Node .env verification failed"
        return 1
    fi
    echo_info "✓ TA Node updated and verified"

    # Update Dashboard .env if it exists
    if [ -f "$dashboard_env" ]; then
        echo_info "Updating Dashboard .env..."
        if ! update_env_variable "$dashboard_env" "WEBHOOK_CLIENT_SECRET" "$new_secret"; then
            echo_error "Failed to update Dashboard .env"
            return 1
        fi

        # Verify Dashboard update
        local dashboard_verify=$(grep "^WEBHOOK_CLIENT_SECRET=" "$dashboard_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
        if [ "$dashboard_verify" != "$new_secret" ]; then
            echo_error "Dashboard .env verification failed"
            return 1
        fi
        echo_info "✓ Dashboard updated and verified"
    else
        echo_warn "Dashboard .env not found - only TA Node updated"
    fi

    echo ""
    echo_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo_info "Restarting services to reload configuration..."
    echo_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local restart_count=0

    # Restart app service
    if docker-compose -f "$COMPOSE_FILE" ps app 2>/dev/null | grep -q "Up"; then
        echo_info "Restarting app service..."
        docker-compose -f "$COMPOSE_FILE" restart app
        restart_count=$((restart_count + 1))
    else
        echo_warn "App service not running (skip restart)"
    fi

    # Restart ta-node service
    if docker-compose -f "$COMPOSE_FILE" ps ta-node 2>/dev/null | grep -q "Up"; then
        echo_info "Restarting ta-node service..."
        docker-compose -f "$COMPOSE_FILE" restart ta-node
        restart_count=$((restart_count + 1))
    else
        echo_warn "TA Node service not running (skip restart)"
    fi

    echo ""
    echo_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo_info "✅ Webhook secret regenerated successfully!"
    echo_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo_info "  Services restarted: $restart_count"
    echo_info "  Secret length: ${#new_secret} characters"
    echo ""
    echo_warn "⚠️  IMPORTANT: Save this secret securely!"
    echo_warn "     New secret: $new_secret"
    echo ""
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
        i)
            FULL_INSTALL_MODE=true

            echo_info "========================================="
            echo_info "  Veriscope Full Installation"
            echo_info "========================================="
            echo ""

            # Step 1: Pre-flight checks
            echo_info "Step 1/11: Running pre-flight checks..."
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

            # Get the project name from docker-compose config
            project_name=$(docker-compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')

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

            # Step 8: Start services and wait for readiness
            echo_info "Step 8/11: Starting services..."
            if ! start_services; then
                echo_error "Failed to start services - aborting installation"
                exit 1
            fi

            echo_info "Waiting for services to be ready..."
            if ! wait_for_services_ready 120; then
                echo_error "Services failed to become ready - aborting installation"
                echo_info "Check service logs: docker-compose -f $COMPOSE_FILE logs"
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
            if ! docker-compose -f "$COMPOSE_FILE" restart ta-node; then
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

            # Run pre-flight checks
            echo ""
            echo_info "Running pre-flight checks before installation..."
            if ! preflight_checks; then
                exit 1
            fi
            echo ""

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
            docker volume rm "${project_name}_app_data" 2>/dev/null || true
            docker volume rm "${project_name}_artifacts" 2>/dev/null || true
            echo_info "PostgreSQL, Redis, app, and artifacts volumes reset (Nethermind data preserved)"

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
