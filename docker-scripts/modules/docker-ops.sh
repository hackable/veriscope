#!/bin/bash
# Veriscope Docker Scripts - Docker Operations Module
# This module provides Docker container and service management functions
#
# Functions:
# - Container lifecycle: build_images, start_services, stop_services, restart_services
# - Volume management: reset_volumes, destroy_services
# - Service readiness: wait_for_postgres_ready, wait_for_redis_ready, wait_for_app_ready,
#                      wait_for_ta_node_ready, wait_for_services_ready
# - Status and logs: show_status, show_logs, show_supervisord_logs

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# BUILD AND IMAGE MANAGEMENT
# ============================================================================

# Build Docker images
# Returns: 0 on success, 1 on failure
build_images() {
    echo_info "Building Docker images..."
    if ! docker compose -f "$COMPOSE_FILE" build; then
        echo_error "Failed to build Docker images"
        return 1
    fi
    echo_info "Docker images built successfully"
}

# ============================================================================
# SERVICE LIFECYCLE
# ============================================================================

# Start all services
# Returns: 0 on success, 1 on failure
start_services() {
    echo_info "Starting Veriscope services..."
    if ! docker compose -f "$COMPOSE_FILE" up -d; then
        echo_error "Failed to start services"
        return 1
    fi
    echo_info "Services started. Use 'docker compose -f $COMPOSE_FILE ps' to check status"
}

# Stop all services
# Returns: 0 on success, 1 on failure
stop_services() {
    echo_info "Stopping Veriscope services..."

    # Stop certbot auto-renewal container (production profile)
    docker compose -f "$COMPOSE_FILE" --profile production stop certbot 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" --profile production rm -f certbot 2>/dev/null || true

    # Clean up any certbot-run containers from manual operations
    docker ps -a --filter "name=certbot-run" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true

    if ! docker compose -f "$COMPOSE_FILE" down; then
        echo_error "Failed to stop services"
        return 1
    fi
    echo_info "Services stopped"
}

# Restart all services
# Returns: 0 on success, 1 on failure
restart_services() {
    echo_info "Restarting Veriscope services..."
    if ! docker compose -f "$COMPOSE_FILE" restart; then
        echo_error "Failed to restart services"
        return 1
    fi
    echo_info "Services restarted"
}

# ============================================================================
# SERVICE READINESS CHECKS
# ============================================================================

# Wait for PostgreSQL to be ready to accept connections
# Usage: wait_for_postgres_ready [timeout_seconds]
# Returns: 0 if ready, 1 if timeout
wait_for_postgres_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for PostgreSQL to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U trustanchor >/dev/null 2>&1; then
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
        if docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
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
            if docker compose -f "$COMPOSE_FILE" exec -T app php artisan --version >/dev/null 2>&1; then
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
            if docker compose -f "$COMPOSE_FILE" exec -T ta-node sh -c "pgrep -f node" >/dev/null 2>&1; then
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

# ============================================================================
# VOLUME MANAGEMENT
# ============================================================================

# Reset database and cache volumes
# This is necessary when database credentials change, as PostgreSQL
# initializes with credentials on first run and stores them in the volume
# Note: This does NOT delete Nethermind volume (blockchain sync data)
# Returns: 0 on success, 1 on failure
reset_volumes() {
    echo_info "Resetting database and cache volumes..."
    echo_warn "This will delete all data in PostgreSQL and Redis!"
    echo_info "Nethermind blockchain data will be preserved"

    # Stop services first
    echo_info "Stopping services..."
    if ! docker compose -f "$COMPOSE_FILE" down; then
        echo_warn "Failed to stop services cleanly, continuing..."
    fi

    # Get the project name from docker compose config
    local project_name=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')

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
        echo_info "Make sure all containers are stopped: docker compose -f $COMPOSE_FILE down"
        return 1
    fi

    echo_info "Successfully removed $removed volume(s)"
    echo_warn "You will need to run migrations and seed the database again"
}

# Destroy all services, containers, volumes, and networks
# This is a destructive operation that removes everything
# Returns: 0 on success, 1 on cancellation
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

    # Get the project name from docker compose config
    local project_name=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')

    # Stop and remove containers, networks
    echo_info "Stopping and removing containers and networks..."
    docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true

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

# ============================================================================
# STATUS AND LOGS
# ============================================================================

# Show service status
show_status() {
    echo_info "Veriscope service status:"
    docker compose -f "$COMPOSE_FILE" ps
}

# Show logs
# Usage: show_logs [service_name]
# If service_name is omitted, shows logs for all services
show_logs() {
    local service=$1
    if [ -z "$service" ]; then
        docker compose -f "$COMPOSE_FILE" logs --tail=100 -f
    else
        docker compose -f "$COMPOSE_FILE" logs --tail=100 -f "$service"
    fi
}

# Show supervisord logs from the app container
# Interactive menu to select which log to view
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
            docker compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/supervisord.log
            ;;
        2)
            echo_info "Viewing websocket log..."
            docker compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/websocket.log
            ;;
        3)
            echo_info "Viewing worker log..."
            docker compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/worker.log
            ;;
        4)
            echo_info "Viewing horizon log..."
            docker compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/horizon.log
            ;;
        5)
            echo_info "Viewing scheduler log..."
            docker compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/scheduler.log
            ;;
        6)
            echo_info "Viewing cron log..."
            docker compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/cron.log
            ;;
        a)
            echo_info "Viewing all supervisord logs (combined)..."
            docker compose -f "$COMPOSE_FILE" exec app tail -f /var/log/supervisord/*.log
            ;;
        *)
            echo_error "Invalid option"
            ;;
    esac
}
