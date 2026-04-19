#!/bin/bash

PY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/py"

# Check if installation should be skipped based on version matching
should_skip_direct_install() {
    local app_path="$1"
    local display_name="$2"
    local supported_ver="$3"
    local installed_ver=""

    if [[ ! -d "$app_path" ]]; then
        return 1
    fi

    installed_ver="$(get_app_version "$app_path")"

    if [[ -z "$supported_ver" || "$supported_ver" == "unknown" ]]; then
        print_info "$display_name installed. Version: $installed_ver"
        print_ok "$display_name already installed. Skipping reinstall."
        return 0
    fi

    print_info "$display_name supported version for this macOS: $supported_ver"

    if versions_match_compatible "$installed_ver" "$supported_ver"; then
        print_ok "$display_name already at latest supported version ($installed_ver). Skipping reinstall."
        return 0
    fi

    print_info "$display_name installed version ($installed_ver) differs from supported ($supported_ver). Reinstalling."
    return 1
}

# Check if versions match exactly
versions_match_latest() {
    local installed_ver="$1"
    local supported_ver="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" match-exact "$installed_ver" "$supported_ver" >/dev/null 2>&1
        return $?
    fi

    return 1
}

# Check if versions are compatible (allows prefix matching)
versions_match_compatible() {
    local installed_ver="$1"
    local supported_ver="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" match-compatible "$installed_ver" "$supported_ver" >/dev/null 2>&1
        return $?
    fi

    return 1
}

# Extract version from URL
extract_version_from_url() {
    local url="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" extract-version "$url"
        return 0
    fi

    echo "unknown"
    return 0
}

# Normalize Packet Tracer version from build numbers
normalize_packet_tracer_version() {
    local raw="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" normalize-pt "$raw"
        return 0
    fi

    echo "$raw"
    return 0
}

