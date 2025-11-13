# Docker Setup Guide for Veriscope

This document provides comprehensive instructions for running Veriscope using the microservices Docker architecture.

## Overview

The Veriscope project uses a modern microservices Docker architecture with separate containers for each component:

### Services Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      Docker Compose Setup                     │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────┐         ┌──────────────┐                   │
│  │   nginx     │────────▶│     app      │                   │
│  │  (proxy)    │         │  (Laravel)   │                   │
│  │  Port 80    │         │   PHP 8.3    │                   │
│  │  Port 443   │         │              │                   │
│  └─────────────┘         └──────────────┘                   │
│         │                        │                            │
│         │                        ├──────────┐                │
│         │                        ▼          ▼                │
│         │                 ┌──────────┐  ┌──────────┐        │
│         │                 │ postgres │  │  redis   │        │
│         │                 │ (12)     │  │ (stack)  │        │
│         │                 └──────────┘  └──────────┘        │
│         │                        ▲          ▲                │
│         │                        │          │                │
│         └──────────────┐         │          │                │
│                        ▼         │          │                │
│                 ┌──────────────┐ │          │                │
│                 │   ta-node    │─┴──────────┘                │
│                 │  (Node.js)   │                             │
│                 │   Node 18    │                             │
│                 └──────────────┘                             │
│                        │                                      │
│                        ▼                                      │
│                 ┌──────────────┐                             │
│                 │  nethermind  │                             │
│                 │  (Ethereum)  │                             │
│                 └──────────────┘                             │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### Container Details

| Container | Image | Purpose | Exposed Ports |
|-----------|-------|---------|---------------|
| **nginx** | nginx:alpine | Reverse proxy, SSL termination | 80, 443 |
| **app** | Custom (PHP 8.3, Ubuntu 22.04) | Laravel dashboard & API | Internal only |
| **ta-node** | Custom (Node 18 Alpine) | Trust Anchor service, Bull Arena | Internal only |
| **postgres** | postgres:12-alpine | Database | Internal only |
| **redis** | redis/redis-stack:latest | Cache, queues, RedisBloom | Internal only |
| **nethermind** | nethermind/nethermind:latest | Ethereum client | Internal only |
| **certbot** | certbot/certbot:latest | SSL certificates (production) | None |

## Prerequisites

### Required Software
- **Docker Engine** 20.10 or later
- **Docker Compose** V2 or later (bundled with Docker Desktop)
- **Bash** shell (for management scripts)
- **Git** for version control

### System Requirements
- **OS**: Ubuntu 22.04+ (recommended), macOS 11+, Windows 10/11 with WSL2
- **RAM**: Minimum 8GB, recommended 16GB
- **Disk**: 50GB free space
- **CPU**: 4+ cores recommended

## Quick Start

### 1. Clone and Configure

```bash
# Clone the repository
git clone <repository-url>
cd veriscope

# Create environment files
cp veriscope_ta_dashboard/.env.example veriscope_ta_dashboard/.env
cp veriscope_ta_node/.env.example veriscope_ta_node/.env

# Edit the root .env file (create if it doesn't exist)
cat > .env <<EOF
# Network selection
VERISCOPE_TARGET=veriscope_testnet

# Database credentials
POSTGRES_DB=trustanchor
POSTGRES_USER=trustanchor
POSTGRES_PASSWORD=your_secure_password_here

# Application settings
VERISCOPE_SERVICE_HOST=localhost
VERISCOPE_COMMON_NAME="Your Organization Name"

# Nethermind Stats (optional)
NETHERMIND_ETHSTATS_ENABLED=true
NETHERMIND_ETHSTATS_SERVER=wss://fedstats.veriscope.network/api
NETHERMIND_ETHSTATS_SECRET=Oogongi4
NETHERMIND_ETHSTATS_CONTACT=
EOF
```

### 2. Build Images

```bash
# Build all Docker images
docker-compose build

# Or build specific service
docker-compose build app
docker-compose build ta-node
```

### 3. Initialize with Setup Script

