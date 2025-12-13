# GitHub Runner Scalability Implementation Tasks

## Overview

This repository contains a Docker Compose setup for running self-hosted GitHub Actions runners with a local cache server. The current implementation uses filesystem storage and SQLite database, which cannot handle concurrent access from multiple runner instances safely. This plan upgrades the architecture to support multiple scaled runner replicas.

## Problem Statement

**Current Architecture:**
- Cache server uses `STORAGE_DRIVER=filesystem` with local volume
- Cache server uses `DB_DRIVER=sqlite` (file-based database)
- Single runner instance with hardcoded name
- **Issue:** SQLite and filesystem storage have concurrency/locking problems when multiple runners access the cache simultaneously

**Target Architecture:**
- Cache server uses `STORAGE_DRIVER=s3` with MinIO (S3-compatible object storage)
- Cache server uses `DB_DRIVER=postgres` (supports concurrent connections)
- Multiple runner replicas (configurable via `.env` file)
- Friendly runner names: `{hostname}-runner-{N}` (e.g., `myserver-runner-1`, `myserver-runner-2`)
- Helper scripts for easy management

## Tasks Checklist

### ✅ Task 1: Create TASKS.md
- [x] Create this file with comprehensive implementation plan
- [x] Include all context needed for fresh AI sessions

### ✅ Task 2: Add PostgreSQL Service to docker-compose.yml

**Location:** After the `services:` line, before `actions-cache` service

**Add this new service:**
```yaml
  # PostgreSQL database for cache metadata
  postgres:
    image: postgres:16-alpine
    container_name: actions-cache-postgres
    environment:
      POSTGRES_DB: gha_cache
      POSTGRES_USER: cache_user
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-changeme}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    restart: always
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U cache_user -d gha_cache"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - runner-network
```

**Why:** PostgreSQL handles concurrent database connections properly, unlike SQLite which has write locking issues with multiple runners.

### ✅ Task 3: Add MinIO Service to docker-compose.yml

**Location:** After the `postgres` service, before `actions-cache` service

**Add this new service:**
```yaml
  # MinIO S3-compatible object storage for cache data
  minio:
    image: quay.io/minio/minio:latest
    container_name: actions-cache-minio
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER:-minio_admin}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD:-changeme123}
    volumes:
      - minio-data:/data
    ports:
      - "9000:9000"  # MinIO API
      - "9001:9001"  # MinIO Web Console
    restart: always
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - runner-network
```

**Why:** MinIO provides S3-compatible object storage that multiple runners can access concurrently without conflicts. The console UI on port 9001 helps with debugging.

### ✅ Task 4: Update actions-cache Service Configuration

**Changes needed in the `actions-cache` service:**

1. **Remove the hardcoded container_name:**
   - Delete: `container_name: actions-cache-server`
   - Why: Allows Docker's service-based networking

2. **Remove the filesystem volume:**
   - Delete: `volumes:` section and `- cache-storage:/app/.data`
   - Why: No longer using filesystem storage

3. **Change storage driver to S3 (MinIO):**
   - Replace: `- STORAGE_DRIVER=filesystem`
   - With: `- STORAGE_DRIVER=s3`

4. **Add MinIO S3 configuration (add these after STORAGE_DRIVER):**
```yaml
      - STORAGE_S3_BUCKET=gh-actions-cache
      - AWS_ACCESS_KEY_ID=${MINIO_ROOT_USER:-minio_admin}
      - AWS_SECRET_ACCESS_KEY=${MINIO_ROOT_PASSWORD:-changeme123}
      - AWS_ENDPOINT_URL=http://minio:9000
      - AWS_REGION=us-east-1
```

5. **Change database driver to PostgreSQL:**
   - Replace: `- DB_DRIVER=sqlite`
   - With: `- DB_DRIVER=postgres`

6. **Add PostgreSQL configuration (add these after DB_DRIVER):**
```yaml
      - DB_POSTGRES_HOST=postgres
      - DB_POSTGRES_PORT=5432
      - DB_POSTGRES_DATABASE=gha_cache
      - DB_POSTGRES_USER=cache_user
      - DB_POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-changeme}
```

7. **Change restart policy:**
   - Replace: `restart: unless-stopped`
   - With: `restart: always`

8. **Update depends_on with health checks:**
   - Replace the simple `depends_on:` section
   - With:
