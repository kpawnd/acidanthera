#!/usr/bin/env python3
"""
Version parsing and comparison utilities.
"""
import re
import sys


def normalize_version(raw_version: str) -> str:
    """
    Normalize version string for comparison.
    Removes commas, spaces, and other formatting.
    
    Args:
        raw_version: Raw version string (e.g., "2025.3, (build 123)")
        
    Returns:
        Normalized version string
    """
    if not raw_version:
        return ""
    
    # Remove everything after first comma
    normalized = raw_version.split(",")[0]
    # Remove whitespace
    normalized = normalized.replace(" ", "")
    return normalized


def versions_match_exact(installed: str, supported: str) -> bool:
    """
    Check if versions match exactly (after normalization).
    
    Args:
        installed: Installed version string
        supported: Supported version string
        
    Returns:
        True if versions match
    """
    if not installed or not supported or supported == "unknown":
        return False
    
    norm_installed = normalize_version(installed)
    norm_supported = normalize_version(supported)
    
    return norm_installed == norm_supported


def versions_match_compatible(installed: str, supported: str) -> bool:
    """
    Check if versions are compatible (allows prefix matching).
    E.g., 2025.3 is compatible with 2025.3.3.7
    
    Args:
        installed: Installed version string
        supported: Supported version string
        
    Returns:
        True if versions are compatible
    """
    if versions_match_exact(installed, supported):
        return True
    
    if not installed or not supported or supported == "unknown":
        return False
    
    norm_installed = normalize_version(installed)
    norm_supported = normalize_version(supported)
    
    # Check if one is a prefix of the other
    if norm_supported.startswith(norm_installed + ".") or norm_installed.startswith(norm_supported + "."):
        return True
    
    return False


def extract_version_from_url(url: str) -> str:
    """
    Extract version number from URL.
    Tries multiple patterns to find version-like strings.
    
    Args:
        url: URL string to search
        
    Returns:
        Version string or "unknown"
    """
    if not url:
        return "unknown"
    
    patterns = [
        r"([0-9]+(?:\.[0-9]+)+)",  # Standard dotted version (1.2.3, 2025.3.1)
        r"[_-]([0-9]{3,})[_-]",    # Underscored version (Build_810_ or 900)
    ]
    
    for pattern in patterns:
        match = re.search(pattern, url)
        if match:
            return match.group(1)
    
    return "unknown"


def normalize_packet_tracer_version(raw_version: str) -> str:
    """
    Normalize Cisco Packet Tracer version from build numbers.
    E.g., "900" -> "9.0.0", "9000" -> "9.0.0", "Build810" -> "8.1.0"
    
    Args:
        raw_version: Raw version string
        
    Returns:
        Normalized version string
    """
    if not raw_version or raw_version == "unknown":
        return "unknown"
    
    # Extract digits only
    digits = re.sub(r"[^0-9]", "", raw_version)
    
    if len(digits) == 3:
        # 900 -> 9.0.0
        return f"{digits[0]}.{digits[1]}.{digits[2]}"
    elif len(digits) == 4:
        # 9000 -> 9.0.00, but normalize to 9.0.0
        version = f"{digits[0]}.{digits[1]}.{digits[2:4]}"
        return version
    
    return raw_version


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: version_utils.py <command> [args...]", file=sys.stderr)
        sys.exit(1)
    
    command = sys.argv[1]
    
    if command == "normalize":
        if len(sys.argv) < 3:
            print("", file=sys.stderr)
            sys.exit(1)
        print(normalize_version(sys.argv[2]))
    
    elif command == "match-exact":
        if len(sys.argv) < 4:
            sys.exit(1)
        result = versions_match_exact(sys.argv[2], sys.argv[3])
        sys.exit(0 if result else 1)
    
    elif command == "match-compatible":
        if len(sys.argv) < 4:
            sys.exit(1)
        result = versions_match_compatible(sys.argv[2], sys.argv[3])
        sys.exit(0 if result else 1)
    
    elif command == "extract-version":
        if len(sys.argv) < 3:
            print("unknown")
            sys.exit(0)
        print(extract_version_from_url(sys.argv[2]))
    
    elif command == "normalize-pt":
        if len(sys.argv) < 3:
            print("unknown")
            sys.exit(0)
        print(normalize_packet_tracer_version(sys.argv[2]))
    
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)