```bash
# Make scripts executable
chmod +x docker-scripts/*.sh

# Run the interactive setup
./docker-scripts/setup-docker.sh

# Follow the menu to:
# - Check requirements
# - Setup chain artifacts
# - Initialize database
# - Generate secrets
# - Setup SSL (production only)
```

### 4. Start Services

```bash
# Start all services
docker-compose up -d

# View logs
docker-compose logs -f

# Check service health
docker-compose ps
```

### 5. Access the Application

- **HTTP**: http://localhost (redirects to HTTPS)
- **HTTPS**: https://localhost (with self-signed cert in development)
- **Arena UI**: https://localhost/arena/ (Bull queue dashboard)

## Environment Configuration

### Network Targets

Set `VERISCOPE_TARGET` in your root `.env` file:

```env
# Options:
VERISCOPE_TARGET=veriscope_testnet  # Veriscope test network
VERISCOPE_TARGET=fed_testnet        # Federation test network
VERISCOPE_TARGET=fed_mainnet        # Federation mainnet (production)
```

### Database Configuration

```env
POSTGRES_DB=trustanchor
POSTGRES_USER=trustanchor
POSTGRES_PASSWORD=<secure-password>
```

These are used by both the postgres container and the application.

### Laravel Application (.env in veriscope_ta_dashboard)

Key settings:

```env
APP_NAME="Veriscope TA Dashboard"
APP_ENV=local                    # local, production
APP_DEBUG=true                   # false for production
APP_URL=https://your-domain.com

DB_CONNECTION=pgsql
DB_HOST=postgres                 # Docker service name
DB_PORT=5432
DB_DATABASE=trustanchor
DB_USERNAME=trustanchor
DB_PASSWORD=<same-as-root-env>

REDIS_HOST=redis                 # Docker service name
REDIS_PORT=6379

QUEUE_CONNECTION=redis
CACHE_DRIVER=redis
SESSION_DRIVER=database
```

### Node.js Service (.env in veriscope_ta_node)

Key settings:

```env
DB_HOST=postgres                 # Docker service name
DB_PORT=5432
DB_NAME=trustanchor
DB_USER=trustanchor
DB_PASS=<same-as-root-env>

REDIS_HOST=redis                 # Docker service name
REDIS_PORT=6379

NETHERMIND_URL=http://nethermind:8545

TRUST_ANCHOR_ACCOUNT=<generated-during-setup>
TRUST_ANCHOR_PK=<generated-during-setup>
TRUST_ANCHOR_PREFNAME="Your Organization Name"
```

## Docker Management Scripts

### Modular Architecture

The Docker management scripts follow a **modular architecture** for better maintainability and code organization. All scripts follow the standards defined in [CODE_QUALITY.md](docker-scripts/CODE_QUALITY.md).

#### Module Structure

```
docker-scripts/
├── setup-docker.sh          # Main management script (962 lines)
└── modules/                 # Modular components
    ├── helpers.sh          # Core utilities (colors, logging, wait functions)
    ├── validators.sh       # Validation functions (passwords, domains, system checks)
    ├── docker-ops.sh       # Docker operations (build, start/stop, volumes, logs)
    ├── database.sh         # Database management (credentials, migrations, backup)
    ├── ssl.sh              # SSL certificate management (Let's Encrypt)
    ├── chain.sh            # Blockchain configuration (Nethermind, static nodes)
    ├── secrets.sh          # Secrets management (webhook, keypairs, encryption)
    ├── services.sh         # Application services (Laravel, Horizon, health checks)
    └── backup-restore.sh   # Backup and restore operations
```

**Benefits of Modular Design**:
- ✅ **Organized by domain** - Each module has clear, focused responsibilities
- ✅ **Better maintainability** - Easy to locate and modify specific functionality
- ✅ **Consistent patterns** - Fail-fast validation, comprehensive error handling
- ✅ **Reduced complexity** - Smaller, digestible code units (72% reduction in main script)
- ✅ **Reusable components** - Functions can be used across different scripts

