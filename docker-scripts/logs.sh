#!/bin/bash
# Veriscope Docker Logs Viewer

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

SERVICE=$1
LINES=${2:-100}

if [ -z "$SERVICE" ]; then
    echo "Usage: $0 <service> [lines]"
    echo ""
    echo "Available services:"
    docker-compose -f "$COMPOSE_FILE" ps --services
    exit 1
fi

echo "=== Showing last $LINES lines of $SERVICE logs (press Ctrl+C to exit) ==="
docker-compose -f "$COMPOSE_FILE" logs --tail="$LINES" -f "$SERVICE"
