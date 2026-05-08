#!/usr/bin/env python3
"""
CI verification script for Fabric Minecraft server.
Boots the server image, verifies it starts and responds to mcstatus queries.
Optionally tests volume persistence by rebooting with the same volume.
"""

import argparse
import subprocess
import sys
import time
import os

try:
    import mcstatus
except ImportError:
    print("ERROR: mcstatus not found. Install with: pip install mcstatus", file=sys.stderr)
    sys.exit(1)


def run_command(cmd, check=True, capture_output=False):
    """Run a shell command and return result."""
    kwargs = {'check': check}
    if capture_output:
        kwargs['capture_output'] = True
        kwargs['text'] = True
    result = subprocess.run(cmd, shell=True, **kwargs)
    return result


def tail_docker_logs(container_id, lines=50):
    """Print last N lines of container logs."""
    print("\n--- Container logs (last 50 lines) ---", file=sys.stderr)
    run_command(f"docker logs --tail {lines} {container_id}", check=False)
    print("--- End logs ---\n", file=sys.stderr)


def verify_server(image, host='127.0.0.1', port=25565, timeout=240, test_persistence=False):
    """
    Boot server image and verify it responds to mcstatus.
    
    Args:
        image: Docker image to boot
        host: Host address to connect to (default: 127.0.0.1)
        port: Server port (default: 25565)
        timeout: Max seconds to wait for server to start (default: 240)
        test_persistence: If True, reboot server with same volume to verify data persists
    
    Returns:
        True on success, False on failure
    """
    
    volume_name = f"verify_{int(time.time())}"
    container_id = None
    
    try:
        print(f"Starting verification of image {image}...", file=sys.stderr)
        
        # Launch server in container
        print(f"Launching container with volume {volume_name}...", file=sys.stderr)
        cmd = (
            f"docker run -d "
            f"--name verify_server_{int(time.time())} "
            f"-e ACCEPT_EULA=true "
            f"-p {port}:25565 "
            f"-v {volume_name}:/opt/minecraft/data "
            f"{image}"
        )
        result = run_command(cmd, capture_output=True)
        
        if result.returncode != 0:
            print(f"ERROR: Failed to start container: {result.stderr}", file=sys.stderr)
            return False
        
        container_id = result.stdout.strip()
        print(f"Container started: {container_id}", file=sys.stderr)
        
        # Wait for server to respond to mcstatus
        print(f"Waiting for server to respond (timeout: {timeout}s)...", file=sys.stderr)
        server = mcstatus.JavaServer.lookup(f"{host}:{port}")
        
        start_time = time.time()
        server_ready = False
        last_error = None
        
        while time.time() - start_time < timeout:
            try:
                status = server.status()
                print(
                    f"✓ Server is up! Version: {status.version.name}, "
                    f"Players: {status.players.online}/{status.players.max}",
                    file=sys.stderr
                )
                
                # Verify Fabric presence in version string
                if 'Fabric' not in status.version.name:
                    print(
                        f"WARNING: 'Fabric' not found in version string: {status.version.name}",
                        file=sys.stderr
                    )
                
                server_ready = True
                break
            
            except Exception as e:
                last_error = str(e)
                elapsed = time.time() - start_time
                print(
                    f"[{elapsed:.1f}s] Waiting... (error: {type(e).__name__})",
                    file=sys.stderr
                )
                time.sleep(5)
        
        if not server_ready:
            print(
                f"ERROR: Server did not respond within {timeout} seconds. Last error: {last_error}",
                file=sys.stderr
            )
            tail_docker_logs(container_id)
            return False
        
        # Stop and remove container for potential second run
        print(f"Stopping container {container_id}...", file=sys.stderr)
        run_command(f"docker stop {container_id}", check=False)
        run_command(f"docker rm {container_id}", check=False)
        container_id = None
        
        # Test persistence if requested
        if test_persistence:
            print("\n--- Testing volume persistence ---", file=sys.stderr)
            print(f"Rebooting server with same volume {volume_name}...", file=sys.stderr)
            
            cmd = (
                f"docker run -d "
                f"--name verify_server_reboot_{int(time.time())} "
                f"-e ACCEPT_EULA=true "
                f"-p {port}:25565 "
                f"-v {volume_name}:/opt/minecraft/data "
                f"{image}"
            )
            result = run_command(cmd, capture_output=True)
            
            if result.returncode != 0:
                print(f"ERROR: Failed to reboot container: {result.stderr}", file=sys.stderr)
                return False
            
            container_id = result.stdout.strip()
            print(f"Rebooted container: {container_id}", file=sys.stderr)
            
            # Wait for server again
            print(f"Waiting for rebooted server to respond (timeout: {timeout}s)...", file=sys.stderr)
            start_time = time.time()
            server_ready = False
            
            while time.time() - start_time < timeout:
                try:
                    status = server.status()
                    print(
                        f"✓ Rebooted server is up! Version: {status.version.name}, "
                        f"Players: {status.players.online}/{status.players.max}",
                        file=sys.stderr
                    )
                    server_ready = True
                    break
                except Exception as e:
                    elapsed = time.time() - start_time
                    print(f"[{elapsed:.1f}s] Waiting for reboot... (error: {type(e).__name__})", file=sys.stderr)
                    time.sleep(5)
            
            if not server_ready:
                print(
                    f"ERROR: Rebooted server did not respond within {timeout} seconds.",
                    file=sys.stderr
                )
                tail_docker_logs(container_id)
                return False
            
            print("✓ Volume persistence verified.", file=sys.stderr)
        
        print("\n✓ All verification checks passed!", file=sys.stderr)
        return True
    
    finally:
        # Cleanup
        if container_id:
            print(f"Cleaning up container {container_id}...", file=sys.stderr)
            run_command(f"docker stop {container_id}", check=False)
            run_command(f"docker rm {container_id}", check=False)
        
        print(f"Cleaning up volume {volume_name}...", file=sys.stderr)
        run_command(f"docker volume rm {volume_name}", check=False)


def main():
    parser = argparse.ArgumentParser(
        description="Verify Fabric Minecraft server image boots and responds to mcstatus."
    )
    parser.add_argument(
        'image',
        help='Docker image to verify (e.g., ghcr.io/owner/craftbox:latest)'
    )
    parser.add_argument(
        '--host',
        default='127.0.0.1',
        help='Host address for mcstatus connection (default: 127.0.0.1)'
    )
    parser.add_argument(
        '--port',
        type=int,
        default=25565,
        help='Server port (default: 25565)'
    )
    parser.add_argument(
        '--timeout',
        type=int,
        default=240,
        help='Timeout in seconds (default: 240)'
    )
    parser.add_argument(
        '--test-persistence',
        action='store_true',
        help='Test volume persistence by rebooting with the same volume'
    )
    
    args = parser.parse_args()
    
    success = verify_server(
        args.image,
        host=args.host,
        port=args.port,
        timeout=args.timeout,
        test_persistence=args.test_persistence
    )
    
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
