#!/bin/bash
set -e

VERISCOPE_SERVICE_HOST="${VERISCOPE_SERVICE_HOST:=unset}"
VERISCOPE_COMMON_NAME="${VERISCOPE_COMMON_NAME:=unset}"
VERISCOPE_TARGET="${VERISCOPE_TARGET:=unset}"
# INSTALL_ROOT="${VERISCOPE_INSTALL_ROOT:=/opt/veriscope}"
INSTALL_ROOT="/opt/veriscope"

# Check script is run with sudo
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run with sudo or as root"
	exit 1
fi

# Check location of install
cd $INSTALL_ROOT
if [ $? -ne 0 ]; then
	echo "$INSTALL_ROOT not found"
	exit 1
fi
echo "+ Install root will be $INSTALL_ROOT"

# Load .env file
if [ -f ".env" ]; then
	set -o allexport
	source .env
	set +o allexport
fi

# Ensure necessary information is provided
if [ $VERISCOPE_SERVICE_HOST = 'unset' ]; then
	echo "Please set VERISCOPE_SERVICE_HOST in .env"
	exit 1
fi
if [ $VERISCOPE_COMMON_NAME = 'unset' ]; then
	echo "Please set VERISCOPE_COMMON_NAME in .env"
	exit 1
fi

# Rig variables based on chosen target
case "$VERISCOPE_TARGET" in
	"veriscope_testnet")
		ETHSTATS_HOST="wss://fedstats.veriscope.network/api"
		ETHSTATS_GET_ENODES="wss://fedstats.veriscope.network/primus/?_primuscb=1627594389337-0"
		ETHSTATS_SECRET="Oogongi4"
		CHAINSPEC_URL="${SHYFT_CHAINSPEC_URL}"
		;;

	"fed_testnet")
		ETHSTATS_HOST="wss://stats.testnet.shyft.network/api"
		ETHSTATS_GET_ENODES="wss://stats.testnet.shyft.network/primus/?_primuscb=1627594389337-0"
		ETHSTATS_SECRET="Ish9phieph"
		CHAINSPEC_URL="${SHYFT_CHAINSPEC_URL:-https://spec.shyft.network/ShyftTestnet-current.json}"
		;;

	"fed_mainnet")
		ETHSTATS_HOST="wss://stats.shyft.network/api"
		ETHSTATS_GET_ENODES="wss://stats.shyft.network/primus/?_primuscb=1627594389337-0"
		ETHSTATS_SECRET="uL4tohChia"
		CHAINSPEC_URL="${SHYFT_CHAINSPEC_URL:-https://spec.shyft.network/ShyftMainnet-current.json}"
		;;

	*)
		echo "VERISCOPE_TARGET must be set to veriscope_testnet, fed_testnet, or fed_mainnet"
		exit 1
		;;
esac

# to copy this file in case of changes in contracts. However, the trust anchor PK,
# contract, and account credentials in the target network will all need to be preserved.
NETHERMIND_TARBALL="https://github.com/NethermindEth/nethermind/releases/download/1.15.0/nethermind-1.15.0-e00406f5-linux-x64.zip"
NETHERMIND_DEST="/opt/nm"
NETHERMIND_CFG="/opt/nm/config.cfg"
ENVDEST=$INSTALL_ROOT/veriscope_ta_dashboard/.env
APACHECONFDIR=/etc/nginx/sites-enabled
APACHE2CONF=$APACHECONFDIR/laravel.conf

NC='\033[0m'
GREEN='\033[0;32m'

function create_sealer_pk {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	su $SERVICE_USER -c "npm install web3 dotenv"
	local OUTPUT=$(node -e 'require("./create-account").trustAnchorCreateAccount()')
	SEALERACCT=$(echo $OUTPUT | jq -r '.address')
	SEALERPK=$(echo $OUTPUT | jq -r '.privateKey')
}

function install_redis {
	if systemctl is-active --quiet redis; then
		echo "Redis server is already installed."
	else
		systemctl start redis
	fi
}

function install_redis_bloom {
	if systemctl is-active --quiet redis; then
		echo "Redis server is already installed."
	else
		systemctl start redis
	fi
	# Note that Redis bloom filter is available in redis stack that should have been installed already
	echo "To check if bloom filter is available, run: redis-cli MODULE LIST"
}

