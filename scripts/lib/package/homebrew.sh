#!/bin/bash

resolve_brew_bin() {
    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return 0
    fi
    if [[ -x /opt/homebrew/bin/brew ]]; then
        echo "/opt/homebrew/bin/brew"
        return 0
    fi
    if [[ -x /usr/local/bin/brew ]]; then
        echo "/usr/local/bin/brew"
        return 0
    fi
    return 1
}

ensure_brew_in_path() {
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"
}

brew_cmd() {
    local brew_bin
    ensure_brew_in_path
    brew_bin="$(resolve_brew_bin 2>/dev/null || true)"
    if [[ -z "$brew_bin" ]]; then
        return 127
    fi

    if [[ "$EUID" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" "$brew_bin" "$@"
    else
        "$brew_bin" "$@"
    fi
}

ensure_git_installed() {
    local clt_label

    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

    if command -v git >/dev/null 2>&1; then
        print_ok "git is already available: $(command -v git)"
        return 0
    fi

    if [[ -x /usr/bin/git ]]; then
        print_warn "git exists at /usr/bin/git but was missing from PATH. PATH corrected."
        return 0
    fi

    print_warn "git is not installed. Attempting to install Command Line Tools."

    clt_label="$(softwareupdate -l 2>/dev/null | awk -F'* ' '/Command Line Tools/ {print $2}' | sed 's/^Label: //' | tail -n 1)"
    if [[ -n "$clt_label" ]]; then
        print_info "Installing: $clt_label"
        if sudo softwareupdate -i "$clt_label" --verbose; then
            if command -v git >/dev/null 2>&1 || [[ -x /usr/bin/git ]]; then
                print_ok "git installed successfully via Command Line Tools."
                return 0
            fi
        fi
    fi

    print_warn "Automatic CLT install did not complete. Triggering interactive installer."
    xcode-select --install >/dev/null 2>&1 || true

    if command -v git >/dev/null 2>&1 || [[ -x /usr/bin/git ]]; then
        print_ok "git is now available."
        return 0
    fi

    print_err "git is still unavailable. Complete Command Line Tools installation, then rerun this script."
    return 1
}

brew_is_healthy() {
    ensure_brew_in_path
    if ! resolve_brew_bin >/dev/null 2>&1; then
        return 1
    fi

    if brew_cmd --version >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

repair_homebrew_shallow_clones() {
    local brew_repo
    local core_tap
    local cask_tap
    local had_error=0

    if ! resolve_brew_bin >/dev/null 2>&1; then
        print_warn "brew is unavailable; cannot repair shallow clones."
        return 1
    fi

    brew_repo="$(brew_cmd --repository 2>/dev/null || true)"
    if [[ -z "$brew_repo" ]]; then
        if [[ -d /opt/homebrew ]]; then
            brew_repo="/opt/homebrew"
        elif [[ -d /usr/local/Homebrew ]]; then
            brew_repo="/usr/local/Homebrew"
        fi
    fi

    if [[ -z "$brew_repo" || ! -d "$brew_repo" ]]; then
        print_warn "Could not resolve Homebrew repository path for shallow clone repair."
        return 1
    fi

    core_tap="$brew_repo/Library/Taps/homebrew/homebrew-core"
    cask_tap="$brew_repo/Library/Taps/homebrew/homebrew-cask"

    if [[ -d "$core_tap/.git" ]]; then
        print_info "Repairing shallow clone: homebrew-core"
        if ! git -C "$core_tap" fetch --unshallow >/dev/null 2>&1; then
            print_warn "Could not unshallow homebrew-core."
            had_error=1
        fi
    fi

    if [[ -d "$cask_tap/.git" ]]; then
        print_info "Repairing shallow clone: homebrew-cask"
        if ! git -C "$cask_tap" fetch --unshallow >/dev/null 2>&1; then
            print_warn "Could not unshallow homebrew-cask."
            had_error=1
        fi
    fi

    [[ "$had_error" -eq 0 ]]
}

repair_homebrew_permissions() {
    local had_error=0
    local owner_user="${SUDO_USER:-$USER}"
    local owner_group
    local zsh_dirs=(
        "/usr/local/share/zsh"
        "/usr/local/share/zsh/site-functions"
    )
    local d

    owner_group="$(id -gn "$owner_user" 2>/dev/null || echo staff)"

    for d in "${zsh_dirs[@]}"; do
        if [[ ! -d "$d" ]]; then
            sudo mkdir -p "$d" >/dev/null 2>&1 || {
                print_warn "Could not create directory: $d"
                had_error=1
                continue
            }
        fi

        if [[ ! -w "$d" ]]; then
            print_info "Fixing write permissions for: $d"
            sudo chown -R "$owner_user":"$owner_group" "$d" >/dev/null 2>&1 || {
                print_warn "Could not change ownership for: $d"
                had_error=1
            }
            sudo chmod u+w "$d" >/dev/null 2>&1 || {
                print_warn "Could not set write permission for: $d"
                had_error=1
            }
        fi
    done

    [[ "$had_error" -eq 0 ]]
}

repair_homebrew_environment() {
    local had_error=0

    if resolve_brew_bin >/dev/null 2>&1; then
        print_info "Repairing Homebrew tap clone depth and permissions."
        repair_homebrew_shallow_clones || had_error=1
    fi

    repair_homebrew_permissions || had_error=1

    [[ "$had_error" -eq 0 ]]
}

install_homebrew() {
    ensure_brew_in_path

    if ! ensure_git_installed; then
        print_err "Cannot install Homebrew without git in PATH."
        return 1
    fi

    if brew_is_healthy; then
        print_ok "Homebrew is already installed."
        return 0
    fi

    if resolve_brew_bin >/dev/null 2>&1; then
        print_warn "Homebrew is installed but appears broken. Attempting reinstall."
    fi

    print_info "Installing Homebrew..."
    repair_homebrew_environment || true
    if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        if resolve_brew_bin >/dev/null 2>&1; then
            print_warn "Homebrew install/update failed. Attempting shallow clone repair and retry."
            repair_homebrew_environment || true
            brew_cmd update --force --quiet >/dev/null 2>&1 || true
        fi

        if brew_is_healthy; then
            print_ok "Homebrew is healthy after repair/retry."
            return 0
        fi

        print_err "Homebrew installation failed."
        return 1
    fi

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if ! brew_is_healthy; then
        print_err "Homebrew is still unavailable or unhealthy after reinstall attempt."
        return 1
    fi

    print_ok "Homebrew installed successfully."
    return 0
}

ensure_runtime_dependencies() {
    local had_error=0

    if ! command -v curl >/dev/null 2>&1; then
        print_warn "curl is missing. Attempting Command Line Tools install path."
        ensure_git_installed || had_error=1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        if brew_is_healthy; then
            print_info "Installing missing dependency: python3"
            HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install python >/dev/null 2>&1 || had_error=1
        else
            print_warn "python3 is missing and Homebrew is unavailable right now."
            had_error=1
        fi
    fi

    [[ "$had_error" -eq 0 ]]
}

ensure_go_installed() {
    local install_status=0

    ensure_brew_in_path

    if command -v go >/dev/null 2>&1; then
        print_ok "go is already available: $(command -v go)"
        return 0
    fi

    if ! brew_is_healthy; then
        print_warn "go is missing and Homebrew is unavailable right now."
        return 1
    fi

    repair_homebrew_environment || true

    print_info "Installing Golang (go) via Homebrew..."
    if ! HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install go; then
        install_status=$?
        print_warn "Initial go install failed. Retrying after Homebrew repair/update."
        repair_homebrew_environment || true
        brew_cmd update --force --quiet >/dev/null 2>&1 || true
        HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install go
        install_status=$?
    fi

    if [[ "$install_status" -eq 0 ]]; then
        hash -r
        if command -v go >/dev/null 2>&1; then
            print_ok "go installed successfully: $(command -v go)"
            return 0
        fi

        if [[ -x /opt/homebrew/bin/go ]]; then
            print_ok "go installed successfully: /opt/homebrew/bin/go"
            return 0
        fi

        if [[ -x /usr/local/bin/go ]]; then
            print_ok "go installed successfully: /usr/local/bin/go"
            return 0
        fi
    fi

    print_err "go installation failed. Check Homebrew output above for exact reason."
    return 1
}

attempt_dependency_repair() {
    local log_file="$1"
    local repaired=0

    if grep -qiE 'command not found: python3|python3: command not found' "$log_file"; then
        if brew_is_healthy; then
            print_info "Auto-fix: installing python3"
            HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install python >/dev/null 2>&1 && repaired=1
        fi
    fi

    if grep -qiE 'command not found: go|go: command not found' "$log_file"; then
        if brew_is_healthy; then
            print_info "Auto-fix: installing go"
            HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install go >/dev/null 2>&1 && repaired=1
        fi
    fi

    if grep -qiE 'command not found: git|git: command not found' "$log_file"; then
        print_info "Auto-fix: installing git via CLT path"
        ensure_git_installed && repaired=1
    fi

    if grep -qiE 'command not found: brew|brew: command not found' "$log_file"; then
        print_info "Auto-fix: attempting Homebrew install"
        install_homebrew && repaired=1
    fi

    if grep -qiE 'homebrew-core is a shallow clone|homebrew-cask is a shallow clone|not writable by your user' "$log_file"; then
        print_info "Auto-fix: repairing Homebrew environment"
        repair_homebrew_environment && repaired=1
    fi

    [[ "$repaired" -eq 1 ]]
}
