# Docker Scripts for Veriscope

This directory contains utility scripts for managing Veriscope using Docker Compose. These scripts provide similar functionality to the bare-metal `scripts/` directory, but adapted for Docker deployments.

## Prerequisites

- Docker Engine 20.10 or later
- Docker Compose V2 or later
- Bash shell
- Git

## Production Workflow

**Important**: This Docker setup uses a production-ready isolated approach:

- Application code is **copied into Docker images** at build time
- Host filesystem remains **completely clean** - no modifications by containers
- Configuration files (`.env`) are read via env_file directive
- Network-specific artifacts are stored in **Docker volume** (not visible on host)
- All writable data persisted in named volumes (postgres_data, redis_data, nethermind_data, veriscope_artifacts, app_storage, app_bootstrap_cache)

**Benefits:**
- Zero host filesystem pollution
- Clean separation between host and containers
- Consistent deployments
- Version control friendly
- Production-ready security

**Workflow:**
```bash
# Build images with application code
docker-compose build

# Start services
docker-compose up -d

# View logs
docker-compose logs -f app
docker-compose logs -f ta-node

# After code changes: rebuild and restart
docker-compose build
docker-compose up -d
```

**Switching networks:**
```bash
# Update VERISCOPE_TARGET in .env
echo "VERISCOPE_TARGET=fed_testnet" >> .env

# Run setup to copy new network artifacts to Docker volume
./docker-scripts/setup-docker.sh setup-chain

# Restart ta-node to use new artifacts
docker-compose restart ta-node
```

**Inspecting artifacts (if needed):**
```bash
# List artifacts in Docker volume
docker run --rm -v veriscope_artifacts:/artifacts alpine ls -la /artifacts

# View a specific artifact file
docker run --rm -v veriscope_artifacts:/artifacts alpine cat /artifacts/SomeContract.json
```

## Quick Start

### Initial Setup

```bash
# Make scripts executable
chmod +x docker-scripts/*.sh

# Run the main setup script
./docker-scripts/setup-docker.sh
```

This will launch an interactive menu with all available options.

## Available Scripts

### 1. setup-docker.sh

**Main setup and management script** with interactive menu for all common tasks.

**Usage:**
```bash
# Interactive mode
./docker-scripts/setup-docker.sh

# Command line mode
./docker-scripts/setup-docker.sh <command>
```

**Available commands:**

