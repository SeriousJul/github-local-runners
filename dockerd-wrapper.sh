#!/bin/bash
# Docker daemon wrapper with socket permission management
# This script ensures the Docker socket always has correct permissions
# and handles permission resets during daemon restarts

set -e

SOCKET_PATH="/var/run/docker.sock"
DOCKER_GROUP="docker"

# Start dockerd in background with all passed arguments
/usr/bin/dockerd "$@" &
DOCKERD_PID=$!

# Function to fix socket permissions
fix_socket_permissions() {
    if [ -S "$SOCKET_PATH" ]; then
        chmod 660 "$SOCKET_PATH"
        chown root:$DOCKER_GROUP "$SOCKET_PATH"
        return 0
    fi
    return 1
}

# Wait for socket to be created (with timeout)
echo "Waiting for Docker socket..."
TIMEOUT=300  # 30 seconds (300 * 0.1s)
COUNT=0
while [ ! -S "$SOCKET_PATH" ] && [ $COUNT -lt $TIMEOUT ]; do
    sleep 0.1
    COUNT=$((COUNT + 1))
done

if [ -S "$SOCKET_PATH" ]; then
    fix_socket_permissions
    echo "Docker socket permissions configured: $(stat -c '%a %U:%G' $SOCKET_PATH)"
else
    echo "WARNING: Docker socket not found after 30 seconds"
fi

# Background permission monitor - handles daemon restarts and permission resets
(
    while kill -0 $DOCKERD_PID 2>/dev/null; do
        sleep 5
        if [ -S "$SOCKET_PATH" ]; then
            CURRENT_PERMS=$(stat -c "%a" "$SOCKET_PATH" 2>/dev/null || echo "")
            CURRENT_GROUP=$(stat -c "%G" "$SOCKET_PATH" 2>/dev/null || echo "")
            if [[ "$CURRENT_PERMS" != "660" || "$CURRENT_GROUP" != "$DOCKER_GROUP" ]]; then
                fix_socket_permissions
                echo "Docker socket permissions restored: $(stat -c '%a %U:%G' $SOCKET_PATH)"
            fi
        fi
    done
) &
MONITOR_PID=$!

# Cleanup on exit
cleanup() {
    echo "Stopping Docker daemon and monitor..."
    kill $MONITOR_PID 2>/dev/null || true
    kill $DOCKERD_PID 2>/dev/null || true
    wait $DOCKERD_PID 2>/dev/null || true
}
trap cleanup EXIT TERM INT

# Wait for dockerd (this is the main process)
wait $DOCKERD_PID
EXIT_CODE=$?

exit $EXIT_CODE
