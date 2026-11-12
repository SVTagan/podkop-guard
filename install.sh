#!/bin/sh
set -u

TAG="podkop-guard"
VERSION="0.2.4"
DEFAULT_REF="v${VERSION}"
BASE_URL="${PODKOP_GUARD_BASE_URL:-https://raw.githubusercontent.com/SVTagan/podkop-guard/${DEFAULT_REF}}"

# Tests may substitute a fully isolated filesystem tree. In production this
# variable is unset, so no destination path can change from OpenWrt defaults.
TEST_ROOT="${PODKOP_GUARD_INSTALL_TEST_ROOT:-}"
WORKER_DST="${TEST_ROOT}/usr/bin/podkop-guard"
INIT_DST="${TEST_ROOT}/etc/init.d/podkop-guard"
PODKOP_INIT="${TEST_ROOT}/etc/init.d/podkop"
OPENWRT_RELEASE="${TEST_ROOT}/etc/openwrt_release"
STATE_DIR="${TEST_ROOT}/etc/podkop-guard"
PKG_MANAGER=""

WORK_DIR=""
TMP_WORKER=""
TMP_INIT=""
STAGE_WORKER=""
STAGE_INIT=""
BACKUP_WORKER=""
BACKUP_INIT=""
HAD_WORKER=0
HAD_INIT=0
EXISTING_INSTALL=0
WAS_RUNNING=0
WAS_ENABLED=0
TRANSACTION_ACTIVE=0
TRANSACTION_COMMITTED=0
ROLLBACK_IN_PROGRESS=0
KEEP_RECOVERY_FILES=0

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

if [ -n "$TEST_ROOT" ]; then
    [ -d "$TEST_ROOT" ] || fail "Test root does not exist."
else
    [ "$(id -u)" = 0 ] || fail "Run this installer as root."
fi
[ -r "$OPENWRT_RELEASE" ] || fail "This installer is intended for OpenWrt."
command -v uci >/dev/null 2>&1 || fail "uci is required."
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER=apk
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER=opkg
else
    fail "Neither apk nor opkg was found."
fi
info "Detected package manager: $PKG_MANAGER"

fetch() {
    local url="$1" dst="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -q -fsSL "$url" -o "$dst"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$dst" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dst" "$url"
    else
        return 127
    fi
}

pkg_installed() {
    if [ "$PKG_MANAGER" = apk ]; then
        apk info -e "$1" >/dev/null 2>&1
    else
        opkg status "$1" 2>/dev/null | grep -q '^Status: install .* installed$'
    fi
}
pkg_update() {
    if [ "$PKG_MANAGER" = apk ]; then apk update; else opkg update; fi
}
pkg_install() {
    if [ "$PKG_MANAGER" = apk ]; then apk add "$1"; else opkg install "$1"; fi
}

luci_present=0
luci_commands_ready=0
if pkg_installed luci-base || pkg_installed luci-app-commands; then
    luci_present=1
fi

need_pkg_update=0
pkg_installed curl || need_pkg_update=1
pkg_installed jq || need_pkg_update=1
if [ "$luci_present" -eq 1 ] && ! pkg_installed luci-app-commands; then
    need_pkg_update=1
fi
if [ "$need_pkg_update" -eq 1 ]; then
    if ! pkg_update; then
        warn "$PKG_MANAGER update failed; continuing with cached package lists."
    fi
fi
for package in curl jq; do
    if ! pkg_installed "$package"; then
        info "Installing $package..."
        pkg_install "$package" || fail "$package installation failed."
        pkg_installed "$package" || fail "$package is not installed after package-manager success."
    fi
done
if pkg_installed luci-app-commands; then
    luci_commands_ready=1
elif [ "$luci_present" -eq 1 ]; then
    if pkg_install luci-app-commands; then
        luci_commands_ready=1
    else
        warn "Optional luci-app-commands installation failed; proceeding."
    fi
fi

for cmd in logger nice sort cmp date mktemp grep tail touch sync sed head cp mv chmod tr; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required."
done
date -r "$OPENWRT_RELEASE" +%s >/dev/null 2>&1 ||
    fail "date must support '-r FILE +%s'."
command -v sing-box >/dev/null 2>&1 || fail "sing-box is required."
if ! command -v podkop >/dev/null 2>&1 && [ ! -x "$TEST_ROOT/usr/bin/podkop" ]; then
    fail "Podkop is not installed."
fi
[ -x "$PODKOP_INIT" ] || fail "Podkop init service not found."

# Never write the target files until all inputs and backups are verified.
WORK_DIR=$(mktemp -d "/tmp/${TAG}.install.XXXXXX") ||
    fail "Cannot create transaction directory."
