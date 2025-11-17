#!/bin/bash
set -e

# Veriscope Setup Script v2.0 - Bare-Metal Deployment
# Modularized architecture matching docker-scripts/setup-docker.sh
# For systemd-based deployments on Ubuntu servers
# Linux-only - No macOS/Darwin support

# Check for Linux OS (enforce Linux-only)
if [[ "$OSTYPE" != "linux-gnu"* ]]; then
	echo "ERROR: This script only supports Linux (Ubuntu/Debian with systemd)"
	echo "Detected OS: $OSTYPE"
	exit 1
fi

# ============================================================================
# ENVIRONMENT SETUP
# ============================================================================

VERISCOPE_SERVICE_HOST="${VERISCOPE_SERVICE_HOST:=unset}"
VERISCOPE_COMMON_NAME="${VERISCOPE_COMMON_NAME:=unset}"
VERISCOPE_TARGET="${VERISCOPE_TARGET:=unset}"
INSTALL_ROOT="/opt/veriscope"

# ============================================================================
# SOURCE MODULAR COMPONENTS
# ============================================================================
# Load all modularized functions from scripts/modules/
# Modules provide organized, maintainable functions

MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/modules" && pwd)"

# Core modules (must be loaded first)
source "${MODULES_DIR}/helpers.sh"
source "${MODULES_DIR}/validators.sh"

# Operational modules
source "${MODULES_DIR}/dependencies.sh"
source "${MODULES_DIR}/database.sh"
source "${MODULES_DIR}/ssl.sh"
source "${MODULES_DIR}/chain.sh"
source "${MODULES_DIR}/secrets.sh"
source "${MODULES_DIR}/services.sh"
source "${MODULES_DIR}/systemd-ops.sh"
source "${MODULES_DIR}/nginx.sh"
source "${MODULES_DIR}/health.sh"

# ============================================================================
# SCRIPT-SPECIFIC INITIALIZATION
# ============================================================================

# Check script is run with sudo
if [[ $EUID -ne 0 ]]; then
	echo_error "This script must be run with sudo or as root"
	exit 1
fi

# Check location of install
cd $INSTALL_ROOT
if [ $? -ne 0 ]; then
	echo_error "$INSTALL_ROOT not found"
	exit 1
fi
echo_info "Install root: $INSTALL_ROOT"

# Load .env file
if [ -f ".env" ]; then
	set -o allexport
	source .env
	set +o allexport
fi

# Ensure necessary information is provided
if [ $VERISCOPE_SERVICE_HOST = 'unset' ]; then
	echo_error "Please set VERISCOPE_SERVICE_HOST in .env"
	exit 1
fi
if [ $VERISCOPE_COMMON_NAME = 'unset' ]; then
	echo_error "Please set VERISCOPE_COMMON_NAME in .env"
	exit 1
fi

# Configure network-specific variables including chainspec URL
case "$VERISCOPE_TARGET" in
	"veriscope_testnet")
		ETHSTATS_HOST="wss://fedstats.veriscope.network/api"
		ETHSTATS_GET_ENODES="wss://fedstats.veriscope.network/primus/?_primuscb=1627594389337-0"
		ETHSTATS_SECRET="Oogongi4"
		CHAINSPEC_URL="${SHYFT_CHAINSPEC_URL}"  # Custom URL required for veriscope_testnet
		;;

	"fed_testnet")
		ETHSTATS_HOST="wss://stats.testnet.shyft.network/api"
		ETHSTATS_SECRET="Ish9phieph"
		ETHSTATS_GET_ENODES="wss://stats.testnet.shyft.network/primus/?_primuscb=1627594389337-0"
		CHAINSPEC_URL="${SHYFT_CHAINSPEC_URL:-https://spec.shyft.network/ShyftTestnet-current.json}"
		;;

	"fed_mainnet")
		ETHSTATS_HOST="wss://stats.shyft.network/api"
		ETHSTATS_SECRET="uL4tohChia"
		ETHSTATS_GET_ENODES="wss://stats.shyft.network/primus/?_primuscb=1627594389337-0"
		CHAINSPEC_URL="${SHYFT_CHAINSPEC_URL:-https://spec.shyft.network/ShyftMainnet-current.json}"
		;;

	*)
		echo_error "Please set VERISCOPE_TARGET to veriscope_testnet, fed_testnet, or fed_mainnet"
		exit 1
		;;
esac

# Export network-specific variables for module functions
export ETHSTATS_HOST ETHSTATS_SECRET ETHSTATS_GET_ENODES CHAINSPEC_URL

# Copy chain-specific ta-node env if not exists
cp -n chains/$VERISCOPE_TARGET/ta-node-env veriscope_ta_node/.env 2>/dev/null || true

# Determine service user
if [ -z "$(logname 2>/dev/null)" ]; then
	SERVICE_USER=serviceuser
else
	SERVICE_USER=$(logname)
fi

# Export for modules
export SERVICE_USER
export INSTALL_ROOT
export VERISCOPE_SERVICE_HOST
export VERISCOPE_COMMON_NAME
export VERISCOPE_TARGET

# Configuration variables
CERTFILE=/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/fullchain.pem
CERTKEY=/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/privkey.pem

NETHERMIND_DEST=/opt/nm
NETHERMIND_CFG=$NETHERMIND_DEST/config.cfg
NETHERMIND_VERSION="1.25.4"
NETHERMIND_TARBALL="https://github.com/NethermindEth/nethermind/releases/download/${NETHERMIND_VERSION}/nethermind-${NETHERMIND_VERSION}-20b10b35-linux-x64.zip"
NETHERMIND_RPC="http://localhost:8545"

NGINX_CFG=/etc/nginx/sites-enabled/ta-dashboard.conf