```yaml
    depends_on:
      postgres:
        condition: service_healthy
      minio:
        condition: service_healthy
```

9. **Add networks section:**
```yaml
    networks:
      - runner-network
```

10. **Add health check (optional but recommended):**
```yaml
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3000/"]
      interval: 10s
      timeout: 5s
      retries: 5
```

### ✅ Task 5: Update github-runner Service Configuration

**Changes needed in the `github-runner` service:**

1. **Remove the hardcoded RUNNER_NAME:**
   - Delete this line: `RUNNER_NAME: docker-runner`
   - Why: We'll use dynamic naming based on container hostname

2. **Add RUNNER_NAME_PREFIX environment variable:**
   - Add in the `environment:` section:
```yaml
      # Runner name will be: {prefix}-{container-hostname}
      RUNNER_NAME_PREFIX: ${RUNNER_NAME_PREFIX:-docker-runner}
```

3. **Change restart policy:**
   - Replace: `restart: unless-stopped`
   - With: `restart: always`

4. **Update depends_on with health check:**
   - Replace: `depends_on:` section
   - With:
```yaml
    depends_on:
      actions-cache:
        condition: service_healthy
```

5. **Add networks section:**
```yaml
    networks:
      - runner-network
```

6. **Add comment about scaling:**
   - Add comment above the service explaining scaling:
```yaml
  # GitHub Actions Runner - scales to multiple replicas
  # Scale with: docker compose up --scale github-runner=4
  # Or use ./up.sh script which reads RUNNER_REPLICAS from .env
  github-runner:
```

### ✅ Task 6: Update start.sh Runner Script

**Location:** In `/home/max/Source/github-runners/start.sh`

**Find this function (around line 42-53):**
```bash
# Function to setup/configure the runner
setup_runner() {
    remove_runner

    echo "Configuring runner for repository: ${REPO_URL}"
    ./config.sh --unattended \
        --url ${REPO_URL} \
        --token ${RUNNER_TOKEN} \
        --name ${RUNNER_NAME:-$(hostname)} \
        --work _work \
        --labels ${LABELS:-self-hosted,linux,x64,docker} \
        --replace
}
```

**Change the --name line:**
- Replace: `--name ${RUNNER_NAME:-$(hostname)} \`
- With: `--name ${RUNNER_NAME_PREFIX}-${HOSTNAME} \`

**Why:** This creates unique runner names like `myserver-runner-github-runners-github-runner-1` where the container hostname (HOSTNAME) provides uniqueness when scaled.

**Also update the remove_runner function (around line 33):**
- Replace: `local runner_name="${RUNNER_NAME:-$(hostname)}"`
- With: `local runner_name="${RUNNER_NAME_PREFIX}-${HOSTNAME}"`

### ✅ Task 7: Update volumes Section in docker-compose.yml

**Find the volumes section at the bottom:**
```yaml
volumes:
  cache-storage:
```

**Replace with:**
```yaml
volumes:
  postgres-data:
  minio-data:
```

**Why:** We no longer need cache-storage (filesystem), but need volumes for PostgreSQL and MinIO data persistence.

### ✅ Task 8: Add networks Section to docker-compose.yml

**At the bottom of docker-compose.yml, after volumes:**
```yaml
networks:
  runner-network:
    driver: bridge
```

**Why:** Explicit network definition for better service isolation and networking.

### ✅ Task 9: Create .env.example File

**Create new file:** `/home/max/Source/github-runners/.env.example`

**Content:**
```bash
# ============================================
# GitHub Runner Configuration
# ============================================

# Number of runner replicas to run (used by up.sh script)
RUNNER_REPLICAS=4

# Prefix for runner names (will append container ID)
# Results in names like: myserver-runner-1, myserver-runner-2, etc.
RUNNER_NAME_PREFIX=myserver-runner

# Docker group ID from host system - must match host's docker group
# Get with: getent group docker | cut -d: -f3
DOCKER_GID=999

# GitHub Personal Access Token for automatic runner registration
# Create at: https://github.com/settings/tokens
# Required scopes: 'repo' and 'workflow'
# SECURITY: Never commit this token to git!
ACCESS_TOKEN=ghp_your_token_here

# ============================================
# Database Configuration (PostgreSQL)
# ============================================

# PostgreSQL password for cache database
# SECURITY: Use a strong password in production!
POSTGRES_PASSWORD=your_secure_postgres_password_here

