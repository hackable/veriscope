#!/bin/bash
# Veriscope Bare-Metal Scripts - Nginx Configuration Module
# Nginx setup and configuration

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# NGINX CONFIGURATION
# ============================================================================

setup_nginx() {
    echo_info "Configuring Nginx for $VERISCOPE_SERVICE_HOST..."

    local CERTFILE=/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/fullchain.pem
    local CERTKEY=/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/privkey.pem
    local NGINX_CFG=/etc/nginx/sites-enabled/ta-dashboard.conf

    portable_sed "s/user .*;/user $SERVICE_USER www-data;/g" /etc/nginx/nginx.conf

    cat > $NGINX_CFG << NGINX_CONFIG
server {
	listen 80;
	server_name $VERISCOPE_SERVICE_HOST;
	rewrite ^/(.*)\$ https://$VERISCOPE_SERVICE_HOST\$1 permanent;
}

server {
	listen 443 ssl;
	server_name $VERISCOPE_SERVICE_HOST;
	root $INSTALL_ROOT/veriscope_ta_dashboard/public;

	ssl_certificate     $CERTFILE;
	ssl_certificate_key $CERTKEY;
	ssl_protocols       TLSv1 TLSv1.1 TLSv1.2;
	ssl_ciphers         HIGH:!aNULL:!MD5;

	add_header X-Frame-Options "SAMEORIGIN";
	add_header X-XSS-Protection "1; mode=block";
	add_header X-Content-Type-Options "nosniff";

	index index.html index.htm index.php;

	charset utf-8;

	location /arena/ {
		proxy_pass  http://127.0.0.1:8080/arena/;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
	}

	location / {
		try_files \$uri \$uri/ /index.php?\$query_string;
	}

	location = /favicon.ico { access_log off; log_not_found off; }
	location = /robots.txt  { access_log off; log_not_found off; }

	error_page 404 /index.php;

	location ~ \.php\$ {
		fastcgi_split_path_info ^(.+\.php)(/.+)\$;
		fastcgi_pass unix:/var/run/php/php-fpm.sock;
		fastcgi_index index.php;
		fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
		include fastcgi_params;
	}

	location ~ /\.(?!well-known).* {
		deny all;
	}

	location /app/websocketkey {
		proxy_pass             http://127.0.0.1:6001;
		proxy_set_header Host  \$host;
		proxy_set_header X-Real-IP  \$remote_addr;
		proxy_set_header X-VerifiedViaNginx yes;
		proxy_read_timeout                  60;
		proxy_connect_timeout               60;
		proxy_redirect                      off;

		# Allow the use of websockets
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection 'upgrade';
		proxy_set_header Host \$host;
		proxy_cache_bypass \$http_upgrade;
	}
}
NGINX_CONFIG

    systemctl enable nginx
    systemctl restart php8.3-fpm
    systemctl restart nginx

    echo_info "Nginx configured successfully"
    return 0
}
