#!/bin/sh
# Nginx entrypoint script with automatic SSL detection
# This script checks if SSL certificates exist and generates the appropriate nginx config

set -e

# Get the domain from environment variable
DOMAIN="${VERISCOPE_SERVICE_HOST:-localhost}"
SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

# Export variables so envsubst can access them
export NGINX_HOST="${DOMAIN}"
export SSL_CERT
export SSL_KEY

echo "Checking for SSL certificates..."
echo "  Domain: ${DOMAIN}"
echo "  Certificate: ${SSL_CERT}"
echo "  Key: ${SSL_KEY}"

# Check if SSL certificates exist
if [ -f "${SSL_CERT}" ] && [ -f "${SSL_KEY}" ]; then
    echo "✓ SSL certificates found - enabling HTTPS"
    SSL_ENABLED="true"
else
    echo "✗ SSL certificates not found - using HTTP only"
    SSL_ENABLED="false"
fi

# Generate nginx configuration
cat > /etc/nginx/conf.d/default.conf <<'EOF'
# HTTP server
server {
    listen 80;
    server_name ${NGINX_HOST};

    # Client settings
    client_max_body_size 128M;
    client_body_buffer_size 128k;

    # Logging
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Let's Encrypt ACME challenge (always available)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

EOF

# Add SSL redirect or content serving based on SSL availability
if [ "${SSL_ENABLED}" = "true" ]; then
    # If SSL is available, add webhook exception and redirect HTTP to HTTPS
    cat >> /etc/nginx/conf.d/default.conf <<'EOF'
    # Internal webhook endpoint (exact match, allow HTTP for internal services)
    location = /webhook {
        fastcgi_pass app:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME /var/www/html/public/index.php;
        include fastcgi_params;

        fastcgi_param HTTP_X_REAL_IP $remote_addr;
        fastcgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
        fastcgi_param HTTP_X_FORWARDED_PROTO $scheme;
        fastcgi_param HTTP_X_FORWARDED_HOST $host;
        fastcgi_param HTTP_X_FORWARDED_PORT $server_port;

        # Timeouts
        fastcgi_connect_timeout 120s;
        fastcgi_send_timeout 120s;
        fastcgi_read_timeout 120s;
    }

    # Redirect all other HTTP traffic to HTTPS
    location / {
        return 301 https://$server_name$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name ${NGINX_HOST};

    # SSL certificates
    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Client settings
    client_max_body_size 128M;
    client_body_buffer_size 128k;

    # Logging
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss;

    # Laravel application (main site)
    root /var/www/html/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass app:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_param HTTP_X_REAL_IP $remote_addr;
        fastcgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
        fastcgi_param HTTP_X_FORWARDED_PROTO $scheme;
        fastcgi_param HTTP_X_FORWARDED_HOST $host;
        fastcgi_param HTTP_X_FORWARDED_PORT $server_port;

        # Timeouts
        fastcgi_connect_timeout 120s;
        fastcgi_send_timeout 120s;
        fastcgi_read_timeout 120s;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    # Bull Arena queue UI
    location /arena {
        proxy_pass http://ta-node:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts
        proxy_connect_timeout 120s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
    }

    # WebSocket key endpoint for Laravel
    location /app/websocketkey {
        proxy_pass http://app:6001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-VerifiedViaNginx yes;
        proxy_read_timeout 60;
        proxy_connect_timeout 60;
        proxy_redirect off;

        # Allow the use of websockets
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass $http_upgrade;
    }

    # Health check endpoint
    location /nginx-health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
else
    # If no SSL, serve content on HTTP
    cat >> /etc/nginx/conf.d/default.conf <<'EOF'
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss;

    # Laravel application (main site)
    root /var/www/html/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass app:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_param HTTP_X_REAL_IP $remote_addr;
        fastcgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
        fastcgi_param HTTP_X_FORWARDED_PROTO $scheme;
        fastcgi_param HTTP_X_FORWARDED_HOST $host;
        fastcgi_param HTTP_X_FORWARDED_PORT $server_port;

        # Timeouts
        fastcgi_connect_timeout 120s;
        fastcgi_send_timeout 120s;
        fastcgi_read_timeout 120s;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    # Bull Arena queue UI
    location /arena {
        proxy_pass http://ta-node:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts
        proxy_connect_timeout 120s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
    }

    # WebSocket key endpoint for Laravel
    location /app/websocketkey {
        proxy_pass http://app:6001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-VerifiedViaNginx yes;
        proxy_read_timeout 60;
        proxy_connect_timeout 60;
        proxy_redirect off;

        # Allow the use of websockets
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass $http_upgrade;
    }

    # Health check endpoint
    location /nginx-health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
fi

# Perform environment variable substitution in the generated config
envsubst '${NGINX_HOST} ${SSL_CERT} ${SSL_KEY}' < /etc/nginx/conf.d/default.conf > /tmp/default.conf
mv /tmp/default.conf /etc/nginx/conf.d/default.conf

echo "Nginx configuration generated successfully"
echo "Configuration summary:"
echo "  SSL Enabled: ${SSL_ENABLED}"
echo "  Domain: ${DOMAIN}"

# Execute the original nginx entrypoint
exec /docker-entrypoint.sh "$@"
