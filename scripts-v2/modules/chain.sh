#!/bin/bash
# Veriscope Bare-Metal Scripts - Blockchain Chain Configuration Module
# Nethermind installation, chainspec management, and static nodes

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# NETHERMIND INSTALLATION
# ============================================================================

install_or_update_nethermind() {
    echo_info "Installing Nethermind to $NETHERMIND_DEST for network: $VERISCOPE_TARGET"

    wget -q -O /tmp/nethermind-dist.zip "$NETHERMIND_TARBALL"
    rm -rf $NETHERMIND_DEST/plugins
    unzip -qq -o -d $NETHERMIND_DEST /tmp/nethermind-dist.zip
    rm -rf $NETHERMIND_DEST/chainspec
    rm -rf $NETHERMIND_DEST/configs

    echo_info "Installing chainspec and static nodes..."
    cp chains/$VERISCOPE_TARGET/static-nodes.json $NETHERMIND_DEST
    cp chains/$VERISCOPE_TARGET/shyftchainspec.json $NETHERMIND_DEST

    if ! test -s "/etc/systemd/system/nethermind.service"; then
        echo_info "Installing systemd unit for Nethermind"
        cp scripts-v2/nethermind.service /etc/systemd/system/nethermind.service
        portable_sed "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/nethermind.service
        systemctl daemon-reload
    fi

    if ! test -s $NETHERMIND_CFG; then
        echo_info "Creating Nethermind configuration..."
        echo '{
            "Init": {
                "WebSocketsEnabled": true,
                "StoreReceipts": true,
                "EnableUnsecuredDevWallet": false,
                "IsMining": true,
                "ChainSpecPath": "shyftchainspec.json",
                "BaseDbPath": "nethermind_db/vasp",
                "LogFileName": "/var/log/nethermind.log",
                "StaticNodesPath": "static-nodes.json",
                "DiscoveryEnabled": true,
                "PeerManagerEnabled": true,
                "ProcessingEnabled": true
            },
            "Network": {
                "DiscoveryPort": 30303,
                "P2PPort": 30303,
                "OnlyStaticPeers": false,
                "StaticPeers": null
            },
            "JsonRpc": {
                "Enabled": true,
                "Host": "0.0.0.0",
                "Port": 8545,
                "EnabledModules": ["Admin", "Eth", "Parity", "Subscribe", "Trace", "TxPool", "Web3", "Personal", "Proof", "Net", "Health", "Rpc"]
            },
            "Sync": {
                "SynchronizationEnabled": true,
                "DownloadBodiesInFastSync": true,
                "DownloadReceiptsInFastSync": true,
                "AncientBodiesBarrier": 0,
                "AncientReceiptsBarrier": 0
            },
            "Aura": {
                "ForceSealing": true,
                "AllowAuRaPrivateChains": true
            },
            "HealthChecks": {
                "Enabled": true,
                "UIEnabled": false,
                "PollingInterval": 10,
                "Slug": "/health"
            },
            "Pruning": {
                "Enabled": false
            },
            "EthStats": {
                "Enabled": true,
                "Contact": "not-yet",
                "Secret": "'$ETHSTATS_SECRET'",
                "Name": "'$VERISCOPE_SERVICE_HOST'",
                "Server": "'$ETHSTATS_HOST'"
            }
        }' > $NETHERMIND_CFG
    fi

    echo_info "Setting permissions and restarting Nethermind..."
    if [ $SERVICE_USER == "serviceuser" ]; then
        chown -R $SERVICE_USER /opt/nm/
    else
        chown -R $SERVICE_USER:$SERVICE_USER /opt/nm/
    fi

    systemctl restart nethermind
    echo_info "Nethermind installed and running"
    return 0
}

# ============================================================================
# STATIC NODES REFRESH
# ============================================================================

refresh_static_nodes() {
    echo_info "Refreshing static nodes from ethstats..."

    local DEST=/opt/nm/static-nodes.json
    local TEMP_FILE=$(mktemp)

    # Fetch enodes from ethstats and parse properly
    # Note: wscat adds '> ' prefix to echoed input lines, must strip before jq parsing
    (sleep 2 && echo '{"emit":["ready"]}' && sleep 5) | timeout 10 wscat --connect $ETHSTATS_GET_ENODES 2>/dev/null | \
        sed 's/^> //' | \
        jq -c 'select(.emit[1].nodes != null) | .emit[1].nodes[].info.contact' 2>/dev/null | \
        grep '^"enode://' | \
        jq -s '.' > $TEMP_FILE

    # Validate before overwriting
    if [ ! -s "$TEMP_FILE" ] || ! jq empty "$TEMP_FILE" 2>/dev/null; then
        echo_warn "Failed to fetch static nodes from ethstats, keeping existing file"
        rm -f "$TEMP_FILE"
        return 1
    fi

    # Check if we got valid enodes
    local enode_count=$(jq -r 'length' "$TEMP_FILE" 2>/dev/null)
    if [ -z "$enode_count" ] || [ "$enode_count" -eq 0 ]; then
        echo_warn "No static nodes retrieved from ethstats, keeping existing file"
        rm -f "$TEMP_FILE"
        return 1
    fi

    # Only now overwrite the destination
    mv "$TEMP_FILE" "$DEST"
    echo_info "Successfully updated with $enode_count static nodes"
    cat $DEST

    echo
    echo_info "Querying local Nethermind for enode..."

    local ENODE=`curl -s -X POST -d '{"jsonrpc":"2.0","id":1, "method":"admin_nodeInfo", "params":[]}' http://localhost:8545/ | jq '.result.enode'`
    echo_info "This node's enode: $ENODE"
    jq ".EthStats.Contact = $ENODE" $NETHERMIND_CFG | sponge $NETHERMIND_CFG
    echo_info "Clearing peer cache and restarting Nethermind..."
    rm /opt/nm/nethermind_db/vasp/discoveryNodes/SimpleFileDb.db 2>/dev/null || true
    rm /opt/nm/nethermind_db/vasp/peers/SimpleFileDb.db 2>/dev/null || true
    systemctl restart nethermind

    echo_info "Static nodes refreshed successfully"
    return 0
}

