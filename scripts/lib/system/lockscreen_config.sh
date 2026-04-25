#!/bin/bash

# Best-effort lock screen/login window background customization
# Works across macOS Monterey (12) through Sequoia (15)

apply_wallpaper_for_user() {
    local target_user="$1"
    local image_path="$2"
    local target_uid

    target_uid="$(id -u "$target_user" 2>/dev/null || true)"
    if [[ -z "$target_uid" ]]; then
        return 1
    fi

    # gui/<uid> only exists when the user is actively logged into a GUI session.
    # user/<uid> is kept alive by launchd for all users regardless of login state —
    # using that domain would always take the osascript path and silently fail for
    # any user who is not currently at the login window.
    if launchctl print "gui/$target_uid" >/dev/null 2>&1; then
        launchctl asuser "$target_uid" sudo -u "$target_user" osascript \
            -e 'tell application "System Events"' \
            -e 'tell every desktop to set picture to POSIX file "'"$image_path"'"' \
            -e 'end tell' >/dev/null 2>&1
        return $?
    fi

    # User is not currently logged in.
    # Resolve home directory from the directory service — eval/~ is unreliable as root.
    local user_home
    user_home="$(dscl . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [[ -z "$user_home" ]] && user_home="/Users/$target_user"
    [[ -d "$user_home" ]] || return 1

    local prefs_dir="${user_home}/Library/Preferences"
    local plist="${prefs_dir}/com.apple.desktop.plist"

    # Ensure the Preferences directory exists and is owned by the target user.
    if [[ ! -d "$prefs_dir" ]]; then
        sudo mkdir -p "$prefs_dir" >/dev/null 2>&1 && \
            sudo chown "${target_user}" "$prefs_dir" >/dev/null 2>&1 || return 1
    fi

    # PlistBuddy handles nested dicts reliably.
    # Delete any existing Background key first (ignore failure if not present),
    # then rebuild the full nested structure.
    sudo -u "$target_user" /usr/libexec/PlistBuddy \
        -c "Delete :Background" "$plist" >/dev/null 2>&1 || true
    sudo -u "$target_user" /usr/libexec/PlistBuddy \
        -c "Add :Background dict" \
        -c "Add :Background:default dict" \
        -c "Add :Background:default:ImageFilePath string ${image_path}" \
        -c "Add :Background:default:Change string Never" \
        "$plist" >/dev/null 2>&1
}

disable_screensaver_for_user() {
    local target_user="$1"
    local target_uid

    target_uid="$(id -u "$target_user" 2>/dev/null || true)"
    if [[ -z "$target_uid" ]]; then
        return 1
    fi

    # idleTime=0 disables the screen saver. Write to both the regular domain and
    # the ByHost domain (host-specific) since the latter takes precedence on macOS.
    # gui/<uid> only exists for actively logged-in GUI sessions; user/<uid> is always
    # present on Ventura regardless of login state and would route all users through
    # the launchctl asuser path, which silently fails for logged-out users.
    if launchctl print "gui/$target_uid" >/dev/null 2>&1; then
        # User has an active GUI session — run defaults in their context.
        launchctl asuser "$target_uid" sudo -u "$target_user" \
            defaults write com.apple.screensaver idleTime 0 >/dev/null 2>&1 || true
        launchctl asuser "$target_uid" sudo -u "$target_user" \
            defaults -currentHost write com.apple.screensaver idleTime 0 >/dev/null 2>&1 || true
    else
        # User not logged in — write directly to their preferences.
        sudo -u "$target_user" \
            defaults write com.apple.screensaver idleTime 0 >/dev/null 2>&1 || true
        sudo -u "$target_user" \
            defaults -currentHost write com.apple.screensaver idleTime 0 >/dev/null 2>&1 || true
    fi
}

apply_lockscreen_cache_for_user() {
    local target_user="$1"
    local image_path="$2"
    local generated_uid
    local cache_dir

    generated_uid="$(dscl . -read "/Users/$target_user" GeneratedUID 2>/dev/null | awk '{print $2}')"
    if [[ -z "$generated_uid" ]]; then
        return 1
    fi

    cache_dir="/Library/Caches/Desktop Pictures/$generated_uid"
    if ! sudo mkdir -p "$cache_dir"; then
        return 1
    fi

    # Write both png/jpg variants used by different macOS builds.
    sudo cp "$image_path" "$cache_dir/lockscreen.png" 2>/dev/null || return 1
    sudo cp "$image_path" "$cache_dir/lockscreen.jpg" 2>/dev/null || true
    sudo cp "$image_path" "/Library/Caches/com.apple.desktop.admin.png" 2>/dev/null || true
    sudo chmod 644 "$cache_dir/lockscreen.png" "$cache_dir/lockscreen.jpg" "/Library/Caches/com.apple.desktop.admin.png" >/dev/null 2>&1 || true
    sudo chown root:wheel "$cache_dir/lockscreen.png" "$cache_dir/lockscreen.jpg" "/Library/Caches/com.apple.desktop.admin.png" >/dev/null 2>&1 || true

    return 0
}

