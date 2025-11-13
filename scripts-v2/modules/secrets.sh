#!/bin/bash
# Veriscope Bare-Metal Scripts - Secrets Management Module
# Secret generation and regeneration for various services

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# ETHEREUM KEYPAIR GENERATION
# ============================================================================

create_sealer_keypair() {
    echo_info "Generating new Ethereum keypair for Trust Anchor sealer..."

    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_node

    su $SERVICE_USER -c "npm install web3 dotenv"
    local OUTPUT=$(node -e 'require("./create-account").trustAnchorCreateAccount()')
    SEALERACCT=$(echo $OUTPUT | jq -r '.address')
    SEALERPK=$(echo $OUTPUT | jq -r '.privateKey');
    [[ $SEALERPK =~ 0x(.+) ]]
    SEALERPK=${BASH_REMATCH[1]}

    # Generate webhook secret if not already set
    local WEBHOOK_SECRET=$(generate_password 20)

    local ENVDEST=.env
    portable_sed "s#TRUST_ANCHOR_ACCOUNT=.*#TRUST_ANCHOR_ACCOUNT=$SEALERACCT#g" $ENVDEST
    portable_sed "s#TRUST_ANCHOR_PK=.*#TRUST_ANCHOR_PK=$SEALERPK#g" $ENVDEST
    portable_sed "s#TRUST_ANCHOR_PREFNAME=.*#TRUST_ANCHOR_PREFNAME=\"$VERISCOPE_COMMON_NAME\"#g" $ENVDEST
    portable_sed "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$WEBHOOK_SECRET#g" $ENVDEST

    # Also update dashboard env with same webhook secret
    portable_sed "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$WEBHOOK_SECRET#g" $INSTALL_ROOT/veriscope_ta_dashboard/.env

    popd >/dev/null

    echo_info "Sealer account: $SEALERACCT"
    echo_warn "Sealer private key: $SEALERPK"
    echo_warn "IMPORTANT: Save this private key securely!"

    return 0
}

# ============================================================================
# WEBHOOK SECRET
# ============================================================================

regenerate_webhook_secret() {
    echo_info "Generating new webhook shared secret..."

    SHARED_SECRET=$(generate_password 20)

    local ENVDEST=$INSTALL_ROOT/veriscope_ta_dashboard/.env
    portable_sed "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$SHARED_SECRET#g" $ENVDEST

    ENVDEST=$INSTALL_ROOT/veriscope_ta_node/.env
    portable_sed "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$SHARED_SECRET#g" $ENVDEST

    systemctl restart ta-node-1 || true
    systemctl restart ta || true

    echo_info "Webhook secret regenerated: $SHARED_SECRET"
    return 0
}

# ============================================================================
# PASSPORT SECRET
# ============================================================================

regenerate_passport_secret() {
    echo_info "Regenerating Passport OAuth secret..."

    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan --force passport:install"
    popd >/dev/null

    echo_info "Passport secret regenerated"
    return 0
}

# ============================================================================
# ENCRYPTION SECRET
# ============================================================================

regenerate_encrypt_secret() {
    echo_info "Regenerating encryption secret (EloquentEncryption)..."

    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan encrypt:generate"
    popd >/dev/null

    echo_info "Encryption secret regenerated"
    return 0
}
