#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

DRY_RUN=0
FORCE=0
ALL_USERS=0
NO_QUIT=0
TARGET_USER=""

# Classic Teams first, followed by the Microsoft-documented new Teams containers.
TEAMS_CACHE_PATHS=(
    "Library/Application Support/Microsoft/Teams"
    "Library/Group Containers/UBF8T346G9.com.microsoft.teams"
    "Library/Containers/com.microsoft.teams2"
)

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [options]

Clears Microsoft Teams cache/state for macOS Sequoia 15.x and Tahoe 26.x.

Options:
  --user USER     Clear Teams cache for a specific local user.
  --all-users     Clear Teams cache for every local user under /Users.
  --dry-run       Show what would be removed without deleting anything.
  --no-quit       Do not attempt to quit Teams before clearing cache.
  --force         Run even if the macOS major version is not 15 or 26.
  -h, --help      Show this help text.

Examples:
  bash $SCRIPT_NAME
  sudo bash $SCRIPT_NAME --user student
  sudo bash $SCRIPT_NAME --all-users
  bash $SCRIPT_NAME --dry-run
USAGE
}

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                [[ $# -ge 2 ]] || die "--user requires a username."
                TARGET_USER="$2"
                shift 2
                ;;
            --all-users)
                ALL_USERS=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --no-quit)
                NO_QUIT=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    if [[ "$ALL_USERS" -eq 1 && -n "$TARGET_USER" ]]; then
        die "Use either --user or --all-users, not both."
    fi
}

require_supported_macos() {
    local version major release_name

    [[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only."

    version="$(/usr/bin/sw_vers -productVersion)"
    major="${version%%.*}"

    case "$major" in
        15)
            release_name="Sequoia"
            ;;
        26)
            release_name="Tahoe"
            ;;
        *)
            if [[ "$FORCE" -eq 0 ]]; then
                die "Unsupported macOS version $version. Re-run with --force if you intentionally want to try it anyway."
            fi
            release_name="unsupported"
            warn "Running on unsupported macOS version $version because --force was supplied."
            ;;
    esac

    log "Detected macOS $version ($release_name)."
}

console_user() {
    local user

    user="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
    if [[ -z "$user" || "$user" == "root" || "$user" == "_mbsetupuser" ]]; then
        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
            user="$SUDO_USER"
        else
            return 1
        fi
    fi

    printf '%s\n' "$user"
}

home_for_user() {
    local user="$1"
    local home=""

    home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | /usr/bin/sed 's/^NFSHomeDirectory: //' || true)"
    if [[ -z "$home" || ! -d "$home" ]]; then
        home="/Users/$user"
    fi

    [[ -n "$home" && -d "$home" ]] || return 1
    printf '%s\n' "$home"
}

list_local_users() {
    local home name

    for home in /Users/*; do
        [[ -d "$home" ]] || continue
        name="$(basename "$home")"

        case "$name" in
            Shared|Guest|Deleted\ Users)
                continue
                ;;
        esac

        if /usr/bin/id "$name" >/dev/null 2>&1; then
            printf '%s\n' "$name"
        fi
    done
}

teams_is_running() {
    local process_name

    for process_name in "Microsoft Teams" "MSTeams" "Teams"; do
        if /usr/bin/pgrep -x "$process_name" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

quit_teams() {
    [[ "$NO_QUIT" -eq 0 ]] || return 0

    if ! teams_is_running; then
        log "Microsoft Teams is not running."
        return 0
    fi

    log "Quitting Microsoft Teams if it is running."

    /usr/bin/osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
tell application id "com.microsoft.teams2" to quit
tell application id "com.microsoft.teams" to quit
tell application "Microsoft Teams" to quit
APPLESCRIPT

    /bin/sleep 3

    for process_name in "Microsoft Teams" "MSTeams" "Teams"; do
        if /usr/bin/pgrep -x "$process_name" >/dev/null 2>&1; then
            warn "Teams process '$process_name' is still running; terminating it."
            /usr/bin/pkill -x "$process_name" >/dev/null 2>&1 || true
        fi
    done
}

remove_path() {
    local path="$1"

    if [[ ! -e "$path" ]]; then
        log "Not present: $path"
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Would remove: $path"
        return 0
    fi

    /bin/rm -rf "$path"
    log "Removed: $path"
}

clear_for_user() {
    local user="$1"
    local home rel_path

    home="$(home_for_user "$user")" || {
        warn "Could not resolve a home directory for user '$user'; skipping."
        return 0
    }

    log "Clearing Teams cache for user '$user' at $home."

    for rel_path in "${TEAMS_CACHE_PATHS[@]}"; do
        remove_path "$home/$rel_path"
    done
}

main() {
    local user

    parse_args "$@"
    require_supported_macos
    quit_teams

    if [[ "$ALL_USERS" -eq 1 ]]; then
        list_local_users | while IFS= read -r user; do
            clear_for_user "$user"
        done
    else
        if [[ -z "$TARGET_USER" ]]; then
            TARGET_USER="$(console_user)" || die "Could not detect a logged-in console user. Re-run with --user USER or --all-users."
        fi
        clear_for_user "$TARGET_USER"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Dry run complete. No files were deleted."
    else
        log "Teams cache clear complete. Start Teams again and sign in fresh."
    fi
}

main "$@"
