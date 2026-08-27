#!/bin/sh

set -u

TAG="podkop-guard"
BASE_URL="${PODKOP_GUARD_BASE_URL:-https://raw.githubusercontent.com/SVTagan/podkop-guard/main}"
WORKER_DST="/usr/bin/podkop-guard"
INIT_DST="/etc/init.d/podkop-guard"
STATE_DIR="/etc/podkop-guard"

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || fail "Run this installer as root."
[ -r /etc/openwrt_release ] || fail "This installer is intended for OpenWrt."
command -v uci >/dev/null 2>&1 || fail "uci is required."
command -v opkg >/dev/null 2>&1 || fail "This installer currently targets OpenWrt systems using opkg."

fetch() {
    local url="$1" dst="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dst"
        return $?
    fi

    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$dst" "$url"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$dst" "$url"
        return $?
    fi

    return 127
}

pkg_installed() {
    opkg status "$1" 2>/dev/null | grep -q '^Status: install .* installed$'
}

luci_present=0
luci_commands_ready=0
if pkg_installed luci-base || pkg_installed luci-app-commands; then
    luci_present=1
fi

need_opkg_update=0
pkg_installed curl || need_opkg_update=1
pkg_installed jq || need_opkg_update=1
if [ "$luci_present" -eq 1 ] && ! pkg_installed luci-app-commands; then
    need_opkg_update=1
fi

if [ "$need_opkg_update" -eq 1 ]; then
    info "Updating opkg package lists..."
    if ! opkg update; then
        warn "opkg update reported errors; continuing with available package lists."
    fi
fi

if ! pkg_installed curl; then
    info "Installing curl..."
    opkg install curl || fail "curl installation failed."
fi

if ! pkg_installed jq; then
    info "Installing jq..."
    opkg install jq || fail "jq installation failed."
fi

# LuCI integration is optional for the core guard. On routers that already use
# LuCI, install luci-app-commands when possible and expose the safe CLI actions
# there. A feed/package problem must not make the core recovery helper fail.
if pkg_installed luci-app-commands; then
    luci_commands_ready=1
elif [ "$luci_present" -eq 1 ]; then
    info "Installing optional luci-app-commands integration..."
    if opkg install luci-app-commands; then
        luci_commands_ready=1
    else
        warn "Could not install luci-app-commands; continuing without LuCI Custom Commands."
    fi
fi

for cmd in logger nice sort cmp date mktemp grep tail touch sync; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required."
done

# BusyBox date -r is used to read the mtime of the last successful cache
# snapshot. This avoids depending on a separate GNU/coreutils stat package.
date -r /etc/openwrt_release +%s >/dev/null 2>&1 || \
    fail "date must support '-r FILE +%s' to read file modification time."

command -v sing-box >/dev/null 2>&1 || fail "sing-box is required. Install Podkop/sing-box first."
if ! command -v podkop >/dev/null 2>&1 && [ ! -x /usr/bin/podkop ]; then
    fail "Podkop is not installed."
fi
[ -x /etc/init.d/podkop ] || fail "Podkop init service was not found at /etc/init.d/podkop."

TMP_WORKER="/tmp/${TAG}.worker.$$"
TMP_INIT="/tmp/${TAG}.init.$$"
trap 'rm -f "$TMP_WORKER" "$TMP_INIT"' EXIT INT TERM

info "Downloading podkop-guard worker..."
fetch "${BASE_URL}/podkop-guard" "$TMP_WORKER" || fail "Failed to download worker from ${BASE_URL}."

info "Downloading procd init script..."
fetch "${BASE_URL}/podkop-guard.init" "$TMP_INIT" || fail "Failed to download init script from ${BASE_URL}."

[ -s "$TMP_WORKER" ] || fail "Downloaded worker is empty."
[ -s "$TMP_INIT" ] || fail "Downloaded init script is empty."

/bin/sh -n "$TMP_WORKER" || fail "Downloaded worker failed shell syntax validation."
/bin/sh -n "$TMP_INIT" || fail "Downloaded init script failed shell syntax validation."
grep -q '^# podkop-guard - persistent Last Known Good protection' "$TMP_WORKER" || \
    fail "Downloaded worker does not look like podkop-guard."

existing_install=0
was_running=0
was_enabled=0

if [ -x "$INIT_DST" ]; then
    existing_install=1
    "$INIT_DST" running >/dev/null 2>&1 && was_running=1
    "$INIT_DST" enabled >/dev/null 2>&1 && was_enabled=1

    if [ "$was_running" -eq 1 ]; then
        info "Stopping existing podkop-guard service before update..."
        "$INIT_DST" stop >/dev/null 2>&1 || true
    fi
fi

mkdir -p "$STATE_DIR" || fail "Failed to create ${STATE_DIR}."
chmod 0755 "$STATE_DIR" || true

