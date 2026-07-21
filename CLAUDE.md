# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Docker Compose infrastructure that runs self-hosted GitHub Actions runners registered against a single GitHub repository (`GITHUB_REPO` in `.env`), scaled horizontally, sharing a local GitHub Actions cache server and an optional Nx remote cache — both backed by MinIO (S3) and PostgreSQL.

There is no application code here — this repo *is* the deployment tooling (Dockerfile, compose file, shell scripts). There's no build/lint/test framework; verification means bringing the stack up and checking runner/cache behavior.

[AGENTS.md](AGENTS.md) is a pre-existing, more exhaustive AI-assistant reference (env var tables, per-symptom troubleshooting trees). Consult it for detail beyond what's summarized here.

## Commands

```bash
./up.sh      # postgres+minio up -> create MinIO buckets via mc -> build & scale github-runner from RUNNER_REPLICAS in .env
./down.sh    # docker compose down (preserves volumes)
./logs.sh    # tail logs for all github-runner containers/replicas
```

```bash
docker compose ps                        # service health status
docker compose logs -f <service>         # actions-cache | postgres | minio
docker compose exec github-runner <cmd>  # exec into a runner (use --index N to target replica N)
docker stats                             # resource usage across containers
```

Rebuild after touching `Dockerfile`, `start.sh`, `dockerd-wrapper.sh`, or `supervisord.conf` (`up.sh` always passes `--build`, so this is sufficient):
```bash
./down.sh && ./up.sh
```

Change replica count: edit `RUNNER_REPLICAS` in `.env`, then `./down.sh && ./up.sh`.

Full reset, including cached data (note the actual volume prefix, see Gotchas below):
```bash
./down.sh
docker volume rm github-local-runners_minio-data github-local-runners_postgres-data
./up.sh
```

Sanity-check a change end-to-end:
```bash
docker compose ps                                    # everything should be "healthy"
./logs.sh                                             # look for "Successfully obtained fresh runner token" and correct arch detection
docker compose exec --user runner github-runner docker ps   # Docker socket must be usable by the unprivileged runner user
docker compose exec github-runner docker run --rm alpine echo ok   # embedded dockerd works

# DinD isolation between replicas:
docker compose exec github-runner docker run -d --name test alpine sleep 3600
docker compose exec --index 2 github-runner docker ps   # must NOT show 'test'
```

## Architecture

Four services on one bridge network (`runner-network`), defined in [docker-compose.yml](docker-compose.yml):

- **postgres** — cache metadata. Must be Postgres (not SQLite) because multiple runners hit the cache server concurrently and SQLite's write locking can't handle that.
- **minio** — S3-compatible storage for two buckets: `gh-actions-cache` and `nx-cache`. Neither bucket is declared in compose — `up.sh` creates both imperatively with the `mc` client after MinIO's healthcheck passes. If you bypass `up.sh` (e.g. `docker compose up` directly), the buckets won't exist and `actions-cache`/Nx will fail against them.
- **actions-cache** — `falcondev-oss/github-actions-cache-server`; speaks the GitHub Actions cache protocol over HTTP, backed by postgres + minio. Runners point `ACTIONS_RESULTS_URL` / `CUSTOM_ACTIONS_RESULTS_URL` at `http://actions-cache:3000/` instead of the real GitHub cache endpoint.
- **github-runner** — the scalable service, built locally from [Dockerfile](Dockerfile) (not pulled). Scaled via Compose's `--scale` flag driven by `up.sh` — this is plain Docker Compose, not Swarm, so there's no `deploy.replicas` or `{{.Task.Slot}}` templating available.

Startup order is enforced with `depends_on: condition: service_healthy`: postgres/minio healthy → (`up.sh` creates buckets) → actions-cache healthy → github-runner starts.

### Docker-in-Docker isolation

Each `github-runner` container runs its **own embedded `dockerd`** rather than mounting the host socket. This is the central design decision in the repo: with a shared daemon, workflows in different runner replicas that bind fixed ports (Postgres, Redis, Supabase, etc.) would collide. With embedded DinD, each replica gets its own network namespace, so containers started in replica N are invisible to replica M (`docker compose exec --index 2 github-runner docker ps` won't show replica 1's containers).

