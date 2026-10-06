#!/bin/sh
# Install/remove a volatile udev exception for the diagnosed card only.
# Reload rules without triggering existing devices: the next physical cold
# insertion is the experiment. Never alter NVIDIA drivers or global USB policy.
set -eu
pango_host=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pango_source="$pango_host/config/99-pango-hagibis-no-autosuspend.rules"
pango_target=/run/udev/rules.d/99-pango-hagibis-no-autosuspend.rules
pango_action=${1:-}
if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'Run through pkexec or sudo.' >&2
    exit 2
fi
case "$pango_action" in
    enable)
        # Refuse to overwrite another rule with the same filename. Keep the
        # volatile installation scoped to the reviewed, checked-in candidate.
        if [ -e "$pango_target" ] && ! cmp -s "$pango_source" "$pango_target"; then
            printf '%s\n' 'Existing rule differs; refusing to overwrite it.' >&2
            exit 3
        fi
        install -d -m 0755 /run/udev/rules.d
        install -m 0644 "$pango_source" "$pango_target"
        udevadm control --reload-rules
        printf '%s\n' 'Temporary Hagibis rule loaded for the next cold insertion.'
        ;;
    disable)
        # Remove only our exact rule; currently attached devices are untouched.
        # Replug afterwards to restore the normal driver-selected PM settings.
        if [ -e "$pango_target" ]; then
            if ! cmp -s "$pango_source" "$pango_target"; then
                printf '%s\n' 'Existing rule differs; refusing to remove it.' >&2
                exit 3
            fi
            rm -- "$pango_target"
        fi
        udevadm control --reload-rules
        printf '%s\n' 'Temporary rule removed; replug the card to restore defaults.'
        ;;
    *)
        printf '%s\n' 'Usage: manage_hagibis_autosuspend.sh enable|disable' >&2
        exit 2
        ;;
esac