# Download file with resilience (retries with exponential backoff)
download_file_resilient() {
    local url="$1"
    local out_file="$2"
    local attempt=1
    local max_attempts=6

    while [[ "$attempt" -le "$max_attempts" ]]; do
        print_info "Downloading $(basename "$out_file") (attempt $attempt/$max_attempts)"
        if download_file_optimized "$url" "$out_file"; then
            return 0
        fi

        if [[ "$attempt" -lt "$max_attempts" ]]; then
            print_warn "Download attempt failed for $(basename "$out_file"). Retrying..."
            sleep $((attempt * 2))
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

# Optimized download using aria2c if available, otherwise curl
download_file_optimized() {
    local url="$1"
    local out_file="$2"

    if command -v aria2c >/dev/null 2>&1; then
        aria2c \
            --quiet=true \
            --console-log-level=error \
            --file-allocation=none \
            --max-connection-per-server=8 \
            --split=8 \
            --continue=true \
            --retry-wait=3 \
            --max-tries=8 \
            --summary-interval=0 \
            --download-result=hide \
            -o "$(basename "$out_file")" \
            -d "$(dirname "$out_file")" \
            "$url"
        return $?
    fi

    curl \
        --fail \
        --location \
        --retry 8 \
        --retry-all-errors \
        --retry-delay 2 \
        --connect-timeout 15 \
        --continue-at - \
        --silent \
        --show-error \
        "$url" \
        --output "$out_file"
}

# Get file size from URL via HEAD request
get_remote_file_size() {
    local url="$1"
    local content_length=""
    
    content_length="$(curl -fsI -L "$url" 2>/dev/null | grep -i "content-length:" | tail -1 | awk '{print $2}' | tr -d '\r')"
    if [[ -n "$content_length" && "$content_length" =~ ^[0-9]+$ ]]; then
        echo "$content_length"
        return 0
    fi
    
    echo "0"
    return 1
}

# Monitor download progress in background with ETA
monitor_download_progress() {
    local file_path="$1"
    local stage_file="$2"
    local app_name="$3"
    local total_size="$4"
    local start_time
    local last_size=0
    local current_size=0
    local last_time=0
    local current_time=0
    local elapsed=0
    local speed_bps=0
    local speed_display=""
    local size_mb=0
    local total_mb=0
    local percent=0
    local remaining_bytes=0
    local eta_seconds=0
    local eta_display=""
    local no_growth_count=0

    start_time=$(date +%s)
    last_time=$start_time

    while true; do
        if [[ ! -f "$file_path" ]]; then
            sleep 0.5
            continue
        fi

        current_size=$(stat -f%z "$file_path" 2>/dev/null || echo 0)
        current_time=$(date +%s)
        elapsed=$((current_time - last_time))

        if [[ $elapsed -ge 2 ]]; then
            if [[ $current_size -eq $last_size ]]; then
                no_growth_count=$((no_growth_count + 1))
                if [[ $no_growth_count -ge 3 ]]; then
                    break
                fi
            else
                no_growth_count=0
                speed_bps=$(( (current_size - last_size) / elapsed ))
                size_mb=$(( current_size / 1048576 ))

                # Calculate speed display
                if [[ $speed_bps -ge 1048576 ]]; then
                    speed_display="$((speed_bps / 1048576))MB/s"
                else
                    speed_display="$((speed_bps / 1024))KB/s"
                fi

                # Calculate ETA if total size is known
                eta_display=""
                if [[ -n "$total_size" && "$total_size" != "0" && $total_size -gt 0 && $speed_bps -gt 0 ]]; then
                    percent=$(( (current_size * 100) / total_size ))
                    remaining_bytes=$(( total_size - current_size ))
                    if [[ $remaining_bytes -gt 0 ]]; then
                        eta_seconds=$(( remaining_bytes / speed_bps ))
                        
                        if [[ $eta_seconds -gt 3600 ]]; then
                            local eta_h=$(( eta_seconds / 3600 ))
                            local eta_m=$(( (eta_seconds % 3600) / 60 ))
                            eta_display=" - ${percent}% | ETA ${eta_h}h ${eta_m}m"
                        elif [[ $eta_seconds -gt 60 ]]; then
                            local eta_m=$(( eta_seconds / 60 ))
                            local eta_s=$(( eta_seconds % 60 ))
                            eta_display=" - ${percent}% | ETA ${eta_m}m ${eta_s}s"
                        else
                            eta_display=" - ${percent}% | ETA ${eta_seconds}s"
                        fi
                    fi
                fi

                echo "Downloading ${app_name} - ${size_mb}MB @ ${speed_display}${eta_display}" > "$stage_file" 2>/dev/null || true
            fi

            last_size=$current_size
            last_time=$current_time
        fi

        sleep 1
    done
}

# Check if an app bundle is an installer bundle
is_packet_tracer_installer_bundle() {
    local app_path="$1"
    local name_lc=""
    local plist="$app_path/Contents/Info.plist"
    local bundle_id=""

    [[ -d "$app_path" ]] || return 1

    name_lc="$(basename "$app_path" | tr '[:upper:]' '[:lower:]')"
    if [[ "$name_lc" == *installer* || "$name_lc" == *setup* ]]; then
        return 0
    fi

    if [[ -x "$app_path/Contents/MacOS/installbuilder.sh" || -f "$app_path/Contents/Resources/installbuilder.sh" ]]; then
        return 0
    fi

    if [[ -f "$plist" ]]; then
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
        bundle_id="$(printf '%s' "$bundle_id" | tr '[:upper:]' '[:lower:]')"
        if [[ "$bundle_id" == *installbuilder* || "$bundle_id" == *installer* ]]; then
            return 0
        fi
    fi

    return 1
}

# Find installed Packet Tracer app (excluding installer bundles)
find_installed_packet_tracer_app() {
    local candidate=""

    # First try direct match in /Applications
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if is_packet_tracer_installer_bundle "$candidate"; then
            continue
        fi
        echo "$candidate"
        return 0
    done < <(find /Applications -maxdepth 1 -type d -name '*Packet*Tracer*.app' 2>/dev/null)

    # If not found, search recursively for nested app bundles
    # (e.g., /Applications/Cisco Packet Tracer 9.0.0/PacketTracer.app)
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if is_packet_tracer_installer_bundle "$candidate"; then
            continue
        fi
        echo "$candidate"
        return 0
    done < <(find /Applications -maxdepth 3 -type d -name '*Packet*Tracer*.app' 2>/dev/null | grep -v '/Contents/' | head -5)

    echo ""
    return 1
}

# Run Packet Tracer installer unattended
run_packet_tracer_installer_unattended() {
    local app_path="$1"
    local install_log="$2"
    local mount_point="$3"
    local app_name=""
    local installer_exec=""
    local version=""
    local install_dir=""

    app_name="$(basename "$app_path" .app)"
    version="$(printf '%s' "$app_name" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    if [[ -z "$version" ]]; then
        version="9.0.0"
    fi

    install_dir="/Applications/Cisco Packet Tracer $version"
    mkdir -p "$install_dir" || true

    if [[ -x "$app_path/Contents/MacOS/$app_name" ]]; then
        installer_exec="$app_path/Contents/MacOS/$app_name"
    else
        installer_exec="$(find "$app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 2>/dev/null | head -n 1)"
    fi

    if [[ -z "$installer_exec" ]]; then
        echo "No executable installer binary found in $app_path/Contents/MacOS" >"$install_log"
        return 1
    fi

    if sudo -n "$installer_exec" install \
        --root "$install_dir" \
        --accept-licenses \
        --accept-messages \
        --confirm-command >"$install_log" 2>&1; then
        return 0
    fi

    if sudo "$installer_exec" install \
        --root "$install_dir" \
        --accept-licenses \
        --accept-messages \
        --confirm-command >>"$install_log" 2>&1; then
        return 0
    fi

    if sudo -n "$installer_exec" install --root "$install_dir" >>"$install_log" 2>&1; then
        return 0
    fi

    if sudo "$installer_exec" install --root "$install_dir" >>"$install_log" 2>&1; then
        return 0
    fi

    return 1
}