Mechanics, spread across [Dockerfile](Dockerfile), [supervisord.conf](supervisord.conf), [dockerd-wrapper.sh](dockerd-wrapper.sh), [start.sh](start.sh):
- `supervisord` (root) runs two children: `dockerd` via `dockerd-wrapper.sh` (root, priority 10) and the runner agent `start.sh` (user `runner`, priority 20).
- Storage driver is **VFS**, deliberately — overlay2 doesn't work reliably nested inside a container. Don't switch it.
- Containers run `privileged: true`, required for the embedded daemon to operate.
- `dockerd-wrapper.sh` doesn't just launch dockerd: it polls for the socket to appear, `chmod`s it to `660` / `chown root:docker`, and runs a background loop that re-fixes permissions if they ever drift (e.g. after a daemon restart). This is what lets workflows run `docker` as the unprivileged `runner` user without permission errors — don't remove the monitor loop.
- The runner container itself (not its embedded dockerd) is still on the shared `runner-network` bridge and reaches cache/MinIO/Postgres via service name (`actions-cache:3000`, `minio:9000`).

### Runner lifecycle (start.sh)

- Waits for the local `dockerd` (started by supervisord) to respond to `docker info` before doing anything else.
- Detects CPU architecture via `uname -m` unless `RUNNER_ARCH` is set in `.env` (`x86_64`→`x64`, `aarch64`/`arm64`→`ARM64`), and folds it into the GitHub label set: `self-hosted,linux,{arch},docker`.
- Mints a short-lived runner registration token from the long-lived `ACCESS_TOKEN` PAT via the GitHub REST API (`get_runner_token`) — `config.sh` never sees the PAT itself.
- Runner name is `${RUNNER_NAME_PREFIX}-${HOSTNAME}`, where `HOSTNAME` is the container's Docker-assigned hostname — this is what makes each `--scale`d replica unique without Swarm-style templating.
- `remove_runner` deregisters any stale runner with the same name via the GitHub API, both before registering (startup) and in the `INT`/`TERM` trap (shutdown/`cleanup`) — runners are meant to be fully ephemeral.
- Registration tokens expire after 1 hour; `token_refresh_service` (background loop, started after the runner starts) refreshes every 50 minutes by killing `Runner.Listener`, re-running `setup_runner`, and restarting `run.sh`. Preserve this loop when editing `start.sh`.

### Nx remote caching (optional)

Reuses the same MinIO instance as the GitHub Actions cache, in a separate `nx-cache` bucket. Enabled purely by setting `NX_KEY` in `.env` — the runner already has `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (aliased to the MinIO root credentials) and `AWS_ENDPOINT_URL=http://minio:9000` wired into `docker-compose.yml`, so no workflow YAML changes are required. Be aware of CVE-2025-36852 (bucket-cache poisoning via untrusted writers, e.g. external PRs) before enabling this on a repo that runs workflows from forks.

## Gotchas

- **Docker Compose project name is `github-local-runners`** (derived from this directory's name), not `github-runners` as older prose in [README.md](README.md)/[AGENTS.md](AGENTS.md) says — actual resource names are `github-local-runners_minio-data`, `github-local-runners_postgres-data`, `github-local-runners-github-runner-N`, etc. Verify with `docker compose config --format json | head` if this ever seems to drift again (e.g. after a directory rename).
- `github-runner` must never get a `container_name` in compose — it's the one service scaled with `--scale`, and a fixed name breaks that.
- `.env` is gitignored (contains `ACCESS_TOKEN`, `POSTGRES_PASSWORD`, `MINIO_ROOT_PASSWORD`, optionally `NX_KEY`, `DOCKERHUB_PASSWORD`); update `.env.example` instead when adding new variables.
- `docker-compose.yml` and `up.sh` both fall back to weak default credentials (`changeme...`) when `.env` values are unset — fine for local dev, not for anything reachable beyond localhost.
- MinIO bucket creation lives in `up.sh`, not in a compose `depends_on` init-container — if you add a new bucket, add its creation step there too.
