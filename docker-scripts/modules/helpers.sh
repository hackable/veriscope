#!/bin/bash
# Veriscope Docker Scripts - Core Helper Functions
# This module provides essential helper functions used across all modules
#
# Functions:
# - echo_info, echo_warn, echo_error: Colored output
# - portable_sed: Cross-platform sed in-place editing
# - is_dev_mode: Detect development/production environment
# - generate_secret: Generate secure random secrets

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Standard output functions with colors
echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Portable sed in-place editing (works on both macOS and Linux)
# Usage: portable_sed 's/pattern/replacement/' filename
# Returns: 0 on success, 1 on error
portable_sed() {
    local sed_expression="$1"
    local file="$2"

    if [ -z "$sed_expression" ] || [ -z "$file" ]; then
        echo_error "portable_sed: Missing arguments"
        return 1
    fi

    if [ ! -f "$file" ]; then
        echo_error "portable_sed: File not found: $file"
        return 1
    fi

    if [ ! -w "$file" ]; then
        echo_error "portable_sed: File not writable: $file"
        return 1
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS requires empty string after -i
        if ! sed -i "" "$sed_expression" "$file"; then
            echo_error "portable_sed: sed command failed on $file"
            return 1
        fi
    else
        # Linux doesn't use empty string
        if ! sed -i "$sed_expression" "$file"; then
            echo_error "portable_sed: sed command failed on $file"
            return 1
        fi
    fi
    return 0
}

# Detect if running in development mode
# Returns: 0 if dev mode, 1 if production
is_dev_mode() {
    # Check if using dev compose file
    if [[ "${COMPOSE_FILE:-}" == *"dev"* ]]; then
        return 0
    fi

    # Check if APP_ENV is local/development
    if [ "${APP_ENV:-}" = "local" ] || [ "${APP_ENV:-}" = "development" ]; then
        return 0
    fi

    # Check if host is localhost or similar
    if [[ "${VERISCOPE_SERVICE_HOST:-}" =~ ^(localhost|127\.0\.0\.1|.*\.local|.*\.test)$ ]]; then
        return 0
    fi

    return 1
}

# Generate a cryptographically secure random secret
# Usage: generate_secret <length>
# Returns: random string of specified length
generate_secret() {
    local length="${1:-32}"

    if ! [[ "$length" =~ ^[0-9]+$ ]] || [ "$length" -lt 1 ]; then
        echo_error "generate_secret: Invalid length: $length"
        return 1
    fi

    # Try multiple methods to ensure cross-platform compatibility
    if command -v openssl &>/dev/null; then
        openssl rand -base64 48 | tr -d "=+/" | cut -c1-"$length"
    elif [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
    else
        echo_error "generate_secret: No secure random source available"
        return 1
    fi
}

# Check if a Docker container is running
# Usage: is_container_running <container_name>
# Returns: 0 if running, 1 if not
is_container_running() {
    local container_name="$1"

    if [ -z "$container_name" ]; then
        echo_error "is_container_running: No container name provided"
        return 1
    fi

    if docker compose -f "${COMPOSE_FILE:-docker-compose.yml}" ps "$container_name" 2>/dev/null | grep -q "Up"; then
        return 0
    else
        return 1
    fi
}

# Wait for a command to succeed with timeout
# Usage: wait_for <timeout_seconds> <command> [args...]
# Returns: 0 if command succeeded within timeout, 1 if timeout
wait_for() {
    local timeout="$1"
    shift
    local elapsed=0

    while [ $elapsed -lt "$timeout" ]; do
        if "$@" 2>/dev/null; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for: $*"
    return 1
}

# Log operations to file
# Usage: log_operation <operation> <status> <details>
log_operation() {
    local operation="$1"
    local status="$2"
    local details="$3"
    local log_file="${LOG_FILE:-./logs/operations.log}"

    mkdir -p "$(dirname "$log_file")"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$status] $operation - $details" >> "$log_file"
}

# Get Docker Compose project name
# Returns: project name from docker-compose.yml (defaults to "veriscope")
get_project_name() {
    docker compose -f "${COMPOSE_FILE:-docker-compose.yml}" config --format json 2>/dev/null | jq -r '.name // "veriscope"'
}

# Read variable from .env file
# Usage: get_env_var <variable_name> [default_value] [strip_quotes]
# Returns: variable value or default if not found
get_env_var() {
    local var_name="$1"
    local default_value="${2:-}"
    local strip_quotes="${3:-false}"

    if [ -z "$var_name" ]; then
        echo_error "get_env_var: No variable name provided"
        echo "$default_value"
        return 1
    fi

    if [ ! -f ".env" ]; then
        echo "$default_value"
        return 0
    fi

    local value=$(grep "^${var_name}=" .env 2>/dev/null | cut -d= -f2)

    if [ "$strip_quotes" = "true" ]; then
        value=$(echo "$value" | tr -d '"')
    fi

    echo "${value:-$default_value}"
}

# Load .env file into environment
# Usage: load_env_file [path_to_env_file]
# Returns: 0 on success, 1 if file not found
load_env_file() {
    local env_file="${1:-.env}"

    if [ ! -f "$env_file" ]; then
        echo_error "Environment file not found: $env_file"
        return 1
    fi

    set -o allexport
    source "$env_file"
    set +o allexport

    return 0
}

# Check if a named container is running (by container name, not compose service)
# Usage: is_named_container_running <container_name> [require_status]
# Returns: 0 if running, 1 if not
is_named_container_running() {
    local container_name="$1"
    local require_status="${2:-}"  # Optional: "running" to check status

    if [ -z "$container_name" ]; then
        echo_error "is_named_container_running: No container name provided"
        return 1
    fi

    local filter_args="--filter name=$container_name"
    if [ -n "$require_status" ]; then
        filter_args="$filter_args --filter status=$require_status"
    fi

    if docker ps $filter_args --format "{{.Names}}" | grep -q "$container_name"; then
        return 0
    else
        return 1
    fi
}

# Display service URLs with automatic protocol detection
# Usage: show_service_urls [service_host] [context]
# Context: "available" (default), "configured", "access"
show_service_urls() {
    local service_host="${1:-$(get_env_var "VERISCOPE_SERVICE_HOST" "localhost" true)}"
    local context="${2:-available}"

    # Detect protocol based on SSL certificate availability
    local protocol="http"
    local ssl_status=""

    if check_ssl_cert_exists "$service_host" false 2>/dev/null; then
        protocol="https"
        ssl_status=" (HTTPS)"
    else
        ssl_status=" (HTTP only)"
    fi

    case "$context" in
        "available")
            echo_info "Your services are now available at:"
            ;;
        "configured")
            echo_info "Services configured at:"
            ;;
        "access")
            echo_info "Access your Veriscope instance at:"
            ;;
    esac

    echo_info "  Laravel: ${protocol}://${service_host}${ssl_status}"
    echo_info "  Arena:   ${protocol}://${service_host}/arena"
}

# Report installation failure and exit
# Usage: abort_install <step_name> [error_details]
abort_install() {
    local step_name="$1"
    local error_details="${2:-}"

    echo_error "${step_name} - aborting installation"

    if [ -n "$error_details" ]; then
        echo_info "$error_details"
    fi

    if [ "${FULL_INSTALL_MODE:-false}" = "true" ]; then
        echo ""
        echo_info "Installation failed. You can:"
        echo_info "  - Check logs above for specific errors"
        echo_info "  - Run individual setup steps manually"
        echo_info "  - Check documentation for troubleshooting"
    fi

    exit 1
}
