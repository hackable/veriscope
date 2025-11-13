#!/bin/bash
# Veriscope Bare-Metal Scripts - Validators Module
# Validation functions for preflight checks and system requirements

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# SYSTEM VALIDATION
# ============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo_error "This script must be run with sudo or as root"
        return 1
    fi
    return 0
}

# Check if required commands are available
check_command() {
    local cmd=$1
    if ! command -v $cmd >/dev/null 2>&1; then
        echo_warn "$cmd not found"
        return 1
    fi
    return 0
}

# Preflight checks
preflight_checks() {
    echo_info "Running preflight checks..."

    local checks_passed=true

    # Check for required commands
    for cmd in jq curl wget systemctl; do
        if ! check_command $cmd; then
            checks_passed=false
        fi
    done

    # Check PostgreSQL
    if ! systemctl is-active --quiet postgresql; then
        echo_warn "PostgreSQL is not running"
    fi

    # Check disk space (at least 10GB free)
    local free_space=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$free_space" -lt 10 ]; then
        echo_warn "Low disk space: ${free_space}GB free (recommend at least 10GB)"
    fi

    if [ "$checks_passed" = true ]; then
        echo_info "Preflight checks passed"
        return 0
    else
        echo_error "Preflight checks failed"
        return 1
    fi
}
