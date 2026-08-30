#!/bin/sh
# Installs the component for the current user.
set -e

SCRIPTS="${XDG_DATA_HOME:-$HOME/.local/share}/wireplumber/scripts"
CONFD="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

mkdir -p "$SCRIPTS" "$CONFD"
cp "$HERE/src/preferred-devices.lua" "$SCRIPTS/"
cp "$HERE/src/config/90-preferred-devices.conf" "$CONFD/"
cp "$HERE/src/config/91-bt-profile.conf" "$CONFD/"

echo "Installed. Applying:"
systemctl --user restart wireplumber
sleep 2
if systemctl --user is-active --quiet wireplumber; then
    echo "  wireplumber OK"
    echo
    echo "  If you had Bluetooth headphones connected, reconnect them:"
    echo "  restarting WirePlumber with them connected loses the A2DP endpoint."
else
    echo "  ERROR: wireplumber did not start. Rolling back..." >&2
    rm -f "$CONFD/90-preferred-devices.conf" "$CONFD/91-bt-profile.conf"
    systemctl --user reset-failed wireplumber || true
    systemctl --user restart wireplumber
    exit 1
fi