# Resolve Homebrew cask download locks
resolve_brew_download_locks_for_token() {
    local token="$1"
    local lock_dir="${HOME}/Library/Caches/Homebrew/downloads"
    local lockfile
    local holders
    local elapsed
    local wait_limit=45

    if [[ ! -d "$lock_dir" ]]; then
        return 0
    fi

    while IFS= read -r lockfile; do
        [[ -z "$lockfile" ]] && continue
        print_warn "Detected cask lock for $token: $(basename "$lockfile")"

        holders="$(lsof -t "$lockfile" 2>/dev/null | tr '\n' ' ')"
        if [[ -z "$holders" ]]; then
            rm -f "$lockfile" >/dev/null 2>&1 || true
            continue
        fi

        print_info "Lock held by process(es): $holders"
        elapsed=0
        while [[ "$elapsed" -lt "$wait_limit" ]]; do
            sleep 3
            elapsed=$((elapsed + 3))
            holders="$(lsof -t "$lockfile" 2>/dev/null | tr '\n' ' ')"
            [[ -z "$holders" ]] && break
        done

        holders="$(lsof -t "$lockfile" 2>/dev/null | tr '\n' ' ')"
        if [[ -n "$holders" ]]; then
            print_warn "Lock still active after wait. Terminating holder process(es): $holders"
            kill $holders >/dev/null 2>&1 || true
            sleep 2
            holders="$(lsof -t "$lockfile" 2>/dev/null | tr '\n' ' ')"
            if [[ -n "$holders" ]]; then
                kill -9 $holders >/dev/null 2>&1 || true
            fi
        fi

        rm -f "$lockfile" >/dev/null 2>&1 || true
    done < <(find "$lock_dir" -maxdepth 1 -type f -name "*${token}*.incomplete" 2>/dev/null)

    return 0
}

# Record cask lock metadata
record_cask_lock() {
    local token="$1"
    local app_path="$2"
    local lock_dir="$HOME/.labstate/cask-locks"
    local lock_file="$lock_dir/$token.lock"
    local macos_ver
    local installed_ver
    local brew_ver

    macos_ver="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    installed_ver="$(get_app_version "$app_path")"
    brew_ver="$(get_brew_cask_version "$token")"

    mkdir -p "$lock_dir" || return 1
    cat > "$lock_file" <<EOF
token=$token
macos=$macos_ver
installed_app_version=$installed_ver
brew_cask_version=$brew_ver
locked_at=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    print_info "Locked $token to current supported release metadata: $lock_file"
    return 0
}

# Get Homebrew cask version
get_brew_cask_version() {
    local token="$1"
    local json

    json="$(brew_cmd info --cask --json=v2 "$token" 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
        echo "unknown"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo "$json" | python3 "$PY_LIB_DIR/brew_utils.py" cask-version
    else
        echo "unknown"
    fi
}

