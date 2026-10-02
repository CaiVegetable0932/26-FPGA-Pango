#!/bin/sh
# Open the prepared native browser with a separate profile, keeping desktop
# browser sessions independent. Sandbox disabling is an explicit test option.
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
if [ "${PANGO_BROWSER_TEST_NO_SANDBOX:-0}" = 1 ]; then
    set -- --no-sandbox "$@"
fi
exec "$pango_chrome" --user-data-dir="$pango_environment/browser-profile" --no-first-run --no-default-browser-check "$@"
