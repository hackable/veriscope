#!/bin/bash
set -e

# Veriscope Setup Script v2.0 - Bare-Metal Deployment
# Enhanced with features from docker-scripts/setup-docker.sh
# For systemd-based deployments on Ubuntu servers

VERISCOPE_SERVICE_HOST="${VERISCOPE_SERVICE_HOST:=unset}"
VERISCOPE_COMMON_NAME="${VERISCOPE_COMMON_NAME:=unset}"
VERISCOPE_TARGET="${VERISCOPE_TARGET:=unset}"
INSTALL_ROOT="/opt/veriscope"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Helper functions
echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

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

# Copy chain-specific ta-node env if not exists
cp -n chains/$VERISCOPE_TARGET/ta-node-env veriscope_ta_node/.env 2>/dev/null || true

# Determine service user
if [ -z "$(logname 2>/dev/null)" ]; then
	SERVICE_USER=serviceuser
else
	SERVICE_USER=$(logname)
fi

# Configuration variables
CERTFILE=/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/fullchain.pem
CERTKEY=/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/privkey.pem
SHARED_SECRET=

NETHERMIND_DEST=/opt/nm
NETHERMIND_CFG=$NETHERMIND_DEST/config.cfg
NETHERMIND_TARBALL="https://github.com/NethermindEth/nethermind/releases/download/1.15.0/nethermind-linux-amd64-1.15.0-2b70876-20221228.zip"
NETHERMIND_RPC="http://localhost:8545"

REDISBLOOM_DEST=/opt/RedisBloom
REDISBLOOM_TARBALL="https://github.com/ShyftNetwork/RedisBloom/archive/refs/tags/v2.4.5.zip"

NGINX_CFG=/etc/nginx/sites-enabled/ta-dashboard.conf

echo_info "Service user: $SERVICE_USER"
echo_info "Network: $VERISCOPE_TARGET"

# ============================================================================
# ETHEREUM KEYPAIR GENERATION
# ============================================================================

function create_sealer_pk {
	echo_info "Generating new Ethereum keypair for Trust Anchor sealer..."
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_node

	su $SERVICE_USER -c "npm install web3 dotenv"
	local OUTPUT=$(node -e 'require("./create-account").trustAnchorCreateAccount()')
	SEALERACCT=$(echo $OUTPUT | jq -r '.address')
	SEALERPK=$(echo $OUTPUT | jq -r '.privateKey');
	[[ $SEALERPK =~ 0x(.+) ]]
	SEALERPK=${BASH_REMATCH[1]}

	ENVDEST=.env
	sed -i "s#TRUST_ANCHOR_ACCOUNT=.*#TRUST_ANCHOR_ACCOUNT=$SEALERACCT#g" $ENVDEST
	sed -i "s#TRUST_ANCHOR_PK=.*#TRUST_ANCHOR_PK=$SEALERPK#g" $ENVDEST
	sed -i "s#TRUST_ANCHOR_PREFNAME=.*#TRUST_ANCHOR_PREFNAME=\"$VERISCOPE_COMMON_NAME\"#g" $ENVDEST
	sed -i "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$SHARED_SECRET#g" $ENVDEST

	popd >/dev/null
	
	echo_info "Sealer account: $SEALERACCT"
	echo_warn "Sealer private key: $SEALERPK"
	echo_warn "IMPORTANT: Save this private key securely!"
}

# ============================================================================
# REDIS INSTALLATION
# ============================================================================

function install_redis {
	echo_info "Installing Redis server..."
	DEBIAN_FRONTEND=noninteractive apt-get -qq -y -o Acquire::https::AllowRedirect=false install redis-server
	cp /etc/redis/redis.conf /etc/redis/redis.conf.bak
	sed 's/^supervised.*/supervised systemd/' /etc/redis/redis.conf >> /etc/redis/redis.conf.new
	cp /etc/redis/redis.conf.new /etc/redis/redis.conf

	systemctl restart redis.service
	echo_info "Redis installed and running"
}

