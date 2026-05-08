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

read_env_value() {
    local key="$1"
    local value

    value="$(awk -F= -v k="$key" '
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "=" {
            sub("^[[:space:]]*(export[[:space:]]+)?" k "=", "", $0)
            print
            exit
        }
    ' "$ENV_FILE")"

    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

    case "$value" in
        \"*\")
            value="${value#\"}"
            value="${value%\"}"
            value="${value//\\\\/\\}"
            value="${value//\\\"/\"}"
            value="${value//\\\$/\$}"
            ;;
        \'*\')
            value="${value#\'}"
            value="${value%\'}"
            ;;
    esac

    printf '%s' "$value"
}

# Read image name without sourcing .env (values may contain spaces).
if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi

# Use docker compose variable or fall back
IMAGE="$(read_env_value CRAFTBOX_IMAGE)"
if [ -z "$IMAGE" ]; then
    IMAGE="ghcr.io/your-org/craftbox:latest"
fi

log_info "Checking for updates to $IMAGE..."

# Pull latest image (without starting containers)
cd "$CRAFTBOX_DIR"
docker compose pull

# Compare local image IDs (sha256 of the image config) — both `docker inspect
# <image>` and `docker inspect <container> .Image` return values in the same
# `sha256:...` namespace, unlike RepoDigests which is the registry manifest
# digest and is not comparable to a container's image ID.
NEW_ID=$(docker inspect "$IMAGE" --format='{{.Id}}' 2>/dev/null || echo "")
log_info "Pulled image ID: ${NEW_ID:-unknown}"

RUNNING_CONTAINER=$(docker compose ps -q mc-server 2>/dev/null || true)

if [ -z "$RUNNING_CONTAINER" ]; then
    log_info "No running container found. Starting services..."
    docker compose up -d
    exit 0
fi

RUNNING_ID=$(docker inspect "$RUNNING_CONTAINER" --format='{{.Image}}' 2>/dev/null || echo "")
log_info "Running container image ID: ${RUNNING_ID:-unknown}"

if [ -n "$NEW_ID" ] && [ "$NEW_ID" = "$RUNNING_ID" ]; then
    log_info "No updates available. Container is up to date."
    exit 0
fi

log_info "Update detected! Recreating container..."
log_info "  Old: ${RUNNING_ID:-unknown}"
log_info "  New: ${NEW_ID:-unknown}"

# Recreate container with new image (volumes persist)
docker compose up -d

log_info "Container updated successfully. World and player data preserved."
