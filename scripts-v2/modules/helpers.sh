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
