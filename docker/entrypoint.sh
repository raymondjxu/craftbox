#!/bin/bash
set -e

# Entrypoint for Fabric Minecraft server container.
# Renders server.properties from template, ensures directories exist,
# verifies EULA acceptance, and exec's the JVM.

MINECRAFT_HOME=/opt/minecraft
DATA_DIR="${MINECRAFT_HOME}/data"
WORLD_DIR="${DATA_DIR}/world"
LOGS_DIR="${MINECRAFT_HOME}/logs"
CONFIG_DIR="${MINECRAFT_HOME}/config"
DATAPACKS_BUNDLED="${MINECRAFT_HOME}/datapacks"
DATAPACKS_WORLD="${WORLD_DIR}/datapacks"

# Ensure required directories exist (volumes will be mounted)
mkdir -p "${DATA_DIR}" "${LOGS_DIR}"

# Verify EULA acceptance via environment variable
if [ "${ACCEPT_EULA}" != "true" ]; then
  echo "ERROR: You must accept the Minecraft EULA by setting ACCEPT_EULA=true"
  exit 1
fi

# Ensure eula.txt exists with acceptance (baked into image, but double-check)
if [ ! -f "${MINECRAFT_HOME}/eula.txt" ]; then
  echo "eula=true" > "${MINECRAFT_HOME}/eula.txt"
fi

# Deploy bundled datapacks on first run (don't overwrite existing datapacks)
if [ -d "${DATAPACKS_BUNDLED}" ] && [ "$(ls -A "${DATAPACKS_BUNDLED}" 2>/dev/null | grep -v '^\.' | wc -l)" -gt 0 ]; then
  mkdir -p "${DATAPACKS_WORLD}"
  if [ ! -d "${DATAPACKS_WORLD}" ] || [ "$(ls -A "${DATAPACKS_WORLD}" 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "Deploying bundled datapacks to world/datapacks/..."
    cp -r "${DATAPACKS_BUNDLED}"/* "${DATAPACKS_WORLD}" 2>/dev/null || true
  fi
fi

# Render server.properties from template
# Replace ${VAR_NAME} with env var value, falling back to default in template
render_properties() {
  local template="$1"
  local output="$2"
  
  # Read template and expand env vars
  # Use envsubst if available, otherwise fall back to bash variable expansion
  if command -v envsubst &> /dev/null; then
    envsubst < "${template}" > "${output}"
  else
    # Manual expansion of known variables
    sed -e "s|\${MOTD:-[^}]*}|${MOTD:-A Fabric Minecraft Server}|g" \
        -e "s|\${MAX_PLAYERS:-[^}]*}|${MAX_PLAYERS:-20}|g" \
        -e "s|\${DIFFICULTY:-[^}]*}|${DIFFICULTY:-normal}|g" \
        -e "s|\${GAMEMODE:-[^}]*}|${GAMEMODE:-survival}|g" \
        -e "s|\${PVP:-[^}]*}|${PVP:-true}|g" \
        -e "s|\${VIEW_DISTANCE:-[^}]*}|${VIEW_DISTANCE:-10}|g" \
        -e "s|\${SIMULATION_DISTANCE:-[^}]*}|${SIMULATION_DISTANCE:-10}|g" \
        -e "s|\${ONLINE_MODE:-[^}]*}|${ONLINE_MODE:-true}|g" \
        -e "s|\${SPAWN_PROTECTION:-[^}]*}|${SPAWN_PROTECTION:-16}|g" \
        -e "s|\${ENABLE_COMMAND_BLOCKS:-[^}]*}|${ENABLE_COMMAND_BLOCKS:-false}|g" \
        -e "s|\${SPAWN_ANIMALS:-[^}]*}|${SPAWN_ANIMALS:-true}|g" \
        -e "s|\${SPAWN_MONSTERS:-[^}]*}|${SPAWN_MONSTERS:-true}|g" \
        -e "s|\${ENABLE_RCON:-[^}]*}|${ENABLE_RCON:-false}|g" \
        -e "s|\${RCON_PASSWORD:-[^}]*}|${RCON_PASSWORD:-}|g" \
        -e "s|\${LEVEL_SEED:-[^}]*}||g" \
        -e "s|\${ALLOW_NETHER:-[^}]*}|${ALLOW_NETHER:-true}|g" \
        -e "s|\${ALLOW_FLIGHT:-[^}]*}|${ALLOW_FLIGHT:-false}|g" \
        -e "s|\${HARDCORE:-[^}]*}|${HARDCORE:-false}|g" \
        -e "s|\${WHITE_LIST:-[^}]*}|${WHITE_LIST:-false}|g" \
        "${template}" > "${output}"
  fi
}

render_properties "${MINECRAFT_HOME}/server.properties.tmpl" "${DATA_DIR}/server.properties"

# Clean up template after rendering
rm -f "${MINECRAFT_HOME}/server.properties.tmpl"

# Set up traps for clean shutdown
trap 'kill ${MC_PID}; wait ${MC_PID}' SIGTERM SIGINT

# Launch the server
cd "${DATA_DIR}"
exec java \
  ${JVM_OPTS:--Xms1G -Xmx2G} \
  -jar "${MINECRAFT_HOME}/fabric-server-launch.jar" \
  nogui &
MC_PID=$!

# Wait for the server process
wait ${MC_PID}
