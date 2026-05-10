# craftbox

A curated [Fabric](https://fabricmc.net/) Minecraft server pack for Minecraft `26.1.2`.

**Craftbox is a server pack, not a Minecraft server.** It provides a mod manifest, mod configs, datapacks, and a starter `server.properties`. CI resolves the manifest against [Modrinth](https://modrinth.com/) and publishes a `craftbox-pack.tar.gz` tarball to GitHub Releases. A game-server host (e.g. [PufferPanel](https://pufferpanel.com/)) downloads and extracts it.

## Contents

| Path | Description |
|------|-------------|
| `mods/manifest.yaml` | Mod list — Modrinth slugs + version IDs, or vendored jar paths |
| `server/vendored-mods/` | Mods not available on Modrinth |
| `config/` | Mod configuration files |
| `datapacks/` | Datapack zips or directories |
| `server.properties` | Starter server properties (edit via panel or SFTP after deploy) |
| `scripts/resolve_mods.py` | Downloads mods from Modrinth at CI time |
| `scripts/package.py` | Bundles everything into `craftbox-pack.tar.gz` |

## Deployment

### Recommended: PufferPanel

Create a server using the stock **Minecraft Java (Fabric)** template, then add these steps to the `install` phase to overlay the craftbox pack:

```json
{
  "type": "download",
  "files": [
    "https://github.com/raymondjxu/craftbox/releases/latest/download/craftbox-pack.tar.gz"
  ]
},
{
  "type": "command",
  "commands": [
    "tar -xzf craftbox-pack.tar.gz",
    "rm craftbox-pack.tar.gz"
  ]
}
```

Set the Minecraft version and Fabric loader version to match `mods/manifest.yaml`.

### Manual

```bash
# On a fresh Fabric server data directory:
curl -fsSL https://github.com/raymondjxu/craftbox/releases/latest/download/craftbox-pack.tar.gz \
  | tar -xzf -
```

Then start the server. `world/`, `ops.json`, and `whitelist.json` are not in the tarball and are safe across re-extractions.

## Updating mods

To apply an updated pack to a running server:
1. Stop the server.
2. Re-extract the tarball over the existing data directory.
3. Start the server.

World data is preserved — the tarball does not include `world/` or player state files.

## Adding or updating a mod

1. Find the mod on [Modrinth](https://modrinth.com/).
2. Get the `version_id` from the download URL: `https://cdn.modrinth.com/data/{project_id}/versions/{version_id}/{filename}`
3. Add or update the entry in `mods/manifest.yaml`.
4. Open a PR — CI will resolve all mods and verify the manifest is valid.

For mods not on Modrinth, place the jar in `server/vendored-mods/` and add a `source: vendored` entry to the manifest.

## Local development

```bash
pip install pyyaml
python scripts/resolve_mods.py --manifest mods/manifest.yaml --out build/mods
python scripts/package.py --out craftbox-pack.tar.gz
tar tzf craftbox-pack.tar.gz   # verify contents
```
