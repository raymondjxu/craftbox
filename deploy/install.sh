#!/bin/bash
# Craftbox installation script
# Detects OS, installs Docker, deploys compose stack, and configures auto-updates.
# Supports multiple instances on the same host (each with its own directory and systemd units).
# Usage: curl https://raw.githubusercontent.com/raymondjxu/craftbox/main/deploy/install.sh | bash
#        or: bash install.sh [--instance NAME] [--tag TAG] [--loki-url URL]
#
# Examples:
#   bash install.sh                    # Single instance in /opt/craftbox
#   bash install.sh --instance vanilla # Instance in /opt/craftbox-vanilla
#   bash install.sh --instance modded  # Instance in /opt/craftbox-modded

set -e

# Defaults
CRAFTBOX_INSTANCE="${CRAFTBOX_INSTANCE:-default}"
if [ "$CRAFTBOX_INSTANCE" = "default" ]; then
    CRAFTBOX_DIR="${CRAFTBOX_DIR:-/opt/craftbox}"
else
    CRAFTBOX_DIR="${CRAFTBOX_DIR:-/opt/craftbox-${CRAFTBOX_INSTANCE}}"
fi
CRAFTBOX_REPO="${CRAFTBOX_REPO:-https://raw.githubusercontent.com/raymondjxu/craftbox/main}"
CRAFTBOX_TAG="${CRAFTBOX_TAG:-latest}"
LOKI_URL=""
LOKI_USERNAME=""
LOKI_PASSWORD=""
SKIP_DOCKER=0
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

install_docker() {
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
    sudo mkdir -p "$CRAFTBOX_DIR"
    sudo chown "$(id -u):$(id -g)" "$CRAFTBOX_DIR" 2>/dev/null || {
        log_warn "Could not change ownership of $CRAFTBOX_DIR. You may need sudo to manage it."
    }
    cd "$CRAFTBOX_DIR"
}

download_files() {
    log_info "Downloading deployment files from $CRAFTBOX_REPO..."

    local files=(
        "deploy/docker-compose.yml"
        "deploy/alloy/config.alloy"
        "deploy/craftbox-update.sh"
        "deploy/craftbox-update.service"
        "deploy/craftbox-update.timer"
    )

    for file in "${files[@]}"; do
        local dest_file="$(basename "$file")"
        # Create subdirs if needed
        mkdir -p "$(dirname "$file")"
        
        log_info "Downloading $file..."
        
        if [ -n "$NO_TLS_VERIFY" ]; then
            curl -k "$CRAFTBOX_REPO/$file" -o "$file"
        else
            curl "$CRAFTBOX_REPO/$file" -o "$file"
        fi
    done

    log_info "Files downloaded successfully"
}

prompt_loki_config() {
    log_info "Configuring Grafana Loki integration..."
    echo ""
    echo "Grafana Alloy will ship server logs to Loki."
    echo "Leave blank to skip Loki integration (logs only stay in container)."
    echo ""

    read -p "Loki endpoint URL (e.g., http://loki.example.com:3100): " LOKI_URL
    
    if [ -z "$LOKI_URL" ]; then
        log_warn "Loki integration skipped."
        LOKI_URL="http://localhost:3100"
        return
    fi

    read -p "Loki username (leave blank if no auth): " LOKI_USERNAME
    read -sp "Loki password (leave blank if no auth): " LOKI_PASSWORD
    echo ""

    log_info "Loki endpoint: $LOKI_URL"
}

write_env_file() {
    log_info "Writing .env file..."

    cat > .env << EOF
# Craftbox environment configuration (Instance: $CRAFTBOX_INSTANCE)
CRAFTBOX_INSTANCE=$CRAFTBOX_INSTANCE
CRAFTBOX_IMAGE=ghcr.io/your-org/craftbox:\${CRAFTBOX_TAG:-$CRAFTBOX_TAG}

# Network ports (adjust if running multiple instances on same host)
SERVER_PORT=25565
ALLOY_PORT=12345

# Loki credentials for log shipping
LOKI_URL=$LOKI_URL
LOKI_USERNAME=$LOKI_USERNAME
LOKI_PASSWORD=$LOKI_PASSWORD

# Minecraft server settings
MOTD=A Fabric Minecraft Server
MAX_PLAYERS=20
DIFFICULTY=normal
GAMEMODE=survival
VIEW_DISTANCE=10
SIMULATION_DISTANCE=10
ONLINE_MODE=true
PVP=true
SPAWN_ANIMALS=true
SPAWN_MONSTERS=true

# Java VM options
JVM_OPTS=-Xms1G -Xmx2G
EOF

    chmod 600 .env
    log_info ".env file created (and protected with mode 600)"
}}

install_systemd_units() {
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

    docker compose up -d

    log_info "Services started!"
    echo ""
    log_info "Status:"
    docker compose ps
    echo ""
    log_info "View logs:"
    echo "  docker compose logs -f mc-server"
    echo "  docker compose logs -f alloy"
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
A systemd timer will check for new images daily.
Status: systemctl status craftbox-update@${CRAFTBOX_INSTANCE}.timer
To manually update now:
  $CRAFTBOX_DIR/craftbox-update.sh

${YELLOW}Managing multiple instances:${NC}
Each instance has its own directory and systemd units.
To run another instance:
  bash install.sh --instance vanilla
  bash install.sh --instance modded

${YELLOW}Logs via Loki:${NC}
EOF
    if [ -z "$LOKI_URL" ] || [ "$LOKI_URL" = "http://localhost:3100" ]; then
        echo "  No remote Loki endpoint configured."
        echo "  To enable: edit .env and set LOKI_URL"
    else
        echo "  Logs are being shipped to: $LOKI_URL"
        echo "  Query logs in Loki: {service=\"craftbox-${CRAFTBOX_INSTANCE}\"}"
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
                if [ "$CRAFTBOX_INSTANCE" = "default" ]; then
                    CRAFTBOX_DIR="/opt/craftbox"
                else
                    CRAFTBOX_DIR="/opt/craftbox-${CRAFTBOX_INSTANCE}"
                fi
                shift 2
                ;;
            --craftbox-dir)
                CRAFTBOX_DIR="$2"
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
                shift 2
                ;;
            --no-tls-verify)
                NO_TLS_VERIFY=1
                shift
                ;;
            --skip-docker)
                SKIP_DOCKER=1
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

    # Configure Loki
    if [ -z "$LOKI_URL" ]; then
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
