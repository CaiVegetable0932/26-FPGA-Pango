#!/bin/sh
# Ubuntu/Linux entry point; paths and arguments may contain spaces.
set -eu
pango_script_dir=$(cd -P -- "$(dirname -- "$0")" >/dev/null && pwd)
pango_python=${PANGO_PYTHON:-python3}
if ! command -v "$pango_python" >/dev/null 2>&1; then
    printf '%s\n' '[Pango] Python 3.12 or newer is required. Install python3 or set PANGO_PYTHON.' >&2
    exit 2
fi
if ! "$pango_python" -I -B -c 'import sys; sys.exit(sys.version_info[:2] < (3, 12))'; then
    printf '%s\n' '[Pango] Python 3.12 or newer is required; check PANGO_PYTHON / python3.' >&2
    exit 2
fi
exec "$pango_python" -X utf8 -B "$pango_script_dir/web.py" "$@"
