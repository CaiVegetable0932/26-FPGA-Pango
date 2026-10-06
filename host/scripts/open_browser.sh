#!/bin/sh
# Reuse a tab in the prepared browser profile. All login/manual entries share
# the same serialized opener; sandbox disabling remains an explicit test option.
set -eu
pango_script_dir=$(cd -P -- "$(dirname -- "$0")" >/dev/null && pwd)
pango_environment="$pango_script_dir/../build/environment"
pango_chrome=
for pango_candidate in "$pango_environment"/browsers/chromium-*/chrome-linux-arm64/chrome "$pango_environment"/browsers/chromium-*/chrome-linux/chrome "$pango_environment"/browsers/chromium-*/chrome-linux64/chrome; do
    if [ -x "$pango_candidate" ]; then
        pango_chrome=$pango_candidate
        break
    fi
done
if [ -z "$pango_chrome" ]; then
    printf '%s\n' 'Prepared Chromium is missing; see host/docs/本机环境配置.md.' >&2
    exit 2
fi
# Keep special browser command-line invocations compatible; normal URL opens
# use the prepared Python helper to focus an existing tab without reloading it.
if [ "$#" = 1 ]; then
    exec "$pango_environment/venv/bin/python" -B "$pango_script_dir/open_browser.py" --chrome "$pango_chrome" "$1"
fi
# Special invocations retain the old explicit sandbox test switch.
if [ "${PANGO_BROWSER_TEST_NO_SANDBOX:-0}" = 1 ]; then
    set -- --no-sandbox "$@"
fi
exec "$pango_chrome" --user-data-dir="$pango_environment/browser-profile" --no-first-run --no-default-browser-check "$@"
