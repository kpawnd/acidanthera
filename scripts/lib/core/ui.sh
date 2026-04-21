#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_STEPS=0
FAILED_STEPS=0
FIRMWARE_PASSWORD_CHANGED=0

print_ok() {
    clear_inline_status
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    clear_inline_status
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_err() {
    clear_inline_status
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    clear_inline_status
    echo -e "${BLUE}[INFO]${NC} $1"
}

clear_inline_status() {
    if [[ -t 1 ]]; then
        printf "\r\033[2K"
    fi
}

normalize_stage_label() {
    local raw="$1"
    local normalized

    normalized="$(printf '%s' "$raw" | tr -s ' ' | sed 's/^ *//;s/ *$//')"
    if [[ -z "$normalized" ]]; then
        printf '%s' ""
        return 0
    fi

    if [[ "${#normalized}" -gt 120 ]]; then
        normalized="${normalized:0:117}..."
    fi

    printf '%s' "$normalized"
}

spinner_wait_with_stages() {
    local pid="$1"
    local label="$2"
    local stage_file="$3"
    local frames='|/-\\'
    local i=0
    local current_stage=""
    local last_stage=""

    if [[ ! -t 1 ]]; then
        wait "$pid"
        return $?
    fi

    while kill -0 "$pid" >/dev/null 2>&1; do
        if [[ -f "$stage_file" ]]; then
            current_stage="$(tail -n 1 "$stage_file" 2>/dev/null || echo '')"
            current_stage="$(normalize_stage_label "$current_stage")"
            if [[ -n "$current_stage" && "$current_stage" != "$last_stage" ]]; then
                last_stage="$current_stage"
            fi
        fi
        if [[ -n "$last_stage" ]]; then
            printf "\r\033[2K${BLUE}[RUN]${NC} %s - %s [%c]" "$label" "$last_stage" "${frames:i++%${#frames}:1}"
        else
            printf "\r\033[2K${BLUE}[RUN]${NC} %s [%c]" "$label" "${frames:i++%${#frames}:1}"
        fi
        sleep 0.12
    done

    wait "$pid"
    local status=$?
    clear_inline_status
    return $status
}

render_app_install_progress() {
    local current="$1"
    local total="$2"
    local label="$3"
    local width=28
    local pct=0
    local filled=0
    local empty=0
    local bar

    if [[ "$total" -gt 0 ]]; then
        pct=$(( (current * 100) / total ))
    fi

    filled=$(( (pct * width) / 100 ))
    empty=$(( width - filled ))
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"

    printf "\r\033[2K${BLUE}[INSTALL]${NC} [%s] %3d%% - %s" "$bar" "$pct" "$label"
}