function install_redis_bloom {
	echo_info "Installing RedisBloom filter module..."

	if [ -f "/etc/redis/redis.conf" ]; then
		cd /opt
		rm -rf RedisBloom /tmp/buildresult
		apt-get install -y cmake build-essential

		wget -q -O /tmp/redisbloom-dist.zip "$REDISBLOOM_TARBALL"
		unzip -qq -o -d $REDISBLOOM_DEST /tmp/redisbloom-dist.zip

		cd RedisBloom/RedisBloom-2.4.5 && make | tee /tmp/buildresult
		export MODULE=`tail -n1 /tmp/buildresult | awk '{print $2}' | sed 's/\.\.\.//'`
		grep -v redisbloom /etc/redis/redis.conf >/tmp/redis.conf
		echo "loadmodule $MODULE" | sudo tee --append /tmp/redis.conf
		mv /tmp/redis.conf /etc/redis/redis.conf
		systemctl restart redis-server

		sed -i 's/^.*post_max_size.*/post_max_size = 128M/' /etc/php/8.3/fpm/php.ini
		sed -i 's/^.*upload_max_filesize .*/upload_max_filesize = 128M/'  /etc/php/8.3/fpm/php.ini
		if grep -q client_max_body_size $NGINX_CFG; then
			echo_info "NGINX config already updated"
		else
			sed -i 's/listen 443 ssl;/listen 443 ssl;\n	client_max_body_size 128M;/' $NGINX_CFG
		fi

		pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
		
		# Ensure bloom filter folder permissions
		directory="storage/app/files"
		if [ ! -d "$directory" ]; then
			mkdir -p "$directory"
		fi

		chmod 775 "$directory"
		chown -R $SERVICE_USER .
		su $SERVICE_USER -c "composer update"

		systemctl restart php8.3-fpm
		systemctl restart nginx

		echo_info "RedisBloom installed successfully"
	else
		echo_error "Redis server is not installed"
		return 1
	fi
}

# ============================================================================
# DATABASE SETUP
# ============================================================================

function create_postgres_trustanchor_db {
	echo_info "Setting up PostgreSQL database for Trust Anchor..."
	
	if su postgres -c "psql -t -c '\du'" | cut -d \| -f 1 | grep -qw trustanchor; then
		echo_warn "Postgres user trustanchor already exists"
	else
		PGPASS=$(pwgen -B 20 1)
		PGDATABASE=trustanchor
		PGUSER=trustanchor

		sudo -u postgres psql -c "create user $PGUSER with createdb login password '$PGPASS'" || { echo_error "Postgres user creation failed"; exit 1; }
		sudo -u postgres psql -c "create database $PGDATABASE owner $PGUSER" || { echo_error "Postgres database creation failed"; exit 1; }

		ENVDEST=$INSTALL_ROOT/veriscope_ta_dashboard/.env
		sed -i "s#DB_CONNECTION=.*#DB_CONNECTION=pgsql#g" $ENVDEST
		sed -i "s#DB_HOST=.*#DB_HOST=localhost#g" $ENVDEST
		sed -i "s#DB_PORT=.*#DB_PORT=5432#g" $ENVDEST
		sed -i "s#DB_DATABASE=.*#DB_DATABASE=$PGDATABASE#g" $ENVDEST
		sed -i "s#DB_USERNAME=.*#DB_USERNAME=$PGUSER#g" $ENVDEST
		sed -i "s#DB_PASSWORD=.*#DB_PASSWORD=$PGPASS#g" $ENVDEST

		echo_info "Database created: $PGDATABASE"
		echo_info "User: $PGUSER / Password: $PGPASS"
		echo_warn "Save these credentials securely!"
	fi
}

# ============================================================================
# DEPENDENCIES INSTALLATION
# ============================================================================

