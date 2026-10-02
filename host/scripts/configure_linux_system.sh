#!/bin/sh
# Run through local administrator authentication. Prepare only the UDP receive
# ceiling and serial group; preserve NVIDIA's packages and network addresses.
set -eu
if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'Run this script with sudo or pkexec.' >&2
    exit 2
fi
pango_user=${1:?Specify the desktop login name}
getent passwd "$pango_user" >/dev/null
getent group dialout >/dev/null
usermod -a -G dialout "$pango_user"
# The receiver requests 8 MiB. Linux also reports doubled accounting overhead;
# a 16 MiB ceiling permits that request without changing global default buffers.
cat > /etc/sysctl.d/90-pango-host.conf <<'PANGO_SYSCTL'
# Pango RAW8 receiver: allow application-requested UDP receive buffers.
net.core.rmem_max = 16777216
PANGO_SYSCTL
sysctl -w net.core.rmem_max=16777216
printf '%s\n' "Prepared dialout membership for $pango_user; a new login applies it."
