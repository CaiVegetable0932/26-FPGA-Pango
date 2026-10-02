#!/bin/sh
# Ubuntu/Linux entry point; paths and arguments may contain spaces.
set -eu
pango_script_dir=$(cd -P -- "$(dirname -- "$0")" >/dev/null && pwd)
# Prefer Jetson's prepared runtime over the optional calibration venv, while
# honoring an explicit interpreter; never alter Ubuntu/NVIDIA's system Python.
pango_environment="$pango_script_dir/../build/environment"
# Use the native project browser when the prepared runtime is present. This
# avoids relying on Snap in constrained Jetson desktop sessions and respects
# an explicit desktop browser preference.
if [ -z "${BROWSER:-}" ] && [ -d "$pango_environment/browsers" ] && [ -x "$pango_script_dir/open_browser.sh" ]; then
    export BROWSER="\"$pango_script_dir/open_browser.sh\" %s &"
fi
if [ -n "${PANGO_PYTHON:-}" ]; then
    pango_python=$PANGO_PYTHON
elif [ -x "$pango_environment/venv/bin/python" ]; then
    pango_python="$pango_environment/venv/bin/python"
elif [ -x "$pango_script_dir/../build/calibration-venv/bin/python" ]; then
    pango_python="$pango_script_dir/../build/calibration-venv/bin/python"
elif command -v python3.12 >/dev/null 2>&1; then
    pango_python=python3.12
else
    pango_python=python3
fi
if ! command -v "$pango_python" >/dev/null 2>&1; then
    printf '%s\n' '[Pango] Python 3.12 or newer is required. Install python3 or set PANGO_PYTHON.' >&2
    exit 2
fi
if ! "$pango_python" -I -B -c 'import sys; sys.exit(sys.version_info[:2] < (3, 12))'; then
    printf '%s\n' '[Pango] Python 3.12 or newer is required; check PANGO_PYTHON / python3.' >&2
    exit 2
fi
exec "$pango_python" -X utf8 -B "$pango_script_dir/web.py" "$@"
