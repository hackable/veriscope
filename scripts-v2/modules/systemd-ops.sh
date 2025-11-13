#!/bin/bash
# Veriscope Bare-Metal Scripts - SystemD Operations Module
# Service management and status functions

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# SERVICE MANAGEMENT
# ============================================================================

restart_all_services() {
    echo_info "Restarting all Veriscope services..."

    systemctl restart nethermind
    systemctl restart ta
    systemctl restart ta-wss
    systemctl restart ta-schedule
    systemctl restart nginx
    systemctl restart postgresql
    systemctl restart redis.service
    systemctl restart ta-node-1
    systemctl restart horizon || true

    echo_info "All services restarted successfully"
    return 0
}

stop_services() {
    echo_info "Stopping all Veriscope services..."

    systemctl stop ta
    systemctl stop ta-wss
    systemctl stop ta-schedule
    systemctl stop ta-node-1
    systemctl stop horizon || true
    systemctl stop nethermind
    systemctl stop nginx

    echo_info "All services stopped"
    return 0
}

start_services() {
    echo_info "Starting all Veriscope services..."

    systemctl start postgresql
    systemctl start redis.service
    systemctl start nethermind
    systemctl start nginx
    systemctl start ta
    systemctl start ta-wss
    systemctl start ta-schedule
    systemctl start ta-node-1
    systemctl start horizon || true

    echo_info "All services started"
    return 0
}

show_status() {
    echo_info "Showing service status..."
    systemctl status nethermind ta ta-wss ta-schedule ta-node-1 nginx postgresql redis.service horizon | less
}

daemon_status() {
    show_status
}

# ============================================================================
# LOGS
# ============================================================================

show_logs() {
    local service=${1:-nethermind}
    echo_info "Showing logs for $service..."
    journalctl -u $service -f
}