# Install or update a Homebrew cask
reinstall_cask_app() {
    local token="$1"
    local app_path="$2"
    local display_name="$3"
    local stage_file="${4:-}"
    local supported_ver="unknown"
    local installed_ver=""
    local attempt=1
    local max_attempts=3

    # Initialize stage file with default value
    if [[ -n "$stage_file" ]]; then
        echo "Checking app" > "$stage_file"
    fi

    if ! brew_is_healthy; then
        print_warn "Homebrew unavailable; cannot install $display_name."
        return 1
    fi

    # Fast path: Check if app is already installed locally FIRST
    if [[ -d "$app_path" ]]; then
        echo "Checking installed version" > "$stage_file" 2>/dev/null || true
        installed_ver="$(get_app_version "$app_path")"
        if [[ -n "$installed_ver" && "$installed_ver" != "unknown" ]]; then
            echo "Checking supported version" > "$stage_file" 2>/dev/null || true
            supported_ver="$(get_brew_cask_version "$token")"
            if [[ "$supported_ver" != "unknown" ]] && versions_match_latest "$installed_ver" "$supported_ver"; then
                print_ok "$display_name already at latest supported version ($installed_ver). Skipping reinstall."
                record_cask_lock "$token" "$app_path" || true
                return 0
            fi
        fi
    fi

    # Slow path: App not found or version mismatch, need to install
    # Only fetch supported version again if we haven't already
    if [[ "$supported_ver" == "unknown" ]]; then
        echo "Checking supported version" > "$stage_file" 2>/dev/null || true
        supported_ver="$(get_brew_cask_version "$token")"
    fi
    
    if [[ "$supported_ver" == "unknown" ]]; then
        print_warn "$display_name cask metadata is unavailable for this Homebrew/macOS state."
    fi
    print_info "$display_name supported cask version for this macOS: $supported_ver"

    echo "Removing old version" > "$stage_file" 2>/dev/null || true
    print_info "Removing old $display_name version (if present)..."
    brew_cmd uninstall --cask --force "$token" >/dev/null 2>&1 || true
    if [[ -d "$app_path" ]]; then
        # Retry sudo with -n flag if keepalive is active
        if ! sudo -n rm -rf "$app_path" 2>/dev/null; then
            # Fall back to non-n flag if keepalive expired
            if ! sudo rm -rf "$app_path" 2>/dev/null; then
                print_warn "Could not remove old app bundle: $app_path"
            fi
        fi
    fi

    while [[ "$attempt" -le "$max_attempts" ]]; do
        resolve_brew_download_locks_for_token "$token" || true
        echo "Installing ($attempt/$max_attempts)" > "$stage_file" 2>/dev/null || true
        print_info "Installing latest supported $display_name... (attempt $attempt/$max_attempts)"
        if HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install --cask "$token" >/dev/null 2>&1; then
            break
        fi

        if [[ "$attempt" -lt "$max_attempts" ]]; then
            echo "Repairing Homebrew" > "$stage_file" 2>/dev/null || true
            print_warn "Install attempt failed for $display_name. Repairing Homebrew and retrying once."
            resolve_brew_download_locks_for_token "$token" || true
            repair_homebrew_environment || true
            brew_cmd update --force --quiet >/dev/null 2>&1 || true
        fi

        attempt=$((attempt + 1))
    done

    if [[ "$attempt" -gt "$max_attempts" ]]; then
        print_warn "Failed to install $display_name via cask $token after retries."
        return 1
    fi

    echo "Verifying installation" > "$stage_file" 2>/dev/null || true
    if [[ -d "$app_path" ]]; then
        print_ok "$display_name installed. Version: $(get_app_version "$app_path")"
    else
        print_warn "$display_name install command completed but app bundle not found at $app_path"
    fi

    record_cask_lock "$token" "$app_path" || true
    return 0
}

# Verify all required software is installed
verify_required_software_present() {
    local had_error=0
    local blender_app="/Applications/Blender.app"
    local android_app="/Applications/Android Studio.app"
    local azure_app="/Applications/Azure Data Studio.app"
    local packet_tracer_app=""

    if [[ -d "$blender_app" ]]; then
        print_ok "Verified Blender installation."
    else
        print_warn "Blender is not installed at expected path: $blender_app"
        had_error=1
    fi

    if [[ -d "$android_app" ]]; then
        print_ok "Verified Android Studio installation."
    else
        print_warn "Android Studio is not installed at expected path: $android_app"
        had_error=1
    fi

    if [[ -d "$azure_app" ]]; then
        print_ok "Verified Azure Data Studio installation."
    else
        print_warn "Azure Data Studio is not installed at expected path: $azure_app"
        had_error=1
    fi

    packet_tracer_app="$(find_installed_packet_tracer_app)"
    if [[ -n "$packet_tracer_app" ]]; then
        print_ok "Verified Cisco Packet Tracer installation: $packet_tracer_app"
    else
        print_warn "Cisco Packet Tracer app bundle was not found in /Applications."
        had_error=1
    fi

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    return 0
}