# ============================================
# Storage Configuration (MinIO S3)
# ============================================

# MinIO admin credentials (S3-compatible storage)
# SECURITY: Use strong credentials in production!
MINIO_ROOT_USER=minio_admin
MINIO_ROOT_PASSWORD=your_secure_minio_password_here

# ============================================
# Security Notes
# ============================================
# 1. Copy this file to .env: cp .env.example .env
# 2. Fill in your actual values (especially ACCESS_TOKEN)
# 3. Set restrictive permissions: chmod 600 .env
# 4. Never commit .env to version control (it's in .gitignore)
# 5. Use strong passwords for POSTGRES_PASSWORD and MINIO_ROOT_PASSWORD
# 6. Regularly rotate ACCESS_TOKEN and other credentials
```

**Why:** Template for users to create their own `.env` file with documentation and security warnings.

### ✅ Task 10: Create up.sh Helper Script

**Create new file:** `/home/max/Source/github-runners/up.sh`

**Content:**
```bash
#!/bin/bash

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Starting GitHub Runner Infrastructure${NC}"
echo -e "${GREEN}========================================${NC}"

# Check if .env file exists
if [[ ! -f .env ]]; then
    echo -e "${RED}ERROR: .env file not found!${NC}"
    echo -e "${YELLOW}Please create one from the template:${NC}"
    echo "  cp .env.example .env"
    echo "  # Edit .env and fill in your values"
    exit 1
fi

# Source environment variables
source .env

# Check required variables
if [[ -z "${ACCESS_TOKEN}" ]] || [[ "${ACCESS_TOKEN}" == "ghp_your_token_here" ]]; then
    echo -e "${RED}ERROR: ACCESS_TOKEN not configured in .env${NC}"
    echo "Please set your GitHub Personal Access Token in .env"
    exit 1
fi

if [[ -z "${DOCKER_GID}" ]]; then
    echo -e "${YELLOW}WARNING: DOCKER_GID not set in .env${NC}"
    echo "Get your Docker GID with: getent group docker | cut -d: -f3"
fi

# Set default replica count if not specified
RUNNER_REPLICAS=${RUNNER_REPLICAS:-1}

echo -e "\n${GREEN}Configuration:${NC}"
echo "  Runner replicas: ${RUNNER_REPLICAS}"
echo "  Runner name prefix: ${RUNNER_NAME_PREFIX:-docker-runner}"
echo ""

# Build and start services with scaling
echo -e "${GREEN}Building and starting services...${NC}"
docker compose up --build --scale github-runner=${RUNNER_REPLICAS} -d

echo -e "\n${GREEN}Waiting for services to be healthy...${NC}"
sleep 5

# Wait for MinIO to be ready
echo -e "${GREEN}Checking MinIO status...${NC}"
timeout=60
elapsed=0
while [[ $elapsed -lt $timeout ]]; do
    if docker compose exec -T minio mc alias set local http://localhost:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" &>/dev/null; then
        echo -e "${GREEN}MinIO is ready!${NC}"
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

if [[ $elapsed -ge $timeout ]]; then
    echo -e "${RED}ERROR: MinIO did not become ready in time${NC}"
    exit 1
fi

# Create MinIO bucket if it doesn't exist
echo -e "${GREEN}Ensuring MinIO bucket exists...${NC}"
if docker compose exec -T minio mc ls local/gh-actions-cache &>/dev/null; then
    echo -e "${YELLOW}Bucket 'gh-actions-cache' already exists${NC}"
else
    echo -e "${GREEN}Creating bucket 'gh-actions-cache'...${NC}"
    docker compose exec -T minio mc mb local/gh-actions-cache
    echo -e "${GREEN}Bucket created successfully!${NC}"
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✓ All services started successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}Running services:${NC}"
docker compose ps
echo ""
echo -e "${GREEN}Access points:${NC}"
echo "  - MinIO Console: http://localhost:9001"
echo "    Username: ${MINIO_ROOT_USER}"
echo "    Password: ${MINIO_ROOT_PASSWORD}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  - View logs: ./logs.sh"
echo "  - Stop services: ./down.sh"
echo "  - Check status: docker compose ps"
echo ""
```

**Make it executable:**
```bash
chmod +x up.sh
```

**Why:** Automates the startup process, handles scaling, creates MinIO bucket, and provides helpful feedback.

### ✅ Task 11: Create down.sh Helper Script

**Create new file:** `/home/max/Source/github-runners/down.sh`

**Content:**
```bash
#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Stopping GitHub Runner Infrastructure${NC}"
echo -e "${YELLOW}========================================${NC}"

