#!/bin/bash

# Function to get a fresh runner token using Personal Access Token
get_runner_token() {
    echo "Getting fresh runner token using Personal Access Token..."

    if [[ -z "${ACCESS_TOKEN}" ]]; then
        echo "ERROR: ACCESS_TOKEN is required but not provided"
        echo "Please set your Personal Access Token in the ACCESS_TOKEN environment variable"
        echo "Create one at: https://github.com/settings/tokens with 'repo' and 'workflow' scopes"
        exit 1
    fi

    # Extract repo owner and name from REPO_URL
    REPO_PATH=$(echo "${REPO_URL}" | sed 's|https://github.com/||')

    RESPONSE=$(curl -s -X POST \
        -H "Authorization: token ${ACCESS_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${REPO_PATH}/actions/runners/registration-token")

    # Extract the token from the JSON response using sed
    RUNNER_TOKEN=$(echo "$RESPONSE" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    if [[ -n "$RUNNER_TOKEN" ]]; then
        echo "Successfully obtained fresh runner token"
        export RUNNER_TOKEN
        return 0
    else
        echo "Failed to extract runner token from response: $RESPONSE"
        echo "Please check your ACCESS_TOKEN and repository permissions"
        exit 1
    fi
}

# Function to remove existing runner via GitHub API
remove_runner() {
    local runner_name="${RUNNER_NAME:-$(hostname)}"
    echo "Removing any existing runner with name: $runner_name"

    # Extract repo owner and name from REPO_URL
    REPO_PATH=$(echo "${REPO_URL}" | sed 's|https://github.com/||')

    # Get list of runners and find the one with our name
    RUNNERS_RESPONSE=$(curl -s -H "Authorization: token ${ACCESS_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${REPO_PATH}/actions/runners")

    # Extract runner ID - try multiple parsing approaches
    RUNNER_ID=$(echo "$RUNNERS_RESPONSE" | sed -n "s/.*\"id\":[[:space:]]*\([0-9]*\),.*\"name\":[[:space:]]*\"$runner_name\".*/\1/p")

    if [[ -z "$RUNNER_ID" ]]; then
        # Alternative parsing method
        RUNNER_ID=$(echo "$RUNNERS_RESPONSE" | grep -B 5 "\"name\":\"$runner_name\"" | grep -o '"id":[0-9]*' | cut -d':' -f2 | head -1)
    fi

    if [[ -n "$RUNNER_ID" ]]; then
        echo "Found existing runner with ID: $RUNNER_ID, removing it..."
        curl -s -X DELETE \
            -H "Authorization: token ${ACCESS_TOKEN}" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${REPO_PATH}/actions/runners/$RUNNER_ID" > /dev/null
        echo "Runner removed via GitHub API"
        # Give GitHub a moment to process the deletion
        sleep 2
    else
        echo "No existing runner found with name: $runner_name"
    fi
}

# Function to setup/configure the runner
setup_runner() {
    remove_runner

    echo "Configuring runner for repository: ${REPO_URL}"
    ./config.sh --unattended \
        --url ${REPO_URL} \
        --token ${RUNNER_TOKEN} \
        --name ${RUNNER_NAME:-$(hostname)} \
        --work /github/workspace \
        --labels ${LABELS:-self-hosted,linux,x64,docker} \
        --replace
}

# Background token refresh service
token_refresh_service() {
    local refresh_interval=3000  # 50 minutes in seconds

    while true; do
        sleep $refresh_interval
        echo "$(date): Auto-refreshing runner token..."

        # Get new token
        if get_runner_token; then
            echo "$(date): Successfully refreshed token, restarting runner..."

            # Find and gracefully stop the current runner
            local runner_pid=$(pgrep -f "Runner.Listener")
            if [[ -n "$runner_pid" ]]; then
                echo "$(date): Stopping current runner (PID: $runner_pid)"
                kill -TERM "$runner_pid"

                # Wait for graceful shutdown
                local timeout=30
                while [[ $timeout -gt 0 ]] && kill -0 "$runner_pid" 2>/dev/null; do
                    sleep 1
                    ((timeout--))
                done

                # Force kill if still running
                if kill -0 "$runner_pid" 2>/dev/null; then
                    echo "$(date): Force killing runner"
                    kill -KILL "$runner_pid"
                fi
            fi

            # Reconfigure and restart runner
            echo "$(date): Reconfiguring runner with fresh token..."
            setup_runner

            echo "$(date): Starting refreshed runner..."
            ./run.sh &
            RUNNER_PID=$!

            echo "$(date): Runner restarted successfully with PID: $RUNNER_PID"
        else
            echo "$(date): Failed to refresh token, keeping current runner"
        fi
    done
}

# Function to remove runner on exit
cleanup() {
    echo "Cleaning up..."

    # Stop token refresh service if running
    if [[ -n "$REFRESH_PID" ]]; then
        echo "Stopping token refresh service..."
        kill "$REFRESH_PID" 2>/dev/null || true
    fi

    # Stop runner if running
    if [[ -n "$RUNNER_PID" ]]; then
        echo "Stopping runner..."
        kill "$RUNNER_PID" 2>/dev/null || true
    fi

    # Always remove runner on exit since we clean up on startup anyway
    echo "Removing runner registration..."
    # Try local config removal first, then API removal as fallback
    ./config.sh remove --unattended --token ${RUNNER_TOKEN} 2>/dev/null || remove_runner
}
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM


# Add runner to docker group for Docker socket access if DOCKER_GID is set
if [[ -n "$DOCKER_GID" ]]; then
    if ! getent group docker >/dev/null; then
        sudo groupadd -g "$DOCKER_GID" docker
    fi
    sudo usermod -aG docker runner
    echo "Added runner to docker group with GID $DOCKER_GID"
else
    echo "DOCKER_GID not set, skipping docker group setup."
fi

# Get fresh runner token at startup
get_runner_token

# Setup the runner
setup_runner

# Start the token refresh service in background
echo "Starting token refresh service..."
token_refresh_service &
REFRESH_PID=$!
echo "Token refresh service started (PID: $REFRESH_PID)"

# Start the runner
echo "Starting GitHub Actions runner..."
./run.sh &
RUNNER_PID=$!
echo "Runner started (PID: $RUNNER_PID)"

# Wait for the runner process
wait $RUNNER_PID