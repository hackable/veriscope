# Docker Scripts Code Quality Standards

This document defines the production-ready code quality standards for all scripts in the `docker-scripts/` directory. All new modules and modifications to existing scripts must adhere to these standards.

---

## Table of Contents

1. [Overview](#overview)
2. [Core Principles](#core-principles)
3. [Required Helper Functions](#required-helper-functions)
4. [Error Handling Patterns](#error-handling-patterns)
5. [Validation Requirements](#validation-requirements)
6. [Security Requirements](#security-requirements)
7. [Operation Logging](#operation-logging)
8. [Function Design](#function-design)
9. [User Experience](#user-experience)
10. [Testing Requirements](#testing-requirements)
11. [Documentation Requirements](#documentation-requirements)
12. [Code Review Checklist](#code-review-checklist)

---

## Overview

These standards ensure:
- **Reliability**: Scripts fail gracefully with clear error messages
- **Security**: No hardcoded credentials, proper input validation
- **Maintainability**: Consistent patterns, comprehensive logging
- **User Experience**: Clear feedback, actionable error messages
- **Production Readiness**: Suitable for enterprise deployments

**Reference Implementations**:
- `setup-docker.sh` - Primary reference (100% compliant)
- `modules/backup-restore.sh` - Secondary reference (100% compliant)

---

## Core Principles

### 1. Fail-Fast Philosophy

Operations must validate prerequisites BEFORE execution:

```bash
# ✅ CORRECT: Validate before executing
function_name() {
    # 1. Validate prerequisites
    validate_prerequisites || return 1
    check_resources || return 1

    # 2. Execute operation
    perform_operation || return 1

    # 3. Verify result
    verify_result || return 1
}
```

```bash
# ❌ INCORRECT: Execute first, discover issues later
function_name() {
    perform_operation  # Might fail due to missing prereqs
    # Too late to prevent wasted time/resources
}
```

### 2. No Silent Failures

Every operation must:
- Check return codes
- Log failures
- Return proper error codes
- Clean up on failure

### 3. Comprehensive Logging

All significant operations must be logged with:
- Timestamp
- Operation name
- Status (SUCCESS/FAILED/PARTIAL/CANCELLED)
- Relevant details

### 4. Idempotency Where Possible

Operations should be safely repeatable without side effects.

### 5. Clear User Feedback

Users must always know:
- What's happening (progress)
- What succeeded (confirmation)
- What failed (specific error + remediation)

---

## Required Helper Functions

All modules must include or import these helper functions:

### Container Management

```bash
# Check if a Docker container is running
is_container_running() {
    local container_name="$1"

    if [ -z "$container_name" ]; then
        echo_error "is_container_running: No container name provided"
        return 1
    fi

    if docker-compose -f "$COMPOSE_FILE" ps "$container_name" 2>/dev/null | grep -q "Up"; then
        return 0
    else
        return 1
    fi
}
```

**Usage**: Call before any `docker-compose exec` operation

### Service Readiness Checks

```bash
# Wait for PostgreSQL to be ready
wait_for_postgres_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for PostgreSQL to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "${POSTGRES_USER:-trustanchor}" >/dev/null 2>&1; then
            echo_info "PostgreSQL is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for PostgreSQL to be ready"
    return 1
}

# Wait for Redis to be ready
wait_for_redis_ready() {
    local timeout=${1:-60}
    local elapsed=0

    echo_info "Waiting for Redis to be ready..."

    while [ $elapsed -lt $timeout ]; do
        if docker-compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping >/dev/null 2>&1; then
            echo_info "Redis is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo_error "Timeout waiting for Redis to be ready"
    return 1
}
```

**Usage**: Call after starting containers, before executing operations

### Output Functions

```bash
# Standard output functions with colors
echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Color definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
```

### Operation Logging

```bash
# Log operations to file
LOG_FILE="${LOG_FILE:-./logs/operations.log}"

log_operation() {
    local operation="$1"
    local status="$2"
    local details="$3"

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$status] $operation - $details" >> "$LOG_FILE"
}
```

**Usage**: Log all significant operations

---

## Error Handling Patterns

### Pattern 1: Validate → Execute → Verify

```bash
perform_operation() {
    # Step 1: Validate prerequisites
    if ! validate_prerequisites; then
        log_operation "OPERATION" "FAILED" "Prerequisites validation failed"
        return 1
    fi

    # Step 2: Execute operation with error checking
    if ! execute_command; then
        log_operation "OPERATION" "FAILED" "Command execution failed"
        return 1
    fi

    # Step 3: Verify result
    if ! verify_result; then
        log_operation "OPERATION" "FAILED" "Result verification failed"
        return 1
    fi

    log_operation "OPERATION" "SUCCESS" "Completed successfully"
    return 0
}
```

### Pattern 2: Cleanup on Failure

```bash
create_backup() {
    local backup_file="/tmp/backup-$$.tar.gz"

    # Create backup
    if ! tar -czf "$backup_file" ...; then
        echo_error "Backup creation failed"
        rm -f "$backup_file"  # Clean up partial file
        return 1
    fi

    # Verify backup
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        echo_error "Backup file is corrupted"
        rm -f "$backup_file"  # Clean up corrupted file
        return 1
    fi

    return 0
}
```

### Pattern 3: Service State Management

```bash
restart_service() {
    # Stop service
    if ! docker-compose stop service_name; then
        echo_error "Failed to stop service"
        return 1
    fi

    # Perform operation
    if ! perform_operation; then
        echo_error "Operation failed"
        # Attempt to restore service
        docker-compose start service_name
        return 1
    fi

    # Start service
    if ! docker-compose start service_name; then
        echo_error "Failed to start service"
        return 1
    fi

    # Verify service is ready
    if ! wait_for_service_ready; then
        echo_error "Service not ready after restart"
        return 1
    fi

    return 0
}
```

### Pattern 4: Consistent Return Codes

```bash
# ✅ CORRECT: Always return proper codes
function_name() {
    if condition; then
        echo_info "Success message"
        return 0  # Explicit success
    else
        echo_error "Failure message"
        return 1  # Explicit failure
    fi
}

# ❌ INCORRECT: Implicit returns
function_name() {
    if condition; then
        echo_info "Success message"
    else
        echo_error "Failure message"
    fi
    # No explicit return - unreliable
}
```

### Pattern 5: Error Aggregation

```bash
perform_multiple_operations() {
    local failed=0
    local failed_operations=()

    if ! operation_one; then
        failed=1
        failed_operations+=("OPERATION_ONE")
    fi

    if ! operation_two; then
        failed=1
        failed_operations+=("OPERATION_TWO")
    fi

    if [ $failed -eq 0 ]; then
        echo_info "All operations completed successfully"
        return 0
    else
        echo_error "Failed operations: ${failed_operations[*]}"
        return 1
    fi
}
```

---

## Validation Requirements

### Pre-Operation Validation

Every operation must validate:

#### 1. **Directory Validation**

```bash
validate_directory() {
    local dir="$1"

    if [ ! -d "$dir" ]; then
        echo_error "Directory does not exist: $dir"
        return 1
    fi

    if [ ! -w "$dir" ]; then
        echo_error "Directory not writable: $dir"
        return 1
    fi

    return 0
}
```

#### 2. **File Validation**

```bash
validate_file() {
    local file="$1"

    if [ -z "$file" ]; then
        echo_error "No file specified"
        return 1
    fi

    if [ ! -f "$file" ]; then
        echo_error "File not found: $file"
        return 1
    fi

    if [ ! -r "$file" ]; then
        echo_error "File not readable: $file"
        return 1
    fi

    return 0
}
```

#### 3. **Disk Space Validation**

```bash
check_disk_space() {
    local required_mb=${1:-100}
    local available_mb=$(df -m "$TARGET_DIR" | awk 'NR==2 {print $4}')

    if [ "$available_mb" -lt "$required_mb" ]; then
        echo_error "Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB"
        return 1
    fi

    return 0
}
```

#### 4. **Container State Validation**

```bash
# Always check before docker-compose exec
if ! is_container_running "container_name"; then
    echo_error "Container is not running: container_name"
    echo_info "Start with: docker-compose up -d container_name"
    return 1
fi
```

#### 5. **Service Readiness Validation**

```bash
# Always wait after starting services
docker-compose up -d postgres

# Wait for service to be ready (don't assume immediate availability)
if ! wait_for_postgres_ready 60; then
    echo_error "PostgreSQL failed to become ready"
    return 1
fi
```

### Post-Operation Verification

Verify operations succeeded:

```bash
# Verify file was created and is not empty
if [ ! -s "$output_file" ]; then
    echo_error "Output file is empty or was not created"
    return 1
fi

# Verify archive integrity
if [[ "$file" == *.gz ]]; then
    if ! gunzip -t "$file" 2>/dev/null; then
        echo_error "Archive is corrupted: $file"
        return 1
    fi
fi

# Verify tar.gz integrity
if ! tar -tzf "$file" >/dev/null 2>&1; then
    echo_error "Tar archive is corrupted: $file"
    return 1
fi
```

---

## Security Requirements

### 1. **No Hardcoded Credentials**

```bash
# ❌ INCORRECT: Hardcoded credentials
docker-compose exec postgres pg_dump -U trustanchor trustanchor

# ✅ CORRECT: Load from environment
load_credentials() {
    if [ -f ".env" ]; then
        source .env
    fi
    POSTGRES_USER="${POSTGRES_USER:-trustanchor}"
    POSTGRES_DB="${POSTGRES_DB:-trustanchor}"
}

load_credentials
docker-compose exec postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"
```

### 2. **Input Validation**

```bash
# Validate user input to prevent injection
validate_input() {
    local input="$1"

    # Check for dangerous characters
    if [[ "$input" =~ [^\w\.\-\/] ]]; then
        echo_error "Invalid characters in input"
        return 1
    fi

    return 0
}
```

### 3. **Path Validation**

```bash
# Prevent path traversal attacks
validate_path() {
    local file="$1"
    local allowed_dir="$2"

    # Get real paths
    local real_allowed="$(cd "$allowed_dir" 2>/dev/null && pwd)"
    local real_file_dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd)"

    # Ensure file is within allowed directory
    if [[ "$real_file_dir" != "$real_allowed"* ]]; then
        echo_error "File must be in $allowed_dir"
        return 1
    fi

    return 0
}
```

### 4. **Safe Command Substitution**

```bash
# ❌ INCORRECT: Unsafe command substitution
docker cp $(docker-compose ps -q redis):/data/dump.rdb backup.rdb

# ✅ CORRECT: Validate before use
redis_container=$(docker-compose ps -q redis)

if [ -z "$redis_container" ]; then
    echo_error "Redis container not found"
    return 1
fi

if [ $(echo "$redis_container" | wc -l) -gt 1 ]; then
    echo_error "Multiple redis containers found"
    return 1
fi

docker cp "$redis_container:/data/dump.rdb" backup.rdb
```

### 5. **Secure Temporary Files**

```bash
# Use unique temporary files
temp_file="/tmp/operation-$$.tmp"

# Clean up on exit
trap 'rm -f "$temp_file"' EXIT

# Ensure proper permissions
touch "$temp_file"
chmod 600 "$temp_file"
```

### 6. **Confirmation for Destructive Operations**

```bash
# Require explicit confirmation for dangerous operations
confirm_destructive_operation() {
    local operation="$1"

    echo ""
    echo_warn "⚠️  WARNING: This will $operation"
    echo ""
    read -p "Type 'yes' to confirm: " -r confirm

    if [ "$confirm" != "yes" ]; then
        echo_info "Operation cancelled"
        return 1
    fi

    return 0
}
```

---

## Operation Logging

### Log File Setup

```bash
# Define log file location
LOG_FILE="${LOG_FILE:-./logs/$(basename "$0" .sh).log}"

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")"
```

### Log Entry Format

```
[YYYY-MM-DD HH:MM:SS] [STATUS] OPERATION - details
```

**Status Values**:
- `SUCCESS` - Operation completed successfully
- `FAILED` - Operation failed
- `PARTIAL` - Operation partially completed
- `CANCELLED` - User cancelled operation
- `SKIPPED` - Operation skipped (not an error)

### When to Log

Log these events:
- ✅ Start of significant operations
- ✅ Success/failure of operations
- ✅ User cancellations
- ✅ Skipped operations
- ✅ Security-relevant events
- ❌ Don't log: routine validation, informational messages

### Example Implementation

```bash
backup_operation() {
    log_operation "BACKUP_START" "INFO" "Starting backup of $TARGET"

    if ! perform_backup; then
        log_operation "BACKUP" "FAILED" "Backup failed: $ERROR_REASON"
        return 1
    fi

    log_operation "BACKUP" "SUCCESS" "Backup completed: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
    return 0
}
```

---

## Function Design

### Function Structure

```bash
# Function header with description
# Description: One-line summary of what function does
# Parameters:
#   $1 - parameter description
#   $2 - parameter description
# Returns:
#   0 - success
#   1 - failure
function_name() {
    local param1="$1"
    local param2="$2"

    # Validate parameters
    if [ -z "$param1" ]; then
        echo_error "Parameter 1 required"
        return 1
    fi

    # Validate prerequisites
    validate_prerequisites || return 1

    # Execute operation
    perform_operation || return 1

    # Verify result
    verify_result || return 1

    return 0
}
```

### Naming Conventions

- **Functions**: `snake_case` (e.g., `backup_database`, `wait_for_service`)
- **Variables**: `snake_case` (e.g., `backup_file`, `container_name`)
- **Constants**: `UPPER_CASE` (e.g., `MAX_RETRIES`, `DEFAULT_TIMEOUT`)
- **Environment Variables**: `UPPER_CASE` (e.g., `POSTGRES_USER`, `LOG_FILE`)

### Function Granularity

Functions should:
- Have a single, clear purpose
- Be testable in isolation
- Be reusable across operations
- Be 50-100 lines maximum (split if larger)

### Parameter Handling

```bash
# ✅ CORRECT: Validate and use local variables
function_name() {
    local required_param="$1"
    local optional_param="${2:-default_value}"

    if [ -z "$required_param" ]; then
        echo_error "Required parameter missing"
        return 1
    fi

    # Use parameters
}

# ❌ INCORRECT: Use $1, $2 directly throughout function
function_name() {
    if [ -z "$1" ]; then  # Unclear what $1 is
        return 1
    fi
    operation "$1" "$2"  # Hard to read
}
```

---

## User Experience

### Progress Feedback

Show users what's happening:

```bash
echo_info "Step 1/5: Validating prerequisites..."
validate_prerequisites

echo_info "Step 2/5: Stopping services..."
stop_services

echo_info "Step 3/5: Performing backup..."
perform_backup

# etc.
```

### Error Messages

Error messages must include:
1. **What went wrong** (specific)
2. **Why it matters** (context)
3. **How to fix it** (remediation)

```bash
# ✅ CORRECT: Actionable error message
echo_error "PostgreSQL container is not running"
echo_info "Start containers with: docker-compose up -d"
echo_info "Or run full setup: ./setup-docker.sh i"

# ❌ INCORRECT: Vague error
echo_error "Database error"
```

### Confirmation Prompts

```bash
# Standard confirmation
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo_info "Operation cancelled"
    return 0
fi

# Destructive operation confirmation
echo_warn "⚠️  This will DELETE all data!"
read -p "Type 'DELETE' to confirm: " -r confirm
if [ "$confirm" != "DELETE" ]; then
    echo_info "Operation cancelled"
    return 0
fi
```

### Success Summaries

```bash
# Show clear success with relevant details
echo_info "========================================="
echo_info "✅ Backup completed successfully!"
echo_info "========================================="
echo ""
echo_info "Backup file: $backup_file"
echo_info "Size: $(du -h "$backup_file" | cut -f1)"
echo_info "Location: $BACKUP_DIR"
```

---

## Testing Requirements

### 1. **Syntax Validation**

```bash
# All scripts must pass syntax check
bash -n script.sh
```

### 2. **Shellcheck Compliance**

```bash
# Run shellcheck (install if needed)
shellcheck script.sh

# Address all warnings or add justification comments
# shellcheck disable=SC2086  # Justification here
```

### 3. **Test Suite**

Create test file: `/tmp/test_<module_name>.sh`

**Minimum Test Coverage**:
- ✅ All helper functions exist
- ✅ All main functions exist
- ✅ Functions use required validations
- ✅ Error handling is comprehensive
- ✅ Logging is implemented
- ✅ Security requirements met
- ✅ Syntax validation passes

**Example Test Structure**:

```bash
#!/bin/bash

echo "=== Testing module_name.sh ==="

# Test 1: Helper functions exist
echo "Test 1: Verify helper functions"
for func in is_container_running wait_for_postgres_ready; do
    if grep -q "^${func}()" module.sh; then
        echo "  ✓ $func exists"
    else
        echo "  ✗ $func missing"
    fi
done

# Test 2: Main function uses validation
echo "Test 2: Verify main_function uses validation"
if grep -A50 "^main_function()" module.sh | grep -q "validate_prerequisites"; then
    echo "  ✓ Uses validation"
else
    echo "  ✗ Missing validation"
fi

# Test 3: Error handling
echo "Test 3: Verify error handling"
if grep -A50 "^main_function()" module.sh | grep -q "return 1"; then
    echo "  ✓ Has error returns"
else
    echo "  ✗ Missing error returns"
fi

# Test 4: Logging
echo "Test 4: Verify logging"
if grep -q "log_operation" module.sh; then
    echo "  ✓ Has operation logging"
else
    echo "  ✗ Missing logging"
fi

echo ""
echo "✅ Test suite completed"
```

### 4. **Integration Testing**

Test with actual Docker environment:

```bash
# Start test environment
docker-compose up -d

# Run module operations
./module.sh test-command

# Verify results
# Check logs
# Verify state
```

---

## Documentation Requirements

### 1. **Script Header**

Every script must have:

```bash
#!/bin/bash
# Module Name: Brief description
#
# Description:
#   Detailed multi-line description of what this module does,
#   its purpose, and key capabilities.
#
# Usage:
#   ./script.sh                    - Interactive mode
#   ./script.sh <command> [args]   - CLI mode
#
# Commands:
#   command1        - Description
#   command2 <arg>  - Description
#
# Examples:
#   ./script.sh command1
#   ./script.sh command2 value
#
# Environment Variables:
#   VAR_NAME    - Description (default: value)
#
# Requirements:
#   - Docker and docker-compose
#   - Specific dependencies
#
# Author: Team/Person
# Last Modified: YYYY-MM-DD
```

### 2. **Function Documentation**

```bash
# Function: function_name
# Description: What the function does
# Parameters:
#   $1 - parameter description
#   $2 - parameter description (optional, default: value)
# Returns:
#   0 - success
#   1 - failure
# Example:
#   function_name "value1" "value2"
function_name() {
    # implementation
}
```

### 3. **Inline Comments**

```bash
# Comment WHY, not WHAT
# ✅ CORRECT
# Wait for service to be ready to prevent race condition
wait_for_service_ready

# ❌ INCORRECT
# Call wait function
wait_for_service_ready
```

### 4. **README Integration**

Document in `docker-scripts/README.md`:
- Module purpose
- Usage examples
- Common workflows
- Troubleshooting tips

---

## Code Review Checklist

Use this checklist when reviewing code:

### ✅ Error Handling
- [ ] All operations check return codes
- [ ] Failed operations return proper error codes
- [ ] Error messages are clear and actionable
- [ ] Cleanup happens on failure
- [ ] No silent failures

### ✅ Validation
- [ ] Container state checked before `docker-compose exec`
- [ ] Service readiness verified after starting containers
- [ ] Disk space checked before creating large files
- [ ] File/directory existence and permissions validated
- [ ] User input validated before use

### ✅ Security
- [ ] No hardcoded credentials
- [ ] Credentials loaded from environment/files
- [ ] Path validation prevents traversal attacks
- [ ] Input validation prevents injection
- [ ] Destructive operations require confirmation
- [ ] Temporary files properly secured
- [ ] Command substitution is safe

### ✅ Logging
- [ ] Log file defined and directory created
- [ ] Significant operations logged
- [ ] Log format is consistent
- [ ] Status values are appropriate
- [ ] Log entries include relevant details

### ✅ User Experience
- [ ] Progress feedback for long operations
- [ ] Clear success/failure messages
- [ ] Actionable error messages with remediation
- [ ] Confirmation prompts for destructive operations
- [ ] Usage help available (`-h` or `--help`)

### ✅ Code Quality
- [ ] Functions have single, clear purpose
- [ ] Function names are descriptive
- [ ] Variables use meaningful names
- [ ] Code is DRY (Don't Repeat Yourself)
- [ ] Magic numbers/strings extracted to variables
- [ ] Syntax check passes (`bash -n`)
- [ ] Shellcheck warnings addressed

### ✅ Documentation
- [ ] Script header present and complete
- [ ] Functions documented
- [ ] Complex logic explained with comments
- [ ] README.md updated
- [ ] Usage examples provided

### ✅ Testing
- [ ] Test suite created
- [ ] All critical paths tested
- [ ] Error conditions tested
- [ ] Test results documented

### ✅ Compatibility
- [ ] Works on macOS and Linux
- [ ] Uses `portable_sed` for sed operations
- [ ] No Linux-only or macOS-only commands
- [ ] Paths work on both platforms

---

## Anti-Patterns to Avoid

### ❌ Silent Failures

```bash
# WRONG
command_that_might_fail
continue_anyway

# RIGHT
if ! command_that_might_fail; then
    echo_error "Operation failed"
    return 1
fi
```

### ❌ Assuming Container State

```bash
# WRONG
docker-compose exec postgres psql ...

# RIGHT
if ! is_container_running "postgres"; then
    echo_error "PostgreSQL container not running"
    return 1
fi
docker-compose exec postgres psql ...
```

### ❌ Race Conditions

```bash
# WRONG
docker-compose up -d postgres
docker-compose exec postgres psql ...  # Might not be ready

# RIGHT
docker-compose up -d postgres
wait_for_postgres_ready 60
docker-compose exec postgres psql ...
```

### ❌ Hardcoded Values

```bash
# WRONG
pg_dump -U trustanchor trustanchor

# RIGHT
POSTGRES_USER="${POSTGRES_USER:-trustanchor}"
pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"
```

### ❌ Unsafe Command Substitution

```bash
# WRONG
container_id=$(docker ps -q -f name=myapp)
docker exec $container_id command  # What if multiple containers?

# RIGHT
container_id=$(docker ps -q -f name=myapp)
if [ -z "$container_id" ]; then
    echo_error "Container not found"
    return 1
fi
if [ $(echo "$container_id" | wc -l) -gt 1 ]; then
    echo_error "Multiple containers found"
    return 1
fi
docker exec "$container_id" command
```

### ❌ Poor Error Messages

```bash
# WRONG
echo "Error"
echo "Operation failed"
echo "Something went wrong"

# RIGHT
echo_error "PostgreSQL backup failed: disk full"
echo_info "Free up space and try again: df -h"
echo_info "Or specify different location: BACKUP_DIR=/path ./script.sh"
```

---

## Quick Reference

### File Structure

```
docker-scripts/
├── setup-docker.sh          # Main setup script (reference implementation)
├── CODE_QUALITY.md          # This document
├── README.md                # User documentation
├── modules/
│   └── backup-restore.sh    # Modular functionality (reference implementation)
├── nginx/
│   └── nginx.conf
└── certbot/
    └── certbot-entrypoint.sh
```

### Command Template

```bash
#!/bin/bash

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh" 2>/dev/null || {
    # Define functions inline if common.sh doesn't exist
}

# Main operation
main() {
    # 1. Validate
    validate_prerequisites || return 1

    # 2. Execute
    perform_operation || return 1

    # 3. Verify
    verify_result || return 1

    return 0
}

# Run main
main "$@"
```

---

## Version History

- **v1.0.0** (2024-11-13): Initial release
  - Codified standards from setup-docker.sh and backup-restore.sh
  - Established error handling, validation, and security patterns
  - Defined testing and documentation requirements

---

## Maintainers

This document is maintained by the Veriscope development team.

For questions or suggestions, please create an issue or pull request.

---

## References

- `setup-docker.sh` - Primary reference implementation
- `modules/backup-restore.sh` - Secondary reference implementation
- [Shellcheck](https://www.shellcheck.net/) - Shell script static analysis
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- [Bash Best Practices](https://bertvv.github.io/cheat-sheets/Bash.html)