# Stop all services
echo -e "\n${YELLOW}Stopping all services...${NC}"
docker compose down

echo -e "\n${GREEN}✓ All services stopped${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} Data volumes are preserved (postgres-data, minio-data)"
echo "To completely remove all data, run: docker compose down -v"
echo ""
```

**Make it executable:**
```bash
chmod +x down.sh
```

**Why:** Provides a simple way to stop all services cleanly.

### ✅ Task 12: Create logs.sh Helper Script

**Create new file:** `/home/max/Source/github-runners/logs.sh`

**Content:**
```bash
#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Tailing GitHub Runner Logs${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Press Ctrl+C to exit"
echo ""

# Follow logs for all runner containers
docker compose logs -f github-runner
```

**Make it executable:**
```bash
chmod +x logs.sh
```

**Why:** Easy way to monitor logs from all runner instances simultaneously.

### ✅ Task 13: Create README.md Documentation

**Create new file:** `/home/max/Source/github-runners/README.md`

**Content:**
```markdown
# Self-Hosted GitHub Actions Runners with Local Cache

This repository provides a scalable Docker Compose setup for running self-hosted GitHub Actions runners with a local cache server for faster builds.

## Architecture

- **GitHub Runners**: Multiple scaled instances (configurable)
- **Cache Server**: GitHub Actions cache server for fast artifact/dependency caching
- **PostgreSQL**: Database for cache metadata (supports concurrent access)
- **MinIO**: S3-compatible object storage for cache data (supports concurrent access)

## Features

- ✅ Scale to multiple runner instances
- ✅ Concurrent cache access (PostgreSQL + MinIO)
- ✅ Automatic runner registration with GitHub
- ✅ Docker-in-Docker support for containerized workflows
- ✅ Automatic token refresh (every 50 minutes)
- ✅ Friendly runner names with hostname prefix
- ✅ Easy management with helper scripts

## Prerequisites

- Docker and Docker Compose installed
- GitHub Personal Access Token with `repo` and `workflow` scopes
- Host machine's Docker group GID

## Quick Start

### 1. Clone and Setup

```bash
cd /home/max/Source/github-runners

# Copy environment template
cp .env.example .env

# Edit .env and fill in your values
nano .env
```

### 2. Configure .env File

Required variables:

```bash
# Number of runner replicas
RUNNER_REPLICAS=4

# Runner name prefix (will create: myserver-runner-1, myserver-runner-2, etc.)
RUNNER_NAME_PREFIX=myserver-runner

# Docker group ID - get with: getent group docker | cut -d: -f3
DOCKER_GID=999

# GitHub Personal Access Token
# Create at: https://github.com/settings/tokens
ACCESS_TOKEN=ghp_your_actual_token_here

# Database password (set a strong password!)
POSTGRES_PASSWORD=your_secure_password

# MinIO credentials (set strong credentials!)
MINIO_ROOT_USER=minio_admin
MINIO_ROOT_PASSWORD=your_secure_minio_password
```

### 3. Start Services

```bash
# Start all services (automatically scales based on RUNNER_REPLICAS)
./up.sh
```

### 4. Verify

```bash
# Check service status
docker compose ps

# View runner logs
./logs.sh
```

## Management Scripts

- **./up.sh** - Start all services with configured scaling
- **./down.sh** - Stop all services (preserves data)
- **./logs.sh** - View logs from all runner instances

## Accessing Services

### MinIO Console (S3 Storage)

- URL: http://localhost:9001
- Username: `${MINIO_ROOT_USER}` (from .env)
- Password: `${MINIO_ROOT_PASSWORD}` (from .env)

Use this to inspect cached artifacts and troubleshoot storage issues.

## Scaling Runners

To change the number of runners:

1. Edit `.env` and change `RUNNER_REPLICAS`
2. Run `./down.sh` to stop services
3. Run `./up.sh` to restart with new scale

## Runner Names

Runners will appear in GitHub with names like:
- `myserver-runner-github-runners-github-runner-1`
- `myserver-runner-github-runners-github-runner-2`
- `myserver-runner-github-runners-github-runner-3`

