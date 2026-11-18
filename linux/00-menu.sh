#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=science-common.sh
. "$SCRIPT_DIR/science-common.sh"
while true; do
    printf '\nScientific Python Ubuntu LTS V4-r5.2\n1  Install/update\nO  Optional packages\n2  Remove Spyder settings\n3  Remove science\n4  Remove owned Micromamba (preserve root/cache)\nI  Info\nD  Diagnostics\nV  Validation only\nC  Package configuration location\nQ  Quit\n'
    read -r -p 'Selection: ' choice || exit 0
    case "$choice" in
        1) script=01-install-science.sh ;;
        o|O) python3 "$SCRIPT_DIR/science-install.py" optional; continue ;;
        2) script=02-remove-spyder-settings.sh ;;
        3) script=03-remove-science.sh ;;
        4) script=04-remove-micromamba.sh ;;
        i|I) show_info; continue ;;
        d|D) script=05-diagnostics.sh ;;
        v|V) python3 "$SCRIPT_DIR/science-install.py" validate; continue ;;
        c|C) python3 "$SCRIPT_DIR/science-config-info.py"; continue ;;
        q|Q) exit 0 ;;
        *) printf 'Unknown selection: %s\n' "$choice"; continue ;;
    esac
    bash "$SCRIPT_DIR/$script"
    status=$?
    if (( status != 0 )); then
        printf '%s returned error code %s.\n' "$script" "$status" >&2
    fi
done
