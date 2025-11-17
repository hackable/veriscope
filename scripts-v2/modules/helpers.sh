#!/bin/bash
# Veriscope Bare-Metal Scripts - Helper Functions Module
# Core utility functions for logging, text processing, and common operations

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================================
# TEXT PROCESSING
# ============================================================================

# In-place sed for Linux
# Note: This is Linux-only. Use sed -i for in-place file editing.
portable_sed() {
    local sed_expression="$1"
    local file="$2"
    sed -i "$sed_expression" "$file"
}

# ============================================================================
# PHP VERSION DETECTION
# ============================================================================

# Global variable to store detected PHP version
PHP_VERSION=""

# Detect installed PHP version (8.5 > 8.4)
detect_php_version() {
    if [ -n "$PHP_VERSION" ]; then
        return 0
    fi

    for version in 8.5 8.4; do
        if command -v php${version} >/dev/null 2>&1 || apt-cache search php${version}-fpm 2>/dev/null | grep -q "php${version}-fpm"; then
            PHP_VERSION="$version"
            echo_info "Detected PHP $PHP_VERSION"
            return 0
        fi
    done

    echo_error "No compatible PHP version found (requires PHP 8.4 or higher)"
    return 1
}

# ============================================================================
# SECRET GENERATION
# ============================================================================

# Generate cryptographically secure random string
generate_secret() {
    local length=${1:-32}
    openssl rand -hex $length 2>/dev/null || xxd -l $length -p /dev/urandom | tr -d '\n'
}

# Generate password with pwgen
generate_password() {
    local length=${1:-20}
    pwgen -B $length 1
}
