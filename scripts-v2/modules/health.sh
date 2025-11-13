#!/bin/bash
# Veriscope Bare-Metal Scripts - Health and Monitoring Module
# Health checks and system monitoring for bare-metal deployments

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# HEALTH CHECK
# ============================================================================

health_check() {
    echo_info "Running comprehensive health check..."
    echo ""

    local all_healthy=true

    # 1. SystemD Services Status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1. SystemD Services Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local services=("nethermind" "ta" "ta-wss" "ta-schedule" "ta-node-1" "nginx" "postgresql" "redis-stack-server" "horizon")
    local service_names=("Nethermind" "Laravel Queue" "Laravel WebSocket" "Laravel Scheduler" "TA Node" "Nginx" "PostgreSQL" "Redis Stack" "Laravel Horizon")

    for i in "${!services[@]}"; do
        local service="${services[$i]}"
        local name="${service_names[$i]}"

        if systemctl is-active --quiet "$service" 2>/dev/null; then
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
    if su postgres -c "psql -U trustanchor -d trustanchor -c 'SELECT 1'" >/dev/null 2>&1; then
        echo_info "✓ PostgreSQL is accepting connections"
    else
        echo_error "✗ PostgreSQL is not ready"
        all_healthy=false
    fi

    # Redis
    if redis-cli ping 2>/dev/null | grep -q "PONG"; then
        echo_info "✓ Redis is responding"

        # Check RedisBloom module
        if redis-cli MODULE LIST 2>/dev/null | grep -q "bf"; then
            echo_info "✓ RedisBloom module is loaded"
        else
            echo_warn "⚠ RedisBloom module not detected"
        fi
    else
        echo_error "✗ Redis is not responding"
        all_healthy=false
    fi

    # Laravel
    if php -v >/dev/null 2>&1; then
        echo_info "✓ PHP is functional ($(php -r 'echo PHP_VERSION;'))"
    else
        echo_error "✗ PHP is not functional"
        all_healthy=false
    fi

    # Node.js
    if node --version >/dev/null 2>&1; then
        echo_info "✓ Node.js is functional ($(node --version))"
    else
        echo_error "✗ Node.js is not functional"
        all_healthy=false
    fi

    # Nginx
    if nginx -t >/dev/null 2>&1; then
        echo_info "✓ Nginx configuration is valid"
    else
        echo_error "✗ Nginx configuration has errors"
        all_healthy=false
    fi
    echo ""

    # 3. Network Connectivity
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "3. Network Connectivity"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Test database connection from Laravel
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    if su $SERVICE_USER -c "php artisan db:show" >/dev/null 2>&1; then
        echo_info "✓ Laravel can connect to database"
    else
        echo_error "✗ Laravel cannot connect to database"
        all_healthy=false
    fi
    popd >/dev/null

    # Test Nethermind RPC
    if curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}' http://localhost:8545 2>/dev/null | grep -q "result"; then
        echo_info "✓ Nethermind RPC is responding"
    else
        echo_error "✗ Nethermind RPC is not responding"
        all_healthy=false
    fi
    echo ""

    # 4. Disk Space
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "4. Disk Space"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local free_space=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$free_space" -gt 10 ]; then
        echo_info "✓ Disk space: ${free_space}GB free"
    else
        echo_warn "⚠ Low disk space: ${free_space}GB free (recommend at least 10GB)"
        all_healthy=false
    fi
    echo ""

    # 5. SSL Certificates
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "5. SSL Certificates"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local cert_file="/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/fullchain.pem"
    if [ -f "$cert_file" ]; then
        local expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        local now_epoch=$(date +%s)
        local days_until_expiry=$(( ($expiry_epoch - $now_epoch) / 86400 ))

        if [ $days_until_expiry -gt 30 ]; then
            echo_info "✓ SSL certificate valid (expires in $days_until_expiry days)"
        elif [ $days_until_expiry -gt 0 ]; then
            echo_warn "⚠ SSL certificate expires soon ($days_until_expiry days)"
        else
            echo_error "✗ SSL certificate has expired"
            all_healthy=false
        fi
    else
        echo_warn "⚠ SSL certificate not found"
    fi
    echo ""

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$all_healthy" = true ]; then
        echo_info "Health check: ALL SYSTEMS HEALTHY ✓"
    else
        echo_error "Health check: ISSUES DETECTED ✗"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ "$all_healthy" = true ]; then
        return 0
    else
        return 1
    fi
}
