#!/bin/bash

PY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/py"

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

versions_match_latest() {
    local installed_ver="$1"
    local supported_ver="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" match-exact "$installed_ver" "$supported_ver" >/dev/null 2>&1
        return $?
    fi

    return 1
}

versions_match_compatible() {
    local installed_ver="$1"
    local supported_ver="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" match-compatible "$installed_ver" "$supported_ver" >/dev/null 2>&1
        return $?
    fi

    return 1
}

extract_version_from_url() {
    local url="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" extract-version "$url"
        return 0
    fi

    echo "unknown"
    return 0
}

normalize_packet_tracer_version() {
    local raw="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$PY_LIB_DIR/version_utils.py" normalize-pt "$raw"
        return 0
    fi

    echo "$raw"
    return 0
}

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

get_azure_data_studio_supported_version() {
    local supported_ver="unknown"
    local download_url=""

    if brew_is_healthy; then
        supported_ver="$(get_brew_cask_version "azure-data-studio")"
        if [[ -n "$supported_ver" && "$supported_ver" != "unknown" ]]; then
            echo "$supported_ver"
            return 0
        fi
    fi

    download_url="$(resolve_azure_data_studio_url)"
    supported_ver="$(extract_version_from_url "$download_url")"
    echo "$supported_ver"
    return 0
}

get_packet_tracer_supported_version() {
    local dmg_url=""
    local version="unknown"

    dmg_url="$(resolve_packet_tracer_dmg_url)"
    version="$(extract_version_from_url "$dmg_url")"
    version="$(normalize_packet_tracer_version "$version")"
    echo "$version"
    return 0
}

resolve_reachable_url() {
    local candidate=""
    local final_url=""

    for candidate in "$@"; do
        [[ -z "$candidate" ]] && continue
        final_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' -L "$candidate" 2>/dev/null || true)"
        if [[ -n "$final_url" ]]; then
            echo "$final_url"
            return 0
        fi
    done

    echo ""
    return 1
}

is_supported_package_url() {
    local url="$1"
    local lower=""
    local path_only=""

    lower="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
    path_only="${lower%%\?*}"
    path_only="${path_only%%#*}"

    [[ "$path_only" == *.zip || "$path_only" == *.dmg ]]
}

resolve_reachable_package_url() {
    local candidate=""
    local final_url=""

    for candidate in "$@"; do
        [[ -z "$candidate" ]] && continue
        final_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' -L "$candidate" 2>/dev/null || true)"
        if [[ -n "$final_url" ]] && is_supported_package_url "$final_url"; then
            echo "$final_url"
            return 0
        fi
    done

    echo ""
    return 1
}

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

resolve_azure_data_studio_url() {
    local explicit_url="${AZURE_DATA_STUDIO_URL:-}"
    local json=""
    local zip_url=""

    if [[ -n "$explicit_url" ]]; then
        echo "$explicit_url"
        return 0
    fi

    json="$(curl -fsSL \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: acidanthera-installer' \
        'https://api.github.com/repos/kpawnd/acidanthera/releases/tags/Azure' 2>/dev/null || true)"

    if [[ -n "$json" ]] && command -v python3 >/dev/null 2>&1; then
        zip_url="$(echo "$json" | python3 "$PY_LIB_DIR/github_utils.py" azure-asset)"
        if [[ -n "$zip_url" ]]; then
            echo "$zip_url"
            return 0
        fi
    fi

    echo ""
    return 1
}

