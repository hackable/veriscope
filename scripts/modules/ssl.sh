#!/bin/bash
# Veriscope Bare-Metal Scripts - SSL Certificate Module
# SSL certificate management with Let's Encrypt

# Source required modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# SSL CERTIFICATE MANAGEMENT
# ============================================================================

setup_or_renew_ssl() {
    echo_info "Obtaining/renewing SSL certificate for $VERISCOPE_SERVICE_HOST..."

    systemctl stop nginx

    certbot certonly -n --agree-tos --register-unsafely-without-email \
        --standalone --preferred-challenges http -d $VERISCOPE_SERVICE_HOST || {
        echo_error "Certbot failed to get a certificate"
        systemctl start nginx
        return 1
    }

    local CERTFILE=/etc/letsencrypt/live/$VERISCOPE_SERVICE_HOST/fullchain.pem
    if [ -f $CERTFILE ]; then
        echo_info "Certificate obtained: $CERTFILE"
    else
        echo_error "Couldn't find certificate file $CERTFILE"
        systemctl start nginx
        return 1
    fi

    systemctl start nginx
    echo_info "SSL certificate configured successfully"
    return 0
}

renew_ssl_certificate() {
    echo_info "Renewing SSL certificate..."
    setup_or_renew_ssl
}

setup_auto_renewal() {
    echo_info "Setting up automatic certificate renewal..."

    # Create renewal script
    cat > /usr/local/bin/renew-veriscope-ssl.sh << 'RENEWAL_SCRIPT'
#!/bin/bash
systemctl stop nginx
certbot renew --quiet
systemctl start nginx
RENEWAL_SCRIPT

    chmod +x /usr/local/bin/renew-veriscope-ssl.sh

    # Add to crontab (run twice daily)
    (crontab -l 2>/dev/null; echo "0 0,12 * * * /usr/local/bin/renew-veriscope-ssl.sh") | crontab -

    echo_info "Auto-renewal configured (runs twice daily)"
    return 0
}
