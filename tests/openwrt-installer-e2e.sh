#!/bin/sh
# Executed only inside a disposable x86_64 OpenWrt 25.12.6 QEMU VM.
# Real apk/procd, real installer, genuine candidate init. Podkop and worker
# are harmless local fixtures. NEVER run on a production router.
set -eu
grep -q "DISTRIB_RELEASE='25.12.6'" /etc/openwrt_release
grep -q "DISTRIB_TARGET='x86/64'" /etc/openwrt_release
[ -r /mnt/pg-bundle/install.sh ]
[ -r /mnt/pg-bundle/podkop-guard.init ]
apk info -e procd >/dev/null
apk info -e busybox >/dev/null
test ! -e /etc/init.d/podkop-guard
test ! -e /usr/bin/podkop-guard

mkdir -p /tmp/pg-e2e/bin /tmp/pg-e2e/fixture /etc/podkop-guard
printf 'unchanged-LKG' > /etc/podkop-guard/lkg-marker
cat > /etc/init.d/podkop <<'SH'
#!/bin/sh
exit 0
SH
chmod 0755 /etc/init.d/podkop

# The VM's apk package database is real. Suppress external package downloads:
# curl/jq are marked available by this narrow wrapper, not installed.
cat > /tmp/pg-e2e/bin/apk <<'SH'
#!/bin/sh
if [ "$1" = info ] && [ "$2" = -e ]; then
    case "$3" in
        curl|jq) printf '%s\n' "$3"; exit 0 ;;
    esac
fi
case "$1" in
    add|update) echo 'UNEXPECTED apk write in isolated test' >&2; exit 25 ;;
esac
exec /usr/bin/apk "$@"
SH
cat > /tmp/pg-e2e/bin/curl <<'SH'
#!/bin/sh
dest=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift; dest=$1 ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
case "$url" in
    */podkop-guard) cp /tmp/pg-e2e/fixture/new-worker "$dest" ;;
    */podkop-guard.init)
        cp /mnt/pg-bundle/podkop-guard.init "$dest" ;;
    *) echo "unexpected mocked URL: $url" >&2; exit 20 ;;
esac
SH
cat > /tmp/pg-e2e/bin/podkop <<'SH'
#!/bin/sh
exit 0
SH
cat > /tmp/pg-e2e/bin/sing-box <<'SH'
#!/bin/sh
exit 0
SH
chmod +x /tmp/pg-e2e/bin/*
export PATH="/tmp/pg-e2e/bin:$PATH"
export PODKOP_GUARD_BASE_URL=https://fixtures.invalid/guard
export PODKOP_GUARD_INSTALL_TEST_ROOT=/

cat > /tmp/pg-e2e/fixture/old-worker <<'SH'
#!/bin/sh
# podkop-guard - persistent Last Known Good protection for Podkop/OpenWrt
VERSION="0.2.4"
# PG_E2E_OLD_WORKER
case "${1:-}" in
    boot-restore) exit 0 ;;
    daemon|watchdog-observe)
        while :; do sleep 30; done ;;
    status) echo "VM fixture: old worker" ;;
    *) exit 0 ;;
esac
SH
cat > /tmp/pg-e2e/fixture/new-worker <<'SH'
#!/bin/sh
# podkop-guard - persistent Last Known Good protection for Podkop/OpenWrt
VERSION="0.3.0-dev"
# PG_E2E_NEW_WORKER
case "${1:-}" in
    boot-restore) exit 0 ;;
    daemon|watchdog-observe)
        while :; do sleep 30; done ;;
    status) echo "VM fixture: new worker" ;;
    *) exit 0 ;;
esac
SH
cat > /tmp/pg-e2e/fixture/old-init <<'SH'
#!/bin/sh /etc/rc.common
# PG_E2E_OLD_INIT
START=98
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/podkop-guard daemon
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
SH
cp /tmp/pg-e2e/fixture/old-worker /usr/bin/podkop-guard
cp /tmp/pg-e2e/fixture/old-init /etc/init.d/podkop-guard
chmod 0755 /usr/bin/podkop-guard /etc/init.d/podkop-guard

assert_old() {
    grep -q PG_E2E_OLD_WORKER /usr/bin/podkop-guard
    grep -q PG_E2E_OLD_INIT /etc/init.d/podkop-guard
    /etc/init.d/podkop-guard enabled
    /etc/init.d/podkop-guard running
    [ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
}
assert_new() {
    grep -q PG_E2E_NEW_WORKER /usr/bin/podkop-guard
    grep -q 'procd_open_instance watchdog' /etc/init.d/podkop-guard
    /etc/init.d/podkop-guard enabled
    /etc/init.d/podkop-guard running
    [ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
}

# Real /etc/rc.common, real ubus & procd, no mocked service commands.
/etc/init.d/podkop-guard enable
/etc/init.d/podkop-guard start
assert_old
ubus call service list '{"name":"podkop-guard"}' | grep -q '"instance1"'
echo PASS_VM_OLD_PROCD

PODKOP_GUARD_PREFLIGHT_ONLY=1 \
    sh /mnt/pg-bundle/install.sh >/tmp/pg-e2e/preflight.log 2>&1
grep -q 'PREFLIGHT_PASS.*existing=1 running=1 enabled=1' \
    /tmp/pg-e2e/preflight.log
assert_old
echo PASS_VM_PREFLIGHT

# Failure injection is allowed ONLY here because TEST_ROOT=/ is explicitly set.
for stage in after_worker after_init after_start; do
    export PODKOP_GUARD_TEST_FAILURE="$stage"
    if sh /mnt/pg-bundle/install.sh >/tmp/pg-e2e/failure.log 2>&1; then
        echo "FAIL: injected update unexpectedly succeeded: $stage" >&2
        exit 1
    fi
    unset PODKOP_GUARD_TEST_FAILURE
    grep -q 'Original Guard files and service state restored' \
        /tmp/pg-e2e/failure.log || {
        cat /tmp/pg-e2e/failure.log >&2
        exit 1
    }
    assert_old
    ubus call service list '{"name":"podkop-guard"}' | grep -q '"instance1"'
    echo "PASS_VM_ROLLBACK_$stage"
done

sh /mnt/pg-bundle/install.sh >/tmp/pg-e2e/install.log 2>&1 || {
    cat /tmp/pg-e2e/install.log >&2
    exit 1
}
assert_new
ubus call service list '{"name":"podkop-guard"}' | grep -q '"instance1"'
if ubus call service list '{"name":"podkop-guard"}' | grep -q '"watchdog"'; then
    echo 'FAIL: watchdog must remain disabled by default' >&2
    exit 1
fi
echo PASS_VM_UPGRADE

# Opt-in under real procd, then opt out. Both runs are VM-local.
uci -q set podkop_guard.settings=guard
uci -q set podkop_guard.settings.watchdog_enabled=1
/etc/init.d/podkop-guard restart
ubus call service list '{"name":"podkop-guard"}' | grep -q '"instance1"'
ubus call service list '{"name":"podkop-guard"}' | grep -q '"watchdog"'
echo PASS_VM_WATCHDOG_OPT_IN

uci -q set podkop_guard.settings.watchdog_enabled=0
/etc/init.d/podkop-guard restart
ubus call service list '{"name":"podkop-guard"}' | grep -q '"instance1"'
if ubus call service list '{"name":"podkop-guard"}' | grep -q '"watchdog"'; then
    echo 'FAIL: watchdog still registered after opt-out' >&2
    exit 1
fi
echo PASS_VM_WATCHDOG_OPT_OUT
/etc/init.d/podkop-guard stop
echo OPENWRT_INSTALLER_E2E_PASS