function refresh_dependencies() {
  apt-get -y  update
  apt-get install -y software-properties-common curl sudo wget build-essential systemd netcat
	add-apt-repository >/dev/null -yn ppa:ondrej/php
	add-apt-repository >/dev/null -yn ppa:ondrej/nginx
	# nodesource's script does an apt update
	curl -fsSL https://deb.nodesource.com/setup_14.x | sudo -E bash -

	DEBIAN_FRONTEND=noninteractive apt -y upgrade

	DEBIAN_FRONTEND=noninteractive apt-get -qq -y -o Acquire::https::AllowRedirect=false install  vim git libsnappy-dev libc6-dev libc6 unzip make jq ntpdate moreutils php8.3-fpm php8.3-dom php8.3-zip php8.3-mbstring php8.3-curl php8.3-dom php8.3-gd php8.3-imagick php8.3-pgsql php8.3-gmp php8.3-redis php8.3-mbstring nodejs build-essential postgresql nginx pwgen certbot
	apt-get install -y protobuf-compiler libtiff5-dev libjpeg8-dev libopenjp2-7-dev zlib1g-dev \
    libfreetype6-dev liblcms2-dev libwebp-dev tcl8.6-dev tk8.6-dev python3-tk python3-pip \
    libharfbuzz-dev libfribidi-dev libxcb1-dev
  git config --global url."https://github.com/".insteadOf git@github.com:
	git config --global url."https://".insteadOf git://
	pg_ctlcluster 12 main start
	if ! command -v wscat; then
		npm install -g wscat
	fi

	SHARED_SECRET=$(pwgen -B 10 1)

	# force upgrade composer by reinstalling
	# from https://getcomposer.org/doc/faqs/how-to-install-composer-programmatically.md
	EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
	php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
	ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
	if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]
	then
		>&2 echo 'ERROR: Invalid php conmposer installer checksum'
		rm composer-setup.php
		exit 1
	fi
	php composer-setup.php --quiet
	rm composer-setup.php
	mv composer.phar /usr/local/bin/composer
}

function create_postgres_trustanchor_db {
	PG_PASSWORD=$(pwgen -B 20 1)
	# note that when we set it here, the container we're in doesnt have a .bashrc that sets it so we need to set it explicitly for createuser
	sudo -u postgres psql -U postgres -c "CREATE USER trustanchor WITH CREATEDB PASSWORD '$PG_PASSWORD';"
	sudo -u postgres createdb trustanchor -O trustanchor
	sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$PG_PASSWORD/g" $ENVDEST
}

function install_or_update_nethermind() {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	echo "Installing Nethermind to $NETHERMIND_DEST - target $VERISCOPE_TARGET chain - configuration will be in $NETHERMIND_CFG"

	wget -q -O /tmp/nethermind-dist.zip "$NETHERMIND_TARBALL"
	rm -rf $NETHERMIND_DEST/plugins
	unzip -qq -o -d $NETHERMIND_DEST /tmp/nethermind-dist.zip
	rm -rf $NETHERMIND_DEST/chainspec
	rm -rf $NETHERMIND_DEST/configs

	echo "Installing /opt/nm/shyftchainspec.json genesis file and static node list."
	cp chains/$VERISCOPE_TARGET/static-nodes.json $NETHERMIND_DEST
	cp chains/$VERISCOPE_TARGET/shyftchainspec.json $NETHERMIND_DEST

	if ! test -s "/etc/systemd/system/nethermind.service"; then
		echo "Installing systemd unit for nethermind"
		cp scripts/nethermind.service /etc/systemd/system/nethermind.service
		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/nethermind.service
		systemctl daemon-reload
	fi

	if ! test -s $NETHERMIND_CFG; then
		echo "Installing default $NETHERMIND_CFG"
		create_sealer_pk
		echo "New sealer ACCOUNT/PK will be $SEALERACCT, $SEALERPK"
		echo "MAKE A NOTE OF THIS SOMEPLACE SAFE"
		echo '{
			"Init": {
				"WebSocketsEnabled": true,
				"StoreReceipts" : true,
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
			"Metrics": {
				"Enabled": false
			},
			"EthStats": {
				"Enabled": true,
				"Name": "'"$VERISCOPE_COMMON_NAME"'",
				"Server": "'"$ETHSTATS_HOST"'",
				"Secret": "'"$ETHSTATS_SECRET"'",
				"Contact": "'"$SEALERACCT"'"
			}
		}' | jq > $NETHERMIND_CFG
		sed -i "s/SEALER_PRIVATE_KEY=.*/SEALER_PRIVATE_KEY=$SEALERPK/g" $ENVDEST
		chown -R $SERVICE_USER $NETHERMIND_DEST
	fi
}