# ============================================================================
# CHAINSPEC UPDATE
# ============================================================================

update_chainspec() {
    echo_info "Updating chainspec from remote URL..."

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        echo_error "jq not found. Please install jq to use this feature."
        return 1
    fi

    # Check if CHAINSPEC_URL is set
    if [ -z "$CHAINSPEC_URL" ]; then
        echo_error "CHAINSPEC_URL not set for network $VERISCOPE_TARGET"
        echo_info "Set SHYFT_CHAINSPEC_URL environment variable to specify URL"
        return 1
    fi

    echo_info "Chainspec URL: $CHAINSPEC_URL"

    local chainspec_file="$NETHERMIND_DEST/shyftchainspec.json"

    if [ ! -f "$chainspec_file" ]; then
        echo_error "Chainspec file not found: $chainspec_file"
        return 1
    fi

    # Download chainspec to temporary file
    local temp_file=$(mktemp)
    echo_info "Downloading chainspec..."

    if ! curl -f -s -o "$temp_file" "$CHAINSPEC_URL"; then
        echo_error "Failed to download chainspec from $CHAINSPEC_URL"
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

    # Restart Nethermind if running
    if systemctl is-active --quiet nethermind; then
        echo_warn "Nethermind is running. Changes will take effect after restart."

        # Check if running interactively
        if [ -t 0 ]; then
            read -p "Restart Nethermind now? (y/N): " -n 1 -r confirm
            echo
        else
            confirm="n"
        fi

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo_info "Restarting Nethermind..."
            systemctl restart nethermind
            echo_info "Nethermind restarted with new chainspec"
        else
            echo_info "Skipping restart. Run 'systemctl restart nethermind' to apply changes."
        fi
    else
        echo_info "Nethermind is not running. Changes will apply on next start."
    fi

    echo_info "Chainspec update completed"
    return 0
}

# ============================================================================
# CHAIN CONFIGURATION
# ============================================================================

setup_chain_config() {
    echo_info "Setting up chain-specific configuration for $VERISCOPE_TARGET..."

    # Copy chain artifacts
    local chain_dir="chains/$VERISCOPE_TARGET"

    if [ ! -d "$chain_dir" ]; then
        echo_error "Chain directory not found: $chain_dir"
        return 1
    fi

    # Copy artifacts to ta-node
    if [ -d "$chain_dir/artifacts" ]; then
        echo_info "Copying chain artifacts..."
        cp -r $chain_dir/artifacts $INSTALL_ROOT/veriscope_ta_node/
    fi

    # Copy ta-node env if not exists
    if [ ! -f "$INSTALL_ROOT/veriscope_ta_node/.env" ]; then
        if [ -f "$chain_dir/ta-node-env" ]; then
            echo_info "Creating veriscope_ta_node/.env from chain template..."
            cp $chain_dir/ta-node-env $INSTALL_ROOT/veriscope_ta_node/.env
        fi
    fi

    echo_info "Chain configuration completed"
    return 0
}

# ============================================================================
# UNINSTALL NETHERMIND
# ============================================================================

uninstall_nethermind() {
    echo_warn "This will completely remove Nethermind and all blockchain data"
    echo_warn "This action cannot be undone!"
    echo ""

    # Check if running interactively
    if [ -t 0 ]; then
        read -p "Are you sure you want to continue? (Y/n): " -r confirm
        echo
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            echo_info "Uninstall cancelled"
            return 1
        fi
    fi

    echo_info "Stopping Nethermind service..."
    systemctl stop nethermind 2>/dev/null || true
    systemctl disable nethermind 2>/dev/null || true

    echo_info "Removing Nethermind installation..."
    rm -rf /opt/nm

    echo_info "Removing systemd service file..."
    rm -f /etc/systemd/system/nethermind.service

    systemctl daemon-reload

    echo_info "✓ Nethermind uninstalled successfully"
    return 0
}
