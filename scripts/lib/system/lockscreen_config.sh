#!/bin/bash

# Configure custom lockscreen/login window background
# Works across macOS Monterey (12) through Sequoia (15)

configure_lockscreen_background() {
    local image_url="${LOCKSCREEN_IMAGE_URL:-https://wall-r2.tasw.qzz.io/original_lockscreen11.png}"
    local image_file="/tmp/lockscreen_bg.png"
    local lock_plist="/Library/Preferences/com.apple.loginwindow"
    
    print_info "Downloading lockscreen image..."
    
    # Download the image
    if ! curl -fsSL --connect-timeout 10 --max-time 60 "$image_url" -o "$image_file"; then
        print_warn "Failed to download lockscreen image from $image_url"
        return 1
    fi
    
    # Verify it's a valid image
    if ! file "$image_file" | grep -q "image"; then
        print_warn "Downloaded file is not a valid image"
        rm -f "$image_file"
        return 1
    fi
    
    # Set login window background (works Monterey+)
    print_info "Setting login window background..."
    
    # Copy to system location
    sudo cp "$image_file" /Library/Caches/com.apple.loginwindow/lockscreen_bg.png 2>/dev/null || true
    
    # Set via defaults (Monterey-Sequoia compatible)
    if ! sudo defaults write "$lock_plist" "DesktopPicture" "$image_file" >/dev/null 2>&1; then
        print_warn "Failed to set login window background via defaults"
    fi
    
    # Set wallpaper for all users (post-login background)
    print_info "Applying wallpaper to active user..."
    
    local current_user
    current_user="$(stat -f%Su /dev/console 2>/dev/null || whoami)"
    
    if [[ -n "$current_user" && "$current_user" != "root" ]]; then
        # Set desktop background for current user
        osascript <<EOF 2>/dev/null || true
tell application "System Events"
    set theDesktop to the desktop
    set the picture of theDesktop to "$image_file"
end tell
EOF
    fi
    
    # Restart loginwindow to apply changes
    print_info "Applying lockscreen changes..."
    
    if pgrep -x loginwindow >/dev/null; then
        sudo killall -HUP loginwindow 2>/dev/null || true
        sleep 2
    fi
    
    rm -f "$image_file"
    print_ok "Lockscreen background configured"
    return 0
}

# MDM profile approach for persistent cross-version lockscreen
create_lockscreen_mdm_profile() {
    local image_url="${LOCKSCREEN_IMAGE_URL:-https://wall-r2.tasw.qzz.io/original_lockscreen11.png}"
    local profile_id="com.lab.lockscreen.background"
    local profile_file="/tmp/${profile_id}.mobileconfig"
    local profile_uuid="A7B2C3D4-E5F6-47G8-H9I0-J1K2L3M4N5O6"
    
    print_info "Creating lockscreen MDM profile for Monterey-Sequoia..."
    
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
            <string>Lockscreen Background</string>
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
    <string>Lab Lockscreen Configuration</string>
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
    print_ok "Lockscreen MDM profile ready"
    return 0
}