install_azure_data_studio_direct() {
    local download_url=""
    local target_app="/Applications/Azure Data Studio.app"
    local mount_point="/tmp/azure_data_studio_mount"
    local work_dir="/tmp/azure_data_studio_extract"
    local dmg_file="/tmp/azure_data_studio.dmg"
    local zip_file="/tmp/azure_data_studio.zip"
    local app_path=""
    local supported_ver="unknown"
    local stage_file="${1:-}"

    print_info "Installing Azure Data Studio..."

    supported_ver="$(get_azure_data_studio_supported_version)"
    if should_skip_direct_install "$target_app" "Azure Data Studio" "$supported_ver"; then
        return 0
    fi

    echo "Resolving download URL" > "$stage_file" 2>/dev/null || true
    download_url="$(resolve_azure_data_studio_url)"
    if [[ -z "$download_url" ]]; then
        print_warn "Could not resolve Azure Data Studio download URL."
        return 1
    fi

    sudo rm -rf "$target_app" >/dev/null 2>&1 || true

    if [[ "$download_url" == *.dmg ]]; then
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        echo "Downloading Azure Data Studio" > "$stage_file" 2>/dev/null || true
        monitor_download_progress "$dmg_file" "$stage_file" "Azure Data Studio" &
        local monitor_pid=$!
        if ! download_file_resilient "$download_url" "$dmg_file"; then
            kill $monitor_pid 2>/dev/null || true
            wait $monitor_pid 2>/dev/null || true
            print_warn "Azure Data Studio DMG download failed after retries."
            return 1
        fi
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true

        echo "Verifying download" > "$stage_file" 2>/dev/null || true
        if ! hdiutil verify "$dmg_file" >/dev/null 2>&1; then
            print_warn "Downloaded Azure Data Studio DMG failed integrity verification."
            return 1
        fi

        rm -rf "$mount_point" >/dev/null 2>&1 || true
        mkdir -p "$mount_point" || return 1

        echo "Mounting DMG" > "$stage_file" 2>/dev/null || true
        if ! hdiutil attach "$dmg_file" -quiet -nobrowse -mountpoint "$mount_point" >/dev/null 2>&1; then
            print_warn "Failed to mount Azure Data Studio DMG."
            rm -f "$dmg_file" >/dev/null 2>&1 || true
            return 1
        fi

        echo "Locating app bundle" > "$stage_file" 2>/dev/null || true
        app_path="$(find "$mount_point" -maxdepth 4 -type d -name 'Azure Data Studio.app' | head -n 1)"
        if [[ -z "$app_path" ]]; then
            app_path="$(find "$mount_point" -maxdepth 4 -type d -name '*.app' | head -n 1)"
        fi

        if [[ -z "$app_path" ]]; then
            print_warn "Azure Data Studio app bundle was not found in mounted DMG."
            hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
            rm -f "$dmg_file" >/dev/null 2>&1 || true
            return 1
        fi

        echo "Copying to /Applications" > "$stage_file" 2>/dev/null || true
        if ! sudo ditto "$app_path" "$target_app" >/dev/null 2>&1; then
            print_warn "Failed to copy Azure Data Studio to /Applications."
            hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
            rm -f "$dmg_file" >/dev/null 2>&1 || true
            return 1
        fi

        echo "Cleaning up" > "$stage_file" 2>/dev/null || true
        hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
        rm -f "$dmg_file" >/dev/null 2>&1 || true
    elif [[ "$download_url" == *.zip ]]; then
        rm -f "$zip_file" >/dev/null 2>&1 || true
        rm -rf "$work_dir" >/dev/null 2>&1 || true
        mkdir -p "$work_dir" || return 1

        echo "Downloading Azure Data Studio" > "$stage_file" 2>/dev/null || true
        monitor_download_progress "$zip_file" "$stage_file" "Azure Data Studio" &
        local monitor_pid=$!
        if ! download_file_resilient "$download_url" "$zip_file"; then
            kill $monitor_pid 2>/dev/null || true
            wait $monitor_pid 2>/dev/null || true
            print_warn "Azure Data Studio zip download failed after retries."
            return 1
        fi
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true

        echo "Extracting archive" > "$stage_file" 2>/dev/null || true
        if ! unzip -q "$zip_file" -d "$work_dir"; then
            print_warn "Failed to extract Azure Data Studio zip archive."
            rm -f "$zip_file" >/dev/null 2>&1 || true
            rm -rf "$work_dir" >/dev/null 2>&1 || true
            return 1
        fi

        echo "Locating app bundle" > "$stage_file" 2>/dev/null || true
        app_path="$(find "$work_dir" -maxdepth 2 -type d -name '*.app' | head -n 1)"

        if [[ -z "$app_path" ]]; then
            print_warn "Azure Data Studio app bundle was not found in extracted archive."
            rm -f "$zip_file" >/dev/null 2>&1 || true
            rm -rf "$work_dir" >/dev/null 2>&1 || true
            return 1
        fi

        echo "Copying to /Applications" > "$stage_file" 2>/dev/null || true
        if ! ditto "$app_path" "$target_app"; then
            print_warn "Failed to copy Azure Data Studio to /Applications."
            rm -f "$zip_file" >/dev/null 2>&1 || true
            rm -rf "$work_dir" >/dev/null 2>&1 || true
            return 1
        fi

        echo "Cleaning up" > "$stage_file" 2>/dev/null || true
        rm -f "$zip_file" >/dev/null 2>&1 || true
        rm -rf "$work_dir" >/dev/null 2>&1 || true
    else
        print_warn "Unsupported Azure Data Studio package type: $download_url"
        return 1
    fi

    if [[ -d "$target_app" ]]; then
        print_ok "Azure Data Studio installed. Version: $(get_app_version "$target_app")"
        return 0
    fi

    print_warn "Azure Data Studio installation completed but app was not found at $target_app"
    return 1
}