# Export configuration for modules
export CERTFILE CERTKEY
export NETHERMIND_DEST NETHERMIND_CFG NETHERMIND_TARBALL NETHERMIND_RPC
export NGINX_CFG

echo_info "Service user: $SERVICE_USER"
echo_info "Network: $VERISCOPE_TARGET"

# ============================================================================
# SCRIPT-SPECIFIC FUNCTIONS
# ============================================================================
# Functions specific to this main script (not in modules)

# Full install sequence
full_install() {
	echo_info "Starting full installation..."

	# Run preflight checks
	preflight_checks

	# Installation steps
	refresh_dependencies
	setup_chain_config
	install_or_update_nethermind
	create_postgres_trustanchor_db
	install_redis
	setup_or_renew_ssl
	setup_nginx
	create_sealer_keypair
	install_or_update_nodejs
	full_laravel_setup
	install_horizon
	install_redis_bloom
	refresh_static_nodes

	echo_info "Full installation completed!"
	echo ""
	echo_info "Post-installation steps:"
	echo_info "  1. Create admin user: sudo scripts-v2/setup-vasp.sh create_admin"
	echo_info "  2. Install address proofs: sudo scripts-v2/setup-vasp.sh install_address_proofs"
	echo_info ""
	echo_info "Access your Veriscope instance at:"
	echo_info "  Dashboard: https://$VERISCOPE_SERVICE_HOST"
	echo ""

	return 0
}

# ============================================================================
# INTERACTIVE MENU
# ============================================================================

menu() {
	echo ""
	echo "================================"
	echo "Veriscope Docker Management"
	echo "================================"
	echo ""
	echo "Setup & Installation:"
	echo "  1) Check requirements"
	echo "  2) Refresh dependencies"
	echo "  3) Generate PostgreSQL credentials"
	echo "  4) Setup chain configuration (copy artifacts)"
	echo "  5) Generate Trust Anchor keypair (sealer)"
	echo "  6) Obtain SSL certificate (Let's Encrypt)"
	echo "  7) Setup Nginx configuration"
	echo "  8) Start all services"
	echo "  9) Full Laravel setup (install + migrations + seed)"
	echo "  10) Create admin user"
	echo "  11) Install Horizon"
	echo "  12) Install Passport environment"
	echo "  13) Install address proofs"
	echo "  14) Install Redis Bloom filter"
	echo "  15) Refresh static nodes from ethstats"
	echo "  16) Regenerate webhook secret"
	echo "  17) Update chainspec from remote URL"
	echo "  i) Full Install (all of the above)"
	echo ""
	echo "Service Management:"
	echo "  s) Show service status"
	echo "  r) Restart services"
	echo "  q) Stop services"
	echo "  l) Show logs"
	echo ""
	echo "SSL Management:"
	echo "  u) Renew SSL certificate"
	echo "  a) Setup automated certificate renewal"
	echo ""
	echo "Laravel Maintenance:"
	echo "  m) Run migrations"
	echo "  d) Seed database"
	echo "  k) Generate app key"
	echo "  o) Install/regenerate Passport"
	echo "  e) Regenerate encryption secret"
	echo "  c) Clear Laravel cache"
	echo "  n) Install Node.js dependencies"
	echo "  p) Install Laravel (PHP) dependencies"
	echo ""
	echo "Health & Monitoring:"
	echo "  h) Health check"
	echo ""
	echo "Backup & Restore:"
	echo "  b) Backup database"
	echo "  t) Restore database"
	echo ""
	echo "  x) Exit"
	echo ""
	echo -n "Select an option: "
	read -r choice
	echo

	case $choice in
		1)
			preflight_checks
			;;
		2)
			refresh_dependencies
			;;
		3)
			create_postgres_trustanchor_db
			;;
		4)
			setup_chain_config
			;;
		5)
			create_sealer_keypair
			;;
		6)
			setup_or_renew_ssl
			;;
		7)
			setup_nginx
			;;
		8)
			start_services
			;;
		9)
			full_laravel_setup
			;;
		10)
			create_admin
			;;
		11)
			install_horizon
			;;
		12)
			install_passport_env
			;;
		13)
			install_address_proofs
			;;
		14)
			install_redis_bloom
			;;
		15)
			refresh_static_nodes
			;;
		16)
			regenerate_webhook_secret
			;;
		17)
			update_chainspec
			;;
		i)
			full_install
			;;
		s)
			show_status
			;;
		r)
			restart_all_services
			;;
		q)
			stop_services
			;;
		l)
			echo -n "Which service? (press Enter for all services): "
			read -r service
			show_logs "${service:-nethermind}"
			;;
		u)
			renew_ssl_certificate
			;;
		a)
			setup_auto_renewal
			;;
		m)
			run_migrations
			;;
		d)
			seed_database
			;;
		k)
			generate_app_key
			;;
		o)
			install_passport
			;;
		e)
			regenerate_encrypt_secret
			;;
		c)
			clear_cache
			;;
		n)
			install_node_deps
			;;
		p)
			install_laravel_deps
			;;
		h)
			health_check
			;;
		b)
			backup_database
			;;
		t)
			echo -n "Enter backup file path: "
			read -r backup_file
			restore_database "$backup_file"
			;;
		x)
			echo_info "Exiting..."
			exit 0
			;;
		*)
			echo_error "Invalid option"
			;;
	esac

	echo ""
	echo "Press Enter to continue..."
	read -r
	menu
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

if [ $# -gt 0 ]; then
	# Command-line mode
	for func in $@; do
		$func
		RC=$?
		if [ $RC -ne 0 ]; then
			echo_error "$func returned $RC. Exiting."
			exit $RC
		fi
	done
	echo_info "$@ - completed successfully"
	exit 0
fi

# Interactive menu mode
while [ 1 ]; do
	menu
done