**Setup & Installation:**
- `check` - Check Docker requirements and environment
- `build` - Build Docker images
- `start` - Start all services
- `stop` - Stop all services
- `restart` - Restart all services
- `gen-postgres` - Generate PostgreSQL credentials
- `setup-chain` - Setup chain-specific configuration (copy artifacts)
- `create-sealer` - Generate Trust Anchor Ethereum keypair
- `obtain-ssl` - Obtain SSL certificate (Let's Encrypt)
- `setup-nginx` - Setup Nginx reverse proxy configuration
- `renew-ssl` - Renew SSL certificates
- `full-laravel-setup` - Full Laravel setup (install + migrate + seed)
- `install-horizon` - Install Laravel Horizon
- `install-passport-env` - Install Passport environment
- `install-address-proofs` - Install address proofs
- `install-redis-bloom` - Display Redis modules info (RedisBloom included)
- `refresh-static-nodes` - Refresh static nodes from ethstats
- `regenerate-webhook-secret` - Regenerate webhook shared secret
- `full-install` - Full installation (all of the above)

**Laravel Maintenance:**
- `migrate` - Run Laravel migrations
- `seed` - Seed database
- `gen-app-key` - Generate Laravel app key
- `install-passport` - Install/regenerate Passport
- `gen-encrypt-secret` - Regenerate encryption secret
- `clear-cache` - Clear Laravel cache
- `install-node` - Install Node.js dependencies
- `install-php` - Install Laravel dependencies

**Operations:**
- `status` - Show service status
- `logs [service]` - Show logs
- `create-admin` - Create admin user
- `health` - Run health check
- `backup` - Backup database
- `restore <file>` - Restore database

**Examples:**
```bash
# Interactive menu
./docker-scripts/setup-docker.sh

# Full automated installation
./docker-scripts/setup-docker.sh full-install

# Full Laravel setup (after containers are running)
./docker-scripts/setup-docker.sh full-laravel-setup

# Quick health check
./docker-scripts/setup-docker.sh health

# View app logs
./docker-scripts/setup-docker.sh logs app

# Install Horizon for queue management
./docker-scripts/setup-docker.sh install-horizon

# Restart services
./docker-scripts/setup-docker.sh restart
```

### 2. logs.sh

**View logs from Docker containers.**

**Usage:**
```bash
./docker-scripts/logs.sh <service> [lines]
```

**Examples:**
```bash
# View ta-node logs (last 100 lines, follow)
./docker-scripts/logs.sh ta-node

# View app logs (last 500 lines, follow)
./docker-scripts/logs.sh app 500

# View all available services
./docker-scripts/logs.sh
```

### 3. exec.sh

**Execute commands in Docker containers.**

**Usage:**
```bash
./docker-scripts/exec.sh <service> [command]
```

**Examples:**
```bash
# Open bash shell in app container
./docker-scripts/exec.sh app

# Open shell in ta-node container
./docker-scripts/exec.sh ta-node

# Connect to PostgreSQL
./docker-scripts/exec.sh postgres psql -U trustanchor trustanchor

# Connect to Redis CLI
./docker-scripts/exec.sh redis redis-cli

# Run Laravel artisan command
./docker-scripts/exec.sh app php artisan migrate

# Run npm command in ta-node
./docker-scripts/exec.sh ta-node npm install
```

### 4. manage-secrets.sh

**Manage secrets and generate keys.**

**Usage:**
```bash
# Interactive mode
./docker-scripts/manage-secrets.sh

# Command line mode
./docker-scripts/manage-secrets.sh <command>
```

**Available commands:**
- `webhook` - Regenerate webhook secret
- `app-key` - Regenerate Laravel APP_KEY
- `passport` - Regenerate Laravel Passport keys
- `encrypt` - Regenerate encryption secret (EloquentEncryption)
- `eth` - Generate new Ethereum keypair

**Examples:**
```bash
# Interactive menu
./docker-scripts/manage-secrets.sh

# Generate new webhook secret
./docker-scripts/manage-secrets.sh webhook

# Regenerate Laravel app key
./docker-scripts/manage-secrets.sh app-key

# Regenerate encryption secret
./docker-scripts/manage-secrets.sh encrypt

# Generate Ethereum keypair
./docker-scripts/manage-secrets.sh eth
```

### 5. backup-restore.sh

**Backup and restore database, Redis, and application files.**

**Usage:**
```bash
# Interactive mode
./docker-scripts/backup-restore.sh

# Command line mode
./docker-scripts/backup-restore.sh <command>
```

**Available commands:**
- `backup-db` - Backup PostgreSQL database
- `backup-redis` - Backup Redis data
- `backup-files` - Backup application .env files
- `backup-full` - Full backup (database + Redis + files)
- `restore-db <file>` - Restore database from backup
- `list` - List available backups
- `clean [days]` - Clean backups older than X days (default: 30)

**Examples:**
```bash
# Interactive menu
./docker-scripts/backup-restore.sh

# Full backup
./docker-scripts/backup-restore.sh backup-full

# Backup database only
./docker-scripts/backup-restore.sh backup-db

# List backups
./docker-scripts/backup-restore.sh list

# Restore database
./docker-scripts/backup-restore.sh restore-db ./backups/postgres-20231210-120000.sql.gz

# Clean old backups (older than 30 days)
./docker-scripts/backup-restore.sh clean 30
```

## Common Tasks

### Initial Deployment

```bash
# 1. Make scripts executable
chmod +x docker-scripts/*.sh

# 2. Configure environment
cp .env.example .env
# Edit .env with your settings (including VERISCOPE_SERVICE_HOST for SSL)

# 3. Run full setup
./docker-scripts/setup-docker.sh
# Select option 6 for full setup
# This will automatically generate PostgreSQL credentials

# 4. Start services (Nginx enabled by default on port 80)
docker-compose -f docker-compose.yml up -d

# OR use the setup script
./docker-scripts/setup-docker.sh start

# 5. (Optional) Setup SSL for production deployment
# See "SSL Certificate and Nginx Setup" section for details
./docker-scripts/setup-docker.sh obtain-ssl
./docker-scripts/setup-docker.sh setup-nginx
# Then manually update docker-compose.yml volumes

# 6. Create admin user (if not done in setup)
./docker-scripts/setup-docker.sh create-admin

# 7. Access services
# Development: http://localhost/ and http://localhost/arena
# Production (with SSL): https://your-domain.com/ and https://your-domain.com/arena
```

### PostgreSQL Credential Management

The setup script automatically generates secure PostgreSQL credentials on first run:

```bash
# Generate new PostgreSQL credentials
./docker-scripts/setup-docker.sh gen-postgres
```

**What it does:**
- Generates a random 20-character password using `pwgen` or `openssl`
- Updates root `.env` file with `POSTGRES_PASSWORD`, `POSTGRES_USER`, and `POSTGRES_DB`
- Updates Laravel `.env` file with database credentials
- Will not overwrite existing secure credentials (only replaces `trustanchor_dev` default)

**After generating credentials:**
```bash
# Recreate postgres container with new password
docker-compose -f docker-compose.yml down postgres
docker-compose -f docker-compose.yml up -d postgres

# Recreate app container to pick up new credentials
docker-compose -f docker-compose.yml up -d --force-recreate app
```

### Chain Configuration (Network Selection)

Set up chain-specific artifacts and configuration based on your target network:

```bash
# Setup chain configuration
./docker-scripts/setup-docker.sh setup-chain
```

**Prerequisites:**
Set `VERISCOPE_TARGET` in your root `.env` file to one of:
- `veriscope_testnet` - Veriscope test network
- `fed_testnet` - Federation test network
- `fed_mainnet` - Federation mainnet

**What it does:**
- Validates `VERISCOPE_TARGET` is set and valid
- **Configures Nethermind** with network-specific ethstats server and secrets:
  - `veriscope_testnet` → wss://fedstats.veriscope.network/api (secret: Oogongi4)
  - `fed_testnet` → wss://stats.testnet.shyft.network/api (secret: Ish9phieph)
  - `fed_mainnet` → wss://stats.shyft.network/api (secret: uL4tohChia)
- Updates `.env` with Nethermind environment variables (used by docker-compose.yml)
- Copies chain-specific contract artifacts from `chains/$VERISCOPE_TARGET/artifacts/` to `veriscope_ta_node/artifacts/`
- Creates `veriscope_ta_node/.env` from chain template if it doesn't exist
- Copies Nethermind configuration (`shyftchainspec.json`, `static-nodes.json`) if Nethermind directory exists
- Preserves existing configurations (won't overwrite `veriscope_ta_node/.env`)

**Nethermind Configuration:**
The Nethermind environment variables are set in the root `.env` file and automatically used by `docker-compose.yml`. No additional override files are needed.

**Example:**
```bash
# 1. Set target network in root .env
echo "VERISCOPE_TARGET=veriscope_testnet" >> .env

# 2. Setup chain configuration (includes Nethermind config)
./docker-scripts/setup-docker.sh setup-chain

# 3. Generate Trust Anchor keypair (see next section)
./docker-scripts/setup-docker.sh create-sealer

# 4. Start or restart services to apply configuration
docker-compose -f docker-compose.yml up -d nethermind ta-node
```

### Refreshing Static Nodes from Ethstats

Periodically refresh the static nodes list to get the latest network peers:

```bash
./docker-scripts/setup-docker.sh refresh-static-nodes
```

**Prerequisites:**
- `VERISCOPE_TARGET` must be set in `.env`
- `wscat` must be installed (script will auto-install via npm)
- Nethermind container should be running (optional, for enode info)

**What it does:**
1. **Queries ethstats WebSocket API** to fetch the current list of active nodes in the network
2. **Validates the response** and backs up existing `static-nodes.json`
3. **Updates `chains/$VERISCOPE_TARGET/static-nodes.json`** with the latest node list
4. **Retrieves this node's enode** from the local Nethermind instance
5. **Updates `.env`** with `NETHERMIND_ETHSTATS_CONTACT` (your node's enode)
6. **Optionally restarts Nethermind** with cleared peer database for fresh connections

**Ethstats endpoints by network:**
- `veriscope_testnet` → wss://fedstats.veriscope.network/primus/
- `fed_testnet` → wss://stats.testnet.shyft.network/primus/
- `fed_mainnet` → wss://stats.shyft.network/primus/

**Example:**
```bash
# Refresh static nodes
./docker-scripts/setup-docker.sh refresh-static-nodes

# Output:
# [INFO] Refreshing static nodes from ethstats...
# [INFO] Querying ethstats at wss://fedstats.veriscope.network/primus/...
# [INFO] Successfully retrieved static nodes
# [INFO] Backed up existing static-nodes.json
# [INFO] Updated chains/veriscope_testnet/static-nodes.json
# [INFO] This node's enode: enode://abc123...@1.2.3.4:30303
# [INFO] Updated NETHERMIND_ETHSTATS_CONTACT in .env
# [WARN] To apply changes, Nethermind needs to restart with cleared peer database
# Restart Nethermind and clear peer cache? (y/N): y
# [INFO] Nethermind restarted successfully
```

**When to use:**
- Network topology has changed (new peers added/removed)
- Experiencing connection issues with other nodes
- After a network upgrade or fork
- Periodically for maintenance (monthly recommended)

**Interactive restart:**
The script will ask if you want to restart Nethermind and clear the peer cache. Clearing the peer database forces Nethermind to rediscover peers using the updated static-nodes.json.

### Regenerating Webhook Secret

The webhook secret is a shared secret between Laravel and Node.js services for secure communication. Regenerate it if compromised or for security rotation:

```bash
./docker-scripts/setup-docker.sh regenerate-webhook-secret
```

**What it does:**
1. **Generates a new 20-character random secret** using pwgen or openssl
2. **Updates `veriscope_ta_dashboard/.env`** with `WEBHOOK_CLIENT_SECRET`
3. **Updates `veriscope_ta_node/.env`** with the same `WEBHOOK_CLIENT_SECRET`
4. **Restarts both services** (app and ta-node) to apply the new secret
5. **Displays the new secret** for your records

**Example:**
```bash
./docker-scripts/setup-docker.sh regenerate-webhook-secret

# Output:
# [INFO] Regenerating webhook shared secret...
# [INFO] Generated new secret: kN8mP3qR5sT7uV9wX2yZ
# [INFO] Updated veriscope_ta_dashboard/.env
# [INFO] Updated veriscope_ta_node/.env
# [INFO] Restarting services to apply new secret...
# [INFO] Restarted Laravel app service
# [INFO] Restarted Node.js ta-node service
# [INFO] Webhook secret regenerated successfully
# [WARN] New secret: kN8mP3qR5sT7uV9wX2yZ (save this securely!)
```

**When to use:**
- Security rotation (recommended every 6-12 months)
- If you suspect the secret has been compromised
- After a security audit
- When onboarding new administrators

**Important:**
- Both services must use the **same secret** for communication to work
- The script updates both `.env` files automatically and restarts services
- **Save the displayed secret** in your password manager or secrets vault
- Test webhook functionality after regeneration

**Security best practices:**
- Don't commit the secret to version control
- Use environment variables or secrets management systems
- Rotate regularly as part of security maintenance
- Document the rotation in your security audit log

### Redis with RedisBloom and Extended Modules

Redis is configured with the `redis/redis-stack` image, which includes multiple powerful modules:

**Included Modules:**
- **RedisBloom** - Probabilistic data structures (bloom filters, cuckoo filters)
- **RedisJSON** - Native JSON document storage
- **RedisSearch** - Full-text search and secondary indexing
- **RedisGraph** - Graph database capabilities
- **RedisTimeSeries** - Time series data structures

**RedisInsight UI:**
Access the RedisInsight web interface for monitoring and debugging:
```bash
# Available at http://localhost:8001
# Provides real-time monitoring, CLI, and data browser
```

**Data Persistence:**
Redis data is persisted in a Docker volume (`redis_data`) with AOF (Append-Only File) enabled for durability.

**No Additional Setup Required:**
All modules are pre-installed and ready to use. The `install-redis-bloom` command simply confirms the modules are available.

### Trust Anchor Keypair Generation

Generate an Ethereum keypair for your Trust Anchor node:

```bash
# Generate new sealer keypair
./docker-scripts/setup-docker.sh create-sealer
```

**What it does:**
- Starts ta-node container if not running
- Generates a random Ethereum keypair using ethers.js
- Automatically updates `veriscope_ta_node/.env` with:
  - `TRUST_ANCHOR_ACCOUNT` - Ethereum address
  - `TRUST_ANCHOR_PK` - Private key (without 0x prefix)
- Creates a backup of `.env` before updating

**Output:**
```
[INFO] Generated Ethereum keypair:
[INFO]   Address: 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb5
[INFO]   Private Key: a0b1c2d3e4f5...
[WARN] SAVE THESE CREDENTIALS SECURELY!
```

**Important:**
- **SAVE THE CREDENTIALS** - These are displayed only once
- The private key is saved to `veriscope_ta_node/.env`
- You must also set `TRUST_ANCHOR_PREFNAME` (your organization name)
- Restart ta-node container after generation:
  ```bash
  docker-compose -f docker-compose.yml restart ta-node
  ```

**When to regenerate:**
- Initial setup (first time)
- If credentials are compromised
- When creating a new Trust Anchor node

**Note:** Each Trust Anchor must have a unique Ethereum address. Do not share private keys between nodes.

### SSL Certificate and Nginx Setup

Nginx is always enabled and routes traffic consistently in both development and production:
- **Development**: HTTP on port 80 (uses `docker-scripts/nginx/nginx.conf`)
- **Production**: HTTPS on port 443 + HTTP redirect (uses `docker-scripts/nginx/nginx-ssl.conf`)

Both modes provide the same URL structure:
- Laravel app at `/`
- Bull Arena at `/arena`

#### Development Mode (HTTP Only)

By default, Nginx serves traffic over HTTP on port 80:

```bash
# Start all services
docker-compose -f docker-compose.yml up -d

# Access your services
# Laravel: http://localhost/
# Arena: http://localhost/arena
```

#### Production Mode (HTTPS with SSL)

For production deployment with SSL certificates:

```bash
# 1. Set your domain in .env
echo "VERISCOPE_SERVICE_HOST=node.example.com" >> .env

# 2. Obtain SSL certificate
./docker-scripts/setup-docker.sh obtain-ssl

# 3. Generate SSL nginx configuration
./docker-scripts/setup-docker.sh setup-nginx
# This creates docker-scripts/nginx/nginx-ssl.conf with HTTPS configuration

# 4. Update docker-compose.yml nginx service volumes to use SSL config
# Change from:
#   - ./docker-scripts/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
# To:
#   - ./docker-scripts/nginx/nginx-ssl.conf:/etc/nginx/conf.d/default.conf:ro
#   - ${SSL_CERT_PATH}:/etc/nginx/ssl/cert.pem:ro
#   - ${SSL_KEY_PATH}:/etc/nginx/ssl/key.pem:ro

# 5. Restart nginx
docker-compose -f docker-compose.yml restart nginx

# Access your services over HTTPS
# Laravel: https://node.example.com/
# Arena: https://node.example.com/arena
```

**Prerequisites for SSL:**
- Set `VERISCOPE_SERVICE_HOST` in your root `.env` file (e.g., `node.example.com`)
- DNS A record pointing your domain to the server's public IP
- Ports 80 and 443 open in firewall
- No other service using ports 80/443 (like Apache)
- Docker and Docker Compose installed (Certbot runs in a container)

#### Obtaining SSL Certificate

```bash
./docker-scripts/setup-docker.sh obtain-ssl
```

**Development Mode Detection:**

The script automatically detects development mode and warns you if SSL is not needed:

- Using `docker-compose.yml` → Development mode
- `VERISCOPE_SERVICE_HOST` is `localhost`, `*.local`, or `*.test` → Development mode
- `APP_ENV=local` or `APP_ENV=development` → Development mode

In development mode, the script will:
1. Display a warning that SSL certificates are typically not needed
2. Remind you that Let's Encrypt won't issue certificates for localhost/local domains
3. Ask for confirmation before proceeding

**What it does:**
- Reads `VERISCOPE_SERVICE_HOST` from root `.env`
- Checks for development mode and prompts if detected
- Ensures nginx container is running (for webroot challenge)
- Uses Certbot via Docker container with webroot mode
- Saves certificate paths to root `.env`:
  - `SSL_CERT_PATH` - Full certificate chain path
  - `SSL_KEY_PATH` - Private key path
- Certificates are stored in Docker volume `certbot_conf`

**Requirements:**
- Valid domain with DNS pointing to server (not localhost)
- Docker and Docker Compose installed
- No host-level Certbot installation needed (runs in container)

**Example (Production):**
```bash
# 1. Set your domain in .env
echo "VERISCOPE_SERVICE_HOST=node.example.com" >> .env

# 2. Obtain certificate
./docker-scripts/setup-docker.sh obtain-ssl

# Output:
# [INFO] Setting up SSL certificate...
# [INFO] Domain: node.example.com
# [INFO] Ensuring nginx container is running...
# [INFO] Obtaining certificate for node.example.com using Docker...
# [WARN] Make sure port 80 is accessible from the internet
# Successfully received certificate.
# [INFO] Certificate obtained successfully
# [INFO] Certificate paths saved to .env
```

**Example (Development - Will Skip):**
```bash
# In development mode with localhost
./docker-scripts/setup-docker.sh obtain-ssl

# Output:
# [INFO] Setting up SSL certificate...
# [WARN] Development mode detected!
# [INFO] Current settings:
#   - Compose file: docker-compose.yml
#   - Host: localhost
#   - APP_ENV: local
#
# [WARN] SSL certificates are typically not needed in development.
# [WARN] Let's Encrypt will not issue certificates for localhost or .local/.test domains.
#
# Do you still want to obtain an SSL certificate? (y/N): N
# [INFO] Skipping SSL certificate setup.
```

#### Setting Up Nginx for SSL

The setup-nginx command generates an SSL-enabled configuration:

```bash
./docker-scripts/setup-docker.sh setup-nginx
```

**What it does:**
- Checks that SSL certificates are available
- Updates `.env` with SSL certificate paths
- Creates `docker-scripts/nginx/nginx-ssl.conf` with HTTPS configuration
- Shows instructions for enabling SSL in docker-compose

**SSL configuration includes:**
- HTTP to HTTPS redirect (port 80 → 443)
- SSL/TLS configuration (TLSv1.2, TLSv1.3)
- Security headers (HSTS, X-Frame-Options, X-Content-Type-Options)
- Reverse proxy to Laravel app (app:80)
- Reverse proxy to Bull Arena (ta-node:8080/arena)
- WebSocket support for Laravel Echo (app:6001)
- Client max body size 128M
- Gzip compression enabled

**Nginx Configuration Details:**
```nginx
# HTTP → HTTPS redirect
server {
    listen 80;
    server_name ${VERISCOPE_SERVICE_HOST};
    return 301 https://$server_name$request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name ${VERISCOPE_SERVICE_HOST};

    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/${VERISCOPE_SERVICE_HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${VERISCOPE_SERVICE_HOST}/privkey.pem;

    # Laravel application (main site)
    location / {
        proxy_pass http://app:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Bull Arena queue UI
    location /arena {
        proxy_pass http://ta-node:8080;
    }

    # WebSocket for Laravel Echo
    location /socket.io {
        proxy_pass http://app:6001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

**Managing Nginx:**
```bash
# View Nginx logs
docker-compose -f docker-compose.yml logs -f nginx

# Restart Nginx (after changing configuration)
docker-compose -f docker-compose.yml restart nginx

# Check Nginx configuration syntax
docker-compose -f docker-compose.yml exec nginx nginx -t
```

#### Renewing SSL Certificates

Let's Encrypt certificates expire after 90 days. Renew them before expiry:

```bash
./docker-scripts/setup-docker.sh renew-ssl
```

**Development Mode Detection:**
- The script automatically detects development mode and skips renewal
- No prompt is shown in dev mode (SSL not needed)

**What it does (Production):**
- Ensures nginx container is running (for webroot challenge)
- Runs `certbot renew` via Docker container
- Reloads nginx configuration to pick up new certificates
- No service downtime during renewal

**Automatic Renewal (Production):**

For production deployments, enable auto-renewal by uncommenting the certbot entrypoint in your production docker-compose file:

```yaml
certbot:
  image: certbot/certbot:latest
  volumes:
    - certbot_conf:/etc/letsencrypt
    - certbot_www:/var/www/certbot
  entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;'"
```

Or use the production profile:
```bash
docker-compose --profile production up -d certbot
```

**Manual renewal check:**
```bash
# Check certificate expiration (via Docker)
docker-compose -f docker-compose.yml run --rm certbot certificates

# Test renewal without actually renewing
docker-compose -f docker-compose.yml run --rm certbot renew --dry-run
```

#### Complete SSL/Nginx Workflow

Full example from initial setup to running with HTTPS:

```bash
# 1. Set your domain in .env
echo "VERISCOPE_SERVICE_HOST=node.example.com" >> .env

# 2. Ensure DNS is configured and pointing to your server
dig node.example.com +short
# Should return your server's IP address

# 3. Obtain SSL certificate from Let's Encrypt
./docker-scripts/setup-docker.sh obtain-ssl

# 4. Generate SSL nginx configuration
./docker-scripts/setup-docker.sh setup-nginx
# This creates docker-scripts/nginx/nginx-ssl.conf

# 5. Update docker-compose.yml nginx volumes to use SSL config:
# Change:    - ./docker-scripts/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
# To:        - ./docker-scripts/nginx/nginx-ssl.conf:/etc/nginx/conf.d/default.conf:ro
#            - ${SSL_CERT_PATH}:/etc/nginx/ssl/cert.pem:ro
#            - ${SSL_KEY_PATH}:/etc/nginx/ssl/key.pem:ro

# 6. Restart nginx
docker-compose -f docker-compose.yml restart nginx

# 7. Verify HTTPS is working
curl -I https://node.example.com

# 8. Access your Veriscope node
# Laravel Dashboard: https://node.example.com/
# Bull Arena: https://node.example.com/arena
```

#### Troubleshooting SSL/Nginx

```bash
# Certificate not obtained
# - Check DNS: dig node.example.com
# - Check port 80 is free: sudo netstat -tlnp | grep :80
# - Check firewall: sudo ufw status
# - Run Certbot manually: sudo certbot certonly --standalone -d node.example.com

# Nginx won't start with SSL
# - Check nginx config syntax: docker-compose -f docker-compose.yml exec nginx nginx -t
# - View nginx logs: docker-compose -f docker-compose.yml logs nginx
# - Verify certificate paths in .env: cat .env | grep SSL
# - Ensure SSL certificates are mounted in docker-compose.yml volumes

# 502 Bad Gateway
# - Check app is running: docker-compose -f docker-compose.yml ps app
# - Check app logs: ./docker-scripts/logs.sh app
# - Verify network connectivity: docker-compose -f docker-compose.yml exec nginx ping app

# Certificate renewal failed
# - Check if port 80 is free during renewal
# - Manually stop nginx: docker-compose -f docker-compose.yml stop nginx
# - Run renewal: sudo certbot renew
# - Restart nginx: docker-compose -f docker-compose.yml --profile production up -d nginx
```

### Daily Operations

```bash
# Check service health
./docker-scripts/setup-docker.sh health

# View logs
./docker-scripts/logs.sh ta-node
./docker-scripts/logs.sh app

# Restart services
./docker-scripts/setup-docker.sh restart

# Open a shell in a container
./docker-scripts/exec.sh app

# Access web interfaces
# - RedisInsight (Redis monitoring): http://localhost:8001
# - Laravel App: http://localhost/ (via Nginx)
# - Bull Arena (Queue UI): http://localhost/arena (via Nginx)
```

### Maintenance

```bash
# Run migrations
./docker-scripts/setup-docker.sh migrate

# Clear cache
./docker-scripts/setup-docker.sh clear-cache

# Update dependencies
./docker-scripts/setup-docker.sh install-node
./docker-scripts/setup-docker.sh install-php

# Backup before updates
./docker-scripts/backup-restore.sh backup-full
```

### Troubleshooting

```bash
# Check container status
docker-compose -f docker-compose.yml ps

# View all logs
./docker-scripts/setup-docker.sh logs

# Check health
./docker-scripts/setup-docker.sh health

# Restart everything
./docker-scripts/setup-docker.sh stop
./docker-scripts/setup-docker.sh start

# Rebuild containers (if needed)
./docker-scripts/setup-docker.sh build
./docker-scripts/setup-docker.sh start
```

## Environment Variables

All scripts respect these environment variables:

- `COMPOSE_FILE` - Docker Compose file to use (default: `docker-compose.yml`)
- `BACKUP_DIR` - Directory for backups (default: `./backups`)
- `VERISCOPE_TARGET` - Target blockchain network (`veriscope_testnet`, `fed_testnet`, `fed_mainnet`)
- `VERISCOPE_COMMON_NAME` - Organization name for ethstats display
- `NETHERMIND_ETHSTATS_SERVER` - Ethstats server URL (auto-configured by `setup-chain`)
- `NETHERMIND_ETHSTATS_SECRET` - Ethstats authentication secret (auto-configured by `setup-chain`)
- `NETHERMIND_ETHSTATS_ENABLED` - Enable/disable ethstats reporting (default: `true`)

**Examples:**
```bash
# Use production compose file
COMPOSE_FILE=docker-compose.yml ./docker-scripts/setup-docker.sh status

# Use custom backup directory
BACKUP_DIR=/mnt/backups ./docker-scripts/backup-restore.sh backup-full
```

## Directory Structure

```
docker-scripts/
├── README.md              # This file
├── setup-docker.sh        # Main setup and management script
├── logs.sh                # Log viewer utility
├── exec.sh                # Container exec utility
├── manage-secrets.sh      # Secrets management
├── backup-restore.sh      # Backup and restore utility
└── nginx/                 # Nginx configuration files
    ├── nginx.conf         # HTTP configuration (development)
    └── nginx-ssl.conf     # HTTPS configuration (production, generated)
```

## Comparison with Bare-Metal Scripts

### Feature Parity Matrix

| Feature | Bare-Metal (`setup-vasp.sh`) | Docker (`setup-docker.sh`) | Status |
|---------|------------------------------|----------------------------|--------|
| **Dependencies** | `refresh_dependencies` | Built into Docker images | ✅ Automated |
| **Time Synchronization** | `ntpdate` cron job | Built into Docker images + cron | ✅ Complete |
| **PostgreSQL Setup** | `create_postgres_trustanchor_db` | `gen-postgres` | ✅ Complete |
| **Chain Configuration** | Copy artifacts to ta-node | `setup-chain` | ✅ Complete |
| **Sealer Keypair** | `create_sealer_pk` | `create-sealer` | ✅ Complete |
| **Nethermind Chain Config** | Copy chainspec + static nodes | `setup-chain` | ✅ Complete |
| **Laravel Setup** | `install_or_update_laravel` | `full-laravel-setup` | ✅ Complete |
| **Database Migrations** | `php artisan migrate` | `migrate` | ✅ Complete |
| **Database Seeding** | `php artisan db:seed` | `seed` | ✅ Complete |
| **App Key Generation** | `php artisan key:generate` | `gen-app-key` | ✅ Complete |
| **Passport Install** | `php artisan passport:install` | `install-passport` | ✅ Complete |
| **Passport Environment** | `install_passport_client_env` | `install-passport-env` | ✅ Complete |
| **Encryption Secret** | `regenerate_encrypt_secret` | `gen-encrypt-secret` | ✅ Complete |
| **Horizon Install** | `install_horizon` | `install-horizon` | ✅ Complete |
| **Address Proofs** | `install_addressproof` | `install-address-proofs` | ✅ Complete |
| **Create Admin** | `create_admin` | `create-admin` | ✅ Complete |
| **Webhook Secret** | `regenerate_webhook_secret` | `regenerate-webhook-secret` | ✅ Complete |
| **Refresh Static Nodes** | `refresh_static_nodes` | `refresh-static-nodes` | ✅ Complete |
| **Redis Install** | `install_redis` | Built into Docker Compose | ✅ Automated |
| **Redis Bloom** | `install_redis_bloom` | Built into redis-stack image | ✅ Automated |
| **Service Restart** | `systemctl restart` | `docker-compose restart` | ✅ Complete |
| **Health Check** | Manual checks | `health` | ✅ Enhanced |
| **Backups** | Manual | `backup-restore.sh` | ✅ Enhanced |
| **SSL Certificates** | `setup_or_renew_ssl` | `obtain-ssl`, `renew-ssl` | ✅ Complete |
| **Nginx Setup** | `setup_nginx` | `setup-nginx` | ✅ Complete |
| **Nethermind Config** | Manual config per network | `setup-chain` (auto-config) | ✅ Automated |
| **Nethermind Install** | `install_or_update_nethermind` | Built into Docker Compose | ✅ Automated |
| **Node.js App** | `install_or_update_nodejs` | Built into Docker | ✅ Automated |

### Architecture Differences

| Bare-Metal Script (`scripts/`) | Docker Script (`docker-scripts/`) |
|-------------------------------|----------------------------------|
| `setup-vasp.sh` (full installer) | `setup-docker.sh` (orchestrator) |
| SystemD services | Docker Compose services |
| Direct Redis/Postgres/Nginx install | Containerized services |
| `systemctl restart ta.service` | `docker-compose restart ta-node` |
| Manual dependency management | Automated via Docker images |
| Ubuntu 20.04/22.04 specific | Platform independent |
| Requires sudo/root | Docker user permissions |

## Support

For issues or questions:
1. Check service logs: `./docker-scripts/logs.sh <service>`
2. Run health check: `./docker-scripts/setup-docker.sh health`
3. Review container status: `docker-compose -f docker-compose.yml ps`
4. Consult DOCKER.md for detailed Docker documentation

## License

Same as the main Veriscope project.
