#!/bin/sh
# Project FFmpeg/V4L2 binaries use Ubuntu libraries extracted beside them.
# Keep this library override inside the tool process, rather than the shell.
set -eu
pango_environment=$(cd -P -- "$(dirname -- "$0")/.." >/dev/null && pwd)
pango_program=$(basename -- "$0")
export LD_LIBRARY_PATH="$pango_environment/system/usr/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$pango_environment/system/usr/bin/$pango_program" "$@"
