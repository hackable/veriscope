#!/bin/bash
# Veriscope Bare-Metal Scripts - Services Module
# Application services installation and management

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# NODE.JS APPLICATION
# ============================================================================

install_or_update_nodejs() {
    echo_info "Installing/updating Node.js application..."

    chown -R $SERVICE_USER $INSTALL_ROOT/veriscope_ta_node

    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_node
    su $SERVICE_USER -c "npm install"
    popd >/dev/null

    if ! test -s "/etc/systemd/system/ta-node-1.service"; then
        echo_info "Installing systemd service: ta-node-1"
        cp scripts/ta-node-1.service /etc/systemd/system/
        portable_sed "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta-node-1.service
        systemctl daemon-reload
        systemctl enable ta-node-1
    fi

    systemctl restart ta-node-1

    echo_info "Node.js application installed and running"
    return 0
}

# ============================================================================
# LARAVEL APPLICATION
# ============================================================================

full_laravel_setup() {
    echo_info "Installing/updating Laravel application..."

    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    chown -R $SERVICE_USER .

    local ENVDEST=.env
    portable_sed "s#APP_URL=.*#APP_URL=https://$VERISCOPE_SERVICE_HOST#g" $ENVDEST
    portable_sed "s#SHYFT_ONBOARDING_URL=.*#SHYFT_ONBOARDING_URL=https://$VERISCOPE_SERVICE_HOST#g" $ENVDEST

    echo_info "Building Node.js assets..."
    su $SERVICE_USER -c "npm install"
    su $SERVICE_USER -c "npm run development"

    echo_info "Installing PHP dependencies..."
    su $SERVICE_USER -c "composer install"

    echo_info "Running migrations..."
    su $SERVICE_USER -c "php artisan migrate"
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

        portable_sed "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta-schedule.service
        portable_sed "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta-wss.service
        portable_sed "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/ta.service
    fi

    systemctl daemon-reload

    echo_info "Starting Laravel services..."
    systemctl enable ta-schedule ta-wss ta
    systemctl restart ta-schedule ta-wss ta

    echo_info "Laravel application installed and running"
    return 0
}

install_or_update_laravel() {
    full_laravel_setup
}

run_migrations() {
    echo_info "Running Laravel migrations..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan migrate"
    popd >/dev/null
    echo_info "Migrations completed"
    return 0
}

seed_database() {
    echo_info "Seeding database..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan db:seed"
    popd >/dev/null
    echo_info "Database seeded"
    return 0
}

generate_app_key() {
    echo_info "Generating Laravel APP_KEY..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan key:generate"
    popd >/dev/null
    echo_info "APP_KEY generated"
    return 0
}

clear_cache() {
    echo_info "Clearing Laravel cache..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan cache:clear"
    su $SERVICE_USER -c "php artisan config:clear"
    su $SERVICE_USER -c "php artisan route:clear"
    su $SERVICE_USER -c "php artisan view:clear"
    popd >/dev/null
    echo_info "Cache cleared"
    return 0
}

install_node_deps() {
    echo_info "Installing Node.js dependencies..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "npm install"
    su $SERVICE_USER -c "npm run development"
    popd >/dev/null
    echo_info "Node.js dependencies installed"
    return 0
}

install_laravel_deps() {
    echo_info "Installing Laravel (PHP) dependencies..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "composer install"
    popd >/dev/null
    echo_info "Laravel dependencies installed"
    return 0
}

# ============================================================================
# HORIZON
# ============================================================================

install_horizon() {
    echo_info "Installing Laravel Horizon..."

    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "composer update"
    su $SERVICE_USER -c "php artisan horizon:install"
    su $SERVICE_USER -c "php artisan migrate"
    popd >/dev/null

    if ! test -s "/etc/systemd/system/horizon.service"; then
        echo_info "Installing systemd service: horizon"
        cp scripts/horizon.service /etc/systemd/system/
        portable_sed "s/User=.*/User=$SERVICE_USER/g" /etc/systemd/system/horizon.service
    fi

    systemctl daemon-reload
    systemctl enable horizon
    systemctl restart horizon

    echo_info "Horizon installed and running"
    return 0
}

# ============================================================================
# PASSPORT
# ============================================================================

install_passport() {
    echo_info "Installing/regenerating Laravel Passport..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan --force passport:install"
    popd >/dev/null
    echo_info "Passport installed"
    return 0
}

install_passport_env() {
    echo_info "Installing Passport client environment..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan passportenv:link"
    popd >/dev/null
    echo_info "Passport environment configured"
    return 0
}

# ============================================================================
# ADDRESS PROOFS
# ============================================================================

install_address_proofs() {
    echo_info "Installing address proofs..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan download:addressproof"
    popd >/dev/null
    echo_info "Address proofs installed"
    return 0
}

# ============================================================================
# ADMIN USER
# ============================================================================

create_admin() {
    echo_info "Creating admin user..."
    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard
    su $SERVICE_USER -c "php artisan createuser:admin"
    popd >/dev/null
    echo_info "Admin user created"
    return 0
}

# ============================================================================
# REDIS
# ============================================================================

install_redis() {
    echo_info "Installing Redis server..."

    DEBIAN_FRONTEND=noninteractive apt-get -qq -y -o Acquire::https::AllowRedirect=false install redis-server
    cp /etc/redis/redis.conf /etc/redis/redis.conf.bak
    sed 's/^supervised.*/supervised systemd/' /etc/redis/redis.conf >> /etc/redis/redis.conf.new
    cp /etc/redis/redis.conf.new /etc/redis/redis.conf

    systemctl restart redis.service
    echo_info "Redis installed and running"
    return 0
}

install_redis_bloom() {
    echo_info "Installing RedisBloom filter module..."

    if [ ! -f "/etc/redis/redis.conf" ]; then
        echo_error "Redis server is not installed"
        return 1
    fi

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
    sed -i 's/^.*upload_max_filesize .*/upload_max_filesize = 128M/' /etc/php/8.3/fpm/php.ini

    local NGINX_CFG=/etc/nginx/sites-enabled/ta-dashboard.conf
    if grep -q client_max_body_size $NGINX_CFG; then
        echo_info "NGINX config already updated"
    else
        sed -i 's/listen 443 ssl;/listen 443 ssl;\n\tclient_max_body_size 128M;/' $NGINX_CFG
    fi

    pushd >/dev/null $INSTALL_ROOT/veriscope_ta_dashboard

    # Ensure bloom filter folder permissions
    local directory="storage/app/files"
    if [ ! -d "$directory" ]; then
        mkdir -p "$directory"
    fi

    chmod 775 "$directory"
    chown -R $SERVICE_USER .
    su $SERVICE_USER -c "composer update"

    systemctl restart php8.3-fpm
    systemctl restart nginx

    popd >/dev/null

    echo_info "RedisBloom installed successfully"
    return 0
}