function refresh_dependencies() {
	echo_info "Updating system dependencies..."
	apt-get -y update
	apt-get install -y software-properties-common curl sudo wget build-essential systemd netcat
	add-apt-repository >/dev/null -yn ppa:ondrej/php
	add-apt-repository >/dev/null -yn ppa:ondrej/nginx
	
	# NodeSource setup script does apt update
	curl -fsSL https://deb.nodesource.com/setup_14.x | sudo -E bash -

	DEBIAN_FRONTEND=noninteractive apt -y upgrade

	DEBIAN_FRONTEND=noninteractive apt-get -qq -y -o Acquire::https::AllowRedirect=false install \
		vim git libsnappy-dev libc6-dev libc6 unzip make jq ntpdate moreutils \
		php8.3-fpm php8.3-dom php8.3-zip php8.3-mbstring php8.3-curl php8.3-gd php8.3-imagick \
		php8.3-pgsql php8.3-gmp php8.3-redis nodejs build-essential postgresql nginx pwgen certbot

	apt-get install -y protobuf-compiler libtiff5-dev libjpeg8-dev libopenjp2-7-dev zlib1g-dev \
		libfreetype6-dev liblcms2-dev libwebp-dev tcl8.6-dev tk8.6-dev python3-tk python3-pip \
		libharfbuzz-dev libfribidi-dev libxcb1-dev

	git config --global url."https://github.com/".insteadOf git@github.com:
	git config --global url."https://".insteadOf git://
	
	pg_ctlcluster 12 main start || true
	
	if ! command -v wscat >/dev/null 2>&1; then
		npm install -g wscat
	fi

	# Install/upgrade Composer
	echo_info "Installing/updating Composer..."
	EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
	php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
	ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
	
	if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
		echo_error "Invalid PHP Composer installer checksum"
		rm composer-setup.php
		exit 1
	fi
	
	php composer-setup.php --install-dir="/usr/local/bin/" --filename=composer --2
	rm composer-setup.php

	if [ $SERVICE_USER == "serviceuser" ]; then
		chown -R $SERVICE_USER /opt/veriscope/
	fi

	# Setup cron jobs
	cp scripts/ntpdate /etc/cron.daily/
	cp scripts/journald /etc/cron.daily/
	chmod +x /etc/cron.daily/journald
	chmod +x /etc/cron.daily/ntpdate

	/etc/cron.daily/ntpdate
	
	echo_info "Dependencies refreshed successfully"
	return 0
}

# ============================================================================
# NETHERMIND INSTALLATION
# ============================================================================

function install_or_update_nethermind() {
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
		cp scripts/nethermind.service /etc/systemd/system/nethermind.service
		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/nethermind.service
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
				"PeerManagerEnabled": true
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
				"EnabledModules": ["Eth", "Parity", "Subscribe", "Trace", "TxPool", "Web3", "Personal", "Proof", "Net", "Health", "Rpc"]
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
}

# ============================================================================
# SSL CERTIFICATE MANAGEMENT
# ============================================================================

function setup_or_renew_ssl {
	echo_info "Obtaining/renewing SSL certificate for $VERISCOPE_SERVICE_HOST..."
	systemctl stop nginx
	certbot certonly -n --agree-tos --register-unsafely-without-email --standalone --preferred-challenges http -d $VERISCOPE_SERVICE_HOST || { 
		echo_error "Certbot failed to get a certificate"
		systemctl start nginx
		exit 1
	}
	
	if [ -f $CERTFILE ]; then
		echo_info "Certificate obtained: $CERTFILE"
	else
		echo_error "Couldn't find certificate file $CERTFILE"
		systemctl start nginx
		exit 1
	fi
	
	systemctl start nginx
	echo_info "SSL certificate configured successfully"
}

# ============================================================================
# NGINX CONFIGURATION
# ============================================================================