resolve_packet_tracer_dmg_url() {
    local explicit_url="${PACKET_TRACER_DMG_URL:-}"
    local release_repo="${PACKET_TRACER_RELEASE_REPO:-kpawnd/acidanthera}"
    local release_tag="${PACKET_TRACER_RELEASE_TAG:-Cisco}"
    local api_url
    local json

    if [[ -n "$explicit_url" ]]; then
        echo "$explicit_url"
        return 0
    fi

    api_url="https://api.github.com/repos/${release_repo}/releases/tags/${release_tag}"
    json="$(curl -fsSL "$api_url" 2>/dev/null || true)"

    if [[ -z "$json" ]]; then
        echo ""
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo "$json" | python3 "$PY_LIB_DIR/github_utils.py" packet-tracer-asset
        return 0
    fi

    echo ""
    return 1
}

install_packet_tracer() {
    local dmg_url=""
    local dmg_file="/tmp/cisco_packet_tracer.dmg"
    local mount_point="/tmp/packet_tracer_mount"
    local install_log="/tmp/packet_tracer_install.log"
    local pkg_path
    local mpkg_path
    local app_path
    local app_name_lc=""
    local nested_pkg_path=""
    local nested_mpkg_path=""
    local nested_app_path=""
    local installer_bundle="0"
    local installed_app
    local supported_ver="unknown"
    local stage_file="${1:-}"

    print_info "Installing Cisco Packet Tracer..."

    supported_ver="$(get_packet_tracer_supported_version)"
    installed_app="$(find_installed_packet_tracer_app)"
    if [[ -n "$installed_app" ]]; then
        if should_skip_direct_install "$installed_app" "Cisco Packet Tracer" "$supported_ver"; then
            return 0
        fi
    else
        print_info "Cisco Packet Tracer not currently installed. Proceeding with installation."
    fi

    echo "Resolving download URL" > "$stage_file" 2>/dev/null || true
    dmg_url="$(resolve_packet_tracer_dmg_url)"

    if [[ -z "$dmg_url" ]]; then
        print_warn "Could not resolve Cisco Packet Tracer DMG URL."
        print_warn "Expected a .dmg asset under release tag 'cisco' in the configured GitHub repo."
        print_warn "Set PACKET_TRACER_DMG_URL manually to override."
        return 1
    fi

    print_info "Using Packet Tracer DMG URL: $dmg_url"

    rm -f "$dmg_file" >/dev/null 2>&1 || true
    echo "Downloading Cisco Packet Tracer" > "$stage_file" 2>/dev/null || true
    monitor_download_progress "$dmg_file" "$stage_file" "Cisco Packet Tracer" &
    local monitor_pid=$!
    if ! download_file_resilient "$dmg_url" "$dmg_file"; then
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true
        print_warn "Failed to download Cisco Packet Tracer DMG."
        return 1
    fi
    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true

    echo "Verifying download" > "$stage_file" 2>/dev/null || true
    if ! hdiutil verify "$dmg_file" >/dev/null 2>&1; then
        print_warn "Downloaded Cisco Packet Tracer DMG failed integrity verification."
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        return 1
    fi

    rm -rf "$mount_point" >/dev/null 2>&1 || true
    mkdir -p "$mount_point" || return 1

    echo "Mounting DMG" > "$stage_file" 2>/dev/null || true
    if ! hdiutil attach "$dmg_file" -quiet -nobrowse -readonly -mountpoint "$mount_point" >/dev/null 2>&1; then
        local attach_output=""
        local detected_mount=""
        attach_output="$(hdiutil attach "$dmg_file" -nobrowse -readonly 2>/dev/null || true)"
        detected_mount="$(printf '%s\n' "$attach_output" | awk -F'\t' '/\/Volumes\// {print $3}' | tail -n 1)"
        if [[ -n "$detected_mount" && -d "$detected_mount" ]]; then
            mount_point="$detected_mount"
        else
            print_warn "Failed to mount Cisco Packet Tracer DMG."
            rm -f "$dmg_file" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    echo "Locating app bundle" > "$stage_file" 2>/dev/null || true
    pkg_path="$(find "$mount_point" -maxdepth 5 -name '*.pkg' | head -n 1)"
    mpkg_path="$(find "$mount_point" -maxdepth 5 -name '*.mpkg' | head -n 1)"
    app_path="$(find "$mount_point" -maxdepth 5 -name '*Packet*Tracer*.app' | head -n 1)"
    if [[ -z "$app_path" ]]; then
        app_path="$(find "$mount_point" -maxdepth 5 -name '*.app' | head -n 1)"
    fi

    if [[ -n "$app_path" ]]; then
        app_name_lc="$(basename "$app_path" | tr '[:upper:]' '[:lower:]')"
        if is_packet_tracer_installer_bundle "$app_path"; then
            installer_bundle="1"
        fi
    fi

    if [[ -n "$app_path" ]]; then
        if [[ "$installer_bundle" == "1" ]]; then
            : >"$install_log"
            echo "Running installer" > "$stage_file" 2>/dev/null || true
            if ! run_packet_tracer_installer_unattended "$app_path" "$install_log" "$mount_point"; then
                print_warn "Packet Tracer unattended installation failed."
                hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
                rm -f "$dmg_file" >/dev/null 2>&1 || true
                return 1
            fi
        else
            echo "Copying app bundle to /Applications" > "$stage_file" 2>/dev/null || true
            sudo rm -rf "/Applications/$(basename "$app_path")" >/dev/null 2>&1 || true
            if ! sudo ditto "$app_path" "/Applications/$(basename "$app_path")" >/dev/null 2>&1; then
                print_warn "Packet Tracer app copy failed."
                hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
                rm -f "$dmg_file" >/dev/null 2>&1 || true
                return 1
            fi
        fi
    else
        print_warn "No .app found inside Packet Tracer DMG."
        hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        return 1
    fi

    echo "Verifying installation" > "$stage_file" 2>/dev/null || true
    installed_app="$(find_installed_packet_tracer_app)"
    if [[ -z "$installed_app" ]]; then
        print_warn "Packet Tracer install command completed but app was not found in /Applications."
        hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        return 1
    fi

    echo "Cleaning up" > "$stage_file" 2>/dev/null || true
    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    rm -f "$dmg_file" >/dev/null 2>&1 || true
    print_ok "Cisco Packet Tracer installation completed: $installed_app"
    return 0
}

