#!/bin/bash
# Craftbox auto-update script
# Checks for new image digests and updates the container if needed.
# Designed to be run by systemd timer (see craftbox-update.timer)

set -e

CRAFTBOX_DIR="${CRAFTBOX_DIR:-/opt/craftbox}"
COMPOSE_FILE="$CRAFTBOX_DIR/docker-compose.yml"
ENV_FILE="$CRAFTBOX_DIR/.env"
LOG_LEVEL="${LOG_LEVEL:-info}"

log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# Source environment file to get image name
if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

# Use docker compose variable or fall back
IMAGE="${CRAFTBOX_IMAGE:-ghcr.io/your-org/craftbox:latest}"

log_info "Checking for updates to $IMAGE..."

# Pull latest image (without starting containers)
cd "$CRAFTBOX_DIR"
docker compose pull

# Get the digest of the pulled image
NEW_DIGEST=$(docker inspect "$IMAGE" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "unknown")
log_info "Pulled image digest: $NEW_DIGEST"

# Get the digest of the currently running container
RUNNING_CONTAINER=$(docker compose ps -q mc-server 2>/dev/null || echo "")

if [ -z "$RUNNING_CONTAINER" ]; then
    log_info "No running container found. Starting services..."
    docker compose up -d
    exit 0
fi

RUNNING_DIGEST=$(docker inspect "$RUNNING_CONTAINER" --format='{{index .Image}}' 2>/dev/null || echo "unknown")
log_info "Running container image: $RUNNING_DIGEST"

# Compare digests
if [ "$NEW_DIGEST" = "$RUNNING_DIGEST" ] || [ "$RUNNING_DIGEST" = "unknown" ]; then
    log_info "No updates available. Container is up to date."
    exit 0
fi

log_info "Update detected! Recreating container..."
log_info "  Old: $RUNNING_DIGEST"
log_info "  New: $NEW_DIGEST"

# Recreate container with new image (volumes persist)
docker compose up -d

log_info "Container updated successfully. World and player data preserved."
