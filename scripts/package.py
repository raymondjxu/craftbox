#!/usr/bin/env python3
"""Bundle resolved mods + config + datapacks + server.properties into craftbox-pack.tar.gz."""

import argparse
import tarfile
from pathlib import Path


def package(mods_dir, config_dir, datapacks_dir, server_properties, output):
    with tarfile.open(output, "w:gz") as tar:
        mods = Path(mods_dir)
        for jar in sorted(mods.glob("*.jar")):
            tar.add(jar, arcname=f"mods/{jar.name}")

        config = Path(config_dir)
        if config.exists():
            for f in sorted(config.rglob("*")):
                if f.is_file() and f.name != ".gitkeep":
                    tar.add(f, arcname=f"config/{f.relative_to(config)}")

        datapacks = Path(datapacks_dir)
        if datapacks.exists():
            for f in sorted(datapacks.rglob("*")):
                if f.is_file() and f.name != ".gitkeep":
                    tar.add(f, arcname=f"datapacks/{f.relative_to(datapacks)}")

        sp = Path(server_properties)
        if sp.exists():
            tar.add(sp, arcname="server.properties")


def main():
    parser = argparse.ArgumentParser(description="Package craftbox server pack into a tarball.")
    parser.add_argument("--mods", default="build/mods", help="Resolved mods directory")
    parser.add_argument("--config", default="config", help="Mod config directory")
    parser.add_argument("--datapacks", default="datapacks", help="Datapacks directory")
    parser.add_argument("--server-properties", default="server.properties", help="Starter server.properties")
    parser.add_argument("--out", default="craftbox-pack.tar.gz", help="Output tarball path")
    args = parser.parse_args()

    package(args.mods, args.config, args.datapacks, args.server_properties, args.out)
    print(f"Created {args.out}")


if __name__ == "__main__":
    main()
