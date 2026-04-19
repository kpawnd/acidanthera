#!/usr/bin/env python3
"""
GitHub API utilities for release and asset queries.
"""
import json
import sys


def find_azure_data_studio_asset(json_str: str) -> str:
    """
    Find Azure Data Studio .zip asset URL from GitHub release JSON.
    
    Args:
        json_str: GitHub API releases/tags/Azure response
        
    Returns:
        Asset download URL or empty string
    """
    try:
        data = json.loads(json_str)
        assets = data.get("assets", [])
        for asset in assets:
            url = asset.get("browser_download_url", "")
            if url and "azuredatastudio-macos-" in url and url.endswith(".zip"):
                return url
        return ""
    except Exception:
        return ""


def find_packet_tracer_asset(json_str: str) -> str:
    """
    Find Cisco Packet Tracer .dmg asset URL from GitHub release JSON.
    Prefers assets with "packet" and "tracer" in the name.
    
    Args:
        json_str: GitHub API releases/tags/Cisco response
        
    Returns:
        Asset download URL or empty string
    """
    try:
        data = json.loads(json_str)
        assets = data.get("assets", [])
        
        urls = [a.get("browser_download_url", "") for a in assets]
        urls = [u for u in urls if u.lower().endswith(".dmg")]
        
        # Prefer packet tracer specific assets
        preferred = [u for u in urls if "packet" in u.lower() and "tracer" in u.lower()]
        if preferred:
            return preferred[0]
        
        # Fall back to any .dmg
        if urls:
            return urls[0]
        
        return ""
    except Exception:
        return ""


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: github_utils.py <command> [json_input]", file=sys.stderr)
        sys.exit(1)
    
    command = sys.argv[1]
    
    if command == "azure-asset":
        json_input = sys.stdin.read() if not sys.isatty(0) else ""
        print(find_azure_data_studio_asset(json_input))
    
    elif command == "packet-tracer-asset":
        json_input = sys.stdin.read() if not sys.isatty(0) else ""
        print(find_packet_tracer_asset(json_input))
    
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)