cp "$TMP_WORKER" "$WORKER_DST" || fail "Failed to copy ${WORKER_DST}."
chmod 0755 "$WORKER_DST" || fail "Failed to set permissions on ${WORKER_DST}."
cp "$TMP_INIT" "$INIT_DST" || fail "Failed to copy ${INIT_DST}."
chmod 0755 "$INIT_DST" || fail "Failed to set permissions on ${INIT_DST}."

configure_luci_command() {
    local section="$1" name="$2" command="$3" description="$4"

    uci set "luci.${section}=command" || return 1
    uci set "luci.${section}.name=${name}" || return 1
    uci set "luci.${section}.command=${command}" || return 1
    uci set "luci.${section}.param=0" || return 1
    uci set "luci.${section}.public=0" || return 1

    # Keep a user-customized description on upgrades; only provide a default
    # when the named section did not have one yet.
    if ! uci -q get "luci.${section}.description" >/dev/null 2>&1; then
        uci set "luci.${section}.description=${description}" || return 1
    fi
}

configure_luci_commands() {
    [ "$luci_commands_ready" -eq 1 ] || return 0

    configure_luci_command \
        podkop_guard_status \
        'Podkop Guard: Status' \
        '/usr/bin/podkop-guard status' \
        'Show current guard/LKG state, runtime status and intervals.' || return 1

    configure_luci_command \
        podkop_guard_verify \
        'Podkop Guard: Verify LKG' \
        '/usr/bin/podkop-guard verify-lkg' \
        'Validate and inspect the persistent LKG SRS.' || return 1

    configure_luci_command \
        podkop_guard_test \
        'Podkop Guard: Refresh Test' \
        '/usr/bin/podkop-guard refresh-test' \
        'Build and fully validate candidates without saving persistent LKG.' || return 1

    configure_luci_command \
        podkop_guard_refresh \
        'Podkop Guard: Refresh LKG' \
        '/usr/bin/podkop-guard refresh' \
        'Build, fully validate and save a new persistent LKG.' || return 1

    uci commit luci || return 1
    return 0
}

if [ "$luci_commands_ready" -eq 1 ]; then
    if configure_luci_commands; then
        info "Configured LuCI Custom Commands for podkop-guard."
    else
        warn "Could not configure LuCI Custom Commands; core podkop-guard installation will continue."
        luci_commands_ready=0
    fi
fi

if [ "$existing_install" -eq 1 ]; then
    if [ "$was_enabled" -eq 1 ]; then
        "$INIT_DST" enable >/dev/null 2>&1 || fail "Failed to restore autostart state."
    else
        "$INIT_DST" disable >/dev/null 2>&1 || true
    fi

    if [ "$was_running" -eq 1 ]; then
        info "Restoring running podkop-guard service..."
        "$INIT_DST" start >/dev/null 2>&1 || fail "Updated service could not be started."
    else
        "$INIT_DST" stop >/dev/null 2>&1 || true
    fi
else
    # First installation is deliberately inert until the user has built and
    # verified the initial LKG snapshot.
    "$INIT_DST" disable >/dev/null 2>&1 || true
    "$INIT_DST" stop >/dev/null 2>&1 || true
fi

rm -f "$TMP_WORKER" "$TMP_INIT"
trap - EXIT INT TERM

info "Installed ${TAG}."
printf '\n'
"$WORKER_DST" status || true
printf '\n'

if [ "$luci_present" -eq 1 ]; then
    if [ "$luci_commands_ready" -eq 1 ]; then
        printf 'LuCI integration: ENABLED (4 authenticated Custom Commands)\n'
    else
        printf 'LuCI integration: NOT CONFIGURED (core guard is unaffected)\n'
    fi
    printf '\n'
fi

if [ "$existing_install" -eq 1 ]; then
    printf 'Existing service state was preserved:\n'
    if [ "$was_running" -eq 1 ]; then
        printf '  Service:   RUNNING\n'
    else
        printf '  Service:   STOPPED\n'
    fi
    if [ "$was_enabled" -eq 1 ]; then
        printf '  Autostart: ENABLED\n'
    else
        printf '  Autostart: DISABLED\n'
    fi
else
    printf 'Safety state after first installation:\n'
    printf '  Service:   STOPPED\n'
    printf '  Autostart: DISABLED\n'
    printf '\n'
    printf 'Build and validate the first snapshot before enabling the service:\n'
    printf '  podkop-guard refresh-test\n'
    printf '  podkop-guard refresh\n'
    printf '\n'
    printf 'Then configure /etc/podkop-guard/lkg-subnets.lst as a Podkop Local Subnet List,\n'
    printf 'reload Podkop once, and only then enable/start podkop-guard. See README.md.\n'
fi
