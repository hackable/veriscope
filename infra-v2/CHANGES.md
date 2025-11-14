# Infrastructure v2 Changes

This document outlines the key improvements and updates in `infra-v2/` compared to the original `infra/` directory.

## Summary

The `infra-v2/` directory contains updated Ansible playbooks, CloudFormation templates, and configuration files with:
- **Redis Stack Server** with built-in RedisBloom (replacing manual compilation)
- **Nethermind 1.25.4** (upgraded from 1.15.0)
- **Version locking** for reproducible deployments
- **Deprecated outdated playbooks** with clear documentation

## Key Changes

### 1. Redis Stack Server (7.2.0-v9)

**File**: `configure/playbooks/install-redis.yaml`

- **Changed from**: `redis-server` (basic Redis installation)
- **Changed to**: `redis-stack-server` version `7.2.0-v9`
- **Benefits**:
  - Built-in RedisBloom module (no manual compilation required)
  - Additional modules included: RedisJSON, RedisSearch, RedisProbabilistic
  - Simplified installation and maintenance
  - Version-locked for consistency with docker-compose deployments
  - Automatic fallback to latest if specific version unavailable

**Implementation details**:
- Adds Redis Stack repository with GPG key
- Installs specific version with fallback mechanism
- Verifies RedisBloom module is loaded
- Updates service name to `redis-stack-server`

### 2. Deprecated RedisBloom Manual Compilation

**File**: `configure/playbooks/install-bloom-filter.yaml`

- **Status**: DEPRECATED (kept for reference only)
- **Reason**: Redis Stack Server includes RedisBloom by default
- **Replacement**: Use `install-redis.yaml` instead
- **Note**: File includes clear deprecation notice explaining the change

### 3. Nethermind Version Update

**File**: `configure/inventory/group_vars/all.yaml`

- **Changed from**: `target_nethermind_version: 1.15.0`
- **Changed to**: `target_nethermind_version: 1.25.4`
- **Benefits**:
  - Latest stable Nethermind release
  - Improved performance and bug fixes
  - Consistent with docker-compose and scripts-v2 deployments

### 4. Nethermind v1.25.4 Configuration Template

**Directory**: `configure/playbooks/templates/nm-config/v1.25.4/`

- **Created**: New config template directory for Nethermind v1.25.4
- **Based on**: v1.15.0 configuration (compatible settings)
- **Contains**: `config.cfg.j2` Jinja2 template for Nethermind configuration

### 5. Service Name Updates

**File**: `configure/inventory/group_vars/all.yaml`

- **Changed**: `veriscope_web_prereq_services`
  - **From**: `[ nginx, redis-server ]`
  - **To**: `[ nginx, redis-stack-server ]`
- **Impact**: Service management playbooks now reference correct systemd service

## Migration Guide

### From infra/ to infra-v2/

1. **Redis Migration**:
   - Old Redis installations will continue to work
   - For new deployments, use `install-redis.yaml` (installs Redis Stack)
   - For existing deployments, backup data before migrating to Redis Stack
   - DO NOT run `install-bloom-filter.yaml` on new deployments

2. **Nethermind Upgrade**:
   - Use `upgrade-nethermind.yaml` playbook with `target_nethermind_version: 1.25.4`
   - Configuration template v1.25.4 is compatible with existing chainspecs
   - Backup Nethermind database before upgrading

3. **Variable Updates**:
   - Update inventory files to use `redis-stack-server` service name
   - Verify `target_nethermind_version` is set to desired version

## Version Compatibility

| Component | infra/ | infra-v2/ |
|-----------|--------|-----------|
| Redis | redis-server (latest) | redis-stack-server 7.2.0-v9 |
| RedisBloom | Manual compile v2.4.5 | Built-in (Redis Stack) |
| Nethermind | 1.15.0 | 1.25.4 |
| Config Templates | v1.12.4, v1.15.0 | v1.12.4, v1.15.0, v1.25.4 |

## Benefits of infra-v2/

1. **Simplified Deployment**: No manual RedisBloom compilation
2. **Version Consistency**: Matches docker-compose.yml and scripts-v2 versions
3. **Improved Reliability**: Version locking prevents unexpected updates
4. **Better Maintainability**: Clearer structure with deprecation notices
5. **Feature Parity**: Consistent versions across all deployment methods

## Files Modified

```
infra-v2/
├── CHANGES.md (new)
├── configure/
│   ├── inventory/group_vars/all.yaml (updated)
│   └── playbooks/
│       ├── install-redis.yaml (rewritten)
│       ├── install-bloom-filter.yaml (deprecated)
│       └── templates/nm-config/
│           └── v1.25.4/ (new)
│               └── config.cfg.j2
└── cloudformation/ (no changes needed)
```

## CloudFormation Templates

No changes were required for CloudFormation templates as they don't contain hard-coded version references for Redis or Nethermind. IAM policies and S3 configurations remain unchanged.

## Testing Recommendations

1. Test Redis Stack installation on a fresh Ubuntu/Debian system
2. Verify RedisBloom module functionality with `redis-cli MODULE LIST`
3. Test Nethermind 1.25.4 connectivity to existing chains
4. Validate service restarts and systemd integration
5. Confirm Ansible variable substitution in templates

## Support

For issues or questions about infra-v2:
- Review the original `infra/` directory for comparison
- Check Ansible playbook documentation
- Verify Redis Stack Server compatibility: https://redis.io/docs/stack/
- Verify Nethermind compatibility: https://docs.nethermind.io/

---

**Last Updated**: 2025-11-13
**Compatible With**: scripts-v2, docker-compose.yml (version-locked deployments)
