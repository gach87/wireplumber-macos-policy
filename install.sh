#!/bin/sh
# Instala el componente para el usuario actual.
set -e

SCRIPTS="${XDG_DATA_HOME:-$HOME/.local/share}/wireplumber/scripts"
CONFD="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

mkdir -p "$SCRIPTS" "$CONFD"
cp "$HERE/src/preferred-devices.lua" "$SCRIPTS/"
cp "$HERE/src/config/90-preferred-devices.conf" "$CONFD/"
cp "$HERE/src/config/91-bt-profile.conf" "$CONFD/"

echo "Instalado. Aplicando:"
systemctl --user restart wireplumber
sleep 2
if systemctl --user is-active --quiet wireplumber; then
    echo "  wireplumber OK"
    echo
    echo "  Si tenias auriculares Bluetooth conectados, reconectalos:"
    echo "  reiniciar WirePlumber con el BT conectado pierde el endpoint A2DP."
else
    echo "  ERROR: wireplumber no arranco. Deshaciendo..." >&2
    rm -f "$CONFD/90-preferred-devices.conf" "$CONFD/91-bt-profile.conf"
    systemctl --user reset-failed wireplumber || true
    systemctl --user restart wireplumber
    exit 1
fi
