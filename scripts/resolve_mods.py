#!/usr/bin/env python3
"""
Mod resolver for Fabric Minecraft server.
Reads mods/manifest.yaml and resolves Modrinth mods + vendored jars to build/mods/.
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error
import shutil
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not found. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


MODRINTH_API = "https://api.modrinth.com/v2"
USER_AGENT = "craftbox/resolve_mods (+https://github.com/raymondjxu/craftbox)"


def fetch_modrinth_version(slug, version_id):
    """
    Fetch metadata for a Modrinth version using the per-project endpoint, which
    accepts either a Modrinth version hash ID or a human-readable version number.
    Returns parsed JSON dict, or None on failure.
    """
    api_url = f"{MODRINTH_API}/project/{slug}/version/{version_id}"
    req = urllib.request.Request(api_url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        print(f"ERROR: Modrinth {slug}@{version_id} returned HTTP {e.code}: {e.reason}", file=sys.stderr)
        return None
    except urllib.error.URLError as e:
        print(f"ERROR: Failed to fetch Modrinth {slug}@{version_id}: {e}", file=sys.stderr)
        return None


def primary_file(data):
    """Pick the primary file from a Modrinth version response, or the first available."""
    files = data.get('files') or []
    if not files:
        return None
    return next((f for f in files if f.get('primary')), files[0])


def download_modrinth_mod(slug, version_id, output_path):
    """
    Download a mod from Modrinth API.
    Returns the filename, or None on failure.
    """
    data = fetch_modrinth_version(slug, version_id)
    if data is None:
        return None

    pfile = primary_file(data)
    if pfile is None:
        print(f"ERROR: No files in Modrinth version {version_id}", file=sys.stderr)
        return None

    download_url = pfile['url']
    filename = pfile['filename']

    try:
        print(f"Downloading {filename}...", file=sys.stderr)
        req = urllib.request.Request(download_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as response, open(output_path, 'wb') as out:
            shutil.copyfileobj(response, out)
    except urllib.error.URLError as e:
        print(f"ERROR: Failed to download {filename}: {e}", file=sys.stderr)
        return None

    return filename


def check_mods(manifest_path, expected_mc_version=None, expected_loader='fabric'):
    """
    Validate every entry in the manifest without downloading mod jars.
    - Modrinth entries: query the API, confirm the version exists and (if known)
      that it lists the manifest's minecraft_version and loader.
    - Vendored entries: confirm the local jar exists.
    Returns True if all entries are valid.
    """
    try:
        with open(manifest_path, 'r') as f:
            manifest = yaml.safe_load(f) or {}
    except FileNotFoundError:
        print(f"ERROR: Manifest not found: {manifest_path}", file=sys.stderr)
        return False
    except yaml.YAMLError as e:
        print(f"ERROR: Failed to parse manifest: {e}", file=sys.stderr)
        return False

    mc_version = expected_mc_version or manifest.get('minecraft_version')
    mods = manifest.get('mods', []) or []
    if not mods:
        print("No mods declared.", file=sys.stderr)
        return True

    ok = True
    for mod in mods:
        slug = mod.get('slug', 'unknown')
        source = mod.get('source', 'modrinth')

        if source == 'modrinth':
            version_id = mod.get('version_id')
            if not version_id:
                print(f"✗ {slug}: missing version_id", file=sys.stderr)
                ok = False
                continue

            data = fetch_modrinth_version(slug, version_id)
            if data is None:
                ok = False
                continue

            pfile = primary_file(data)
            if pfile is None:
                print(f"✗ {slug}: Modrinth version {version_id} has no files", file=sys.stderr)
                ok = False
                continue

            game_versions = data.get('game_versions') or []
            loaders = [l.lower() for l in (data.get('loaders') or [])]
            warnings = []
            if mc_version and game_versions and mc_version not in game_versions:
                warnings.append(f"game_versions={game_versions} does not include {mc_version}")
            if expected_loader and loaders and expected_loader.lower() not in loaders:
                warnings.append(f"loaders={loaders} does not include {expected_loader}")

            status = "✓" if not warnings else "!"
            print(f"{status} {slug} → {pfile['filename']} (version_id={version_id})", file=sys.stderr)
            for w in warnings:
                print(f"    WARN: {w}", file=sys.stderr)
            if warnings:
                ok = False

        elif source == 'vendored':
            vendored_path = mod.get('path')
            if not vendored_path:
                print(f"✗ {slug}: vendored mod missing path", file=sys.stderr)
                ok = False
                continue
            source_path = os.path.join('server', 'vendored-mods', vendored_path)
            if not os.path.exists(source_path):
                print(f"✗ {slug}: vendored jar not found at {source_path}", file=sys.stderr)
                ok = False
                continue
            print(f"✓ {slug} (vendored {vendored_path})", file=sys.stderr)

        else:
            print(f"✗ {slug}: unknown source '{source}'", file=sys.stderr)
            ok = False

    return ok


def resolve_mods(manifest_path, output_dir):
    """
    Resolve all mods from manifest to output directory.
    Returns True on success, False on failure.
    """
    
    # Create output directory
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    
    # Load manifest
    try:
        with open(manifest_path, 'r') as f:
            manifest = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"ERROR: Manifest not found: {manifest_path}", file=sys.stderr)
        return False
    except yaml.YAMLError as e:
        print(f"ERROR: Failed to parse manifest: {e}", file=sys.stderr)
        return False
    
    if not manifest:
        print("WARNING: Manifest is empty or malformed", file=sys.stderr)
        manifest = {}
    
    mods = manifest.get('mods', [])
    
    if not mods:
        print("No mods to resolve.", file=sys.stderr)
        return True
    
    failed = False
    
    for mod in mods:
        slug = mod.get('slug', 'unknown')
        source = mod.get('source', 'modrinth')
        
        if source == 'modrinth':
            version_id = mod.get('version_id')
            
            if not version_id:
                print(f"ERROR: Modrinth mod '{slug}' missing version_id", file=sys.stderr)
                failed = True
                continue
            
            # Download from Modrinth
            temp_path = os.path.join(output_dir, f"{slug}.jar.tmp")
            filename = download_modrinth_mod(
                slug,
                version_id,
                temp_path
            )
            
            if not filename:
                failed = True
                continue
            
            # Move to final location
            final_path = os.path.join(output_dir, filename)
            shutil.move(temp_path, final_path)
            print(f"✓ Resolved {slug} → {filename}", file=sys.stderr)
        
        elif source == 'vendored':
            vendored_path = mod.get('path')
            
            if not vendored_path:
                print(f"ERROR: Vendored mod '{slug}' missing path", file=sys.stderr)
                failed = True
                continue
            
            # Resolve path relative to server/vendored-mods/
            source_path = os.path.join('server', 'vendored-mods', vendored_path)
            
            if not os.path.exists(source_path):
                print(f"ERROR: Vendored mod not found: {source_path}", file=sys.stderr)
                failed = True
                continue
            
            # Copy to output
            dest_path = os.path.join(output_dir, os.path.basename(vendored_path))
            shutil.copy2(source_path, dest_path)
            print(f"✓ Copied vendored mod {slug} → {os.path.basename(vendored_path)}", file=sys.stderr)
        
        else:
            print(f"ERROR: Unknown source '{source}' for mod '{slug}'", file=sys.stderr)
            failed = True
    
    return not failed


def main():
    parser = argparse.ArgumentParser(
        description="Resolve Fabric server mods from manifest to build output."
    )
    parser.add_argument(
        '--manifest',
        default='mods/manifest.yaml',
        help='Path to mods/manifest.yaml (default: mods/manifest.yaml)'
    )
    parser.add_argument(
        '--out',
        default='build/mods',
        help='Output directory for resolved mods (default: build/mods)'
    )
    parser.add_argument(
        '--check',
        action='store_true',
        help='Dry run: validate manifest entries against Modrinth API and vendored paths without downloading.'
    )

    args = parser.parse_args()

    if args.check:
        success = check_mods(args.manifest)
    else:
        success = resolve_mods(args.manifest, args.out)
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