install_lockscreen_boot_daemon() {
    local image_path="$1"
    local daemon_label="com.atherion.lockscreen"
    local daemon_plist="/Library/LaunchDaemons/${daemon_label}.plist"
    local support_dir="/Library/Application Support/Atherion"
    local restore_script="${support_dir}/apply-lockscreen.sh"

    sudo mkdir -p "$support_dir" >/dev/null 2>&1 || return 1

    # Write the restore script with fully-qualified paths — no shell environment at boot.
    sudo tee "$restore_script" >/dev/null <<'RESTORE_SCRIPT'
#!/bin/bash
IMAGE="/Library/Application Support/Atherion/lockscreen_bg.png"
[[ -f "$IMAGE" ]] || exit 0

# Restore loginwindow preferences so the custom image shows at boot.
/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow \
    DesktopPicture "$IMAGE"
/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow \
    LockScreenImage "$IMAGE"

# Restore every per-user Desktop Pictures cache.
for cache_dir in "/Library/Caches/Desktop Pictures"/*/; do
    [[ -d "$cache_dir" ]] || continue
    /bin/cp "$IMAGE" "${cache_dir}lockscreen.png" 2>/dev/null || true
    /bin/cp "$IMAGE" "${cache_dir}lockscreen.jpg" 2>/dev/null || true
    /bin/chmod 644 "${cache_dir}lockscreen.png" "${cache_dir}lockscreen.jpg" 2>/dev/null || true
done

# Restore global admin cache.
/bin/cp "$IMAGE" "/Library/Caches/com.apple.desktop.admin.png" 2>/dev/null || true
/bin/chmod 644 "/Library/Caches/com.apple.desktop.admin.png" 2>/dev/null || true
RESTORE_SCRIPT

    sudo chmod 755 "$restore_script" >/dev/null 2>&1 || return 1
    sudo chown root:wheel "$restore_script" >/dev/null 2>&1 || return 1

    # Write the LaunchDaemon plist (paths with spaces are safe inside array elements).
    sudo tee "$daemon_plist" >/dev/null <<DAEMON_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${daemon_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Library/Application Support/Atherion/apply-lockscreen.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
DAEMON_PLIST

    sudo chmod 644 "$daemon_plist" >/dev/null 2>&1 || return 1
    sudo chown root:wheel "$daemon_plist" >/dev/null 2>&1 || return 1

    # Bootstrap (or re-bootstrap) the daemon so it also runs in the current boot session.
    sudo launchctl bootout "system/${daemon_label}" >/dev/null 2>&1 || true
    sudo launchctl bootstrap system "$daemon_plist" >/dev/null 2>&1 || return 1

    return 0
}

list_lockscreen_target_users() {
    dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 500 && $1 != "root" && $1 != "nobody" {print $1}'
}

verify_lockscreen_for_user() {
    local target_user="$1"
    local generated_uid
    local cache_dir
    local png_file

    generated_uid="$(dscl . -read "/Users/$target_user" GeneratedUID 2>/dev/null | awk '{print $2}')"
    [[ -n "$generated_uid" ]] || return 1

    cache_dir="/Library/Caches/Desktop Pictures/$generated_uid"
    png_file="$cache_dir/lockscreen.png"
    [[ -f "$png_file" ]] || return 1
    [[ -s "$png_file" ]] || return 1

    return 0
}

configure_lockscreen_background() {
    local image_url="${LOCKSCREEN_IMAGE_URL:-https://wall.tasw.qzz.io/mac.png}"
    local image_file="/tmp/lockscreen_bg.png"
    local persistent_dir="/Library/Application Support/Atherion"
    local persistent_image="$persistent_dir/lockscreen_bg.png"
    local lock_plist="/Library/Preferences/com.apple.loginwindow"
    local diag_log="/tmp/atherion-lockscreen.log"
    local total_checks=0
    local failed_checks=0
    local defaults_value=""
    
    : > "$diag_log"
    print_info "Diagnostics log: $diag_log"
    print_info "Downloading lockscreen image..."
    
    # Download the image
    if ! curl -fsSL --connect-timeout 10 --max-time 60 "$image_url" -o "$image_file"; then
        print_warn "Failed to download lockscreen image from $image_url"
        return 1
    fi
    total_checks=$((total_checks + 1))
    print_ok "Check $total_checks: image download"
    
    # Verify it's a valid image
    if ! file "$image_file" | grep -q "image"; then
        print_warn "Downloaded file is not a valid image"
        rm -f "$image_file"
        return 1
    fi
    total_checks=$((total_checks + 1))
    print_ok "Check $total_checks: image validation"

    # Persist the image to a system path so settings survive script exit.
    if ! sudo mkdir -p "$persistent_dir"; then
        print_warn "Failed to create lockscreen directory: $persistent_dir"
        rm -f "$image_file"
        return 1
    fi
    if ! sudo cp "$image_file" "$persistent_image"; then
        print_warn "Failed to copy lockscreen image to $persistent_image"
        rm -f "$image_file"
        return 1
    fi
    sudo chmod 644 "$persistent_image" >/dev/null 2>&1 || true
    total_checks=$((total_checks + 1))
    print_ok "Check $total_checks: persistent image write"
    
    # Check if SIP is disabled (OCLP system)
    local sip_enabled=true
    if csrutil status 2>/dev/null | grep -q "disabled"; then
        sip_enabled=false
        print_info "SIP detected as disabled (OCLP system) - using full lockscreen replacement"
    fi
    
    # For SIP-disabled systems (OCLP), replace actual lockscreen images
    if [[ "$sip_enabled" == "false" ]]; then
        _apply_lockscreen_sip_disabled "$persistent_image"
    fi
    
    # Always set loginwindow-related image paths (works with or without SIP)
    print_info "Applying loginwindow image paths..."
    
    # Copy to system location (best-effort cache path; not present on all builds)
    sudo mkdir -p /Library/Caches/com.apple.loginwindow >/dev/null 2>&1 || true
    if sudo cp "$persistent_image" /Library/Caches/com.apple.loginwindow/lockscreen_bg.png >/dev/null 2>&1; then
        total_checks=$((total_checks + 1))
        print_ok "Check $total_checks: loginwindow cache file write"
    else
        print_warn "Could not write optional cache file: /Library/Caches/com.apple.loginwindow/lockscreen_bg.png"
    fi
    
    # Set via defaults (Monterey-Sequoia compatible)
    if ! sudo defaults write "$lock_plist" "DesktopPicture" "$persistent_image" >/dev/null 2>&1; then
        print_warn "Failed to set login window background via defaults"
        failed_checks=$((failed_checks + 1))
    else
        total_checks=$((total_checks + 1))
        print_ok "Check $total_checks: loginwindow DesktopPicture write"
    fi
    if ! sudo defaults write "$lock_plist" "LockScreenImage" "$persistent_image" >/dev/null 2>&1; then
        print_warn "Failed to set LockScreenImage via defaults"
        failed_checks=$((failed_checks + 1))
    else
        total_checks=$((total_checks + 1))
        print_ok "Check $total_checks: loginwindow LockScreenImage write"
    fi
    
    # Verify defaults were actually written
    defaults_value="$(sudo defaults read "$lock_plist" "DesktopPicture" 2>/dev/null || true)"
    if [[ "$defaults_value" == "$persistent_image" ]]; then
        total_checks=$((total_checks + 1))
        print_ok "Check $total_checks: loginwindow DesktopPicture readback"
        print_info "  Value: $defaults_value"
        echo "DesktopPicture=$defaults_value" >> "$diag_log" 2>/dev/null || true
    else
        print_warn "DesktopPicture readback mismatch: expected='$persistent_image' actual='$defaults_value'"
        echo "DesktopPicture mismatch expected='$persistent_image' actual='$defaults_value'" >> "$diag_log" 2>/dev/null || true
        failed_checks=$((failed_checks + 1))
    fi
    defaults_value="$(sudo defaults read "$lock_plist" "LockScreenImage" 2>/dev/null || true)"
    if [[ "$defaults_value" == "$persistent_image" ]]; then
        total_checks=$((total_checks + 1))
        print_ok "Check $total_checks: loginwindow LockScreenImage readback"
        print_info "  Value: $defaults_value"
        echo "LockScreenImage=$defaults_value" >> "$diag_log" 2>/dev/null || true
    else
        print_warn "LockScreenImage readback mismatch: expected='$persistent_image' actual='$defaults_value'"
        echo "LockScreenImage mismatch expected='$persistent_image' actual='$defaults_value'" >> "$diag_log" 2>/dev/null || true
        failed_checks=$((failed_checks + 1))
    fi
    
    # Verify image file is accessible and has correct permissions
    local image_stat
    local image_user
    local image_perms
    image_stat="$(ls -ld "$persistent_image" 2>/dev/null || true)"
    if [[ -n "$image_stat" ]]; then
        print_info "Lockscreen image file stat: $image_stat"
        echo "ImageStat=$image_stat" >> "$diag_log" 2>/dev/null || true
        # Ensure world-readable so loginwindow can access it
        sudo chmod 644 "$persistent_image" >/dev/null 2>&1 || true
    else
        print_warn "Lockscreen image file not accessible: $persistent_image"
        echo "ImageStat missing for $persistent_image" >> "$diag_log" 2>/dev/null || true
        failed_checks=$((failed_checks + 1))
    fi
    
    # Apply lockscreen cache and desktop wallpaper for every local user account.
    print_info "Applying lockscreen and wallpaper for all users..."

    local set_wallpaper="${LOCKSCREEN_SET_WALLPAPER:-1}"
    local applied_any=0
    while IFS= read -r target_user; do
        [[ -n "$target_user" ]] || continue

        if apply_lockscreen_cache_for_user "$target_user" "$persistent_image"; then
            print_info "Lockscreen cache updated for user: $target_user"
            if verify_lockscreen_for_user "$target_user"; then
                total_checks=$((total_checks + 1))
                print_ok "Check $total_checks: lockscreen cache verify ($target_user)"
            else
                print_warn "Lockscreen cache verify failed for user: $target_user"
                failed_checks=$((failed_checks + 1))
            fi
            applied_any=1
        else
            print_warn "Could not update lockscreen cache for $target_user"
            failed_checks=$((failed_checks + 1))
        fi

        if [[ "$set_wallpaper" == "1" ]]; then
            if apply_wallpaper_for_user "$target_user" "$persistent_image"; then
                total_checks=$((total_checks + 1))
                print_ok "Check $total_checks: desktop wallpaper apply ($target_user)"
                echo "Desktop wallpaper apply succeeded for $target_user" >> "$diag_log" 2>/dev/null || true
            else
                print_warn "Could not update wallpaper for $target_user"
                echo "Desktop wallpaper apply failed for $target_user" >> "$diag_log" 2>/dev/null || true
                failed_checks=$((failed_checks + 1))
            fi
        fi

        # Disable screen saver so it does not replace the wallpaper after login.
        disable_screensaver_for_user "$target_user" && \
            print_ok "Screen saver disabled for $target_user" || \
            print_warn "Could not disable screen saver for $target_user"
    done < <(list_lockscreen_target_users)

    if [[ "$applied_any" -eq 0 ]]; then
        print_warn "No eligible local users found for lockscreen cache update."
        failed_checks=$((failed_checks + 1))
    fi

    if [[ -f "/Library/Caches/com.apple.loginwindow/lockscreen_bg.png" ]]; then
        total_checks=$((total_checks + 1))
        print_ok "Check $total_checks: loginwindow cache file exists"
    else
        print_warn "Optional cache file missing: /Library/Caches/com.apple.loginwindow/lockscreen_bg.png"
    fi

    # Invalidate loginwindow cache to force re-read on next lock/reboot.
    # Keep this non-disruptive: do not kill WindowServer (that drops the GUI session).
    print_info "Invalidating loginwindow cache to ensure refresh..."
    
    # Clear loginwindow mutable state (com.apple.loginwindow-state)
    sudo defaults delete /Library/Preferences/com.apple.loginwindow-state >/dev/null 2>&1 || true
    
    # Flush system defaults cache
    sudo killall cfprefsd >/dev/null 2>&1 || true
    sudo killall distnoted >/dev/null 2>&1 || true
    sleep 1
    
    print_ok "Non-disruptive cache invalidation triggered - lockscreen updates on next lock/reboot"
    echo "Cache invalidation completed without WindowServer restart" >> "$diag_log" 2>/dev/null || true

    if [[ "${LOCKSCREEN_SET_WALLPAPER:-1}" != "1" ]]; then
        print_info "Desktop wallpaper unchanged (LOCKSCREEN_SET_WALLPAPER=0)."
        echo "Desktop wallpaper skipped by LOCKSCREEN_SET_WALLPAPER=0" >> "$diag_log" 2>/dev/null || true
    fi

    # Install a LaunchDaemon that re-applies the image on every boot.
    # macOS regenerates the loginwindow boot background from session state on logout/shutdown,
    # overwriting what the script set. The daemon restores our image early in the boot sequence
    # before loginwindow finishes rendering.
    print_info "Installing boot-time lockscreen restore daemon..."
    if install_lockscreen_boot_daemon "$persistent_image"; then
        total_checks=$((total_checks + 1))
        print_ok "Check $total_checks: boot-time restore daemon installed (com.atherion.lockscreen)"
    else
        print_warn "Could not install boot-time restore daemon; lockscreen may reset after reboot"
        failed_checks=$((failed_checks + 1))
    fi

    rm -f "$image_file"
    print_info "Diagnostics persisted at: $diag_log"
    print_info "Verification summary: passed=${total_checks} failed=${failed_checks}"
    if [[ "$failed_checks" -gt 0 ]]; then
        print_warn "Lockscreen/loginwindow update is partial. Review warnings above."
        return 1
    fi

    print_info "Best-effort lock-screen/loginwindow update saved. It applies on next lock screen/reboot without logging out current users."
    print_ok "Lockscreen/loginwindow update configured"
    return 0
}

# Apply lockscreen replacement for SIP-disabled systems (OCLP)
_apply_lockscreen_sip_disabled() {
    local image_file="$1"
    
    print_info "Replacing lockscreen image (SIP disabled)..."
    
    # Copy to standard macOS lockscreen locations (works Monterey-Sequoia)
    local lock_dirs=(
        "/Library/Caches/com.apple.loginwindow"
        "/var/db/loginwindow"
    )
    
    for dir in "${lock_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            sudo cp "$image_file" "$dir/lockscreen.png" 2>/dev/null && \
            sudo chmod 644 "$dir/lockscreen.png" 2>/dev/null || true
        fi
    done
    
    # Set system-wide lockscreen via com.apple.loginwindow defaults
    sudo defaults write /Library/Preferences/com.apple.loginwindow \
        "DesktopPicture" "$image_file" 2>/dev/null || true
    
    # Set for macOS login/lock screen (Monterey+)
    sudo defaults write /Library/Preferences/com.apple.loginwindow \
        "LockScreenImage" "$image_file" 2>/dev/null || true
    
    print_ok "Lockscreen replacement applied (SIP disabled)"
}

# MDM profile approach for loginwindow policy (no image payload key)
create_lockscreen_mdm_profile() {
    local image_url="${LOCKSCREEN_IMAGE_URL:-https://wall.tasw.qzz.io/mac.png}"
    local profile_id="com.lab.lockscreen.background"
    local profile_file="/tmp/${profile_id}.mobileconfig"
    local profile_uuid="A7B2C3D4-E5F6-47G8-H9I0-J1K2L3M4N5O6"
    
    print_info "Creating loginwindow policy MDM profile for Monterey-Sequoia..."
    
    # Create MDM profile that sets login window properties
    cat > "$profile_file" <<'MDMEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.lab.lockscreen.background.payload</string>
            <key>PayloadUUID</key>
            <string>PAYLOAD_UUID_HERE</string>
            <key>PayloadDisplayName</key>
            <string>Login Window Policy</string>
            <key>PayloadEnabled</key>
            <true/>
            <key>PayloadOrganization</key>
            <string>Lab</string>
            
            <key>com.apple.loginwindow</key>
            <dict>
                <key>Forced</key>
                <array>
                    <dict>
                        <key>mcx_preference_settings</key>
                        <dict>
                            <key>LoginwindowText</key>
                            <string>Lab System</string>
                            <key>SHOWFULLNAME</key>
                            <false/>
                            <key>DisableConsoleAccess</key>
                            <false/>
                        </dict>
                    </dict>
                </array>
            </dict>
        </dict>
    </array>
    
    <key>PayloadDisplayName</key>
    <string>Lab Login Window Configuration</string>
    <key>PayloadIdentifier</key>
    <string>com.lab.lockscreen.background</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>PROFILE_UUID_HERE</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
MDMEOF

    print_info "MDM profile created at $profile_file"
    print_info "To enroll: sudo profiles install -type configuration -path $profile_file"
    print_ok "Loginwindow policy MDM profile ready"
    return 0
}
