#!/bin/bash
# Veriscope Docker Scripts - Validation Functions
# This module provides validation functions for security, system readiness, and configuration
#
# Functions:
# - Password validation: is_weak_password, validate_password_strength, validate_postgres_password
# - Domain validation: is_valid_ssl_domain
# - Environment validation: validate_env_vars
# - System checks: check_docker, check_port_available, get_port_process
# - Resource checks: get_available_disk_space_gb
# - Network checks: check_internet_connectivity, check_dns_resolution, check_docker_hub_connectivity
# - Pre-flight checks: preflight_checks

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# PASSWORD VALIDATION
# ============================================================================

# List of known weak/common passwords to reject
# Usage: is_weak_password "password"
# Returns: 0 if weak (BAD), 1 if not weak (GOOD)
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

# ============================================================================
# DOMAIN VALIDATION
# ============================================================================

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

# ============================================================================
# ENVIRONMENT VALIDATION
# ============================================================================

# Validate environment variables
# Returns: 0 if all valid, 1 if errors
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

# ============================================================================
# DOCKER VALIDATION
# ============================================================================

# Check if Docker is installed
# Exits on failure (fail-fast)
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

# ============================================================================
# PORT VALIDATION
# ============================================================================

# Check if a port is available
# Usage: check_port_available <port>
# Returns: 0 if available, 1 if in use
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
# Usage: get_port_process <port>
# Returns: Process name and PID
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

# ============================================================================
# SYSTEM RESOURCE VALIDATION
# ============================================================================

# Get available disk space in GB
# Usage: get_available_disk_space_gb <path>
# Returns: Available space in GB
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

# ============================================================================
# NETWORK VALIDATION
# ============================================================================

# Check internet connectivity
# Returns: 0 if connected, 1 if not
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
# Usage: check_dns_resolution <hostname>
# Returns: 0 if resolves, 1 if not
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
# Returns: 0 if reachable, 1 if not
check_docker_hub_connectivity() {
    if command -v timeout &> /dev/null; then
        timeout 5 curl -s -o /dev/null -w "%{http_code}" https://hub.docker.com/ 2>/dev/null | grep -q "200"
    else
        # macOS and systems without timeout - use curl's max-time
        curl --max-time 5 -s -o /dev/null -w "%{http_code}" https://hub.docker.com/ 2>/dev/null | grep -q "200"
    fi
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

# Pre-flight checks for system readiness
# Performs comprehensive system validation before installation
# Returns: 0 to continue, 1 to abort
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
