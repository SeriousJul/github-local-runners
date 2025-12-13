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
- GitHub Personal Access Token with `repo` and `workflow` scopes (create at: https://github.com/settings/tokens)
- Host machine's Docker group GID (get with: `getent group docker | cut -d: -f3`)

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