function setup_or_renew_ssl {
	systemctl stop nginx
	certbot certonly --standalone -n -m hostmaster@shyft.network --agree-tos -d $VERISCOPE_SERVICE_HOST
	systemctl start nginx
}

function setup_nginx {
	APACHECONFDIR=/etc/nginx/sites-enabled
	APACHE2CONF=$APACHECONFDIR/laravel.conf
	if [ ! -f "$APACHE2CONF" ]; then
		cat <<EOF > $APACHE2CONF
server {
	listen 80;
	listen [::]:80;
	server_name $VERISCOPE_SERVICE_HOST;
	return 301 https://\$host\$request_uri;
}

server {
	listen 443 ssl http2;
	listen [::]:443 ssl http2;
	server_name $VERISCOPE_SERVICE_HOST;
	root $INSTALL_ROOT/veriscope_ta_dashboard/public/;
	index index.php index.html index.htm index.nginx-debian.html;
	ssl_certificate /etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/privkey.pem;
	location / {
		try_files \$uri \$uri/ /index.php?\$query_string;
	}
	location /arena {
		proxy_http_version 1.1;
		proxy_set_header Host \$host;
		proxy_redirect off;
		proxy_pass http://localhost:8080/;
	}
	location ~ \.php$ {
		include snippets/fastcgi-php.conf;
		fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
	}
	location ~ /\.ht {
		deny all;
	}
	location /app/websocketkey {
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_read_timeout 86400;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header Host \$host;
		proxy_redirect off;
		proxy_pass http://localhost:6001;
	}
}
EOF
		sed -i 's/client_max_body_size.*/client_max_body_size 128M;/' /etc/nginx/nginx.conf
		systemctl restart nginx
	fi
}

function install_or_update_nodejs {
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_node
	cp chains/$VERISCOPE_TARGET/ta-node-env .env
	npm install
	if ! test -s "/etc/systemd/system/ta-node-1.service"; then
		echo "Installing systemd unit for ta-node"
		cp $INSTALL_ROOT/scripts/ta-node-1.service /etc/systemd/system/ta-node-1.service
		systemctl daemon-reload
		systemctl enable ta-node-1
	fi
	systemctl restart ta-node-1 || true
	popd >/dev/null
}

function install_or_update_laravel {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "npm install"
	su $SERVICE_USER -c "npm run development"
	chown -R $SERVICE_USER .
	su $SERVICE_USER -c "composer install"
	su $SERVICE_USER -c "php artisan migrate:fresh"
	su $SERVICE_USER -c "php artisan db:seed --class=RolesTableSeeder"
	su $SERVICE_USER -c "php artisan db:seed --class=AdminUserSeeder"
	su $SERVICE_USER -c "php artisan key:generate"
	su $SERVICE_USER -c "php artisan --force passport:install"
	su $SERVICE_USER -c "php artisan encrypt:generate --force"
	su $SERVICE_USER -c "ln -s $INSTALL_ROOT/veriscope_ta_dashboard/storage/oauth-public.key $INSTALL_ROOT/veriscope_ta_node/oauth-public.key"
	chown -R www-data:www-data $INSTALL_ROOT/veriscope_ta_dashboard/storage
	chown -R www-data:www-data $INSTALL_ROOT/veriscope_ta_dashboard/bootstrap/cache
	chmod -R 775 $INSTALL_ROOT/veriscope_ta_dashboard/storage
	popd >/dev/null
	if ! test -s "/etc/systemd/system/ta.service"; then
		echo "Installing systemd unit for ta.service"
		cp scripts/ta.service /etc/systemd/system/ta.service
		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta.service
		systemctl daemon-reload
		systemctl enable ta.service
	fi
	systemctl restart ta || true
	systemctl restart php8.3-fpm || true
}

function restart_all_services() {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	systemctl restart ta || true
	systemctl restart ta-node-1 || true
	systemctl restart horizon || true
	systemctl restart nethermind || true
	systemctl restart php8.3-fpm || true
	systemctl restart nginx || true
}

