*This project was generated with GitHub Copilot and Claude Code and is intended for my personal use. There's a lot of dumb design choices that I wouldn't have made if I wrote this by hand. Use at your own risk.*


# Craftbox — Plug-and-Play Fabric Minecraft Server

A production-ready Docker-based [Fabric Minecraft](https://fabricmc.net/) server with:
- **Reproducible builds** via GitHub Actions (mods resolved from Modrinth + optional vendored jars)
- **Persistent world** (named volumes survive container updates)
- **Auto-updates** via systemd timer (digest check, zero-downtime container swap)
- **Log aggregation** with Grafana Alloy → Loki
- **Multi-instance support** (run multiple servers on the same host)
- **Pure Python scripts** for CI portability (not GitHub-specific)

## Quick Start

### 1. Prerequisites
- Linux host (Debian/Ubuntu or RHEL/CentOS family)
- `curl` or `bash` to run the installer
- ~2 GB disk space (mod cache + world data)
- 2+ GB RAM recommended

### 2. One-Command Installation

```bash
curl -fsSL https://raw.githubusercontent.com/raymondjxu/craftbox/main/deploy/install.sh | bash
```

Or, for a named instance (if running multiple servers):
```bash
curl -fsSL https://raw.githubusercontent.com/raymondjxu/craftbox/main/deploy/install.sh | bash -s -- --instance vanilla
```

The installer will:
- Detect your OS and install Docker
- Download the compose stack and systemd units
- Prompt for Loki credentials (optional)
- Start the server

### 3. Join the Server
Connect to `localhost:25565` (or your server's IP) in Minecraft 26.1.x with Fabric.

### 4. View Logs
```bash
cd /opt/craftbox  # or /opt/craftbox-{instance} for named instances
docker compose logs -f mc-server
docker compose logs -f alloy  # Loki shipping logs
```

---

## Configuration

All Minecraft server settings are in `.env`:

```bash
cd /opt/craftbox
cat .env
```

Edit `.env` to customize:
- `MOTD`, `MAX_PLAYERS`, `DIFFICULTY`, `GAMEMODE`
- `VIEW_DISTANCE`, `SIMULATION_DISTANCE`
- `ONLINE_MODE` (set to `false` for LAN)
- `JVM_OPTS` (Java memory: `-Xms2G -Xmx4G` for more players)
- `SERVER_PORT`, `ALLOY_PORT` (for multi-instance deployments)
- `LOKI_*` (log shipping credentials)

Then restart:
```bash
docker compose up -d
```

---

## Adding Mods

Mods are declared in `mods/manifest.yaml` (Modrinth + optional vendored jars).

### From Modrinth

1. Find a mod on [Modrinth](https://modrinth.com/mods?g=categories:%22fabric%22)
2. Get its **Project ID** and desired **Version ID**
3. Add to `mods/manifest.yaml`:

```yaml
mods:
  - slug: "lithium"
    project_id: "gvQqBUqZ"
    version_id: "abc123def456..."
    source: modrinth
```

### Vendored Jars

Place custom `.jar` files in `server/vendored-mods/` and reference in the manifest:

```yaml
mods:
  - slug: "my-custom-mod"
    path: "my-custom-mod.jar"
    source: vendored
```

### Rebuild & Redeploy

```bash
git add mods/manifest.yaml server/vendored-mods/
git commit -m "Add mods"
git push
```

GitHub Actions will:
1. Resolve mods from manifest
2. Build the image
3. Push to GHCR

Then update your host:
```bash
cd /opt/craftbox
docker compose pull
docker compose up -d
```

Or wait for the automatic daily update (systemd timer).

---

## Adding Datapacks

Datapacks are world-specific customizations and are managed separately from mods.

### Using Bundled Datapacks

Place datapack `.zip` files or directories in `datapacks/`:

```bash
datapacks/
├── my-datapack.zip
├── another-datapack.zip
└── custom-pack/
    └── data/
        └── (datapack contents)
```

Bundled datapacks are copied to `world/datapacks/` on the first server boot. They are baked into the image and deployed reproducibly with your server configuration.

### Rebuild & Redeploy with Datapacks

```bash
git add datapacks/
git commit -m "Add datapacks"
git push
```

The image will rebuild and redeploy with your datapacks. When the container starts, datapacks are deployed to the world directory (only if not already present).

### Adding Datapacks Manually

You can also add datapacks directly to a running server:

```bash
cd /opt/craftbox

# Access the world datapacks directory via Docker
docker run --rm -v craftbox_default_data:/data \
  -v "$(pwd):/upload" alpine \
  cp /upload/my-datapack.zip /data/world/datapacks/

# Then reload datapacks (requires console access or RCON)
```

### Datapack Notes

- Datapacks must be valid for Minecraft 26.1.x (configured in `mods/manifest.yaml`)
- Each datapack should be a `.zip` file containing a `pack.mcmeta` file
- Datapacks are loaded at server startup; changes require a restart
- Player data and world state persist alongside datapacks

---

## Multi-Instance Deployments

Run multiple servers on the same host:

```bash
# Instance 1: vanilla (default settings)
bash install.sh --instance vanilla

# Instance 2: modded (custom image, different port)
bash install.sh --instance modded
```

Each instance has:
- Separate directory: `/opt/craftbox-vanilla` vs `/opt/craftbox-modded`
- Separate systemd units: `craftbox-update@vanilla.service` / `craftbox-update@modded.service`
- Separate Docker volumes (world data persists)
- Separate `.env` file

To manage instances:
```bash
# Vanilla instance
cd /opt/craftbox-vanilla
docker compose logs -f
systemctl status craftbox-update@vanilla.timer

# Modded instance
cd /opt/craftbox-modded
docker compose logs -f
systemctl status craftbox-update@modded.timer
```

---

## Logs & Monitoring

### Local Logs
```bash
cd /opt/craftbox
docker compose logs -f mc-server
```

### Ship Logs to Loki

1. Deploy a Loki instance (e.g., via docker-compose, Grafana Cloud, or your platform)
2. Update `.env` with Loki credentials:
   ```bash
   LOKI_URL=https://your-loki.example.com
   LOKI_USERNAME=username
   LOKI_PASSWORD=secret
   ```
3. Restart Alloy:
   ```bash
   docker compose up -d alloy
   ```
4. Query in Grafana:
   ```
   {service="craftbox"} 
   {service="craftbox-vanilla"}  # For named instances
   ```

---

## Updates & Maintenance

### Manual Update
```bash
cd /opt/craftbox
./craftbox-update.sh
```

### Automatic Updates (Daily)
A systemd timer checks for new container images at 2 AM daily and updates if a new digest is found.

Status:
```bash
systemctl status craftbox-update.timer
systemctl status craftbox-update@default.service  # For named instances
```

View update logs:
```bash
journalctl -u craftbox-update@default.service -f
```

### World Persistence
World data is stored in a Docker named volume:
```bash
docker volume ls | grep craftbox_default_data
```

When the container updates, the volume is **not removed**, so your world, player data, and server state are preserved.

---

## Backup & Recovery

### Backup World
```bash
cd /opt/craftbox

# Export world to a tarball
docker run --rm -v craftbox_default_data:/data \
  -v "$(pwd):/backup" alpine \
  tar czf /backup/world-$(date +%Y%m%d_%H%M%S).tar.gz -C /data .
```

### Restore World
```bash
cd /opt/craftbox
docker compose down

# Stop the container
docker volume rm craftbox_default_data  # Remove old data
docker volume create craftbox_default_data  # Create new volume

# Extract backup
docker run --rm -v craftbox_default_data:/data \
  -v "$(pwd):/backup" alpine \
  tar xzf /backup/world-YYYYMMDD_HHMMSS.tar.gz -C /data

docker compose up -d
```

---

## Troubleshooting

### Server won't start
```bash
# Check logs
docker compose logs mc-server

# Common issues:
# - Out of memory: increase JVM_OPTS in .env
# - Port already in use: change SERVER_PORT in .env
# - Mod conflict: remove problematic mod from manifest, rebuild
```

### Players can't connect
```bash
# Verify server is listening
docker exec craftbox-default-server lsof -i :25565

# Check firewall
sudo ufw allow 25565

# Verify ONLINE_MODE setting (set false for LAN)
grep ONLINE_MODE /opt/craftbox/.env
```

### Loki integration not working
```bash
# Check Alloy logs
docker compose logs alloy

# Verify credentials
grep LOKI_ /opt/craftbox/.env

# Test connectivity
curl -u username:password https://your-loki.example.com/loki/api/v1/query
```

### Stuck on "Scanning mod files..."
Mods are being resolved; this is normal for the first boot. Check the logs:
```bash
docker compose logs -f mc-server
```

---

## Local Development

### Build & Test Image Locally

```bash
# Install Python deps
pip install pyyaml mcstatus

# Resolve mods
python scripts/resolve_mods.py --manifest mods/manifest.yaml --out build/mods

# Build image
docker build --build-arg JAVA_VERSION=25 -t craftbox-test:latest docker/

# Verify it boots
python scripts/verify_server.py craftbox-test:latest --timeout 240 --test-persistence
```

---

## Architecture

### Image Build Pipeline (GitHub Actions)

1. **Checkout** with Git LFS enabled
2. **Resolve mods** (Python script queries Modrinth API, downloads mods)
3. **Build image** with mods baked in
4. **Verify** image boots and clients can connect
5. **Push** to GHCR with tags: `latest`, `vX.Y.Z`, `sha-...`

### Runtime (Host + Containers)

```
/opt/craftbox/
├── docker-compose.yml
├── .env                      (credentials, settings)
├── alloy/config.alloy        (log pipeline)
├── craftbox-update.sh        (digest check, pull, recreate)
│
└── Docker
    ├── mc-server container
    │   └── /opt/minecraft/data/ (world + player data) → volume
    │   └── /opt/minecraft/logs/ → volume
    │   └── /opt/minecraft/mods/ (baked into image)
    │
    └── alloy container
        └── ships logs → Loki (configured via env vars)

Systemd units:
└── /etc/systemd/system/
    ├── craftbox-update@default.service
    └── craftbox-update@default.timer (daily)
```

### Mods Resolution

- **Manifest** (`mods/manifest.yaml`): Modrinth project IDs + version IDs
- **Resolver** (`scripts/resolve_mods.py`): downloads, verifies integrity, copies to `build/mods/`
- **Dockerfile**: `COPY build/mods/ ./mods/` bakes mods into the image
- **Benefits**: reproducible builds, CI portability, no runtime mod downloads

---

## FAQ

**Q: Can I run multiple instances?**  
A: Yes. Use `--instance name` during installation. Each instance has its own directory, containers, volumes, and systemd units.

**Q: Will my world be deleted when I update?**  
A: No. World data is in a Docker named volume, which persists across container updates.

**Q: Can I use this without Loki?**  
A: Yes. Leave `LOKI_URL` empty or set it to a non-routable address. Logs remain accessible via `docker compose logs`.

**Q: How do I pin specific mod versions?**  
A: Edit `mods/manifest.yaml` with exact `version_id`s. Rebuild and redeploy.

**Q: Can I run this on ARM (Raspberry Pi, Apple Silicon)?**  
A: The default image base is `linux/amd64`. Multi-arch support can be added to GitHub Actions (via `buildx`).

**Q: Is this compatible with vanilla server mods/plugins?**  
A: No, this is a **Fabric** server. Mods must be Fabric-compatible. Plugins are not supported (use modding loaders like Fabric instead).

**Q: Can I use RCON?**  
A: Yes. Set `ENABLE_RCON=true` and `RCON_PASSWORD=secret` in `.env`, then restart.

---

## Contributing

Pull requests welcome! Areas for enhancement:
- Multi-arch image builds (ARM64, etc.)
- Automated world backups to S3 or similar
- Web console (e.g., via Rcon or a web UI)
- Performance metrics (Prometheus integration)
- Player whitelist management UI

---

## License

[Specify your license, e.g., MIT]

---

## Support

- **Issues**: GitHub Issues
- **Discussions**: GitHub Discussions
- **Minecraft Version**: 26.1.x (customizable via `mods/manifest.yaml`)
- **Fabric Loader**: 0.16.11 (customizable via `mods/manifest.yaml`)

---

**Happy crafting!** 🎮
