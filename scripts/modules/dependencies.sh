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
