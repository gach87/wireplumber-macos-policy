#!/bin/sh
set -e
SCRIPTS="${XDG_DATA_HOME:-$HOME/.local/share}/wireplumber/scripts"
CONFD="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
rm -f "$SCRIPTS/preferred-devices.lua" \
      "$CONFD/90-preferred-devices.conf" "$CONFD/91-bt-profile.conf"
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/audio-preferred-devices"
systemctl --user restart wireplumber
echo "Uninstalled."