function refresh_static_nodes() {
	echo "Refreshing static nodes from ethstats..."
	DEST=/opt/nm/static-nodes.json
	echo '[' >$DEST
	wscat -x '{"emit":["ready"]}' --connect $ETHSTATS_GET_ENODES | grep enode | jq '.emit[1].nodes' | grep -oP '"enode://.*?"' | sed '$!s/$/,/' | tee -a $DEST
	echo ']' >>$DEST

	ENODE=`curl -s -X POST -d '{"jsonrpc":"2.0","id":1, "method":"admin_nodeInfo", "params":[]}' http://localhost:8545/ | jq '.result.enode'`
	jq ".EthStats.Contact = $ENODE" $NETHERMIND_CFG | sponge $NETHERMIND_CFG

	rm /opt/nm/nethermind_db/vasp/discoveryNodes/SimpleFileDb.db
	rm /opt/nm/nethermind_db/vasp/peers/SimpleFileDb.db
	systemctl restart nethermind
}

function update_chainspec() {
	echo "Updating chainspec from remote URL..."

	# Check if jq is available
	if ! command -v jq >/dev/null 2>&1; then
		echo "ERROR: jq not found. Please install jq to use this feature."
		return 1
	fi

	# Check if CHAINSPEC_URL is set
	if [ -z "$CHAINSPEC_URL" ]; then
		echo "ERROR: CHAINSPEC_URL not set for network $VERISCOPE_TARGET"
		echo "Set SHYFT_CHAINSPEC_URL environment variable to specify URL"
		return 1
	fi

	echo "Chainspec URL: $CHAINSPEC_URL"

	local chainspec_file="$NETHERMIND_DEST/shyftchainspec.json"

	if [ ! -f "$chainspec_file" ]; then
		echo "ERROR: Chainspec file not found: $chainspec_file"
		return 1
	fi

	# Download chainspec to temporary file
	local temp_file=$(mktemp)
	echo "Downloading chainspec..."

	if ! curl -f -s -o "$temp_file" "$CHAINSPEC_URL"; then
		echo "ERROR: Failed to download chainspec from $CHAINSPEC_URL"
		rm -f "$temp_file"
		return 1
	fi

	# Validate file size (at least 5KB)
	local file_size=$(wc -c < "$temp_file")
	if [ "$file_size" -lt 5120 ]; then
		echo "ERROR: Downloaded file is too small ($file_size bytes). Expected at least 5KB."
		rm -f "$temp_file"
		return 1
	fi

	echo "Downloaded $file_size bytes"

	# Validate JSON
	if ! jq . "$temp_file" > /dev/null 2>&1; then
		echo "ERROR: Downloaded file is not valid JSON. Rejecting update."
		rm -f "$temp_file"
		return 1
	fi

	echo "Downloaded chainspec is valid JSON"

	# Compare with existing chainspec
	if cmp -s "$temp_file" "$chainspec_file"; then
		echo "Chainspec is identical to current version. No update needed."
		rm -f "$temp_file"
		return 0
	fi

	echo "WARNING: Chainspec has changed!"

	# Show diff if available
	if command -v diff >/dev/null 2>&1; then
		echo "Changes detected:"
		diff -u "$chainspec_file" "$temp_file" | head -20 || true
	fi

	# Backup existing chainspec
	local backup_file="${chainspec_file}.backup.$(date +%Y%m%d_%H%M%S)"
	cp "$chainspec_file" "$backup_file"
	echo "Backed up existing chainspec to: $backup_file"

	# Update chainspec
	cp "$temp_file" "$chainspec_file"
	chmod 0644 "$chainspec_file"
	rm -f "$temp_file"

	echo "Chainspec updated successfully: $chainspec_file"

	# Restart Nethermind if running
	if systemctl is-active --quiet nethermind; then
		echo "WARNING: Nethermind is running. Changes will take effect after restart."
		read -p "Restart Nethermind now? (y/N): " -n 1 -r confirm
		echo
		if [[ "$confirm" =~ ^[Yy]$ ]]; then
			echo "Restarting Nethermind..."
			systemctl restart nethermind
			echo "Nethermind restarted with new chainspec"
		else
			echo "Skipping restart. Run 'systemctl restart nethermind' to apply changes."
		fi
	else
		echo "Nethermind is not running. Changes will apply on next start."
	fi

	echo "Chainspec update completed"
}

function daemon_status() {
	systemctl status nethermind ta-node-1 ta horizon
}

function create_admin() {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	su $SERVICE_USER -c "php artisan admin:create"
}

function install_addressproof() {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	su $SERVICE_USER -c "php artisan addressproof:install"
}

function install_passport_client_env(){
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	su $SERVICE_USER -c "php artisan passport:client:env"
}

