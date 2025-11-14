#!/bin/bash
# Manage secrets for Veriscope Docker deployment

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Generate a random secret
generate_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

# Regenerate webhook secret
regenerate_webhook_secret() {
    local new_secret=$(generate_secret)
    echo_info "New webhook secret: $new_secret"
    echo_warn "Update your .env file with:"
    echo "WEBHOOK_CLIENT_SECRET=$new_secret"
    echo ""
    echo_info "Then restart the app container:"
    echo "docker compose -f $COMPOSE_FILE restart app"
}

# Regenerate Laravel app key
regenerate_app_key() {
    echo_info "Generating new Laravel APP_KEY..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan key:generate
    echo_info "APP_KEY regenerated successfully"
}

# Regenerate Passport keys
regenerate_passport_keys() {
    echo_info "Generating new Laravel Passport keys..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan passport:keys --force
    echo_info "Passport keys regenerated successfully"
}

# Generate Ethereum key pair
generate_eth_keypair() {
    echo_info "Generating new Ethereum keypair..."
    docker compose -f "$COMPOSE_FILE" exec ta-node node -e "
    const ethers = require('ethers');
    const wallet = ethers.Wallet.createRandom();
    console.log('Private Key:', wallet.privateKey);
    console.log('Public Address:', wallet.address);
    "
}

# Regenerate encryption secret (EloquentEncryption)
regenerate_encrypt_secret() {
    echo_info "Generating new encryption secret..."
    docker compose -f "$COMPOSE_FILE" exec app php artisan encrypt:generate --force
    echo_info "Encryption secret regenerated successfully"
}

# Menu
menu() {
    echo ""
    echo "================================"
    echo "Veriscope Secrets Management"
    echo "================================"
    echo ""
    echo "1) Regenerate webhook secret"
    echo "2) Regenerate Laravel APP_KEY"
    echo "3) Regenerate Passport keys"
    echo "4) Regenerate encryption secret (EloquentEncryption)"
    echo "5) Generate Ethereum keypair"
    echo "6) Exit"
    echo ""
    echo -n "Select an option: "
    read -r choice

    case $choice in
        1)
            regenerate_webhook_secret
            ;;
        2)
            regenerate_app_key
            ;;
        3)
            regenerate_passport_keys
            ;;
        4)
            regenerate_encrypt_secret
            ;;
        5)
            generate_eth_keypair
            ;;
        6)
            echo_info "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option"
            ;;
    esac

    echo ""
    echo "Press Enter to continue..."
    read -r
    menu
}

# Main
if [ $# -eq 0 ]; then
    menu
else
    case "$1" in
        webhook)
            regenerate_webhook_secret
            ;;
        app-key)
            regenerate_app_key
            ;;
        passport)
            regenerate_passport_keys
            ;;
        eth)
            generate_eth_keypair
            ;;
        encrypt)
            regenerate_encrypt_secret
            ;;
        *)
            echo "Usage: $0 {webhook|app-key|passport|encrypt|eth}"
            exit 1
            ;;
    esac
fi
