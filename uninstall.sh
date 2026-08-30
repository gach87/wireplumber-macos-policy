#!/bin/sh
# Removes the component. The preferred-device list is KEPT by default: it is
# the ordering you built up by using the machine, and losing it to a reinstall
# would be rude. Pass --purge to delete it too.
set -e

SCRIPTS="${XDG_DATA_HOME:-$HOME/.local/share}/wireplumber/scripts"
CONFD="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/audio-preferred-devices"

rm -f "$SCRIPTS/preferred-devices.lua" \
      "$CONFD/90-preferred-devices.conf" "$CONFD/90-preferred-devices.conf.new" \
      "$CONFD/91-bt-profile.conf" "$CONFD/91-bt-profile.conf.new" \
      "$CONFD/92-no-automute.conf" "$CONFD/92-no-automute.conf.new"

if [ "${1:-}" = "--purge" ]; then
    rm -f "$STATE"
    echo "Uninstalled, preferred-device list removed."
else
    echo "Uninstalled. Your preferred-device list is kept at:"
    echo "  $STATE"
    echo "Pass --purge to remove it as well."
fi

systemctl --user restart wireplumber || true