Where:
- `myserver-runner` is your `RUNNER_NAME_PREFIX`
- `github-runners-github-runner-N` is the unique container identifier

## Troubleshooting

### Runners not appearing in GitHub

1. Check ACCESS_TOKEN is valid and has correct scopes
2. View runner logs: `./logs.sh`
3. Check runner registration: `docker compose exec github-runner ps aux | grep Runner`

### Cache not working

1. Check MinIO is healthy: `docker compose ps`
2. Access MinIO console: http://localhost:9001
3. Verify bucket exists: Should see `gh-actions-cache` bucket
4. Check cache server logs: `docker compose logs actions-cache`

### Database connection errors

1. Check PostgreSQL is healthy: `docker compose ps postgres`
2. View PostgreSQL logs: `docker compose logs postgres`
3. Verify credentials in .env match docker-compose.yml

### Docker socket permission denied

1. Verify DOCKER_GID matches host's docker group: `getent group docker | cut -d: -f3`
2. Update .env with correct DOCKER_GID
3. Restart: `./down.sh && ./up.sh`

## Security Best Practices

1. **Protect .env file**: `chmod 600 .env`
2. **Never commit .env** to version control
3. **Use strong passwords** for POSTGRES_PASSWORD and MINIO_ROOT_PASSWORD
4. **Rotate ACCESS_TOKEN** regularly
5. **Limit token scopes** to only what's needed (repo, workflow)
6. **Keep Docker images updated**: Regularly pull latest images

## Maintenance

### Update images

```bash
./down.sh
docker compose pull
./up.sh
```

### Clear cache data

```bash
# WARNING: This deletes all cached data
./down.sh
docker volume rm github-runners_minio-data
docker volume rm github-runners_postgres-data
./up.sh
```

### View resource usage

```bash
docker stats
```

## Repository Structure

```
.
├── docker-compose.yml    # Main service orchestration
├── Dockerfile           # Custom runner image
├── start.sh            # Runner startup script (runs inside container)
├── up.sh              # Helper: Start services
├── down.sh            # Helper: Stop services
├── logs.sh            # Helper: View logs
├── .env               # Environment configuration (YOU create this)
├── .env.example       # Environment template
├── README.md          # This file
├── AGENTS.md          # Documentation for AI assistants
└── TASKS.md           # Implementation task checklist
```

## Credits