function install_horizon() {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "composer update laravel/horizon"
	chown -R $SERVICE_USER .
	su $SERVICE_USER -c "php artisan horizon:install"
	chown -R $SERVICE_USER .
	su $SERVICE_USER -c "php artisan migrate"
	if ! test -s "/etc/systemd/system/horizon.service"; then
		echo "Installing systemd unit for horizon"
		cp scripts/horizon.service /etc/systemd/system/horizon.service
		sed -i "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/horizon.service
		systemctl daemon-reload
		systemctl enable horizon
	fi
	systemctl restart horizon || true
	popd >/dev/null
}

function regenerate_webhook_secret() {
	SHARED_SECRET=$(pwgen -B 20 1)

	ENVDEST=$INSTALL_ROOT/veriscope_ta_dashboard/.env
	sed -i "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$SHARED_SECRET#g" $ENVDEST

	ENVDEST=$INSTALL_ROOT/veriscope_ta_node/.env
	sed -i "s#WEBHOOK_CLIENT_SECRET=.*#WEBHOOK_CLIENT_SECRET=$SHARED_SECRET#g" $ENVDEST

	systemctl restart ta-node-1 || true
	systemctl restart ta || true
}

function regenerate_passport_secret() {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "php artisan --force passport:install"
	popd >/dev/null
}

function regenerate_encrypt_secret() {
	if [ -z "$1" ]; then
		SERVICE_USER="$(logname)"
	else
		SERVICE_USER="$1"
	fi
	pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
	su $SERVICE_USER -c "php artisan encrypt:generate --force"
	popd >/dev/null
}

function menu() {
	echo ""
	echo "================================"
	echo "Veriscope Setup (Bare-Metal)"
	echo "================================"
	echo ""
	echo " 1) Refresh dependencies"
	echo " 2) Install or update Nethermind"
	echo " 3) Create PostgreSQL database"
	echo " 4) Setup or renew SSL certificate"
	echo " 5) Setup Nginx"
	echo " 6) Install or update Node.js service"
	echo " 7) Install or update Laravel"
	echo " 8) Refresh static nodes from ethstats"
	echo " 9) Create admin user"
	echo "10) Regenerate webhook secret"
	echo "11) Regenerate Passport secret"
	echo "12) Regenerate encryption secret"
	echo "13) Install Redis"
	echo "14) Install Passport client env"
	echo "15) Install Horizon"
	echo "16) Install address proofs"
	echo "17) Install Redis Bloom filter"
	echo "18) Update chainspec from remote URL"
	echo ""
	echo " i) Full install (all of the above)"
	echo " p) Show daemon status"
	echo " w) Restart all services"
	echo " q) Quit"
	echo " r) Reboot"
	echo ""
	echo -n "Select an option: "
	read -r choice

	case $choice in
		1) refresh_dependencies ; menu ;;
		2) install_or_update_nethermind ; menu ;;
		3) create_postgres_trustanchor_db ; menu ;;
		4) setup_or_renew_ssl ; menu ;;
		5) setup_nginx ; menu ;;
		6) install_or_update_nodejs ; menu ;;
		7) install_or_update_laravel ; menu ;;
		8) refresh_static_nodes ; menu ;;
		9) create_admin; menu ;;
		10) regenerate_webhook_secret; menu ;;
		11) regenerate_passport_secret; menu ;;
		12) regenerate_encrypt_secret; menu ;;
		13) install_redis; menu ;;
		14) install_passport_client_env; menu ;;
		15) install_horizon; menu ;;
		16) install_addressproof; menu ;;
		17) install_redis_bloom; menu ;;
		18) update_chainspec; menu ;;
		"i") refresh_dependencies ; install_or_update_nethermind ; create_postgres_trustanchor_db  ; install_redis ; setup_or_renew_ssl ; setup_nginx ; install_or_update_nodejs ; install_or_update_laravel ; install_horizon ; install_redis_bloom ; refresh_static_nodes; menu ;;
		"p") daemon_status ; menu ;;
		"w") restart_all_services ; menu ;;
		"q") exit 0; ;;
		"r") reboot; ;;
	esac
}

if [ $# -gt 0 ]; then
	for func in $@; do
		$func;
		RC=$?
		if [ $RC -ne 0 ]; then
			echo "$func returned $RC. Exiting."
			exit $RC
		fi
	done
	echo "$@ - completed successfully"
	exit 0
fi

while [ 1 ]; do
	menu
done