### setup-docker.sh - Main Management Script

**Location**: `docker-scripts/setup-docker.sh`

The main entry point for all Docker management operations. Automatically loads all modules from `docker-scripts/modules/`.

Interactive menu for all common operations:

```bash
# Interactive mode
./docker-scripts/setup-docker.sh

# Command line mode
./docker-scripts/setup-docker.sh <command>
```

**Available Commands**:

#### Setup & Installation
- `check` - Check Docker requirements and environment
- `preflight` - Run comprehensive pre-flight system checks
- `build` - Build Docker images
- `start` - Start all services
- `stop` - Stop all services
- `restart` - Restart all services
- `status` - Show service status
- `logs [service]` - Show docker-compose logs
- `supervisord-logs` - Show supervisord logs (interactive)

#### Chain & Network Setup
- `setup-chain` - Setup chain-specific configuration and artifacts
- `create-sealer` - Generate Trust Anchor Ethereum keypair
- `refresh-static-nodes` - Refresh static nodes from ethstats

#### Database Operations
- `init-db` - Initialize database
- `migrate` - Run Laravel migrations
- `seed` - Seed database with initial data
- `backup` - Backup database
- `restore <file>` - Restore database from backup

#### Application Setup
- `install-php` - Install Laravel/PHP dependencies
- `install-node` - Install Node.js dependencies
- `install-horizon` - Install Laravel Horizon (queue dashboard)
- `install-passport` - Install Laravel Passport (OAuth2)
- `gen-app-key` - Generate Laravel application key
- `create-admin` - Create admin user (interactive)
- `clear-cache` - Clear Laravel cache

#### Secret & Credential Management
- `gen-postgres` - Generate PostgreSQL credentials
- `regenerate-webhook` - Regenerate webhook secrets
- `regenerate-encrypt` - Regenerate encryption secrets

