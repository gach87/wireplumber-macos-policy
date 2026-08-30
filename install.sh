#!/bin/sh
# Installs the component for the current user.
#
# The script is always updated; it is the code. Configuration files are only
# written if absent: overwriting them would silently discard local settings
# such as preferred-devices.no-arrival. When a shipped config differs from the
# installed one it is written alongside as .new and you are told. Files ending
# in .new are not loaded by WirePlumber, which matches only *.conf.
#
# The install is transactional. A malformed .conf stops WirePlumber from
# starting outright, so if it does not come back up everything is put back
# exactly as it was. Deleting instead of restoring is not enough: a config left
# from an earlier install declares the component as required, so removing only
# the script leaves WirePlumber unable to start at all.
set -e

SCRIPTS="${XDG_DATA_HOME:-$HOME/.local/share}/wireplumber/scripts"
CONFD="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPTS/preferred-devices.lua"

backup=$(mktemp -d)
created=""
had_script=0

restore () {
    if [ "$had_script" -eq 1 ]; then
        cp "$backup/preferred-devices.lua" "$SCRIPT"
    else
        rm -f "$SCRIPT"
    fi
    if [ -n "$created" ]; then
        # shellcheck disable=SC2086
        rm -f $created
    fi
    rm -rf "$backup"
}

mkdir -p "$SCRIPTS" "$CONFD"
if [ -e "$SCRIPT" ]; then
    cp "$SCRIPT" "$backup/preferred-devices.lua"
    had_script=1
fi
cp "$HERE/src/preferred-devices.lua" "$SCRIPT"

kept=0
for src in "$HERE"/src/config/*.conf; do
    name=$(basename "$src")
    dst="$CONFD/$name"
    if [ ! -e "$dst" ]; then
        cp "$src" "$dst"
        created="$created $dst"
    elif cmp -s "$src" "$dst"; then
        :                                  # identical, nothing to do
    else
        cp "$src" "$dst.new"
        created="$created $dst.new"
        echo "  kept your $name (shipped version written as $name.new)"
        kept=1
    fi
done

echo "Installed. Applying:"
# 'restart' returns non-zero when the unit is already in a failed state or hits
# systemd's start limit. Under set -e that would abort before anything could be
# undone, leaving the system broken -- exactly the case this guards against.
systemctl --user reset-failed wireplumber >/dev/null 2>&1 || true
systemctl --user restart wireplumber || true
sleep 2

if systemctl --user is-active --quiet wireplumber; then
    echo "  wireplumber OK"
    [ "$kept" -eq 1 ] && echo "  review the .new files above for new options."
    echo
    echo "  If you had Bluetooth headphones connected, reconnect them:"
    echo "  restarting WirePlumber with them connected loses the A2DP endpoint."
    rm -rf "$backup"
    exit 0
fi

echo "  ERROR: wireplumber did not start. Rolling back..." >&2
restore
systemctl --user reset-failed wireplumber >/dev/null 2>&1 || true
systemctl --user restart wireplumber || true
sleep 2
if systemctl --user is-active --quiet wireplumber; then
    echo "  rolled back; wireplumber is running again." >&2
else
    echo "  ROLLBACK FAILED: wireplumber is still down. Check:" >&2
    echo "    journalctl --user -u wireplumber -n 30" >&2
fi
exit 1
