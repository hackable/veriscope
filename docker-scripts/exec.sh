#!/bin/bash
# Execute commands in Docker containers

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

SERVICE=$1
shift

if [ -z "$SERVICE" ]; then
    echo "Usage: $0 <service> [command]"
    echo ""
    echo "Available services:"
    docker compose -f "$COMPOSE_FILE" ps --services
    echo ""
    echo "Examples:"
    echo "  $0 app bash              # Open bash shell in app container"
    echo "  $0 ta-node sh            # Open sh shell in ta-node container"
    echo "  $0 postgres psql -U trustanchor trustanchor  # Connect to database"
    echo "  $0 redis redis-cli       # Connect to Redis"
    exit 1
fi

if [ $# -eq 0 ]; then
    # No command specified, open a shell
    case "$SERVICE" in
        app)
            docker compose -f "$COMPOSE_FILE" exec "$SERVICE" bash
            ;;
        ta-node)
            docker compose -f "$COMPOSE_FILE" exec "$SERVICE" sh
            ;;
        *)
            docker compose -f "$COMPOSE_FILE" exec "$SERVICE" sh
            ;;
    esac
else
    # Execute the specified command
    docker compose -f "$COMPOSE_FILE" exec "$SERVICE" "$@"
fi
