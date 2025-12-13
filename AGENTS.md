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
- **Multi-Architecture:** Automatically detects x64 or ARM64 architecture and sets appropriate labels

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
|----------|---------|---------|| `GITHUB_REPO` | GitHub repository (owner/repo format) | `mbeckenbach/hotairandmagic` || `RUNNER_REPLICAS` | Number of runner instances | `4` |
| `RUNNER_NAME_PREFIX` | Prefix for runner names | `myserver-runner` |
| `RUNNER_ARCH` | Runner architecture (optional) | Empty (auto-detect), `x64`, or `ARM64` |
| `DOCKER_GID` | Host's docker group ID | `999` |
| `ACCESS_TOKEN` | GitHub Personal Access Token | `ghp_xxx...` |
| `POSTGRES_PASSWORD` | PostgreSQL password | `securepass123` |
| `MINIO_ROOT_USER` | MinIO admin username | `minio_admin` |
| `MINIO_ROOT_PASSWORD` | MinIO admin password | `securepass456` |

### System-Generated (docker-compose.yml)

| Variable | Purpose | Value |
|----------|---------|-------|
| `REPO_URL` | GitHub repo to register with | Constructed from `GITHUB_REPO`: `https://github.com/${GITHUB_REPO}` |
| `RUNNER_ARCH` | Architecture label (auto-detected) | `x64` or `ARM64` based on `uname -m` |
| `LABELS` | Runner labels for workflow targeting | Constructed in start.sh: `self-hosted,linux,{RUNNER_ARCH},docker` |
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

### Multi-Architecture Support

**Architecture Detection (in `start.sh`):**
- Automatically detects host architecture using `uname -m`
- Maps `x86_64` → `x64` label
- Maps `aarch64` or `arm64` → `ARM64` label
- Falls back to `x64` for unknown architectures
- Can be overridden via `RUNNER_ARCH` environment variable

**Label Format:**
- Uses GitHub Actions standard: `ARM64` (uppercase) for ARM64 runners
- Uses `x64` (lowercase) for x64 runners
- Full label format: `self-hosted,linux,{RUNNER_ARCH},docker`

**Mixed-Architecture Deployments:**
- Supports running both x64 and ARM64 runners simultaneously
- Workflows specify architecture via `runs-on: [self-hosted, linux, x64]` or `runs-on: [self-hosted, linux, ARM64]`
- GitHub automatically routes jobs to matching runner architecture

**Platform Compatibility:**
- All base images support multi-architecture (x64 and ARM64)
- Docker CLI installation auto-detects platform via `dpkg --print-architecture`
- Node.js installed via nvm automatically downloads correct binaries for platform

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

### Problem: Runner shows wrong architecture label

**Check:**
1. View detected architecture: `./logs.sh` - look for "Auto-detected architecture: x64" or "ARM64"
2. Verify host architecture: `uname -m` should show `x86_64`, `aarch64`, or `arm64`
3. Override if needed: Set `RUNNER_ARCH=x64` or `RUNNER_ARCH=ARM64` in `.env`
4. Check runner labels in GitHub: Settings → Actions → Runners → click runner name
5. If using Docker Desktop with emulation, architecture may be incorrectly detected

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

# 5. Check runner registration and architecture detection
./logs.sh  # Look for "Successfully obtained fresh runner token" and "Auto-detected architecture: x64" or "ARM64"

# 6. Verify in GitHub
# Go to repo Settings → Actions → Runners
# Should see multiple runners with correct names and architecture labels

# 7. Test cache
# Trigger a workflow with caching, verify cache hits work

# 8. Test on different architecture (if available)
# On ARM64 Mac: Pull repo, run ./up.sh, verify ARM64 label

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
7. **Architecture is auto-detected** - System automatically detects x64 or ARM64 and sets appropriate labels

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
**Version:** 1.1 (Added multi-architecture support)
