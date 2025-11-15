#!/bin/bash
# Veriscope Docker Scripts - Blockchain Chain Configuration Module
# This module provides blockchain network configuration and management
#
# Functions:
# - Network configuration: configure_nethermind, setup_chain_config
# - Static nodes: refresh_static_nodes
# - Chainspec updates: update_chainspec
# - Monitoring: check_blockchain_sync

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# BLOCKCHAIN MONITORING
# ============================================================================

# Check blockchain synchronization status
# Queries Nethermind RPC to get sync status, peer count, and current block
check_blockchain_sync() {
    if ! docker compose -f "$COMPOSE_FILE" ps nethermind 2>/dev/null | grep -q "Up"; then
        echo_warn "⚠ Nethermind is not running"
        return
    fi

    # Get project name and network for Docker networking
    local project_name=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')
    local network_name="${project_name}_veriscope"

    # Query Nethermind RPC - use temporary Alpine container with curl
    # This works even if Nethermind container doesn't have curl installed
    rpc_query() {
        local method=$1
        docker run --rm --network "$network_name" alpine sh -c \
            "apk add -q curl >/dev/null 2>&1 && curl -m 5 -s -X POST -H 'Content-Type: application/json' \
            -d '{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}' \
            http://nethermind:8545" 2>/dev/null
    }

    # Get sync status
    local sync_response=$(rpc_query "eth_syncing")
    local sync_status=$(echo "$sync_response" | grep -o '"result":[^,}]*' | cut -d: -f2)

    # Get peer count
    local peer_response=$(rpc_query "net_peerCount")
    local peer_count=$(echo "$peer_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

    # Convert hex peer count to decimal
    if [ ! -z "$peer_count" ] && [ "$peer_count" != "null" ]; then
        peer_count=$((16#${peer_count#0x}))
    else
        peer_count="?"
    fi

    # Get current block number
    local block_response=$(rpc_query "eth_blockNumber")
    local current_block=$(echo "$block_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

    if [ ! -z "$current_block" ] && [ "$current_block" != "null" ]; then
        current_block=$((16#${current_block#0x}))
    else
        current_block="?"
    fi

    echo_info "Current block: $current_block"
    echo_info "Connected peers: $peer_count"

    # Check if we got valid responses
    if [ "$current_block" = "?" ] && [ "$peer_count" = "?" ]; then
        echo_error "✗ Unable to query Nethermind RPC"
        echo_info "  Possible issues:"
        echo_info "    - Nethermind is still starting up"
        echo_info "    - RPC port 8545 is not accessible"
        echo_info "    - Network connectivity issues"
        return
    fi

    if [ "$sync_status" = "false" ]; then
        echo_info "✓ Blockchain is fully synchronized"
    elif [ -z "$sync_status" ] || [ "$sync_status" = "null" ]; then
        if [ "$current_block" != "?" ]; then
            echo_info "✓ Nethermind is responding (sync status unknown)"
        else
            echo_warn "⚠ Unable to determine sync status"
        fi
    else
        # Parse sync progress if syncing
        echo_warn "⚠ Blockchain is syncing..."

        # Try to extract current and highest block from sync status
        local highest_block=$(echo "$sync_status" | grep -o '"highestBlock":"[^"]*"' | cut -d'"' -f4)
        if [ ! -z "$highest_block" ] && [ "$highest_block" != "null" ]; then
            highest_block=$((16#${highest_block#0x}))
            if [ "$current_block" != "?" ] && [ "$highest_block" -gt 0 ]; then
                local sync_percent=$((current_block * 100 / highest_block))
                echo_info "  Progress: $sync_percent% ($current_block / $highest_block)"
            fi
        fi
    fi

    # Warn if no peers
    if [ "$peer_count" = "0" ]; then
        echo_error "✗ No peers connected - node is isolated"
    elif [ "$peer_count" = "?" ]; then
        echo_warn "⚠ Unable to determine peer count"
    fi
}

# ============================================================================
# NETWORK CONFIGURATION
# ============================================================================

# Configure Nethermind for selected network
# Sets Docker Compose environment variables in root .env:
#   NETHERMIND_ETHSTATS_SERVER - WebSocket URL for ethstats server
#   NETHERMIND_ETHSTATS_SECRET - Authentication secret for ethstats
#   NETHERMIND_ETHSTATS_ENABLED - Enable/disable ethstats reporting (true/false)
# Usage: configure_nethermind <network>
# Returns: 0 on success
configure_nethermind() {
    local network="$1"

    echo_info "Configuring Nethermind for network: $network"

    # Set network-specific ethstats configuration
    local ethstats_server
    local ethstats_secret
    local ethstats_enabled="true"

    case "$network" in
        "veriscope_testnet")
            ethstats_server="wss://fedstats.veriscope.network/api"
            ethstats_secret="Oogongi4"
            ;;
        "fed_testnet")
            ethstats_server="wss://stats.testnet.shyft.network/api"
            ethstats_secret="Ish9phieph"
            ;;
        "fed_mainnet")
            ethstats_server="wss://stats.shyft.network/api"
            ethstats_secret="uL4tohChia"
            ;;
        *)
            echo_warn "Unknown network, using default ethstats configuration"
            ethstats_server="wss://fedstats.veriscope.network/api"
            ethstats_secret="Oogongi4"
            ;;
    esac

    # Update .env with Nethermind configuration
    # Check if any Nethermind variables exist
    local nethermind_exists=false
    if grep -q "^NETHERMIND_ETHSTATS_SERVER=" .env || \
       grep -q "^NETHERMIND_ETHSTATS_SECRET=" .env || \
       grep -q "^NETHERMIND_ETHSTATS_ENABLED=" .env; then
        nethermind_exists=true
    fi

    if [ "$nethermind_exists" = false ]; then
        # Add Nethermind section with proper formatting
        cat >> .env <<EOF

# Nethermind Ethereum Client Configuration
# Connect to the Veriscope network stats server
NETHERMIND_ETHSTATS_SERVER=$ethstats_server
NETHERMIND_ETHSTATS_SECRET=$ethstats_secret
NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled
EOF
    else
        # Update existing values
        if grep -q "^NETHERMIND_ETHSTATS_SERVER=" .env; then
            portable_sed "s#^NETHERMIND_ETHSTATS_SERVER=.*#NETHERMIND_ETHSTATS_SERVER=$ethstats_server#" .env
        else
            echo "NETHERMIND_ETHSTATS_SERVER=$ethstats_server" >> .env
        fi

        if grep -q "^NETHERMIND_ETHSTATS_SECRET=" .env; then
            portable_sed "s#^NETHERMIND_ETHSTATS_SECRET=.*#NETHERMIND_ETHSTATS_SECRET=$ethstats_secret#" .env
        else
            echo "NETHERMIND_ETHSTATS_SECRET=$ethstats_secret" >> .env
        fi

        if grep -q "^NETHERMIND_ETHSTATS_ENABLED=" .env; then
            portable_sed "s#^NETHERMIND_ETHSTATS_ENABLED=.*#NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled#" .env
        else
            echo "NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled" >> .env
        fi
    fi

    echo_info "Nethermind configuration added to .env for $network network:"
    echo_info "  NETHERMIND_ETHSTATS_SERVER=$ethstats_server"
    echo_info "  NETHERMIND_ETHSTATS_SECRET=$ethstats_secret"
    echo_info "  NETHERMIND_ETHSTATS_ENABLED=$ethstats_enabled"
}

# Setup chain-specific configuration
# Configures Nethermind, copies artifacts, and sets up TA node environment
# Returns: 0 on success, 1 on failure
setup_chain_config() {
    echo_info "Setting up chain-specific configuration..."

    # Load VERISCOPE_TARGET from .env
    if [ ! -f ".env" ]; then
        echo_error ".env file not found. Please run check command first."
        return 1
    fi

    source .env

    if [ -z "$VERISCOPE_TARGET" ] || [ "$VERISCOPE_TARGET" = "unset" ]; then
        echo_error "VERISCOPE_TARGET not set in .env file"
        echo_info "Please set VERISCOPE_TARGET to: veriscope_testnet, fed_testnet, or fed_mainnet"
        return 1
    fi

    case "$VERISCOPE_TARGET" in
        "veriscope_testnet"|"fed_testnet"|"fed_mainnet")
            echo_info "Target network: $VERISCOPE_TARGET"
            ;;
        *)
            echo_error "Invalid VERISCOPE_TARGET: $VERISCOPE_TARGET"
            echo_info "Must be one of: veriscope_testnet, fed_testnet, fed_mainnet"
            return 1
            ;;
    esac

    local chain_dir="chains/$VERISCOPE_TARGET"

    if [ ! -d "$chain_dir" ]; then
        echo_error "Chain directory not found: $chain_dir"
        return 1
    fi

    # Configure Nethermind for this network
    configure_nethermind "$VERISCOPE_TARGET"

    # Copy artifacts directory to Docker volume for ta-node
    if [ -d "$chain_dir/artifacts" ]; then
        echo_info "Copying chain artifacts for $VERISCOPE_TARGET to Docker volume..."

        # Get the project name from docker compose config
        local project_name=$(docker compose -f "$COMPOSE_FILE" config --format json | jq -r '.name // "veriscope"')
        local volume_name="${project_name}_artifacts"

        # Create volume if it doesn't exist
        docker volume create "$volume_name" >/dev/null 2>&1 || true

        # Copy artifacts from chains/$VERISCOPE_TARGET/artifacts to volume
        # Using alpine container to perform the copy
        docker run --rm \
            -v "$(pwd)/$chain_dir:/source:ro" \
            -v "$volume_name:/target" \
            alpine sh -c "rm -rf /target/* && cp -r /source/artifacts/. /target/"

        echo_info "Artifacts copied to Docker volume: $volume_name"
        echo_info "Network: $VERISCOPE_TARGET"
    else
        echo_warn "No artifacts directory found in $chain_dir"
    fi

    # Copy ta-node-env if veriscope_ta_node/.env doesn't exist or is a directory
    # Remove if it exists as a directory (Docker creates this if file doesn't exist before mount)
    if [ -d "veriscope_ta_node/.env" ]; then
        echo_warn "Found .env as a directory instead of file, removing..."
        rm -rf "veriscope_ta_node/.env"
    fi

    if [ ! -f "veriscope_ta_node/.env" ] || [ ! -s "veriscope_ta_node/.env" ]; then
        if [ -f "$chain_dir/ta-node-env" ]; then
            echo_info "Creating veriscope_ta_node/.env from chain template..."
            mkdir -p veriscope_ta_node

            if ! cp "$chain_dir/ta-node-env" veriscope_ta_node/.env; then
                echo_error "Failed to copy ta-node-env template"
                return 1
            fi

            # Verify the file was created
            if [ ! -f "veriscope_ta_node/.env" ]; then
                echo_error "Failed to create veriscope_ta_node/.env"
                return 1
            fi

            # Update localhost URLs to Docker service names on host
            echo_info "Updating .env for Docker networking on host..."
            portable_sed 's|http://localhost:8545|http://nethermind:8545|g' veriscope_ta_node/.env
            portable_sed 's|ws://localhost:8545|ws://nethermind:8545|g' veriscope_ta_node/.env
            portable_sed 's|http://localhost:8000|http://nginx:80|g' veriscope_ta_node/.env
            portable_sed 's|redis://127.0.0.1:6379|redis://redis:6379|g' veriscope_ta_node/.env
            portable_sed 's|/opt/veriscope/veriscope_ta_node/artifacts/|/app/artifacts/|g' veriscope_ta_node/.env

            echo_info "TA node .env configured (changes are immediately visible in container via bind mount)"
            echo_warn "Remember to run 'create-sealer' to generate Trust Anchor keypair"
        else
            echo_warn "No ta-node-env template found in $chain_dir"
            echo_info "Checked: $chain_dir/ta-node-env"
        fi
    else
        echo_info "veriscope_ta_node/.env already exists (not overwriting)"
    fi

    # Setup Nethermind configuration if nethermind directory exists
    if [ -d "nethermind" ] || [ -d "/opt/nm" ]; then
        echo_info "Setting up Nethermind configuration for $VERISCOPE_TARGET..."

        local nm_dir="${NETHERMIND_DIR:-./nethermind}"
        mkdir -p "$nm_dir"

        # Copy chain spec
        if [ -f "$chain_dir/shyftchainspec.json" ]; then
            echo_info "Copying chain specification..."
            cp "$chain_dir/shyftchainspec.json" "$nm_dir/"
            echo_info "Chain spec copied to $nm_dir/shyftchainspec.json"
        fi

        # Copy static nodes
        if [ -f "$chain_dir/static-nodes.json" ]; then
            echo_info "Copying static node list..."
            cp "$chain_dir/static-nodes.json" "$nm_dir/"
            echo_info "Static nodes copied to $nm_dir/static-nodes.json"
        fi

        echo_info "Nethermind configuration updated"
        echo_warn "Restart Nethermind container to apply changes"
    else
        echo_info "Nethermind directory not found (skipping Nethermind config)"
    fi

    echo_info "Chain configuration completed for $VERISCOPE_TARGET"
}

# ============================================================================
# STATIC NODES MANAGEMENT
# ============================================================================

# Refresh static nodes from ethstats
# Queries ethstats WebSocket server to get current list of network nodes
# Updates static-nodes.json and optionally restarts Nethermind
# Returns: 0 on success, 1 on failure
refresh_static_nodes() {
    echo_info "Refreshing static nodes from ethstats..."

    # Load environment
    if [ ! -f ".env" ]; then
        echo_error ".env file not found"
        return 1
    fi

    source .env

    if [ -z "$VERISCOPE_TARGET" ]; then
        echo_error "VERISCOPE_TARGET not set in .env. Please run setup-chain first."
        return 1
    fi

    # Determine ethstats enodes endpoint based on network
    local ethstats_get_enodes
    case "$VERISCOPE_TARGET" in
        "veriscope_testnet")
            ethstats_get_enodes="wss://fedstats.veriscope.network/primus/?_primuscb=1627594389337-0"
            ;;
        "fed_testnet")
            ethstats_get_enodes="wss://stats.testnet.shyft.network/primus/?_primuscb=1627594389337-0"
            ;;
        "fed_mainnet")
            ethstats_get_enodes="wss://stats.shyft.network/primus/?_primuscb=1627594389337-0"
            ;;
        *)
            echo_error "Invalid VERISCOPE_TARGET: $VERISCOPE_TARGET"
            return 1
            ;;
    esac

    echo_info "Querying ethstats at $ethstats_get_enodes..."

    # Check if wscat is available
    if ! command -v wscat &> /dev/null; then
        echo_warn "wscat not found. Installing..."
        if command -v npm &> /dev/null; then
            npm install -g wscat
        else
            echo_error "npm not found. Cannot install wscat."
            echo_info "Please install Node.js/npm or wscat manually"
            return 1
        fi
    fi

    # Create temporary file for static nodes
    local temp_file=$(mktemp)
    local static_nodes_file="chains/$VERISCOPE_TARGET/static-nodes.json"

    echo_info "Fetching current enode list from ethstats..."

    # Query ethstats for current nodes using Alpine container (macOS compatible)
    # This uses wscat + grep approach, running in Alpine where grep -P works
    # Key: Must wait after connecting before sending ready message to receive init response
    local nodes_json=$(docker run --rm node:alpine sh -c "
        npm install -g wscat > /dev/null 2>&1
        apk add --no-cache jq grep coreutils > /dev/null 2>&1

        # Send ready message after brief delay, then wait for response
        (sleep 2 && echo '{\"emit\":[\"ready\"]}' && sleep 5) | timeout 10 wscat --connect '$ethstats_get_enodes' 2>/dev/null | \
            grep enode | \
            jq '.emit[1].nodes' 2>/dev/null | \
            grep -oP '\"enode://[^\"]*\"' | \
            awk 'BEGIN {print \"[\"} {if(NR>1) printf \",\\n\"; printf \"  %s\", \$0} END {print \"\\n]\"}'
    " 2>/dev/null | jq -c '.')

    # Validate the generated JSON and check if not empty
    if [ ! -z "$nodes_json" ] && jq empty <<<"$nodes_json" >/dev/null 2>&1; then
        local enode_count
        enode_count=$(jq -r 'length' <<<"$nodes_json" 2>/dev/null)
        enode_count=${enode_count:-0}

        if [ "$enode_count" -gt 0 ]; then
            printf '%s' "$nodes_json" | jq '.' > "$temp_file"
            echo_info "Successfully retrieved $enode_count static nodes"

            # Update static-nodes.json
            cp "$temp_file" "$static_nodes_file"
            echo_info "Updated $static_nodes_file"

            # Display the nodes
            echo_info "Current static nodes:"
            cat "$static_nodes_file"
        else
            echo_warn "No static nodes retrieved from ethstats"
            echo_info "Keeping existing static-nodes.json unchanged"
            cat "$static_nodes_file"
        fi
    else
        echo_error "Failed to parse static nodes from ethstats output"
        echo_info "Keeping existing static-nodes.json unchanged"
    fi

    rm -f "$temp_file"

    # Get this node's enode information from Nethermind
    echo ""
    echo_info "Retrieving this node's enode information..."

    # Check if Nethermind is running
    if ! docker compose -f "$COMPOSE_FILE" ps nethermind | grep -q "Up"; then
        echo_warn "Nethermind container not running"
        echo_info "Start services and run this command again to update enode contact info"
        return 0
    fi

    # Get the project name and construct the network name dynamically
    local project_name=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // "veriscope"')
    local network_name="${project_name}_veriscope"

    echo_info "Using Docker network: $network_name"

    # Verify network exists
    if ! docker network inspect "$network_name" >/dev/null 2>&1; then
        echo_error "Docker network '$network_name' not found"
        echo_info "Please ensure Docker Compose services are running"
        return 1
    fi

    # Query Nethermind for node info using internal Docker network
    # Run curl from a temporary Alpine container with access to the internal network
    local enode=$(docker run --rm --network "$network_name" alpine sh -c 'apk add -q curl jq && curl -m 10 -s -X POST -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1, \"method\":\"admin_nodeInfo\", \"params\":[]}" http://nethermind:8545/ | jq -r .result.enode' 2>/dev/null)

    if [ ! -z "$enode" ] && [ "$enode" != "null" ]; then
        echo_info "This node's enode: $enode"

        # Update .env with enode contact info
        if grep -q "^NETHERMIND_ETHSTATS_CONTACT=" .env; then
            portable_sed "s#^NETHERMIND_ETHSTATS_CONTACT=.*#NETHERMIND_ETHSTATS_CONTACT=$enode#" .env
        else
            echo "NETHERMIND_ETHSTATS_CONTACT=$enode" >> .env
        fi

        echo_info "Updated NETHERMIND_ETHSTATS_CONTACT in .env"
    else
        echo_warn "Could not retrieve enode information from Nethermind"
    fi

    # Ask user if they want to restart Nethermind and clear peer database
    echo ""
    echo_warn "To apply changes, Nethermind needs to restart with cleared peer database"
    echo_warn "This will remove cached peer information and force reconnection"

    # Check if running interactively
    if [ -t 0 ]; then
        echo -n "Restart Nethermind and clear peer cache? (y/N): "
        read -r confirm
    else
        # Non-interactive mode - auto-confirm restart
        confirm="y"
        echo_info "Running in non-interactive mode - automatically restarting Nethermind"
    fi

    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo_info "Stopping Nethermind..."
        docker compose -f "$COMPOSE_FILE" stop nethermind

        echo_info "Clearing peer database..."
        # Clear discovery and peer databases from volume using temporary alpine container
        docker run --rm -v veriscope_nethermind_data:/data alpine sh -c "rm -f /data/db/discoveryNodes/SimpleFileDb.db /data/db/peers/SimpleFileDb.db" 2>/dev/null || true
        echo_info "Peer cache cleared"

        echo_info "Starting Nethermind with updated configuration..."
        docker compose -f "$COMPOSE_FILE" up -d nethermind
        echo_info "Nethermind restarted successfully"
    else
        echo_info "Skipping Nethermind restart. Changes will apply on next restart."
    fi

    echo_info "Static nodes refresh completed"
}

