#!/bin/sh
# Certbot Auto-Renewal Entrypoint Script
# Runs certbot renewal check every 12 hours and reloads nginx after successful renewal

set -e

echo "[$(date)] Certbot auto-renewal container started"
echo "Renewal check interval: 12 hours"
echo "Renewal threshold: 30 days before expiry"
echo ""

# Install docker client (alpine-based certbot image)
apk add --no-cache docker-cli >/dev/null 2>&1 || echo "Warning: Could not install docker-cli"

# Trap SIGTERM for graceful shutdown
trap 'echo "[$(date)] Received SIGTERM, shutting down..."; exit 0' TERM

# Main renewal loop
while :; do
    echo "[$(date)] Running certificate renewal check..."

    # Run certbot renew and capture output
    if certbot renew 2>&1 | tee /tmp/certbot-output.log; then
        echo "[$(date)] Certbot renew completed"

        # Check if any certificates were actually renewed
        if grep -q "Cert not yet due for renewal" /tmp/certbot-output.log; then
            echo "[$(date)] No certificates needed renewal"
        elif grep -q "Successfully renewed" /tmp/certbot-output.log || grep -q "Renewing" /tmp/certbot-output.log; then
            echo "[$(date)] Certificates were renewed! Reloading nginx..."

            # Reload nginx using docker socket
            if docker exec veriscope-nginx nginx -s reload 2>/dev/null; then
                echo "[$(date)] ✓ Nginx reloaded successfully"
            else
                echo "[$(date)] ✗ Failed to reload nginx (container may not be running)"
            fi
        else
            echo "[$(date)] Renewal check completed (no action needed)"
        fi
    else
        echo "[$(date)] Certbot renew failed or encountered an error"
    fi

    # Clean up temp file
    rm -f /tmp/certbot-output.log

    # Sleep for 12 hours
    echo "[$(date)] Next renewal check in 12 hours..."
    sleep 12h &
    wait $!
done
