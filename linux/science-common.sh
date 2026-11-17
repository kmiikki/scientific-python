#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANAGER="$SCRIPT_DIR/science-manager.py"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
command -v python3 >/dev/null 2>&1 || die 'Ubuntu system python3 is required.'
confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    [[ "$answer" == y || "$answer" == Y ]]
}
require_supported_platform() {
    [[ -n "${BASH_VERSION:-}" ]] || die 'Bash is required.'
    python3 "$MANAGER" guard-platform || die 'Unsupported platform.'
}
show_info() {
    python3 "$SCRIPT_DIR/science-install.py" info
}