function setup_nginx {
	echo_info "Configuring Nginx for $VERISCOPE_SERVICE_HOST..."
	sed -i "s/user .*;/user $SERVICE_USER www-data;/g" /etc/nginx/nginx.conf

	echo '
	server {
		listen 80;
		server_name '$VERISCOPE_SERVICE_HOST';
		rewrite ^/(.*)$ https://'$VERISCOPE_SERVICE_HOST'$1 permanent;
	}

	server {
		listen 443 ssl;
		server_name '$VERISCOPE_SERVICE_HOST';
		root '$INSTALL_ROOT'/veriscope_ta_dashboard/public;

		ssl_certificate     '$CERTFILE';
		ssl_certificate_key '$CERTKEY';
		ssl_protocols       TLSv1 TLSv1.1 TLSv1.2;
		ssl_ciphers         HIGH:!aNULL:!MD5;

		add_header X-Frame-Options "SAMEORIGIN";
		add_header X-XSS-Protection "1; mode=block";
		add_header X-Content-Type-Options "nosniff";

		index index.html index.htm index.php;

		charset utf-8;

		location /arena/ {
			proxy_pass  http://127.0.0.1:8080/arena/;
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
			proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		}

		location / {
			try_files $uri $uri/ /index.php?$query_string;
		}

		location = /favicon.ico { access_log off; log_not_found off; }
		location = /robots.txt  { access_log off; log_not_found off; }

		error_page 404 /index.php;

		location ~ \.php$ {
			fastcgi_split_path_info ^(.+\.php)(/.+)$;
			fastcgi_pass unix:/var/run/php/php-fpm.sock;
			fastcgi_index index.php;
			fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
			include fastcgi_params;
		}

		location ~ /\.(?!well-known).* {
			deny all;
		}

		location /app/websocketkey {
			proxy_pass             http://127.0.0.1:6001;
			proxy_set_header Host  $host;
			proxy_set_header X-Real-IP  $remote_addr;
			proxy_set_header X-VerifiedViaNginx yes;
			proxy_read_timeout                  60;
			proxy_connect_timeout               60;
			proxy_redirect                      off;

			# Allow the use of websockets
			proxy_http_version 1.1;
			proxy_set_header Upgrade $http_upgrade;
			proxy_set_header Connection "upgrade";
			proxy_set_header Host $host;
			proxy_cache_bypass $http_upgrade;
		}
	} ' >$NGINX_CFG

	systemctl enable nginx
	systemctl restart php8.3-fpm
	systemctl restart nginx
	echo_info "Nginx configured successfully"
}

# ============================================================================
# NODE.JS APPLICATION
# ============================================================================

function install_or_update_nodejs {
	echo_info "Installing/updating Node.js application..."
	chown -R $SERVICE_USER $INSTALL_ROOT/veriscope_ta_node

	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_node
	su $SERVICE_USER -c "npm install"
	popd >/dev/null

	pushd >/dev/null $INSTALL_ROOT/
	echo_info "Copying chain-specific artifacts..."
	cp -r chains/$VERISCOPE_TARGET/artifacts $INSTALL_ROOT/veriscope_ta_node/

	if ! test -s "/etc/systemd/system/ta-node-1.service"; then
		echo_info "Installing systemd service: ta-node-1"
		cp scripts/ta-node-1.service /etc/systemd/system/
		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta-node-1.service
		systemctl daemon-reload
		systemctl enable ta-node-1
	fi

	systemctl restart ta-node-1
	regenerate_webhook_secret
	
	echo_info "Node.js application installed and running"
}

# ============================================================================
# LARAVEL APPLICATION
# ============================================================================

function install_or_update_laravel {
	echo_info "Installing/updating Laravel application..."

	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	chown -R $SERVICE_USER .

	ENVDEST=.env
	sed -i "s#APP_URL=.*#APP_URL=https://$VERISCOPE_SERVICE_HOST#g" $ENVDEST
	sed -i "s#SHYFT_ONBOARDING_URL=.*#SHYFT_ONBOARDING_URL=https://$VERISCOPE_SERVICE_HOST#g" $ENVDEST
	regenerate_webhook_secret

	echo_info "Building Node.js assets..."
	su $SERVICE_USER -c "npm install"
	su $SERVICE_USER -c "npm run development"

	echo_info "Installing PHP dependencies..."
	su $SERVICE_USER -c "composer install"
	su $SERVICE_USER -c "php artisan migrate"

	# Initial setup only
	su $SERVICE_USER -c "php artisan db:seed"
	su $SERVICE_USER -c "php artisan key:generate"
	su $SERVICE_USER -c "php artisan passport:install"
	su $SERVICE_USER -c "php artisan encrypt:generate"
	su $SERVICE_USER -c "php artisan passportenv:link"

	chgrp -R www-data ./
	chmod -R 0770 ./storage
	chmod -R g+s ./

	popd >/dev/null

	if ! test -s "/etc/systemd/system/ta.service"; then
		echo_info "Installing systemd services: ta, ta-wss, ta-schedule"
		cp scripts/ta-schedule.service /etc/systemd/system/
		cp scripts/ta-wss.service /etc/systemd/system/
		cp scripts/ta.service /etc/systemd/system/

		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta-schedule.service
		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta-wss.service
		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta.service
	fi

	systemctl daemon-reload

	echo_info "Starting Laravel services..."
	systemctl enable ta-schedule ta-wss ta
	systemctl restart ta-schedule ta-wss ta
	
	echo_info "Laravel application installed and running"
}

