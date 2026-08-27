#!/bin/sh

set -u

INIT="/etc/init.d/podkop-guard"
WORKER="/usr/bin/podkop-guard"
STATE_DIR="/etc/podkop-guard"
LKG_SUBNETS="$STATE_DIR/lkg-subnets.lst"
KEEP_LKG="${KEEP_LKG:-0}"

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

[ "$(id -u)" = "0" ] || {
    printf '[ERROR] Run this uninstaller as root.\n' >&2
    exit 1
}

if [ -x "$INIT" ]; then
    info "Stopping and disabling podkop-guard..."
    "$INIT" stop >/dev/null 2>&1 || true
    "$INIT" disable >/dev/null 2>&1 || true
fi

if command -v uci >/dev/null 2>&1; then
    if uci -q get podkop.main.local_subnet_lists 2>/dev/null | tr ' ' '\n' | grep -Fxq "$LKG_SUBNETS"; then
        info "Removing podkop-guard Local Subnet List entry from Podkop..."
        uci -q del_list "podkop.main.local_subnet_lists=$LKG_SUBNETS" >/dev/null 2>&1 || \
            warn "Could not remove ${LKG_SUBNETS} from podkop.main.local_subnet_lists."
        uci commit podkop >/dev/null 2>&1 || warn "Could not commit Podkop configuration."
        warn "Podkop was not reloaded automatically. Reload it manually when convenient."
    fi
fi

rm -f "$INIT" "$WORKER"
rm -f /etc/rc.d/S98podkop-guard /etc/rc.d/K01podkop-guard 2>/dev/null || true

if [ "$KEEP_LKG" = "1" ]; then
    info "Keeping persistent LKG data in ${STATE_DIR}."
else
    rm -rf "$STATE_DIR"
    info "Removed persistent LKG data from ${STATE_DIR}."
fi

info "podkop-guard uninstalled."