chmod 0700 "$WORK_DIR" || fail "Cannot secure transaction directory."
TMP_WORKER="$WORK_DIR/worker"
TMP_INIT="$WORK_DIR/init"
BACKUP_WORKER="$WORK_DIR/worker.previous"
BACKUP_INIT="$WORK_DIR/init.previous"
STAGE_WORKER="${WORKER_DST}.stage.$$"
STAGE_INIT="${INIT_DST}.stage.$$"

restore_file() {
    local target="$1" backup="$2" previously_present="$3"
    if [ "$previously_present" -eq 1 ]; then
        [ -f "$backup" ] || return 1
        # Restore atomically and preserve the former mode and timestamps.
        local restore_stage="${target}.rollback.$"
        cp -p "$backup" "$restore_stage" && mv -f "$restore_stage" "$target"
    else
        rm -f "$target"
    fi
}
service_running() { [ -x "$INIT_DST" ] && "$INIT_DST" running >/dev/null 2>&1; }
service_enabled() { [ -x "$INIT_DST" ] && "$INIT_DST" enabled >/dev/null 2>&1; }

wait_stopped() {
    local elapsed=0
    while [ "$elapsed" -lt 75 ]; do
        service_running || return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}
wait_running() {
    local elapsed=0
    while [ "$elapsed" -lt 15 ]; do
        if service_running; then
            sleep 1
            service_running && return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}
