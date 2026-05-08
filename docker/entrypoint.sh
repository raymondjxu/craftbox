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

# Minecraft writes logs to ./logs relative to its cwd. We cd into $DATA_DIR
# before launch, so symlink ./logs there to the dedicated logs volume.
ln -sfn "${LOGS_DIR}" "${DATA_DIR}/logs"

# Verify EULA acceptance via environment variable
if [ "${ACCEPT_EULA}" != "true" ]; then
  echo "ERROR: You must accept the Minecraft EULA by setting ACCEPT_EULA=true"
  exit 1
fi

# Ensure eula.txt exists in the data dir (cwd at launch time). Minecraft reads
# eula.txt relative to its working directory, so the baked copy in
# /opt/minecraft is not enough once we cd into the volume.
echo "eula=true" > "${DATA_DIR}/eula.txt"

# Stage mods and config from the image into the data dir so Fabric finds them
# at ./mods and ./config when launched from $DATA_DIR.
if [ -d "${MINECRAFT_HOME}/mods" ]; then
  ln -sfn "${MINECRAFT_HOME}/mods" "${DATA_DIR}/mods"
fi
if [ -d "${MINECRAFT_HOME}/config" ]; then
  # Copy (not symlink) so mods can write to their own config files at runtime.
  mkdir -p "${DATA_DIR}/config"
  cp -rn "${MINECRAFT_HOME}/config/." "${DATA_DIR}/config/" 2>/dev/null || true
fi

# Deploy bundled datapacks on first run (don't overwrite existing datapacks)
if [ -d "${DATAPACKS_BUNDLED}" ] && [ "$(ls -A "${DATAPACKS_BUNDLED}" 2>/dev/null | grep -v '^\.' | wc -l)" -gt 0 ]; then
  mkdir -p "${DATAPACKS_WORLD}"
  if [ ! -d "${DATAPACKS_WORLD}" ] || [ "$(ls -A "${DATAPACKS_WORLD}" 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "Deploying bundled datapacks to world/datapacks/..."
    cp -r "${DATAPACKS_BUNDLED}"/* "${DATAPACKS_WORLD}" 2>/dev/null || true
  fi
fi

# Render server.properties from template using envsubst. The template uses
# bash-style `${VAR:-default}` syntax; we apply defaults here so envsubst sees
# fully-qualified values (envsubst itself does not understand `:-defaults`).
: "${MOTD:=A Fabric Minecraft Server}"
: "${MAX_PLAYERS:=20}"
: "${DIFFICULTY:=normal}"
: "${GAMEMODE:=survival}"
: "${PVP:=true}"
: "${VIEW_DISTANCE:=10}"
: "${SIMULATION_DISTANCE:=10}"
: "${ONLINE_MODE:=true}"
: "${SPAWN_PROTECTION:=16}"
: "${ENABLE_COMMAND_BLOCKS:=false}"
: "${SPAWN_ANIMALS:=true}"
: "${SPAWN_MONSTERS:=true}"
: "${ENABLE_RCON:=false}"
: "${RCON_PASSWORD:=}"
: "${LEVEL_SEED:=}"
: "${ALLOW_NETHER:=true}"
: "${ALLOW_FLIGHT:=false}"
: "${HARDCORE:=false}"
: "${WHITE_LIST:=false}"
export MOTD MAX_PLAYERS DIFFICULTY GAMEMODE PVP VIEW_DISTANCE SIMULATION_DISTANCE \
  ONLINE_MODE SPAWN_PROTECTION ENABLE_COMMAND_BLOCKS SPAWN_ANIMALS SPAWN_MONSTERS \
  ENABLE_RCON RCON_PASSWORD LEVEL_SEED ALLOW_NETHER ALLOW_FLIGHT HARDCORE WHITE_LIST

# Strip the `:-default` portion so envsubst sees plain `${VAR}` references.
sed -E 's/\$\{([A-Z_][A-Z0-9_]*):-[^}]*\}/${\1}/g' \
  "${MINECRAFT_HOME}/server.properties.tmpl" \
  | envsubst > "${DATA_DIR}/server.properties"

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
