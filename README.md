# Self-Hosted GitHub Actions Runners with Local Cache

This repository provides a scalable Docker Compose setup for running self-hosted GitHub Actions runners with a local cache server for faster builds.

## Architecture

- **GitHub Runners**: Multiple scaled instances (configurable)
- **Cache Server**: GitHub Actions cache server for fast artifact/dependency caching
- **PostgreSQL**: Database for cache metadata (supports concurrent access)
- **MinIO**: S3-compatible object storage for cache data (supports concurrent access)
- **Nx Remote Cache**: Optional self-hosted caching for Nx monorepos (uses MinIO)

## Features

- ✅ Scale to multiple runner instances
- ✅ Concurrent cache access (PostgreSQL + MinIO)
- ✅ Automatic runner registration with GitHub
- ✅ Docker-in-Docker support for containerized workflows
- ✅ Automatic token refresh (every 50 minutes)
- ✅ Friendly runner names with hostname prefix
- ✅ Easy management with helper scripts
- ✅ **LOCAL Nx remote caching support** (optional, enforced at runner level)

## Prerequisites

- Docker and Docker Compose installed
- GitHub Personal Access Token with `repo` and `workflow` scopes (create at: https://github.com/settings/tokens)
- Host machine's Docker group GID (get with: `getent group docker | cut -d: -f3`)

## Multi-Architecture Support

This setup **automatically detects your system architecture** and configures runners accordingly:

- **x64 (Intel/AMD)**: Detected on Linux x86_64 systems
- **ARM64 (Apple Silicon)**: Detected on macOS ARM64 and Linux aarch64 systems

### How It Works

The runner automatically detects the host architecture using `uname -m` and sets the appropriate GitHub Actions label:
- `x86_64` → Runner label: `x64`
- `aarch64` or `arm64` → Runner label: `ARM64`

Your workflows will see runners with labels like: `[self-hosted, linux, x64, docker]` or `[self-hosted, linux, ARM64, docker]`

### Targeting Specific Architectures

To run workflows on specific architecture runners, use:

```yaml
jobs:
  build-x64:
    runs-on: [self-hosted, linux, x64]
    steps:
      - run: echo "Running on x64"
  
  build-arm64:
    runs-on: [self-hosted, linux, ARM64]
    steps:
      - run: echo "Running on ARM64"
```

### Override Architecture Detection

If you need to force a specific architecture (e.g., for testing), set `RUNNER_ARCH` in your `.env` file:

```bash
# Force x64 (not recommended unless needed)
RUNNER_ARCH=x64

# Force ARM64 (not recommended unless needed)
RUNNER_ARCH=ARM64
```

**Note:** Leave `RUNNER_ARCH` empty or unset for automatic detection (recommended).

### Mixed Architecture Deployments

You can run both x64 and ARM64 runners simultaneously:
1. Deploy on an x64 host with `RUNNER_REPLICAS=4`
2. Deploy on an ARM64 host with `RUNNER_REPLICAS=4`
3. Workflows automatically route to the correct architecture based on `runs-on` labels

## Quick Start

### 1. Clone and Setup

```bash
cd /home/max/Source/github-runners

# Make helper scripts executable
chmod +x up.sh down.sh logs.sh

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

# Runner architecture (leave empty for auto-detection - recommended)
RUNNER_ARCH=

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

# Optional: Nx remote caching (leave empty if not using Nx)
NX_KEY=
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
3. Verify buckets exist: Should see `gh-actions-cache` and `nx-cache` buckets
4. Check cache server logs: `docker compose logs actions-cache`
5. Check bucket initialization: `docker compose logs init-bucket`

### Database connection errors

1. Check PostgreSQL is healthy: `docker compose ps postgres`
2. View PostgreSQL logs: `docker compose logs postgres`
3. Verify credentials in .env match docker-compose.yml

### Docker socket permission denied

1. Verify DOCKER_GID matches host's docker group: `getent group docker | cut -d: -f3`
2. Update .env with correct DOCKER_GID
3. Restart: `./down.sh && ./up.sh`

## Nx Remote Caching (Optional)

If you're using an Nx monorepo, this infrastructure supports **self-hosted remote caching** using the existing MinIO S3 storage. Cache configuration is **enforced at the runner level** via environment variables, so your workflow YAML files don't need any cache-specific configuration.

### Quick Start: Enable Nx Caching

To enable Nx caching in your Nx workspace:

1. **In your Nx workspace repository:**
   ```bash
   nx add @nx/s3-cache  # This generates NX_KEY automatically
   ```

2. **In this runners repository:**
   ```bash
   # Add the NX_KEY to .env
   echo "NX_KEY=your_generated_key" >> .env
   
   # Restart runners
   ./down.sh
   ./up.sh
   ```

That's it! Nx will automatically use the self-hosted cache without any workflow YAML changes.

### Setup Steps

#### 1. Install Nx S3 Cache Plugin in Your Nx Workspace

In your Nx workspace repository (not this runner repo):

```bash
# Install the S3 cache plugin
nx add @nx/s3-cache

# During installation, an activation key (NX_KEY) will be generated automatically
# Copy this key - you'll need it for the next step
```

**Important:** The `NX_KEY` is free and generated automatically. It's required for the `@nx/s3-cache` plugin to function.

#### 2. Configure the Runner

Add the `NX_KEY` to your `.env` file in this runner repository:

```bash
# In /home/max/Source/github-runners/.env
NX_KEY=your_generated_key_from_step_1
```

The runners are already configured with these environment variables (no changes needed):
- `AWS_ACCESS_KEY_ID` → Uses your `MINIO_ROOT_USER`
- `AWS_SECRET_ACCESS_KEY` → Uses your `MINIO_ROOT_PASSWORD`
- `AWS_ENDPOINT_URL=http://minio:9000`
- `AWS_REGION=us-east-1`

#### 3. Restart Runners

```bash
./down.sh
./up.sh
```

#### 4. Configure Your Nx Workspace (Optional)

The environment variables set in the runners are sufficient for most use cases. However, you can also configure caching in your Nx workspace's `nx.json` if you want explicit configuration:

```json
{
  "s3": {
    "bucket": "nx-cache"
  }
}
```

**Note:** Since authentication and endpoint are provided via environment variables in the runner, you only need to specify the bucket name if you choose to configure `nx.json`.

### How It Works

1. **Transparent to Workflows**: Your GitHub Actions workflows don't need any special configuration. The runner environment variables automatically enable Nx caching.
2. **Shared Storage**: The Nx cache uses the same MinIO instance as GitHub Actions cache, but in a separate `nx-cache` bucket.
3. **Concurrent Access**: Multiple runners can safely read/write to the cache simultaneously.
4. **Automatic Bucket Creation**: The `nx-cache` bucket is automatically created when services start.

### Verification

After running a workflow with Nx tasks:

1. **Check MinIO Console**: http://localhost:9001
   - Navigate to the `nx-cache` bucket
   - You should see cached task outputs stored as objects

2. **Check Nx Output**: Your workflow logs should show cache hits:
   ```
   Nx read the output from the cache instead of running the command for 5 out of 10 tasks.
   ```

### Security Considerations

**⚠️ CVE-2025-36852 (CREEP Vulnerability)**

Bucket-based caching solutions (including `@nx/s3-cache`) are affected by a security vulnerability where anyone with PR access can potentially poison production builds by injecting malicious cache entries.

**Mitigation Strategies:**

1. **Separate Buckets for PR vs Production** (Recommended):
   - Use different `NX_KEY` values for PR runners vs production runners
   - Configure separate MinIO buckets or IAM policies to isolate PR cache from production cache

2. **Implement IAM Policies in MinIO**:
   - Restrict write access to production cache bucket
   - Allow PR runners read-only access to production cache

3. **Monitor Cache Usage**:
   - Regularly audit the `nx-cache` bucket for unexpected entries
   - Set up alerts for unusual cache write patterns

4. **Consider Custom Cache Server**:
   - For maximum security, implement a custom cache server with enhanced authorization logic
   - This allows fine-grained control over who can read/write specific cache entries

For more information, see: [Nx Security Advisories](https://github.com/nrwl/nx/security/advisories)

## Security Best Practices

1. **Protect .env file**: `chmod 600 .env`
2. **Never commit .env** to version control
3. **Use strong passwords** for POSTGRES_PASSWORD and MINIO_ROOT_PASSWORD
4. **Rotate ACCESS_TOKEN** regularly
5. **Limit token scopes** to only what's needed (repo, workflow)
6. **Keep Docker images updated**: Regularly pull latest images
7. **Nx caching security**: Be aware of CVE-2025-36852 and implement appropriate mitigations if using Nx remote caching

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
