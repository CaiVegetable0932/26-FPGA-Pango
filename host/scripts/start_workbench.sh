#!/bin/sh
# One manual entry: start/reuse the installed background service, verify the
# checkout's HTTP identity, then open/focus the shared workbench browser tab.
set -eu
pango_script_dir=$(cd -P -- "$(dirname -- "$0")" >/dev/null && pwd)
pango_python="$pango_script_dir/../build/environment/venv/bin/python"
if [ ! -x "$pango_python" ]; then
    printf '%s\n' 'Project runtime is missing; run host/scripts/setup_environment.sh first.' >&2
    exit 2
fi
exec "$pango_python" -B "$pango_script_dir/start_workbench.py" "$@"