- Runner image: [falcondev-oss/actions-runner](https://github.com/FalconDev-oss/actions-runner)
- Cache server: [falcondev-oss/github-actions-cache-server](https://github.com/FalconDev-oss/github-actions-cache-server)

## License

See individual component licenses.
```

**Why:** Comprehensive user documentation with setup instructions, troubleshooting, and security best practices.

### ✅ Task 14: Create AGENTS.md Documentation

**Create new file:** `/home/max/Source/github-runners/AGENTS.md`

**Content:**
```markdown
# GitHub Runners Repository - AI Assistant Guide

> This document provides context and guidance for AI assistants working with this repository in future sessions.

## Repository Overview

This is a **self-hosted GitHub Actions runner infrastructure** using Docker Compose. It runs multiple GitHub runner instances that connect to a GitHub repository and execute workflow jobs, with a local cache server to speed up builds.

**Key Purpose:** Provide scalable, self-hosted CI/CD runners with shared caching for a GitHub repository.

## Architecture Components

### 1. GitHub Runner Service (`github-runner`)
- **Base Image:** `ghcr.io/falcondev-oss/actions-runner:latest` (forked runner with custom cache support)
- **Purpose:** Executes GitHub Actions workflows
- **Scaling:** Can run multiple replicas (configured via `RUNNER_REPLICAS` in `.env`)
- **Docker-in-Docker:** Mounts host's Docker socket for running containers within workflows
- **Auto-registration:** Automatically registers with GitHub using Personal Access Token
- **Token refresh:** Automatically refreshes registration token every 50 minutes (GitHub tokens expire after 1 hour)

### 2. Cache Server (`actions-cache`)
- **Image:** `ghcr.io/falcondev-oss/github-actions-cache-server:latest`
- **Purpose:** Local cache server compatible with GitHub Actions cache protocol
- **Storage:** Uses MinIO (S3-compatible) for cache data
- **Database:** Uses PostgreSQL for cache metadata
- **Why needed:** Dramatically speeds up workflow execution by caching dependencies, build artifacts, etc.

### 3. PostgreSQL (`postgres`)
- **Image:** `postgres:16-alpine`
- **Purpose:** Stores cache metadata (keys, timestamps, sizes)
- **Why:** Supports concurrent connections from multiple runners (unlike SQLite)
- **Data:** Persisted in `postgres-data` volume

### 4. MinIO (`minio`)
- **Image:** `quay.io/minio/minio:latest`
- **Purpose:** S3-compatible object storage for actual cache data
- **Why:** Supports concurrent reads/writes from multiple runners (unlike filesystem storage)
- **Ports:** 9000 (API), 9001 (Web Console)
- **Data:** Persisted in `minio-data` volume

## File Structure & Purpose

### Core Files

- **`docker-compose.yml`** - Service orchestration, environment variables, networking
- **`Dockerfile`** - Custom runner image (adds Docker CLI, Node.js via nvm)
- **`start.sh`** - Runner startup script (runs INSIDE containers)
  - Handles runner registration with GitHub
  - Manages token refresh every 50 minutes
  - Configures runner name, labels, and Docker group membership

### Helper Scripts (run on HOST machine)

- **`up.sh`** - Starts all services, creates MinIO bucket, handles scaling
- **`down.sh`** - Stops all services
- **`logs.sh`** - Tails logs from all runner containers

### Configuration

- **`.env`** - User's actual configuration (NOT in git, user creates from template)
- **`.env.example`** - Template with documentation for all variables

### Documentation

- **`README.md`** - User-facing documentation (setup, usage, troubleshooting)
- **`AGENTS.md`** - This file (AI assistant context)
- **`TASKS.md`** - Implementation task checklist

## Environment Variables Reference

### User-Configured (in .env)

| Variable | Purpose | Example |
|----------|---------|---------|
| `RUNNER_REPLICAS` | Number of runner instances | `4` |
| `RUNNER_NAME_PREFIX` | Prefix for runner names | `myserver-runner` |
| `DOCKER_GID` | Host's docker group ID | `999` |
| `ACCESS_TOKEN` | GitHub Personal Access Token | `ghp_xxx...` |
| `POSTGRES_PASSWORD` | PostgreSQL password | `securepass123` |
| `MINIO_ROOT_USER` | MinIO admin username | `minio_admin` |
| `MINIO_ROOT_PASSWORD` | MinIO admin password | `securepass456` |

### System-Generated (docker-compose.yml)

| Variable | Purpose | Value |
|----------|---------|-------|
| `REPO_URL` | GitHub repo to register with | Currently: `https://github.com/mbeckenbach/hotairandmagic` |
| `LABELS` | Runner labels for workflow targeting | `linux,x64,docker` |
| `ACTIONS_RESULTS_URL` | Cache server URL | `http://actions-cache:3000/` |
| `CUSTOM_ACTIONS_RESULTS_URL` | Custom cache URL (forked runner) | `http://actions-cache:3000/` |

## Common Operations

### Starting Services
```bash
./up.sh  # Reads RUNNER_REPLICAS from .env, scales automatically
```

### Stopping Services
```bash
./down.sh  # Preserves data volumes
docker compose down -v  # Also removes volumes (deletes all data)
```

### Viewing Logs
```bash
./logs.sh  # All runner logs
docker compose logs -f actions-cache  # Cache server logs
docker compose logs -f postgres  # Database logs
docker compose logs -f minio  # Storage logs
```

### Scaling
```bash
# Method 1: Update .env and restart
echo "RUNNER_REPLICAS=6" >> .env
./down.sh && ./up.sh

# Method 2: Manual scale (not recommended, doesn't persist)
docker compose up --scale github-runner=6 -d
```

### Checking Status
```bash
docker compose ps  # Service status
docker stats  # Resource usage
```

### Accessing MinIO Console
```bash
# Open in browser: http://localhost:9001
# Login with MINIO_ROOT_USER and MINIO_ROOT_PASSWORD from .env
# Navigate to 'Buckets' to see 'gh-actions-cache' bucket
```

## Important Implementation Details

### Runner Naming Strategy

Runners use this naming pattern: `${RUNNER_NAME_PREFIX}-${HOSTNAME}`

- `RUNNER_NAME_PREFIX` comes from `.env` (e.g., `myserver-runner`)
- `HOSTNAME` is the container's hostname (auto-assigned by Docker, e.g., `github-runners-github-runner-1`)
- Final name: `myserver-runner-github-runners-github-runner-1`

**Why this approach:**
- Without Docker Swarm, we can't use templates like `{{.Task.Slot}}`
- Container hostname is automatically unique when using `--scale`
- Allows easy identification of which machine/container a runner is

### Scaling Mechanism

- Uses Docker Compose's `--scale` flag (NOT Docker Swarm `deploy.replicas`)
- `up.sh` script reads `RUNNER_REPLICAS` from `.env` and passes to `--scale`
- Each scaled container gets unique hostname automatically

### Cache Server Concurrency

**Critical:** The cache server must support concurrent access because multiple runners will hit it simultaneously.

- **Storage:** MinIO (S3) supports concurrent object reads/writes
- **Database:** PostgreSQL supports concurrent connections with proper locking
- **Removed:** `container_name: actions-cache-server` to allow Docker service networking

### Health Checks

All services have health checks to ensure proper startup ordering:
- PostgreSQL: `pg_isready` command
- MinIO: `mc ready local` command  
- Cache server: HTTP request to port 3000
- Runners depend on healthy cache server

### Docker Socket Permissions

- Runners need access to host's Docker socket for Docker-in-Docker
- `DOCKER_GID` environment variable sets the container's docker group
- Must match host's docker group ID
- Get with: `getent group docker | cut -d: -f3`

### Token Refresh Mechanism

In `start.sh`:
- Background service runs every 50 minutes
- Fetches new runner token from GitHub API
- Gracefully stops current runner
- Reconfigures with fresh token
- Restarts runner
- **Why:** GitHub runner tokens expire after 1 hour

## Troubleshooting Guide

### Problem: Runners don't appear in GitHub

**Check:**
1. Is `ACCESS_TOKEN` valid? Test with: `curl -H "Authorization: token $ACCESS_TOKEN" https://api.github.com/user`
2. Does token have `repo` and `workflow` scopes?
3. Check logs: `./logs.sh` - look for "Successfully obtained fresh runner token"
4. Check GitHub: Settings → Actions → Runners (should see runners listed)

### Problem: Cache not working (workflows show cache misses)

**Check:**
1. Is cache server healthy? `docker compose ps actions-cache` should show "healthy"
2. Does MinIO bucket exist? Access http://localhost:9001, login, check for `gh-actions-cache` bucket
3. Check cache server logs: `docker compose logs actions-cache` - look for S3 connection errors
4. Verify workflow uses correct cache key pattern
5. Check environment variables in actions-cache service (STORAGE_S3_BUCKET, AWS_ENDPOINT_URL, etc.)

### Problem: "Database connection refused"

**Check:**
1. Is PostgreSQL healthy? `docker compose ps postgres`
2. Credentials correct? `DB_POSTGRES_PASSWORD` should match `POSTGRES_PASSWORD`
3. Database exists? `docker compose exec postgres psql -U cache_user -d gha_cache -c '\dt'`
4. Network issues? All services should be on `runner-network`

### Problem: "Permission denied" for Docker socket

**Check:**
1. Is `DOCKER_GID` set correctly in `.env`?
2. Verify: `getent group docker | cut -d: -f3` on host matches `DOCKER_GID`
3. Check inside container: `docker compose exec github-runner groups` should show "docker"
4. Docker socket mounted? Should see `/var/run/docker.sock` in volumes

### Problem: Runners keep restarting

**Check:**
1. View logs: `./logs.sh` - look for error messages
2. Token refresh failing? Look for "Failed to refresh token" in logs
3. Network connectivity to GitHub? Test: `docker compose exec github-runner curl -I https://github.com`
4. Resource exhaustion? Check: `docker stats` - may need more CPU/memory

### Problem: MinIO not accessible

**Check:**
1. Port conflicts? Verify ports 9000 and 9001 aren't used: `netstat -tuln | grep -E '9000|9001'`
2. MinIO credentials? Try: `docker compose exec minio mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD`
3. Health check passing? `docker compose ps minio` should show "healthy"

## Common Mistakes to Avoid

### ❌ DON'T: Add `container_name` to scalable services
- Services scaled with `--scale` cannot have `container_name`
- Only singleton services (postgres, minio, cache) should have container names

### ❌ DON'T: Use SQLite or filesystem storage with multiple runners
- SQLite has write locking issues with concurrent access
- Filesystem storage doesn't provide concurrency guarantees
- Always use PostgreSQL + MinIO for scaled deployments

### ❌ DON'T: Hardcode runner names
- When scaling, each runner needs a unique name
- Use `RUNNER_NAME_PREFIX` with container hostname for uniqueness

### ❌ DON'T: Forget health checks in depends_on
- Without `condition: service_healthy`, services may start before dependencies are ready
- Results in connection failures and restart loops

### ❌ DON'T: Commit .env file to git
- Contains sensitive credentials (ACCESS_TOKEN, passwords)
- Should be in .gitignore
- Provide .env.example instead

### ❌ DON'T: Use weak credentials
- MINIO_ROOT_PASSWORD, POSTGRES_PASSWORD should be strong
- ACCESS_TOKEN should have minimal required scopes
- Rotate credentials regularly

## Editing Guidelines

### When modifying docker-compose.yml:

1. **Preserve comments** - They explain why things are configured certain ways
2. **Maintain health checks** - Essential for proper startup ordering
3. **Keep environment variables** - Cache server requires specific env vars for S3/PostgreSQL
4. **Don't add container_name to github-runner** - Breaks scaling

### When modifying start.sh:

1. **Don't break token refresh** - The `token_refresh_service` function is critical
2. **Preserve cleanup trap** - Ensures runners deregister properly on shutdown
3. **Keep runner naming pattern** - `${RUNNER_NAME_PREFIX}-${HOSTNAME}` provides uniqueness

### When modifying helper scripts:

1. **Maintain .env sourcing** - Scripts rely on environment variables
2. **Keep error checking** - Prevents startup with invalid configuration
3. **Preserve bucket creation** - MinIO bucket must exist before cache server starts

## Testing Changes

After making changes, test this sequence:

```bash
# 1. Stop everything
./down.sh

# 2. Remove volumes (fresh start)
docker volume rm github-runners_postgres-data github-runners_minio-data 2>/dev/null || true

# 3. Start with scaling
./up.sh

# 4. Verify services are healthy
docker compose ps  # All should show "healthy" status

# 5. Check runner registration
./logs.sh  # Look for "Successfully obtained fresh runner token"

# 6. Verify in GitHub
# Go to repo Settings → Actions → Runners
# Should see multiple runners with correct names

# 7. Test cache
# Trigger a workflow with caching, verify cache hits work

# 8. Test scaling
echo "RUNNER_REPLICAS=2" >> .env
./down.sh && ./up.sh
# Should see 2 runners instead of 4
```

## Key Concepts to Remember

1. **This is NOT Docker Swarm** - Uses regular Docker Compose with `--scale` flag
2. **Runners are ephemeral** - Deregister on shutdown, re-register on startup
3. **Token refresh is automatic** - Handled by `token_refresh_service` in start.sh
4. **Cache is shared** - All runners use same PostgreSQL database and MinIO storage
5. **Names must be unique** - Each runner needs unique name in GitHub
6. **Dependencies matter** - Startup order: postgres/minio → cache → runners

## Additional Resources

- Cache Server Docs: https://gha-cache-server.falcondev.io/getting-started
- Runner Fork: https://github.com/FalconDev-oss/actions-runner
- GitHub Actions Cache: https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows
- MinIO Docs: https://min.io/docs/minio/linux/index.html
- PostgreSQL Docs: https://www.postgresql.org/docs/

## Questions to Ask When Debugging

1. What do the logs show? (`./logs.sh`, `docker compose logs <service>`)
2. Are all services healthy? (`docker compose ps`)
3. Can services reach each other? (Check network connectivity)
4. Are credentials correct? (Verify .env values)
5. Is there enough resources? (`docker stats`)
6. What changed recently? (Check git history, recent .env changes)

---

**Last Updated:** 2025-12-13  
**Version:** 1.0 (Initial scalability implementation)
```

**Why:** Provides comprehensive context for AI assistants in future sessions, explaining architecture, common operations, troubleshooting, and avoiding repeated mistakes.

## Summary

All tasks are defined with enough context to implement in a fresh session. Each task includes:
- Exact file locations
- Code snippets to add/replace
- Explanations of why each change is needed
- Context about the overall architecture

The implementation preserves all existing functionality while adding scalability and improving concurrency support for the cache system.
