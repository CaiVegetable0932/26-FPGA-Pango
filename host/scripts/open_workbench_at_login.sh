#!/bin/sh
# Restore the normal user service and existing browser profile after desktop
# login. Wait for loopback readiness; never run a camera client as root.
set -eu
pango_host=/home/cai/26-FPGA-Pango/26-FPGA-Pango/host
systemctl --user start pango-host.service
pango_attempt=0
while [ "$pango_attempt" -lt 60 ]; do
    if curl -fsS --max-time 2 http://127.0.0.1:8765/api/session >/dev/null 2>&1; then
        exec /usr/bin/sh "$pango_host/scripts/open_browser.sh" http://127.0.0.1:8765/
    fi
    pango_attempt=$((pango_attempt + 1))
    sleep 1
done
printf '%s\n' 'Pango workbench did not become ready; inspect pango-host.service.' >&2
exit 1