stop_service() {
    [ -x "$INIT_DST" ] || return 0
    "$INIT_DST" stop >/dev/null 2>&1 || return 1
    wait_stopped
}
apply_service_state() {
    local running="$1" enabled="$2"
    if [ ! -x "$INIT_DST" ]; then
        [ "$running" -eq 0 ] && [ "$enabled" -eq 0 ]
        return $?
    fi
    if [ "$enabled" -eq 1 ]; then
        "$INIT_DST" enable >/dev/null 2>&1 || return 1
    else
        "$INIT_DST" disable >/dev/null 2>&1 || return 1
    fi
    if [ "$running" -eq 1 ]; then
        "$INIT_DST" start >/dev/null 2>&1 || return 1
        wait_running || return 1
    else
        stop_service || return 1
    fi
    if [ "$running" -eq 1 ]; then
        service_running || return 1
    else
        service_running && return 1
    fi
    if [ "$enabled" -eq 1 ]; then
        service_enabled || return 1
    else
        service_enabled && return 1
    fi
    return 0
}
rollback_update() {
    local ok=1
    [ "$ROLLBACK_IN_PROGRESS" -eq 0 ] || return 1
    ROLLBACK_IN_PROGRESS=1
    warn "Update incomplete; attempting restoration of the prior Guard."

    # After the old init was stopped and files swapped, the new process must
    # be stopped before its executable is restored. Never disturb Podkop.
    stop_service || ok=0
    restore_file "$WORKER_DST" "$BACKUP_WORKER" "$HAD_WORKER" || ok=0
    restore_file "$INIT_DST" "$BACKUP_INIT" "$HAD_INIT" || ok=0
    apply_service_state "$WAS_RUNNING" "$WAS_ENABLED" || ok=0
    ROLLBACK_IN_PROGRESS=0

    if [ "$ok" -eq 1 ]; then
        TRANSACTION_ACTIVE=0
        warn "Original Guard files and service state restored."
        return 0
    fi
    KEEP_RECOVERY_FILES=1
    warn "Automatic rollback incomplete; backups preserved at $WORK_DIR."
    return 1
}
cleanup() {
    [ -n "$STAGE_WORKER" ] && rm -f "$STAGE_WORKER"
    [ -n "$STAGE_INIT" ] && rm -f "$STAGE_INIT"
    [ -n "$WORKER_DST" ] && rm -f "${WORKER_DST}.rollback.$"
    [ -n "$INIT_DST" ] && rm -f "${INIT_DST}.rollback.$"
    if [ "$KEEP_RECOVERY_FILES" -eq 0 ]; then
        [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    fi
}
on_exit() {
    local code="$?"
    trap - EXIT INT TERM HUP
    if [ "$TRANSACTION_ACTIVE" -eq 1 ] &&
       [ "$TRANSACTION_COMMITTED" -eq 0 ] &&
       [ "$ROLLBACK_IN_PROGRESS" -eq 0 ]; then
        rollback_update || true
    fi
    cleanup
    exit "$code"
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'on_exit' EXIT

info "Fetching Guard worker and procd init..."
fetch "$BASE_URL/podkop-guard" "$TMP_WORKER" || fail "Worker download failed."
fetch "$BASE_URL/podkop-guard.init" "$TMP_INIT" || fail "Init download failed."
[ -s "$TMP_WORKER" ] && [ -s "$TMP_INIT" ] ||
    fail "Downloaded Guard file is empty."
/bin/sh -n "$TMP_WORKER" && /bin/sh -n "$TMP_INIT" ||
    fail "Downloaded Guard file failed syntax check."
grep -q '^# podkop-guard - persistent Last Known Good protection' "$TMP_WORKER" ||
    fail "Worker does not look like podkop-guard."
worker_version=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$TMP_WORKER" | head -n 1)
[ "$worker_version" = "$VERSION" ] ||
    fail "Worker version mismatch; expected $VERSION, got $worker_version."

[ -d "${WORKER_DST%/*}" ] && [ -d "${INIT_DST%/*}" ] ||
    fail "Installation destination directories are missing."
if [ -e "$WORKER_DST" ]; then
    HAD_WORKER=1
    cp -p "$WORKER_DST" "$BACKUP_WORKER" || fail "Cannot back up worker."
fi
if [ -e "$INIT_DST" ]; then
    HAD_INIT=1
    cp -p "$INIT_DST" "$BACKUP_INIT" || fail "Cannot back up init."
fi
[ "$HAD_INIT" -eq 0 ] || [ -x "$INIT_DST" ] ||
    fail "Existing init file is not executable; refusing unsafe migration."
if [ "$HAD_WORKER" -ne "$HAD_INIT" ]; then
    fail "Partial old Guard installation detected; refusing unverified migration."
fi
[ "$HAD_INIT" -eq 0 ] || EXISTING_INSTALL=1

# Stage on the same target filesystem to avoid partial in-place writes.
cp "$TMP_WORKER" "$STAGE_WORKER" && chmod 0755 "$STAGE_WORKER" ||
    fail "Cannot stage worker on target overlay."
cp "$TMP_INIT" "$STAGE_INIT" && chmod 0755 "$STAGE_INIT" ||
    fail "Cannot stage init on target overlay."
/bin/sh -n "$STAGE_WORKER" && /bin/sh -n "$STAGE_INIT" ||
    fail "Staged files failed syntax validation."

if [ "$EXISTING_INSTALL" -eq 1 ]; then
    service_running && WAS_RUNNING=1
    service_enabled && WAS_ENABLED=1
fi

# All preflight and backups complete. From here on EXIT can restore the old
# files/service, including failures due to an interruption or start failure.
TRANSACTION_ACTIVE=1
mkdir -p "$STATE_DIR" || fail "Could not create Guard state directory."
if [ "$EXISTING_INSTALL" -eq 1 ]; then
    stop_service || fail "Existing Guard refused to stop; aborting update."
fi
mv -f "$STAGE_WORKER" "$WORKER_DST" || fail "Worker replacement failed."
[ -z "$TEST_ROOT" ] || [ "${PODKOP_GUARD_TEST_FAILURE:-}" != after_worker ] ||
    fail "Injected failure after worker replacement."
mv -f "$STAGE_INIT" "$INIT_DST" || fail "Init replacement failed."
[ -z "$TEST_ROOT" ] || [ "${PODKOP_GUARD_TEST_FAILURE:-}" != after_init ] ||
    fail "Injected failure after init replacement."

# Existing running/enabled state survives upgrades. A fresh install stays
# STOPPED+DISABLED until the owner validates the first LKG snapshot.
apply_service_state "$WAS_RUNNING" "$WAS_ENABLED" ||
    fail "Installed service failed state verification."
[ -z "$TEST_ROOT" ] || [ "${PODKOP_GUARD_TEST_FAILURE:-}" != after_start ] ||
    fail "Injected failure after applying service state."
TRANSACTION_COMMITTED=1
TRANSACTION_ACTIVE=0
info "Guard files and service state committed successfully."


# LuCI changes are optional and made only AFTER committing the Guard update.
# A LuCI failure must not undo a validated worker/init installation.
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

info "Installed ${TAG} ${VERSION}."
printf '\n'
"$WORKER_DST" status || true
printf '\n'
if [ "$luci_present" -eq 1 ]; then
    if [ "$luci_commands_ready" -eq 1 ]; then
        printf 'LuCI: 4 authenticated custom commands configured (best effort).\n'
    else
        printf 'LuCI integration: unavailable; core Guard is unaffected.\n'
    fi
fi
if [ "$EXISTING_INSTALL" -eq 1 ]; then
    printf 'Previous Guard state preserved: running=%s enabled=%s\n' "$WAS_RUNNING" "$WAS_ENABLED"
else
    printf 'First installation: STOPPED and DISABLED. Validate LKG before enabling.\n'
fi