#### SSL/TLS (Production)
- `obtain-ssl` - Obtain SSL certificate (Let's Encrypt)
- `renew-ssl` - Renew SSL certificates
- `setup-auto-renew` - Setup automatic SSL renewal
- `check-cert` - Check certificate expiration
- `setup-nginx` - Setup Nginx SSL configuration

#### Health & Monitoring
- `health` - Run comprehensive health check
- `check-sync` - Check blockchain synchronization status

#### Development Tools
- `tunnel-start` - Start ngrok tunnel for remote access
- `tunnel-stop` - Stop ngrok tunnel
- `tunnel-url` - Get ngrok tunnel URL
- `tunnel-logs` - View ngrok tunnel logs

#### Advanced Operations
- `reset-volumes` - Reset database and cache volumes (preserves blockchain)
- `destroy` - Completely destroy installation (interactive, with options)
- `full-install` - Full automated installation

### Other Utility Scripts

#### exec.sh - Container Shell Access

```bash
# Access app container
./docker-scripts/exec.sh app

# Access ta-node container
./docker-scripts/exec.sh ta-node

# Run command in container
./docker-scripts/exec.sh app php artisan --version
```

#### logs.sh - View Logs

```bash
# All logs
./docker-scripts/logs.sh

# Specific service
./docker-scripts/logs.sh app
./docker-scripts/logs.sh ta-node

# Follow logs
./docker-scripts/logs.sh -f app
```

#### backup-restore.sh - Backup Operations

**Location**: `docker-scripts/modules/backup-restore.sh`

```bash
# Full backup
./docker-scripts/modules/backup-restore.sh backup

# Restore from backup
./docker-scripts/modules/backup-restore.sh restore /path/to/backup

# List backups
./docker-scripts/modules/backup-restore.sh list

# Or use via setup-docker.sh
./docker-scripts/setup-docker.sh backup
./docker-scripts/setup-docker.sh restore <file>
```

## Service-Specific Operations

### Laravel Application (app)

```bash
# Run artisan commands
docker-compose exec app php artisan migrate
docker-compose exec app php artisan db:seed
docker-compose exec app php artisan cache:clear
docker-compose exec app php artisan config:clear
docker-compose exec app php artisan route:list

# Install/update PHP dependencies
docker-compose exec app composer install
docker-compose exec app composer update

# Install/update frontend dependencies
docker-compose exec app npm install
docker-compose exec app npm run production
```

### Node.js Service (ta-node)

```bash
# View Node logs
docker-compose logs -f ta-node

# Install/update dependencies
docker-compose exec ta-node npm install

# Restart service
docker-compose restart ta-node
```

### PostgreSQL Database (postgres)

```bash
# Access PostgreSQL CLI
docker-compose exec postgres psql -U trustanchor -d trustanchor

# Backup database
docker-compose exec postgres pg_dump -U trustanchor trustanchor > backup.sql

# Restore database
docker-compose exec -T postgres psql -U trustanchor trustanchor < backup.sql

# Check database size
docker-compose exec postgres psql -U trustanchor -d trustanchor -c "SELECT pg_database_size('trustanchor');"
```

### Redis (redis)

```bash
# Access Redis CLI
docker-compose exec redis redis-cli

# Check Redis info
docker-compose exec redis redis-cli INFO

# List RedisBloom modules
docker-compose exec redis redis-cli MODULE LIST

# Flush all data (⚠️ destructive)
docker-compose exec redis redis-cli FLUSHALL
```

### Nethermind (nethermind)

```bash
# View Nethermind logs
docker-compose logs -f nethermind

# Check sync status
docker-compose exec nethermind curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}'

# Get block number
docker-compose exec nethermind curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### Nginx (nginx)

```bash
# Test nginx configuration
docker-compose exec nginx nginx -t

# Reload nginx (after config changes)
docker-compose exec nginx nginx -s reload

# View access logs
docker-compose logs nginx | grep "GET\|POST"
```

## Volume Management

### Named Volumes

The setup uses Docker named volumes for persistent data:

```bash
# List all volumes
docker volume ls | grep veriscope

# Inspect volume
docker volume inspect veriscope_postgres_data

# View volume contents
docker run --rm -v veriscope_artifacts:/data alpine ls -la /data

# Backup volume
docker run --rm -v veriscope_postgres_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/postgres-backup.tar.gz -C /data .

# Restore volume
docker run --rm -v veriscope_postgres_data:/data -v $(pwd):/backup alpine \
  tar xzf /backup/postgres-backup.tar.gz -C /data
```

### Volume Locations

| Volume | Purpose | Size (typical) |
|--------|---------|----------------|
| `postgres_data` | Database files | 1-10 GB |
| `redis_data` | Redis persistence | 100 MB - 1 GB |
| `nethermind_data` | Blockchain data | 10-50 GB |
| `veriscope_artifacts` | Contract artifacts | 1 MB |
| `app_storage` | Laravel storage | 100 MB - 1 GB |
| `app_bootstrap_cache` | Laravel cache | 10 MB |
| `app_public` | Public assets | 50 MB |
| `certbot_conf` | SSL certificates | 10 MB |
| `certbot_www` | Certbot challenges | 1 MB |

## Networking

### Service Communication

Services communicate via the `veriscope` Docker network using service names:

**From app (Laravel)**:
- Database: `postgres:5432`
- Redis: `redis:6379`
- Nethermind: `http://nethermind:8545`

**From ta-node**:
- Database: `postgres:5432`
- Redis: `redis:6379`
- Nethermind: `http://nethermind:8545`

**From nginx**:
- Laravel app: `http://app:80`
- Node service: `http://ta-node:4000`

### Port Mapping

Only nginx exposes ports to the host:

```yaml
ports:
  - "80:80"    # HTTP (redirects to HTTPS)
  - "443:443"  # HTTPS
```

All other services are internal to the Docker network.

### Network Inspection

```bash
# List networks
docker network ls

# Inspect veriscope network
docker network inspect veriscope

# Show connected containers
docker network inspect veriscope --format '{{range .Containers}}{{.Name}} - {{.IPv4Address}}{{"\n"}}{{end}}'
```

## Building and Updating

### Build Process

#### Application Image (app)

**Dockerfile**: `veriscope_ta_dashboard/docker/8.0/Dockerfile`

**Base**: Ubuntu 22.04
**Runtime**: PHP 8.3 with extensions
**Build**: Copies Laravel code at build time

```bash
# Build app image
docker-compose build app

# Build with no cache
docker-compose build --no-cache app

# View build logs
docker-compose build --progress=plain app
```

**PHP 8.3 Extensions Included**:
```
php8.3-apcu      php8.3-bcmath    php8.3-cli       php8.3-curl
php8.3-dev       php8.3-gd        php8.3-igbinary  php8.3-imagick
php8.3-imap      php8.3-intl      php8.3-ldap      php8.3-mbstring
php8.3-msgpack   php8.3-mysql     php8.3-pgsql     php8.3-readline
php8.3-redis     php8.3-soap      php8.3-sqlite3   php8.3-xdebug
php8.3-xml       php8.3-yaml      php8.3-zip
```

#### Node Service Image (ta-node)

**Dockerfile**: `veriscope_ta_node/Dockerfile`

**Base**: Node 18 Alpine
**Build**: Installs dependencies, copies code

```bash
# Build ta-node image
docker-compose build ta-node

# Build with no cache
docker-compose build --no-cache ta-node
```

### Updating the Application

After pulling new code:

```bash
# 1. Stop services
docker-compose down

# 2. Rebuild images with new code
docker-compose build

# 3. Start services
docker-compose up -d

# 4. Run migrations (if needed)
docker-compose exec app php artisan migrate

# 5. Clear caches
docker-compose exec app php artisan cache:clear
docker-compose exec app php artisan config:clear
docker-compose exec app php artisan view:clear
```

### Switching Networks

To change between veriscope_testnet, fed_testnet, and fed_mainnet:

```bash
# 1. Update .env
echo "VERISCOPE_TARGET=fed_testnet" > .env

# 2. Run setup script
./docker-scripts/setup-docker.sh setup-chain

# 3. Restart ta-node
docker-compose restart ta-node nethermind
```

## SSL/TLS Certificates

### Development (Self-Signed)

For local development, use self-signed certificates:

```bash
# Generate self-signed certificate
docker-compose run --rm certbot certonly --standalone \
  --register-unsafely-without-email \
  -d localhost
```

### Production (Let's Encrypt)

For production with a real domain:

```bash
# 1. Ensure domain points to your server
# 2. Stop nginx temporarily
docker-compose stop nginx

# 3. Obtain certificate
docker-compose run --rm certbot certonly --standalone \
  --agree-tos \
  --email your@email.com \
  -d your-domain.com

# 4. Start nginx
docker-compose start nginx
```

### Auto-Renewal (Production)

Enable auto-renewal by uncommenting in `docker-compose.yml`:

```yaml
certbot:
  # Uncomment for auto-renewal:
  entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;'"
```

### Manual Renewal

```bash
docker-compose run --rm certbot renew
docker-compose exec nginx nginx -s reload
```

## Monitoring and Logs

### View Logs

```bash
# All services
docker-compose logs

# Follow all logs
docker-compose logs -f

# Specific service
docker-compose logs app
docker-compose logs ta-node
docker-compose logs postgres

# Last N lines
docker-compose logs --tail=100 app

# Since timestamp
docker-compose logs --since 2024-01-01T00:00:00 app
```

### Health Checks

```bash
# Check container health
docker-compose ps

# Inspect health status
docker inspect veriscope-app --format='{{.State.Health.Status}}'

# Health check details
docker inspect veriscope-postgres --format='{{json .State.Health}}' | jq
```

### Resource Usage

```bash
# Container stats
docker stats

# Specific containers
docker stats veriscope-app veriscope-postgres veriscope-nethermind

# Disk usage
docker system df

# Detailed disk usage
docker system df -v
```

### Arena Queue Dashboard

Access Bull Arena at:

- **URL**: `https://your-domain.com/arena/`
- **Purpose**: Monitor job queues
- **Features**: View jobs, retry failed jobs, clean queues

## Troubleshooting

### Container Won't Start

```bash
# Check container logs
docker-compose logs <service-name>

# Check health status
docker-compose ps

# Inspect container
docker inspect veriscope-<service-name>

# Remove and recreate
docker-compose rm -f <service-name>
docker-compose up -d <service-name>
```

### Database Connection Issues

```bash
# Test database connection
docker-compose exec app php artisan tinker
>>> DB::connection()->getPdo();

# Check postgres is running
docker-compose ps postgres

# Check postgres logs
docker-compose logs postgres

# Verify credentials match
grep DB_ veriscope_ta_dashboard/.env
docker-compose exec postgres env | grep POSTGRES
```

### Redis Connection Issues

```bash
# Test Redis connection
docker-compose exec app php artisan tinker
>>> Redis::ping();

# Test from ta-node
docker-compose exec ta-node node -e "
const Redis = require('ioredis');
const redis = new Redis({host: 'redis', port: 6379});
redis.ping().then(() => console.log('PONG')).catch(console.error);
"

# Check Redis logs
docker-compose logs redis
```

### Nethermind Sync Issues

```bash
# Check sync status
docker-compose exec app php artisan nethermind:sync-status

# View Nethermind logs
docker-compose logs -f nethermind

# Check peers
docker-compose exec nethermind curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}'

# Restart Nethermind
docker-compose restart nethermind
```

### Port Conflicts

```bash
# Check what's using port 80/443
sudo lsof -i :80
sudo lsof -i :443

# Change ports in docker-compose.yml
ports:
  - "8080:80"
  - "8443:443"

# Recreate nginx
docker-compose up -d nginx
```

### Permission Issues

```bash
# Fix Laravel storage permissions
docker-compose exec app chmod -R 775 storage bootstrap/cache
docker-compose exec app chown -R www-data:www-data storage bootstrap/cache
```

### Out of Disk Space

```bash
# Clean up unused resources
docker system prune -a --volumes

# Remove specific volumes (⚠️ data loss)
docker volume rm veriscope_redis_data

# Check volume sizes
docker system df -v
```

### Reset Everything

```bash
# ⚠️ WARNING: This will delete ALL data

# Stop and remove containers, volumes
docker-compose down -v

# Remove images
docker rmi $(docker images 'veriscope*' -q)

# Clean system
docker system prune -a --volumes

# Start fresh
docker-compose build
docker-compose up -d
./docker-scripts/setup-docker.sh
```

## Performance Tuning

### PHP-FPM Configuration

Edit `veriscope_ta_dashboard/docker/8.0/www.conf`:

```ini
pm = dynamic
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 500
```

Rebuild image after changes.

### PostgreSQL Tuning

Create `docker-compose.override.yml`:

```yaml
services:
  postgres:
    command:
      - postgres
      - -c
      - shared_buffers=256MB
      - -c
      - effective_cache_size=1GB
      - -c
      - work_mem=16MB
      - -c
      - max_connections=200
```

### Redis Configuration

Adjust Redis memory in `docker-compose.yml`:

```yaml
redis:
  environment:
    - REDIS_ARGS=--maxmemory 512mb --maxmemory-policy allkeys-lru --appendonly yes
```

### Resource Limits

Set resource limits in `docker-compose.yml`:

```yaml
services:
  app:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
        reservations:
          cpus: '1'
          memory: 1G
```

## Security Best Practices

### 1. Secrets Management

- ✅ Use strong passwords for database
- ✅ Never commit `.env` files
- ✅ Use Docker secrets for production
- ✅ Rotate secrets regularly

### 2. Network Security

- ✅ Only expose necessary ports (80, 443)
- ✅ Use internal Docker network for service communication
- ✅ Enable SSL/TLS in production
- ✅ Configure firewall rules

### 3. Container Security

- ✅ Run as non-root user where possible
- ✅ Keep base images updated
- ✅ Scan images for vulnerabilities
- ✅ Limit container capabilities

### 4. Data Protection

- ✅ Regular backups
- ✅ Encrypt sensitive data
- ✅ Use volume encryption if available
- ✅ Test restore procedures

## Production Deployment

### Production Checklist

- [ ] Set `APP_ENV=production` in Laravel .env
- [ ] Set `APP_DEBUG=false`
- [ ] Use strong database password
- [ ] Obtain SSL certificate from Let's Encrypt
- [ ] Enable certbot auto-renewal
- [ ] Configure automated backups
- [ ] Set up log rotation
- [ ] Configure monitoring
- [ ] Enable firewall
- [ ] Review security settings
- [ ] Test disaster recovery
- [ ] Document access procedures

### Production docker-compose.override.yml

Create `docker-compose.override.yml` for production:

```yaml
services:
  app:
    environment:
      - APP_ENV=production
      - APP_DEBUG=false
    deploy:
      resources:
        limits:
          memory: 2G
    restart: unless-stopped

  ta-node:
    restart: unless-stopped

  postgres:
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 2G

  redis:
    restart: unless-stopped

  nethermind:
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 8G

  nginx:
    restart: unless-stopped

  certbot:
    profiles: []  # Enable certbot in production
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;'"
```

### Backup Strategy

```bash
# Daily backup script
#!/bin/bash
BACKUP_DIR="/backups/$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Database
docker-compose exec -T postgres pg_dump -U trustanchor trustanchor > $BACKUP_DIR/database.sql

# Volumes
docker run --rm -v veriscope_app_storage:/data -v $BACKUP_DIR:/backup alpine \
  tar czf /backup/app-storage.tar.gz -C /data .

# Keep last 7 days
find /backups -type d -mtime +7 -exec rm -rf {} \;
```

## Version Information

**Document Version**: 2.1 - Microservices Architecture with Modular Scripts
**Last Updated**: 2025-01-13
**Docker Compose Version**: 3.8+
**Architecture**: Microservices
**Script Architecture**: Modular (8 modules, 962-line main script)

### Software Versions

| Component | Version | Notes |
|-----------|---------|-------|
| PHP | 8.3 | Updated from 8.0/8.2 |
| Node.js | 18 | Alpine-based |
| Python (Lambda) | 3.11 | Updated from 3.8 |
| Ubuntu | 22.04 | Updated from 20.04 |
| PostgreSQL | 12 | Alpine-based |
| Redis | Latest | redis-stack with RedisBloom |
| Nginx | Latest | Alpine-based |
| Nethermind | Latest | Official image |
| Laravel | 11.0 | - |
| axios | 1.6.0 | Updated from 0.21.4 |

### Script Modularization

**Date**: 2025-01-13
**Changes**: Refactored monolithic setup-docker.sh (3,542 lines) into 8 focused modules
**Benefits**: 72% reduction in main script, improved maintainability, consistent error handling
**Modules**: helpers, validators, docker-ops, database, ssl, chain, secrets, services

## Additional Resources

### Project Documentation
- [docker-scripts/README.md](docker-scripts/README.md) - Detailed script documentation
- [docker-scripts/CODE_QUALITY.md](docker-scripts/CODE_QUALITY.md) - Code quality standards for Docker scripts
- [docker-scripts/FEATURE_COMPARISON.md](docker-scripts/FEATURE_COMPARISON.md) - Feature comparison: bare-metal vs Docker setup
- [ARCHITECTURE_MIGRATION.md](ARCHITECTURE_MIGRATION.md) - Architecture migration guide

### External Resources
- [Docker Documentation](https://docs.docker.com/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Laravel Documentation](https://laravel.com/docs)
- [Nethermind Documentation](https://docs.nethermind.io/)
- [Redis Documentation](https://redis.io/docs/)

## Support

For issues or questions:

1. Check the Troubleshooting section
2. Review container logs: `docker-compose logs`
3. Check service status: `docker-compose ps`
4. Review docker-scripts/README.md for script details
5. Consult project documentation