# ============================================================================
# SERVICE MANAGEMENT
# ============================================================================

function restart_all_services() {
	echo_info "Restarting all Veriscope services..."
	systemctl restart nethermind
	systemctl restart ta
	systemctl restart ta-wss
	systemctl restart ta-schedule
	systemctl restart nginx
	systemctl restart postgresql
	systemctl restart redis.service
	systemctl restart ta-node-1
	systemctl restart horizon || true
	echo_info "All services restarted successfully"
}

# ============================================================================
# STATIC NODES REFRESH
# ============================================================================

function refresh_static_nodes() {
	echo_info "Refreshing static nodes from ethstats..."

	DEST=/opt/nm/static-nodes.json
	echo '[' >$DEST
	wscat -x '{"emit":["ready"]}' --connect $ETHSTATS_GET_ENODES | grep enode | jq '.emit[1].nodes' | grep -oP '"enode://.*?"' | sed '$!s/$/,/' | tee -a $DEST
	echo ']' >>$DEST
	cat $DEST

	echo
	echo_info "Querying local Nethermind for enode..."

	ENODE=`curl -s -X POST -d '{"jsonrpc":"2.0","id":1, "method":"admin_nodeInfo", "params":[]}' http://localhost:8545/ | jq '.result.enode'`
	echo_info "This node's enode: $ENODE"
	jq ".EthStats.Contact = $ENODE" $NETHERMIND_CFG | sponge $NETHERMIND_CFG

	echo_info "Clearing peer cache and restarting Nethermind..."
	rm /opt/nm/nethermind_db/vasp/discoveryNodes/SimpleFileDb.db 2>/dev/null || true
	rm /opt/nm/nethermind_db/vasp/peers/SimpleFileDb.db 2>/dev/null || true
	systemctl restart nethermind
	
	echo_info "Static nodes refreshed successfully"
}

# ============================================================================
# CHAINSPEC UPDATE (NEW FEATURE)
# ============================================================================

function update_chainspec() {
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
		read -p "Restart Nethermind now? (y/N): " -n 1 -r confirm
		echo
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
}

# ============================================================================
# UTILITIES
# ============================================================================

function daemon_status() {
	systemctl status nethermind ta ta-wss ta-schedule ta-node-1 nginx postgresql redis.service horizon | less
}

function create_admin() {
	echo_info "Creating admin user..."
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "php artisan createuser:admin"
	popd >/dev/null
}

function install_addressproof() {
	echo_info "Installing address proofs..."
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "php artisan download:addressproof"
	popd >/dev/null
}

function install_passport_client_env() {
	echo_info "Installing Passport client environment..."
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "php artisan passportenv:link"
	popd >/dev/null
}

function install_horizon() {
	echo_info "Installing Laravel Horizon..."
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "composer update"
	su $SERVICE_USER -c "php artisan horizon:install"
	su $SERVICE_USER -c "php artisan migrate"
	popd >/dev/null

	pushd >/dev/null $INSTALL_ROOT/
	if ! test -s "/etc/systemd/system/horizon.service"; then
		echo_info "Installing systemd service: horizon"
		cp scripts/horizon.service /etc/systemd/system/
		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/horizon.service
	fi
	popd >/dev/null

	systemctl daemon-reload
	systemctl enable horizon
	systemctl restart horizon
	echo_info "Horizon installed and running"
}

