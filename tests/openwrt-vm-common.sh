#!/bin/sh
# Shared preflight and real package database helpers for disposable QEMU.
# Sourced by VM tests before any state changes; never source on a router.
[ "${PG_DISPOSABLE_VM:-}" = 1 ] || { echo 'FAIL VM opt-in missing' >&2; exit 1; }
case "${PG_VM_RELEASE:-}" in
    24.10.5) PG_VM_PKG=opkg ;;
    25.12.6) PG_VM_PKG=apk ;;
    *) echo 'FAIL unsupported VM release' >&2; exit 1 ;;
esac
grep -Fxq "DISTRIB_RELEASE='$PG_VM_RELEASE'" /etc/openwrt_release
grep -Fxq "DISTRIB_TARGET='x86/64'" /etc/openwrt_release
grep -Eq 'QEMU|Bochs' /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name
grep -Eq ' /mnt/pg-bundle ext4 ro[, ]' /proc/mounts
PG_VM_REAL_PKG=$(command -v "$PG_VM_PKG")
case "$PG_VM_REAL_PKG" in /*) ;; *) exit 1 ;; esac
case "$PG_VM_PKG" in
    opkg) ! command -v apk >/dev/null 2>&1 ;;
    apk) ! command -v opkg >/dev/null 2>&1 ;;
esac || { echo 'FAIL ambiguous VM package manager' >&2; exit 1; }
export PG_VM_PKG PG_VM_REAL_PKG

vm_pkg_installed() {
    case "$PG_VM_PKG" in
        apk) "$PG_VM_REAL_PKG" info -e "$1" >/dev/null ;;
        opkg) "$PG_VM_REAL_PKG" status "$1" | grep -q '^Status: install .* installed$' ;;
    esac
}
vm_pkg_update() {
    "$PG_VM_REAL_PKG" update
}
vm_pkg_install() {
    case "$PG_VM_PKG" in
        apk) "$PG_VM_REAL_PKG" add "$@" ;;
        opkg) "$PG_VM_REAL_PKG" install "$@" ;;
    esac
}
vm_pkg_version() {
    case "$PG_VM_PKG" in
        apk) "$PG_VM_REAL_PKG" info -v "$1" ;;
        opkg) "$PG_VM_REAL_PKG" status "$1" | grep -E '^(Package|Version|Status):' ;;
    esac
}
vm_pkg_installed procd
vm_pkg_installed busybox
printf 'VM_PLATFORM release=%s pkg_manager=%s\n' "$PG_VM_RELEASE" "$PG_VM_PKG"
