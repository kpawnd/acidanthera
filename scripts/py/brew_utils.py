#!/usr/bin/env python3
"""
Homebrew metadata parsing utilities.
"""
import json
import sys


def extract_brew_cask_version(json_str: str) -> str:
    """
    Extract version from Homebrew cask info JSON.
    
    Args:
        json_str: Homebrew info --cask --json=v2 output
        
    Returns:
        Version string or "unknown"
    """
    try:
        data = json.loads(json_str)
        casks = data.get("casks", [])
        if not casks:
            return "unknown"
        return casks[0].get("version", "unknown")
    except Exception:
        return "unknown"


def extract_brew_cask_url(json_str: str) -> str:
    """
    Extract download URL from Homebrew cask info JSON.
    
    Args:
        json_str: Homebrew info --cask --json=v2 output
        
    Returns:
        URL string or empty string
    """
    try:
        data = json.loads(json_str)
        casks = data.get("casks", [])
        if not casks:
            return ""
        url = casks[0].get("url", "")
        # Reject URLs with uninterpolated Ruby templates
        if url and "#{" not in url:
            return url
        return ""
    except Exception:
        return ""


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: brew_utils.py <command> [json_input]", file=sys.stderr)
        sys.exit(1)
    
    command = sys.argv[1]
    
    if command == "cask-version":
        json_input = sys.stdin.read() if not sys.isatty(0) else ""
        print(extract_brew_cask_version(json_input))
    
    elif command == "cask-url":
        json_input = sys.stdin.read() if not sys.isatty(0) else ""
        print(extract_brew_cask_url(json_input))
    
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)