function regenerate_webhook_secret() {
	echo_info "Generating new webhook shared secret..."
	SHARED_SECRET=$(pwgen -B 20 1)

	ENVDEST=$INSTALL_ROOT/veriscope_ta_dashboard/.env
	sed -i "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$SHARED_SECRET#g" $ENVDEST

	ENVDEST=$INSTALL_ROOT/veriscope_ta_node/.env
	sed -i "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$SHARED_SECRET#g" $ENVDEST

	systemctl restart ta-node-1 || true
	systemctl restart ta || true

	echo_info "Webhook secret regenerated"
}

function regenerate_passport_secret() {
	echo_info "Regenerating Passport OAuth secret..."
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "php artisan --force passport:install"
	popd >/dev/null
	echo_info "Passport secret regenerated"
}

function regenerate_encrypt_secret() {
	echo_info "Regenerating encryption secret (EloquentEncryption)..."
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "php artisan encrypt:generate"
	popd >/dev/null
	echo_info "Encryption secret regenerated"
}

# ============================================================================
# INTERACTIVE MENU
# ============================================================================

function menu() {
	echo
	echo "========================================"
	echo " Veriscope Setup v2.0 - Bare-Metal"
	echo "========================================"
	echo
	echo "Setup & Installation:"
	echo "  1) Refresh dependencies"
	echo "  2) Install/update Nethermind"
	echo "  3) Setup PostgreSQL database"
	echo "  4) Obtain/renew SSL certificate"
	echo "  5) Install/update Nginx"
	echo "  6) Install/update Node.js service"
	echo "  7) Install/update Laravel application"
	echo "  8) Refresh static nodes from ethstats"
	echo "  9) Create admin user"
	echo " 10) Install Horizon"
	echo " 11) Install address proofs"
	echo " 12) Install Redis server"
	echo " 13) Install Redis Bloom filter"
	echo " 14) Install Passport client env"
	echo
	echo "Secrets Management:"
	echo " 15) Regenerate webhook secret"
	echo " 16) Regenerate Passport OAuth secret"
	echo " 17) Regenerate encryption secret"
	echo
	echo "Chain Management:"
	echo " 18) Update chainspec from remote URL"
	echo " 19) Generate Trust Anchor keypair"
	echo
	echo "Service Management:"
	echo "  i) Full install (all of the above)"
	echo "  p) Show daemon status"
	echo "  w) Restart all services"
	echo "  r) Reboot system"
	echo "  q) Quit"
	echo
	echo -n "Select an option: "
	read -r choice
	echo

	case $choice in
		1) refresh_dependencies ; menu ;;
		2) install_or_update_nethermind ; menu ;;
		3) create_postgres_trustanchor_db ; menu ;;
		4) setup_or_renew_ssl ; menu ;;
		5) setup_nginx ; menu ;;
		6) install_or_update_nodejs ; menu ;;
		7) install_or_update_laravel ; menu ;;
		8) refresh_static_nodes ; menu ;;
		9) create_admin ; menu ;;
		10) install_horizon ; menu ;;
		11) install_addressproof ; menu ;;
		12) install_redis ; menu ;;
		13) install_redis_bloom ; menu ;;
		14) install_passport_client_env ; menu ;;
		15) regenerate_webhook_secret ; menu ;;
		16) regenerate_passport_secret ; menu ;;
		17) regenerate_encrypt_secret ; menu ;;
		18) update_chainspec ; menu ;;
		19) create_sealer_pk ; menu ;;
		"i") 
			echo_info "Starting full installation..."
			refresh_dependencies
			install_or_update_nethermind
			create_postgres_trustanchor_db
			install_redis
			setup_or_renew_ssl
			setup_nginx
			install_or_update_nodejs
			install_or_update_laravel
			install_horizon
			install_redis_bloom
			refresh_static_nodes
			echo_info "Full installation completed!"
			menu
			;;
		"p") daemon_status ; menu ;;
		"w") restart_all_services ; menu ;;
		"q") echo_info "Exiting..."; exit 0 ;;
		"r") echo_info "Rebooting..."; reboot ;;
		*) echo_error "Invalid option"; menu ;;
	esac
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
