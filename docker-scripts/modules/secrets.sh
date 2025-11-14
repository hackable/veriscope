#!/bin/bash
# Veriscope Docker Scripts - Secrets Management Module
# This module provides secret generation and synchronization functions
#
# Functions:
# - Environment management: update_env_variable
# - Webhook secrets: sync_webhook_secret, regenerate_webhook_secret
# - Trust Anchor keypair: create_sealer_keypair
# - Encryption: regenerate_encrypt_secret

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# ENVIRONMENT VARIABLE MANAGEMENT
# ============================================================================

# Update or add an environment variable in a .env file
# Usage: update_env_variable <file> <key> <value>
# Returns: 0 on success, 1 on failure
update_env_variable() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    if [ ! -f "$env_file" ]; then
        echo_error "Environment file not found: $env_file"
        return 1
    fi

    # Escape special characters in value for sed
    local escaped_value=$(printf '%s\n' "$value" | sed 's/[[\.*^$/]/\\&/g')

    # Check if key exists
    if grep -q "^${key}=" "$env_file"; then
        # Update existing key (supports quoted and unquoted)
        portable_sed "s|^${key}=.*|${key}=\"${escaped_value}\"|" "$env_file"
    else
        # Add new key with quotes
        echo "${key}=\"${value}\"" >> "$env_file"
    fi

    # Verify the update
    if ! grep -q "^${key}=" "$env_file"; then
        echo_error "Failed to update ${key} in ${env_file}"
        return 1
    fi

    return 0
}

# ============================================================================
# WEBHOOK SECRET MANAGEMENT
# ============================================================================

