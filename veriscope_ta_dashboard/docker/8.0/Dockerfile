FROM ubuntu:22.04

LABEL maintainer="Veriscope"

ARG WWWGROUP

WORKDIR /var/www/html

ENV DEBIAN_FRONTEND noninteractive
ENV TZ=Asia/Jakarta

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update \
    && apt-get install -y gnupg gosu curl ca-certificates zip unzip git supervisor sqlite3 libcap2-bin cron ntpdate \
    && mkdir -p ~/.gnupg \
    && echo "disable-ipv6" >> ~/.gnupg/dirmngr.conf \
    && apt-key adv --homedir ~/.gnupg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys E5267A6C \
    && apt-key adv --homedir ~/.gnupg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C300EE8C \
    && echo "deb http://ppa.launchpad.net/ondrej/php/ubuntu jammy main" > /etc/apt/sources.list.d/ppa_ondrej_php.list \
    && curl -sL https://deb.nodesource.com/setup_lts.x | bash - \
    && curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \
    && echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && apt-get install -y php8.3-cli php8.3-dev php8.3-fpm \
       php8.3-apcu \
       php8.3-bcmath \
       php8.3-curl \
       php8.3-imap \
       php8.3-gd \
       php8.3-gmp \
       php8.3-igbinary \
       php8.3-imagick \
       php8.3-intl \
       php8.3-ldap \
       php8.3-mbstring \
       php8.3-msgpack \
       php8.3-mysql \
       php8.3-pgsql \
       php8.3-readline \
       php8.3-redis \
       php8.3-sqlite3 \
       php8.3-soap \
       php8.3-xdebug \
       php8.3-xml \
       php8.3-yaml \
       php8.3-zip \
    && php -r "readfile('http://getcomposer.org/installer');" | php -- --install-dir=/usr/bin/ --filename=composer \
    && apt-get install -y mysql-client \
    && apt-get install -y nodejs \
    && apt-get install -y yarn \
    && apt-get -y autoremove \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN setcap "cap_net_bind_service=+ep" /usr/bin/php8.3

# Setup ntpdate cronjob for time synchronization
COPY ./scripts/ntpdate /etc/cron.daily/ntpdate
RUN chmod +x /etc/cron.daily/ntpdate

RUN groupadd --force -g $WWWGROUP serviceuser
RUN useradd -ms /bin/bash --no-user-group -g $WWWGROUP -u 1337 serviceuser

# Create supervisord log directory
RUN mkdir -p /var/log/supervisord && chown -R serviceuser:$WWWGROUP /var/log/supervisord

COPY ./veriscope_ta_dashboard/docker/8.0/start-container /usr/local/bin/start-container
COPY ./veriscope_ta_dashboard/docker/8.0/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY ./veriscope_ta_dashboard/docker/8.0/php.ini /etc/php/8.3/cli/conf.d/99-serviceuser.ini
COPY ./veriscope_ta_dashboard/docker/8.0/php.ini /etc/php/8.3/fpm/conf.d/99-serviceuser.ini
COPY ./veriscope_ta_dashboard/docker/8.0/www.conf /etc/php/8.3/fpm/pool.d/www.conf
RUN chmod +x /usr/local/bin/start-container

# Copy Laravel application code (excluding .env which is copied separately)
COPY --chown=serviceuser:$WWWGROUP ./veriscope_ta_dashboard /var/www/html
COPY --chown=serviceuser:$WWWGROUP ./veriscope_ta_node /var/www/veriscope_ta_node

# Install PHP dependencies
RUN cd /var/www/html && composer install --optimize-autoloader --no-interaction

# Copy .env file into the image for runtime configuration
COPY --chown=serviceuser:$WWWGROUP ./veriscope_ta_dashboard/.env /var/www/html/.env

# Install NPM dependencies and build frontend assets
# This ensures assets are built with environment variables from .env
RUN cd /var/www/html && npm install --legacy-peer-deps && npm run prod

# Create Laravel writable directories if they don't exist
RUN mkdir -p /var/www/html/storage/app \
    /var/www/html/storage/framework/cache \
    /var/www/html/storage/framework/sessions \
    /var/www/html/storage/framework/views \
    /var/www/html/storage/logs \
    /var/www/html/bootstrap/cache

# Set proper permissions for Laravel directories
RUN chown -R serviceuser:$WWWGROUP /var/www/html \
    && chmod -R 775 /var/www/html/storage \
    && chmod -R 775 /var/www/html/bootstrap/cache

EXPOSE 8000

ENTRYPOINT ["start-container"]
