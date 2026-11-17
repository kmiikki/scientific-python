#!/usr/bin/env bash
# Scientific Python managed Spyder launcher
# Scientific-Python-Root-Id: @ROOT_ID@
set -euo pipefail
ROOT=@ROOT@
MM=@MM@
SCIENCE="$ROOT/envs/science"
export MAMBA_ROOT_PREFIX="$ROOT"
export MAMBA_EXE="$MM"
export CONDA_EXE="$MM"
unset PYTHONHOME PYTHONPATH
[[ -x "$MM" && -x "$SCIENCE/bin/python" ]] || { printf 'Install science first.\n' >&2; exit 1; }
exec "$MM" run -r "$ROOT" -p "$SCIENCE" "$SCIENCE/bin/python" "$ROOT/share/scientific-python/science-spyder-start.py" "$@"