# Synchronize webhook secret between ta_node and dashboard
# This function ensures both .env files have the same WEBHOOK_CLIENT_SECRET
# Returns: 0 on success, 1 on failure
sync_webhook_secret() {
    echo_info "Synchronizing webhook secret..."

    local node_env="veriscope_ta_node/.env"
    local dashboard_env="veriscope_ta_dashboard/.env"
    local webhook_secret=""
    local source_file=""

    # Check if files exist
    if [ ! -f "$node_env" ]; then
        echo_error "TA Node .env not found: $node_env"
        echo_info "Please run setup-chain first"
        return 1
    fi

    if [ ! -f "$dashboard_env" ]; then
        echo_warn "Dashboard .env not found: $dashboard_env"
        echo_info "Webhook secret will only be set in TA Node"
    fi

    # Step 1: Determine source of truth for the secret
    # Priority: 1) Existing ta_node secret, 2) Existing dashboard secret, 3) Generate new

    # Try to extract from ta_node (supports both quoted and unquoted)
    if grep -q "^WEBHOOK_CLIENT_SECRET=" "$node_env"; then
        webhook_secret=$(grep "^WEBHOOK_CLIENT_SECRET=" "$node_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
        if [ ! -z "$webhook_secret" ]; then
            source_file="ta_node"
            echo_info "Found existing webhook secret in TA Node"
        fi
    fi

    # If empty, try dashboard
    if [ -z "$webhook_secret" ] && [ -f "$dashboard_env" ]; then
        if grep -q "^WEBHOOK_CLIENT_SECRET=" "$dashboard_env"; then
            webhook_secret=$(grep "^WEBHOOK_CLIENT_SECRET=" "$dashboard_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
            if [ ! -z "$webhook_secret" ]; then
                source_file="dashboard"
                echo_info "Found existing webhook secret in Dashboard"
            fi
        fi
    fi

    # If still empty, generate new
    if [ -z "$webhook_secret" ]; then
        webhook_secret=$(openssl rand -hex 32 2>/dev/null || xxd -l 32 -p /dev/urandom | tr -d '\n')
        if [ -z "$webhook_secret" ]; then
            echo_error "Failed to generate webhook secret"
            return 1
        fi
        source_file="generated"
        echo_info "Generated new webhook secret"
    fi

    # Validate secret format (should be hex, at least 32 chars)
    if [ ${#webhook_secret} -lt 32 ]; then
        echo_error "Webhook secret is too short (${#webhook_secret} chars, minimum 32)"
        return 1
    fi

    # Step 2: Update ta_node .env with validation
    echo_info "Updating TA Node .env..."
    if ! update_env_variable "$node_env" "WEBHOOK_CLIENT_SECRET" "$webhook_secret"; then
        echo_error "Failed to update TA Node .env"
        return 1
    fi

    # Verify ta_node update
    local node_verify=$(grep "^WEBHOOK_CLIENT_SECRET=" "$node_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
    if [ "$node_verify" != "$webhook_secret" ]; then
        echo_error "TA Node .env verification failed - secret mismatch"
        return 1
    fi

    # Step 3: Update dashboard .env if it exists
    if [ -f "$dashboard_env" ]; then
        echo_info "Updating Dashboard .env..."
        if ! update_env_variable "$dashboard_env" "WEBHOOK_CLIENT_SECRET" "$webhook_secret"; then
            echo_error "Failed to update Dashboard .env"
            return 1
        fi

        # Verify dashboard update
        local dashboard_verify=$(grep "^WEBHOOK_CLIENT_SECRET=" "$dashboard_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
        if [ "$dashboard_verify" != "$webhook_secret" ]; then
            echo_error "Dashboard .env verification failed - secret mismatch"
            return 1
        fi

        echo_info "✓ Webhook secret synchronized successfully"
        echo_info "  Secret length: ${#webhook_secret} characters"
        echo_info "  Source: $source_file"
    else
        echo_warn "✓ Webhook secret set in TA Node only (Dashboard .env not found)"
    fi

    return 0
}

# Regenerate webhook shared secret
# Generates a new webhook secret and updates both services
# Returns: 0 on success, 1 on failure
regenerate_webhook_secret() {
    echo_info "Regenerating webhook shared secret..."
    echo ""

    # Confirm action
    echo_warn "This will generate a new webhook secret and update both services"
    echo_warn "The old secret will be invalidated"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo_info "Operation cancelled"
        return 0
    fi

    local node_env="veriscope_ta_node/.env"
    local dashboard_env="veriscope_ta_dashboard/.env"

    # Check if files exist
    if [ ! -f "$node_env" ]; then
        echo_error "TA Node .env not found: $node_env"
        return 1
    fi

    # Generate new secret (longer than generate_secret default)
    local new_secret=$(openssl rand -hex 32 2>/dev/null || xxd -l 32 -p /dev/urandom | tr -d '\n')

    if [ -z "$new_secret" ]; then
        echo_error "Failed to generate new secret"
        return 1
    fi

    echo_info "Generated new secret (${#new_secret} characters)"
    echo ""

    # Update TA Node .env
    echo_info "Updating TA Node .env..."
    if ! update_env_variable "$node_env" "WEBHOOK_CLIENT_SECRET" "$new_secret"; then
        echo_error "Failed to update TA Node .env"
        return 1
    fi

    # Verify TA Node update
    local node_verify=$(grep "^WEBHOOK_CLIENT_SECRET=" "$node_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
    if [ "$node_verify" != "$new_secret" ]; then
        echo_error "TA Node .env verification failed"
        return 1
    fi
    echo_info "✓ TA Node updated and verified"

    # Update Dashboard .env if it exists
    if [ -f "$dashboard_env" ]; then
        echo_info "Updating Dashboard .env..."
        if ! update_env_variable "$dashboard_env" "WEBHOOK_CLIENT_SECRET" "$new_secret"; then
            echo_error "Failed to update Dashboard .env"
            return 1
        fi

        # Verify Dashboard update
        local dashboard_verify=$(grep "^WEBHOOK_CLIENT_SECRET=" "$dashboard_env" | head -1 | cut -d= -f2 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")
        if [ "$dashboard_verify" != "$new_secret" ]; then
            echo_error "Dashboard .env verification failed"
            return 1
        fi
        echo_info "✓ Dashboard updated and verified"
    else
        echo_warn "Dashboard .env not found - only TA Node updated"
    fi

    echo ""
    echo_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo_info "Restarting services to reload configuration..."
    echo_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local restart_count=0

    # Restart app service
    if docker compose -f "$COMPOSE_FILE" ps app 2>/dev/null | grep -q "Up"; then
        echo_info "Restarting app service..."
        docker compose -f "$COMPOSE_FILE" restart app
        restart_count=$((restart_count + 1))
    else
        echo_warn "App service not running (skip restart)"
    fi

    # Restart ta-node service
    if docker compose -f "$COMPOSE_FILE" ps ta-node 2>/dev/null | grep -q "Up"; then
        echo_info "Restarting ta-node service..."
        docker compose -f "$COMPOSE_FILE" restart ta-node
        restart_count=$((restart_count + 1))
    else
        echo_warn "TA Node service not running (skip restart)"
    fi

    echo ""
    echo_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo_info "✅ Webhook secret regenerated successfully!"
    echo_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ $restart_count -gt 0 ]; then
        echo_info "Restarted $restart_count service(s)"
    else
        echo_warn "No services were restarted - please restart manually"
    fi
}

# ============================================================================
# TRUST ANCHOR KEYPAIR MANAGEMENT
# ============================================================================

# Generate Ethereum sealer keypair for Trust Anchor
# Creates a new Ethereum wallet and stores credentials in veriscope_ta_node/.env
# Returns: 0 on success, 1 on failure
create_sealer_keypair() {
    echo_info "Generating Ethereum keypair for Trust Anchor..."

    # Generate keypair using ethers.js in a one-off container (no need for ta-node to be running)
    local output=$(docker compose -f "$COMPOSE_FILE" run --rm --no-deps -T ta-node node -e "
    const ethers = require('ethers');
    const wallet = ethers.Wallet.createRandom();
    console.log(JSON.stringify({
        address: wallet.address,
        privateKey: wallet.privateKey.substring(2)
    }));
    " 2>/dev/null)

    if [ -z "$output" ]; then
        echo_error "Failed to generate keypair"
        return 1
    fi

    local address=$(echo "$output" | grep -o '"address":"[^"]*"' | cut -d'"' -f4)
    local privatekey=$(echo "$output" | grep -o '"privateKey":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$address" ] || [ -z "$privatekey" ]; then
        echo_error "Failed to parse generated keypair"
        return 1
    fi

    echo_info "Generated Ethereum keypair:"
    echo_info "  Address: $address"
    echo_info "  Private Key: $privatekey"
    echo_warn "SAVE THESE CREDENTIALS SECURELY!"

    # Update veriscope_ta_node/.env
    if [ -f "veriscope_ta_node/.env" ]; then
        echo_info "Updating veriscope_ta_node/.env with keypair..."

        # Update or add TRUST_ANCHOR_ACCOUNT
        if grep -q "^TRUST_ANCHOR_ACCOUNT=" veriscope_ta_node/.env; then
            portable_sed "s#^TRUST_ANCHOR_ACCOUNT=.*#TRUST_ANCHOR_ACCOUNT=$address#" veriscope_ta_node/.env
        else
            echo "TRUST_ANCHOR_ACCOUNT=$address" >> veriscope_ta_node/.env
        fi

        # Update or add TRUST_ANCHOR_PK
        if grep -q "^TRUST_ANCHOR_PK=" veriscope_ta_node/.env; then
            portable_sed "s#^TRUST_ANCHOR_PK=.*#TRUST_ANCHOR_PK=$privatekey#" veriscope_ta_node/.env
        else
            echo "TRUST_ANCHOR_PK=$privatekey" >> veriscope_ta_node/.env
        fi

        # Update or add TRUST_ANCHOR_PREFNAME from VERISCOPE_COMMON_NAME
        if [ ! -z "$VERISCOPE_COMMON_NAME" ] && [ "$VERISCOPE_COMMON_NAME" != "unset" ]; then
            if grep -q "^TRUST_ANCHOR_PREFNAME=" veriscope_ta_node/.env; then
                portable_sed "s#^TRUST_ANCHOR_PREFNAME=.*#TRUST_ANCHOR_PREFNAME=\"$VERISCOPE_COMMON_NAME\"#" veriscope_ta_node/.env
            else
                echo "TRUST_ANCHOR_PREFNAME=\"$VERISCOPE_COMMON_NAME\"" >> veriscope_ta_node/.env
            fi
            echo_info "Set TRUST_ANCHOR_PREFNAME to: $VERISCOPE_COMMON_NAME"
        else
            echo_warn "VERISCOPE_COMMON_NAME not set - please manually set TRUST_ANCHOR_PREFNAME in veriscope_ta_node/.env"
        fi


        echo_info "Trust Anchor credentials saved (visible in container via bind mount)"

        # Synchronize webhook secret between ta_node and dashboard
        sync_webhook_secret
    else
        echo_warn "veriscope_ta_node/.env not found. Please run setup-chain first."
    fi
}

# ============================================================================
# ENCRYPTION SECRET MANAGEMENT
# ============================================================================

# Regenerate encryption secret
# WARNING: This will reset encryption keys and you will lose access to encrypted data
# Returns: 0 on success
regenerate_encrypt_secret() {
    echo_info "Generating new encryption secret..."
    echo_warn "This will reset your encryption keys and you will lose access to encrypted data!"
    # Use 'yes' to automatically answer the prompt
    echo "yes" | docker compose -f "$COMPOSE_FILE" exec -T app php artisan encrypt:generate
    echo_info "Encryption secret regenerated"
}
