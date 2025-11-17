#!/bin/bash
# Veriscope Bare-Metal Scripts - Dependencies Module
# System dependencies installation and updates

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# SYSTEM DEPENDENCIES
# ============================================================================

refresh_dependencies() {
	echo_info "Updating system dependencies..."
	apt-get -y update
	apt-get install -y software-properties-common curl sudo wget build-essential systemd netcat-openbsd bc lsb-release

	# Check Ubuntu version to determine if PPAs are needed
	local ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "24.04")
	local ubuntu_codename=$(lsb_release -cs 2>/dev/null || echo "unknown")
	echo_info "Detected Ubuntu $ubuntu_version ($ubuntu_codename)"

	# Only add PPAs for Ubuntu versions known to be supported (< 25.04)
	# Newer Ubuntu versions ship with PHP 8.3 in default repos
	if [ "$(echo "$ubuntu_version < 25.00" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
		echo_info "Adding ondrej/php and ondrej/nginx PPAs..."
		add-apt-repository -y ppa:ondrej/php || echo_warn "Failed to add ondrej/php PPA"
		add-apt-repository -y ppa:ondrej/nginx || echo_warn "Failed to add ondrej/nginx PPA"
	else
		echo_info "Skipping PPAs (Ubuntu $ubuntu_version has PHP 8.3 in default repos)"
	fi

	# Update package lists after adding PPAs
	apt-get -y update

	# NodeSource setup script does apt update
	curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -

	DEBIAN_FRONTEND=noninteractive apt -y upgrade

	DEBIAN_FRONTEND=noninteractive apt-get -qq -y -o Acquire::https::AllowRedirect=false install \
		vim git libsnappy-dev libc6-dev libc6 unzip make jq moreutils \
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
	cp scripts-v2/ntpdate /etc/cron.daily/
	cp scripts-v2/journald /etc/cron.daily/
	chmod +x /etc/cron.daily/journald
	chmod +x /etc/cron.daily/ntpdate

	/etc/cron.daily/ntpdate

	echo_info "Dependencies refreshed successfully"
	return 0
}