install_required_software() {
    local had_error=0
    local stage_blender="/tmp/install_stage_blender.txt"
    local stage_android="/tmp/install_stage_android.txt"
    local stage_azure="/tmp/install_stage_azure.txt"
    local stage_packet="/tmp/install_stage_packet.txt"

    print_info "Installing required software set..."

    repair_homebrew_environment || true

    reinstall_cask_app "blender" "/Applications/Blender.app" "Blender" "$stage_blender" >/dev/null 2>&1 &
    spinner_wait_with_stages $! "Installing Blender" "$stage_blender" || had_error=1

    reinstall_cask_app "android-studio" "/Applications/Android Studio.app" "Android Studio" "$stage_android" >/dev/null 2>&1 &
    spinner_wait_with_stages $! "Installing Android Studio" "$stage_android" || had_error=1

    install_azure_data_studio_direct "$stage_azure" >/dev/null 2>&1 &
    spinner_wait_with_stages $! "Installing Azure Data Studio" "$stage_azure" || had_error=1

    install_packet_tracer "$stage_packet" >/dev/null 2>&1 &
    spinner_wait_with_stages $! "Installing Cisco Packet Tracer" "$stage_packet" || had_error=1

    clear_inline_status
    rm -f "$stage_blender" "$stage_android" "$stage_azure" "$stage_packet" >/dev/null 2>&1 || true
    verify_required_software_present || had_error=1

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    return 0
}
