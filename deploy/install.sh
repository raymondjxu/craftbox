#!/bin/bash
# Craftbox installation script
# Detects OS, installs Docker, deploys compose stack, and configures auto-updates.
# Supports multiple instances on the same host (each with its own directory and optional systemd units).
# Usage: curl https://raw.githubusercontent.com/raymondjxu/craftbox/main/deploy/install.sh | bash
#        or: bash install.sh [--instance NAME] [--craftbox-dir PATH] [--tag TAG] [--loki-url URL] [--enable-logs] [--skip-docker] [--skip-systemd]
#
# Examples:
#   bash install.sh                    # Single instance in /opt/craftbox
#   bash install.sh --instance vanilla # Instance in /opt/craftbox-vanilla
#   bash install.sh --instance modded  # Instance in /opt/craftbox-modded
#   bash install.sh --enable-logs      # Enable optional Alloy log shipping

set -e

# Defaults
CRAFTBOX_INSTANCE="${CRAFTBOX_INSTANCE:-default}"
CRAFTBOX_DIR_SPECIFIED=0
if [ -n "${CRAFTBOX_DIR+x}" ]; then
    CRAFTBOX_DIR_SPECIFIED=1
fi
CRAFTBOX_DIR="${CRAFTBOX_DIR:-}"
CRAFTBOX_REPO="${CRAFTBOX_REPO:-https://raw.githubusercontent.com/raymondjxu/craftbox/main}"
CRAFTBOX_TAG="${CRAFTBOX_TAG:-latest}"
LOKI_URL=""
LOKI_USERNAME=""
LOKI_PASSWORD=""
ENABLE_LOG_SHIPPING="${ENABLE_LOG_SHIPPING:-0}"
SKIP_DOCKER=0
SKIP_SYSTEMD=0
NO_TLS_VERIFY=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

detect_os() {
    local uname_out
    uname_out="$(uname -s)"
    if [ "$uname_out" = "Darwin" ]; then
        OS="macos"
        if command -v sw_vers >/dev/null 2>&1; then
            VER="$(sw_vers -productVersion)"
        else
            VER="unknown"
        fi
        log_info "Detected macOS: $VER"
        FAMILY="mac"
        return
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    case "$OS" in
        ubuntu|debian)
            log_info "Detected Debian family: $OS $VER"
            FAMILY="debian"
            ;;
        rhel|centos|rocky|almalinux|fedora)
            log_info "Detected RHEL family: $OS $VER"
            FAMILY="rhel"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

set_default_craftbox_dir() {
    if [ "$CRAFTBOX_DIR_SPECIFIED" -eq 1 ]; then
        return
    fi

    local base_dir
    if [ "$FAMILY" = "mac" ]; then
        base_dir="$HOME"
    else
        base_dir="/opt"
    fi

    if [ "$CRAFTBOX_INSTANCE" = "default" ]; then
        CRAFTBOX_DIR="$base_dir/craftbox"
    else
        CRAFTBOX_DIR="$base_dir/craftbox-${CRAFTBOX_INSTANCE}"
    fi
}

install_docker() {
    if [ "$FAMILY" = "mac" ]; then
        if command -v docker &> /dev/null; then
            log_info "Docker is already installed: $(docker --version)"
            return 0
        fi

        log_error "Docker Desktop is required on macOS. Install it from: https://docs.docker.com/desktop/install/mac-install/"
        exit 1
    fi

    if command -v docker &> /dev/null; then
        log_info "Docker is already installed: $(docker --version)"
        return 0
    fi

    log_info "Installing Docker Engine..."
    
    # Download and run the official Docker installation script
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo bash /tmp/get-docker.sh
    rm /tmp/get-docker.sh

    # Add current user to docker group (if applicable)
    if [ -n "$SUDO_USER" ]; then
        sudo usermod -aG docker "$SUDO_USER"
        log_info "Added $SUDO_USER to docker group. You may need to log out and back in."
    fi

    # Start and enable Docker daemon
    sudo systemctl daemon-reload
    sudo systemctl enable docker
    sudo systemctl start docker

    log_info "Docker installed successfully: $(docker --version)"
}