# ============================================================================
# CHAINSPEC UPDATE
# ============================================================================

# Update chainspec from remote URL
# Downloads latest chainspec, validates it, and updates if different
# Environment variables:
#   SHYFT_CHAINSPEC_URL - URL to download chainspec from (optional)
# Returns: 0 on success, 1 on failure
update_chainspec() {
    echo_info "Updating chainspec from remote URL..."

    # Load environment
    if [ ! -f ".env" ]; then
        echo_error ".env file not found"
        return 1
    fi

    source .env

    if [ -z "$VERISCOPE_TARGET" ]; then
        echo_error "VERISCOPE_TARGET not set in .env. Please run setup-chain first."
        return 1
    fi

    # Determine chainspec URL based on network if not set
    local chainspec_url="${SHYFT_CHAINSPEC_URL}"
    if [ -z "$chainspec_url" ]; then
        case "$VERISCOPE_TARGET" in
            "fed_mainnet")
                chainspec_url="https://spec.shyft.network/ShyftMainnet-current.json"
                ;;
            "fed_testnet")
                chainspec_url="https://spec.shyft.network/ShyftTestnet-current.json"
                ;;
            "veriscope_testnet")
                echo_warn "No default chainspec URL for veriscope_testnet"
                echo_info "Set SHYFT_CHAINSPEC_URL environment variable to specify URL"
                return 1
                ;;
            *)
                echo_error "Unknown network: $VERISCOPE_TARGET"
                return 1
                ;;
        esac
    fi

    echo_info "Chainspec URL: $chainspec_url"

    local chain_dir="chains/$VERISCOPE_TARGET"
    local chainspec_file="$chain_dir/shyftchainspec.json"

    if [ ! -f "$chainspec_file" ]; then
        echo_error "Chainspec file not found: $chainspec_file"
        return 1
    fi

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        echo_error "jq not found. Please install jq to use this feature."
        return 1
    fi

    # Download chainspec to temporary file
    local temp_file=$(mktemp)
    echo_info "Downloading chainspec..."

    if ! curl -f -s -o "$temp_file" "$chainspec_url"; then
        echo_error "Failed to download chainspec from $chainspec_url"
        rm -f "$temp_file"
        return 1
    fi

    # Validate file size (at least 5KB)
    local file_size=$(wc -c < "$temp_file")
    if [ "$file_size" -lt 5120 ]; then
        echo_error "Downloaded file is too small ($file_size bytes). Expected at least 5KB."
        rm -f "$temp_file"
        return 1
    fi

    echo_info "Downloaded $file_size bytes"

    # Validate JSON
    if ! jq . "$temp_file" > /dev/null 2>&1; then
        echo_error "Downloaded file is not valid JSON. Rejecting update."
        rm -f "$temp_file"
        return 1
    fi

    echo_info "Downloaded chainspec is valid JSON"

    # Compare with existing chainspec
    if cmp -s "$temp_file" "$chainspec_file"; then
        echo_info "Chainspec is identical to current version. No update needed."
        rm -f "$temp_file"
        return 0
    fi

    echo_warn "Chainspec has changed!"

    # Show diff if available
    if command -v diff >/dev/null 2>&1; then
        echo_info "Changes detected:"
        diff -u "$chainspec_file" "$temp_file" | head -20 || true
    fi

    # Backup existing chainspec
    local backup_file="${chainspec_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$chainspec_file" "$backup_file"
    echo_info "Backed up existing chainspec to: $backup_file"

    # Update chainspec
    cp "$temp_file" "$chainspec_file"
    chmod 0644 "$chainspec_file"
    rm -f "$temp_file"

    echo_info "Chainspec updated successfully: $chainspec_file"

    # Update Nethermind container if running
    if docker compose -f "$COMPOSE_FILE" ps nethermind 2>/dev/null | grep -q "Up"; then
        echo_warn "Nethermind is running. Changes will take effect after restart."

        # Check if running interactively
        if [ -t 0 ]; then
            echo -n "Restart Nethermind now? (y/N): "
            read -r confirm
        else
            # Non-interactive mode - don't auto-restart
            confirm="n"
        fi

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo_info "Restarting Nethermind..."
            docker compose -f "$COMPOSE_FILE" restart nethermind
            echo_info "Nethermind restarted with new chainspec"
        else
            echo_info "Skipping restart. Run 'docker compose restart nethermind' to apply changes."
        fi
    else
        echo_info "Nethermind is not running. Changes will apply on next start."
    fi

    echo_info "Chainspec update completed"
}
