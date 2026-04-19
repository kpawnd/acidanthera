#!/bin/bash

#
# Shared utilities for macOS app installation
#

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
            --file-allocation=none \
            --max-connection-per-server=8 \
            --split=8 \
            --continue=true \
            --retry-wait=3 \
            --max-tries=8 \
            --summary-interval=1 \
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
        --progress-bar \
        "$url" \
        --output "$out_file"
}

# Monitor download progress in background
monitor_download_progress() {
    local file_path="$1"
    local stage_file="$2"
    local app_name="$3"
    local start_time
    local last_size=0
    local current_size=0
    local last_time=0
    local current_time=0
    local elapsed=0
    local speed_bps=0
    local speed_mbs=0
    local speed_kbs=0
    local size_mb=0
    local no_growth_count=0
    local speed_display=""

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

                if [[ $speed_bps -ge 1048576 ]]; then
                    speed_mbs=$(( speed_bps / 1048576 ))
                    speed_display="${speed_mbs}MB/s"
                else
                    speed_kbs=$(( speed_bps / 1024 ))
                    speed_display="${speed_kbs}KB/s"
                fi

                echo "Downloading ${app_name} - ${size_mb}MB @ ${speed_display}" > "$stage_file" 2>/dev/null || true
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

    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if is_packet_tracer_installer_bundle "$candidate"; then
            continue
        fi
        echo "$candidate"
        return 0
    done < <(find /Applications -maxdepth 1 -type d -name '*Packet*Tracer*.app' 2>/dev/null)

    echo ""
    return 1
}

# Run Packet Tracer installer unattended
run_packet_tracer_installer_unattended() {
    local app_path="$1"
    local install_log="$2"
    local mount_point="$3"
    local installer_bin=""
    local app_name=""
    local version=""
    local install_dir=""

    installer_bin="$(find "$app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 | head -n 1)"
    if [[ -z "$installer_bin" ]]; then
        return 1
    fi

    app_name="$(basename "$app_path" .app)"
    version="$(printf '%s' "$app_name" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    if [[ -z "$version" ]]; then
        version="9.0.0"
    fi

    install_dir="/Applications/Cisco Packet Tracer $version"
    mkdir -p "$install_dir" || true

    if sudo "$installer_bin" install \
        --root "$install_dir" \
        --accept-licenses \
        --accept-messages \
        --confirm-command >"$install_log" 2>&1; then
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
    local lock_dir="$HOME/.acidanthera/cask-locks"
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
    local supported_ver
    local installed_ver=""
    local attempt=1
    local max_attempts=3

    if ! brew_is_healthy; then
        print_warn "Homebrew unavailable; cannot install $display_name."
        return 1
    fi

    echo "Checking supported version" > "$stage_file" 2>/dev/null || true
    supported_ver="$(get_brew_cask_version "$token")"
    if [[ "$supported_ver" == "unknown" ]]; then
        print_warn "$display_name cask metadata is unavailable for this Homebrew/macOS state."
    fi
    print_info "$display_name supported cask version for this macOS: $supported_ver"

    if [[ -d "$app_path" ]]; then
        installed_ver="$(get_app_version "$app_path")"
        if versions_match_latest "$installed_ver" "$supported_ver"; then
            print_ok "$display_name already at latest supported version ($installed_ver). Skipping reinstall."
            record_cask_lock "$token" "$app_path" || true
            return 0
        fi
    fi

    echo "Removing old version" > "$stage_file" 2>/dev/null || true
    print_info "Removing old $display_name version (if present)..."
    brew_cmd uninstall --cask --force "$token" >/dev/null 2>&1 || true
    if [[ -d "$app_path" ]]; then
        if ! sudo rm -rf "$app_path"; then
            print_warn "Could not remove old app bundle: $app_path"
        fi
    fi

    while [[ "$attempt" -le "$max_attempts" ]]; do
        resolve_brew_download_locks_for_token "$token" || true
        echo "Installing ($attempt/$max_attempts)" > "$stage_file" 2>/dev/null || true
        print_info "Installing latest supported $display_name... (attempt $attempt/$max_attempts)"
        if HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install --cask "$token"; then
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