ensure_docker_compose() {
    if docker compose version &> /dev/null; then
        log_info "Docker Compose plugin is installed: $(docker compose version)"
        return 0
    fi

    log_error "Docker Compose plugin is not installed. Please install it manually."
    exit 1
}

create_craftbox_directory() {
    log_info "Creating $CRAFTBOX_DIR..."
    if [ "$FAMILY" = "mac" ]; then
        mkdir -p "$CRAFTBOX_DIR"
    else
        sudo mkdir -p "$CRAFTBOX_DIR"
        sudo chown "$(id -u):$(id -g)" "$CRAFTBOX_DIR" 2>/dev/null || {
            log_warn "Could not change ownership of $CRAFTBOX_DIR. You may need sudo to manage it."
        }
    fi
    cd "$CRAFTBOX_DIR"
}

download_files() {
    log_info "Downloading deployment files from $CRAFTBOX_REPO..."

    # Map of remote source path -> local destination (relative to $CRAFTBOX_DIR).
    local files=(
        "deploy/docker-compose.yml:docker-compose.yml"
        "deploy/alloy/config.alloy:alloy/config.alloy"
        "deploy/craftbox-update.sh:craftbox-update.sh"
        "deploy/craftbox-update.service:craftbox-update.service"
        "deploy/craftbox-update.timer:craftbox-update.timer"
    )

    local curl_opts=(-fsSL)
    if [ -n "$NO_TLS_VERIFY" ]; then
        curl_opts+=(-k)
    fi

    for entry in "${files[@]}"; do
        local src="${entry%%:*}"
        local dest="${entry##*:}"
        mkdir -p "$(dirname "$dest")"
        log_info "Downloading $src -> $dest..."
        if ! curl "${curl_opts[@]}" "$CRAFTBOX_REPO/$src" -o "$dest"; then
            log_error "Failed to download $src"
            exit 1
        fi
    done

    log_info "Files downloaded successfully"
}

prompt_loki_config() {
    log_info "Configuring Grafana Loki integration..."
    echo ""
    echo "Grafana Alloy will ship server logs to Loki."
    echo "Leave blank to use the default (http://localhost:3100)."
    echo ""

    local prompt_in="/dev/stdin"
    if [ ! -t 0 ] && [ -r /dev/tty ]; then
        prompt_in="/dev/tty"
    fi

    if ! read -r -p "Loki endpoint URL (e.g., http://loki.example.com:3100): " LOKI_URL < "$prompt_in"; then
        log_warn "No interactive input detected; defaulting Loki URL to http://localhost:3100."
        LOKI_URL="http://localhost:3100"
        return
    fi

    if [ -z "$LOKI_URL" ]; then
        log_warn "No Loki endpoint provided; defaulting to http://localhost:3100."
        LOKI_URL="http://localhost:3100"
        return
    fi

    if ! read -r -p "Loki username (leave blank if no auth): " LOKI_USERNAME < "$prompt_in"; then
        LOKI_USERNAME=""
    fi
    if ! read -r -s -p "Loki password (leave blank if no auth): " LOKI_PASSWORD < "$prompt_in"; then
        LOKI_PASSWORD=""
    fi
    echo ""

    log_info "Loki endpoint: $LOKI_URL"
}

