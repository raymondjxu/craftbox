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


def download_modrinth_mod(version_id, output_path):
    """
    Download a mod from Modrinth API.
    Returns the filename.
    """
    api_url = f"https://api.modrinth.com/v2/version/{version_id}"
    
    try:
        with urllib.request.urlopen(api_url, timeout=30) as response:
            data = json.loads(response.read().decode('utf-8'))
    except urllib.error.URLError as e:
        print(f"ERROR: Failed to fetch Modrinth version {version_id}: {e}", file=sys.stderr)
        return None, None
    
    # Find primary file (or largest file)
    if not data.get('files'):
        print(f"ERROR: No files in Modrinth version {version_id}", file=sys.stderr)
        return None, None
    
    primary_file = next(
        (f for f in data['files'] if f.get('primary')),
        data['files'][0]
    )
    
    download_url = primary_file['url']
    filename = primary_file['filename']
    
    try:
        print(f"Downloading {filename}...", file=sys.stderr)
        urllib.request.urlretrieve(download_url, output_path)
    except urllib.error.URLError as e:
        print(f"ERROR: Failed to download {filename}: {e}", file=sys.stderr)
        return None
    
    return filename


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
    
    args = parser.parse_args()
    
    success = resolve_mods(args.manifest, args.out)
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
