#!/usr/bin/env bash
# Source this file to use the project runtime without changing Jetson's Python.
pango_environment=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../build/environment" && pwd)
if [ ! -x "$pango_environment/venv/bin/python" ]; then
    printf '%s\n' 'Pango environment is not installed; see host/docs/本机环境配置.md.' >&2
    return 2
fi
export PANGO_PYTHON="$pango_environment/venv/bin/python"
export PLAYWRIGHT_BROWSERS_PATH="$pango_environment/browsers"
export PATH="$pango_environment/venv/bin:$pango_environment/bin:$pango_environment/node/bin:$PATH"
# Use a separate native browser profile if no desktop preference was provided.
if [ -z "${BROWSER:-}" ] && [ -d "$pango_environment/browsers" ]; then
    pango_browser_script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/open_browser.sh
    export BROWSER="\"$pango_browser_script\" %s &"
    unset pango_browser_script
fi
unset pango_environment