write_env_file() {
    log_info "Writing .env file..."

    # Derive the GHCR image namespace from the configured repo URL so the
    # generated .env points at a real image (the repo path matches the GHCR
    # owner/name for repos published from the same source).
    local image_owner_repo
    image_owner_repo="$(echo "$CRAFTBOX_REPO" \
        | sed -E 's#https?://raw\.githubusercontent\.com/##; s#/(main|master)$##')"
    if [ -z "$image_owner_repo" ]; then
        image_owner_repo="raymondjxu/craftbox"
    fi

    env_quote() {
        local value="$1"
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//\$/\\\$}"
        printf '"%s"' "$value"
    }

    cat > .env << EOF
# Craftbox environment configuration (Instance: $CRAFTBOX_INSTANCE)
CRAFTBOX_INSTANCE=$(env_quote "$CRAFTBOX_INSTANCE")
CRAFTBOX_TAG=$(env_quote "$CRAFTBOX_TAG")
CRAFTBOX_IMAGE=$(env_quote "ghcr.io/${image_owner_repo}:$CRAFTBOX_TAG")

# Network ports (adjust if running multiple instances on same host)
SERVER_PORT=$(env_quote "25565")
ALLOY_PORT=$(env_quote "12345")

# Loki credentials for log shipping
LOKI_URL=$(env_quote "$LOKI_URL")
LOKI_USERNAME=$(env_quote "$LOKI_USERNAME")
LOKI_PASSWORD=$(env_quote "$LOKI_PASSWORD")

# Minecraft server settings
MOTD=$(env_quote "A Fabric Minecraft Server")
MAX_PLAYERS=$(env_quote "20")
DIFFICULTY=$(env_quote "normal")
GAMEMODE=$(env_quote "survival")
VIEW_DISTANCE=$(env_quote "10")
SIMULATION_DISTANCE=$(env_quote "10")
ONLINE_MODE=$(env_quote "true")
PVP=$(env_quote "true")
SPAWN_ANIMALS=$(env_quote "true")
SPAWN_MONSTERS=$(env_quote "true")

# Java VM options
JVM_OPTS=$(env_quote "-Xms1G -Xmx2G")
EOF

    chmod 600 .env
    log_info ".env file created (and protected with mode 600)"
}

install_systemd_units() {
    if [ "$SKIP_SYSTEMD" -eq 1 ]; then
        chmod +x craftbox-update.sh
        log_warn "Skipping systemd units (not supported on this OS)."
        return 0
    fi

    log_info "Installing systemd units..."

    # Generate instance-specific service names
    local service_name="craftbox-update@${CRAFTBOX_INSTANCE}.service"
    local timer_name="craftbox-update@${CRAFTBOX_INSTANCE}.timer"

    # Read the service and timer template files
    local service_content=$(cat craftbox-update.service)
    local timer_content=$(cat craftbox-update.timer)

    # Replace paths and instance name in templates
    service_content="${service_content//\{\{CRAFTBOX_DIR\}\}/$CRAFTBOX_DIR}"
    service_content="${service_content//\{\{INSTANCE\}\}/$CRAFTBOX_INSTANCE}"
    timer_content="${timer_content//\{\{INSTANCE\}\}/$CRAFTBOX_INSTANCE}"

    # Write to systemd directory with instance name
    echo "$service_content" | sudo tee "/etc/systemd/system/$service_name" > /dev/null
    echo "$timer_content" | sudo tee "/etc/systemd/system/$timer_name" > /dev/null

    # Make craftbox-update.sh executable
    chmod +x craftbox-update.sh

    # Reload systemd and enable the timer
    sudo systemctl daemon-reload
    sudo systemctl enable "$timer_name"
    sudo systemctl start "$timer_name"

    log_info "Systemd units installed: $service_name, $timer_name"
    log_info "Timer started (daily updates enabled)"
}

start_services() {
    log_info "Starting Craftbox services..."

    if [ "$ENABLE_LOG_SHIPPING" -eq 1 ]; then
        docker compose --profile logs up -d
    else
        docker compose up -d
    fi

    log_info "Services started!"
    echo ""
    log_info "Status:"
    docker compose ps
    echo ""
    log_info "View logs:"
    echo "  docker compose logs -f mc-server"
    if [ "$ENABLE_LOG_SHIPPING" -eq 1 ]; then
        echo "  docker compose logs -f alloy"
    fi
}

show_next_steps() {
    cat << EOF

${GREEN}=== Craftbox Installation Complete ===${NC}

Instance: $CRAFTBOX_INSTANCE
Location: $CRAFTBOX_DIR

${YELLOW}Next steps:${NC}
1. Join the server at localhost:25565 (or your server's IP)
2. View logs: cd $CRAFTBOX_DIR && docker compose logs -f
3. Manage Minecraft server properties in .env
4. Add mods by updating and rebuilding the image

${YELLOW}Auto-updates:${NC}
EOF
        if [ "$SKIP_SYSTEMD" -eq 1 ]; then
                echo "Systemd is not available, so auto-updates are disabled."
                echo "To update manually:"
                echo "  $CRAFTBOX_DIR/craftbox-update.sh"
        else
                echo "A systemd timer will check for new images daily."
                echo "Status: systemctl status craftbox-update@${CRAFTBOX_INSTANCE}.timer"
                echo "To manually update now:"
                echo "  $CRAFTBOX_DIR/craftbox-update.sh"
        fi

        cat << EOF

${YELLOW}Managing multiple instances:${NC}
Each instance has its own directory and docker compose stack.
To run another instance:
  bash install.sh --instance vanilla
  bash install.sh --instance modded

${YELLOW}Logs via Loki:${NC}
EOF
    if [ "$ENABLE_LOG_SHIPPING" -eq 1 ]; then
        if [ -z "$LOKI_URL" ] || [ "$LOKI_URL" = "http://localhost:3100" ]; then
            echo "  No remote Loki endpoint configured."
            echo "  To enable: edit .env and set LOKI_URL"
        else
            echo "  Logs are being shipped to: $LOKI_URL"
            echo "  Query logs in Loki: {service=\"craftbox-${CRAFTBOX_INSTANCE}\"}"
        fi
    else
        echo "  Log shipping is disabled (Alloy profile not enabled)."
        echo "  To enable: rerun with --enable-logs or set ENABLE_LOG_SHIPPING=1"
    fi

    cat << EOF

${YELLOW}Documentation:${NC}
  https://github.com/raymondjxu/craftbox#readme

${RED}Important:${NC}
- Edit .env to customize server settings before restarting
- The world directory is persisted in a Docker named volume
- Always use 'docker compose' commands from $CRAFTBOX_DIR
- Each instance is independent (own containers, volumes, ports)

EOF
}

main() {
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --instance)
                CRAFTBOX_INSTANCE="$2"
                shift 2
                ;;
            --craftbox-dir)
                CRAFTBOX_DIR="$2"
                CRAFTBOX_DIR_SPECIFIED=1
                shift 2
                ;;
            --repo)
                CRAFTBOX_REPO="$2"
                shift 2
                ;;
            --tag)
                CRAFTBOX_TAG="$2"
                shift 2
                ;;
            --loki-url)
                LOKI_URL="$2"
                ENABLE_LOG_SHIPPING=1
                shift 2
                ;;
            --enable-logs)
                ENABLE_LOG_SHIPPING=1
                shift
                ;;
            --no-tls-verify)
                NO_TLS_VERIFY=1
                shift
                ;;
            --skip-docker)
                SKIP_DOCKER=1
                shift
                ;;
            --skip-systemd)
                SKIP_SYSTEMD=1
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    log_info "Starting Craftbox installation..."
    echo ""

    # Detect OS
    detect_os

    if [ "$FAMILY" = "mac" ]; then
        SKIP_SYSTEMD=1
    fi

    # Set instance directory defaults once OS is known
    set_default_craftbox_dir

    # Install Docker if needed
    if [ $SKIP_DOCKER -eq 0 ]; then
        install_docker
    else
        log_info "Skipping Docker installation"
    fi

    # Ensure Docker Compose is available
    ensure_docker_compose

    # Create working directory
    create_craftbox_directory

    # Download deployment files
    download_files

    # Create alloy subdirectory
    mkdir -p alloy

    # Configure Loki if log shipping is enabled
    if [ "$ENABLE_LOG_SHIPPING" -eq 1 ] && [ -z "$LOKI_URL" ]; then
        prompt_loki_config
    fi

    # Write .env
    write_env_file

    # Install systemd units
    install_systemd_units

    # Start services
    start_services

    # Show next steps
    show_next_steps
}

# Run main
main "$@"
