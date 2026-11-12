#!/bin/sh
# Runs ONLY in a disposable OpenWrt 25.12.6 x86_64 VM.
# Unlike the installer E2E, uses real podkop-guard 0.3.0-dev and real
# OpenWrt apk-installed curl, jq and sing-box. No live Podkop/VPN is present.
set -eu
grep -q "DISTRIB_RELEASE='25.12.6'" /etc/openwrt_release
grep -q "DISTRIB_TARGET='x86/64'" /etc/openwrt_release
[ -r /mnt/pg-bundle/podkop-guard ]
[ ! -e /tmp/pg-real-worker ]
/etc/init.d/podkop-guard running && {
    echo 'FAIL: prior fixture service still running' >&2
    exit 1
}
: >/tmp/pg-real-worker.install.log
if ! apk -U add curl jq sing-box >/tmp/pg-real-worker.install.log 2>&1; then
    echo 'FAIL: apk -U add curl jq sing-box (real dependencies)' >&2
    tail -n 45 /tmp/pg-real-worker.install.log >&2
    exit 1
fi
for package in curl jq sing-box; do
    apk info -e "$package" >/dev/null || {
        echo "FAIL: missing real $package package" >&2
        exit 1
    }
done
for cmd in curl jq sing-box logger nice sort cmp date mktemp grep tail touch sync jsonfilter ubus nft nslookup; do
    command -v "$cmd" >/dev/null || {
        echo "FAIL: $cmd not available on real VM" >&2
        exit 1
    }
done
sing-box version | head -n 2
printf 'PASS_REAL_APK_DEPS\n'

cp /mnt/pg-bundle/podkop-guard /usr/bin/podkop-guard
chmod 0755 /usr/bin/podkop-guard
sh -n /usr/bin/podkop-guard
[ "$(/usr/bin/podkop-guard version)" = '0.3.0-dev' ]
echo PASS_REAL_WORKER_VERSION

# Test actual LKG functions using the actual sing-box ruleset codec, jq, awk
# and BusyBox. Work in /tmp to avoid contaminating the Guard state directory.
mkdir -p /tmp/pg-real-worker
cat > /tmp/pg-real-worker/rules.json <<'JSON'
{
  "version": 3,
  "rules": [
    {
      "domain_suffix": ["example.invalid"],
      "ip_cidr": ["198.51.100.0/24", "203.0.113.0/24"]
    }
  ]
}
JSON
sing-box rule-set compile --output /tmp/pg-real-worker/lkg.srs /tmp/pg-real-worker/rules.json
PODKOP_GUARD_DIR=/tmp/pg-real-worker /usr/bin/podkop-guard verify-lkg \
    >/tmp/pg-real-worker/verify.log
grep -q '^rules=1$' /tmp/pg-real-worker/verify.log
grep -q '^cidrs=2$' /tmp/pg-real-worker/verify.log
PODKOP_GUARD_DIR=/tmp/pg-real-worker /usr/bin/podkop-guard derive-subnets \
    >/tmp/pg-real-worker/derive.log
grep -q '^198.51.100.0/24$' /tmp/pg-real-worker/lkg-subnets.lst
grep -q '^203.0.113.0/24$' /tmp/pg-real-worker/lkg-subnets.lst
[ "$(wc -l < /tmp/pg-real-worker/lkg-subnets.lst)" -eq 2 ]
echo PASS_REAL_SRS_COMPILE_DECOMPILE_DERIVE

# No sing-box instance with Podkop's runtime config is running; the guard must
# not claim routing health based merely on the installed sing-box binary.
set +e
PODKOP_GUARD_DIR=/tmp/pg-real-worker /usr/bin/podkop-guard watchdog-check \
    >/tmp/pg-real-worker/watch.log 2>&1
check_rc=$?
set -e
[ "$check_rc" -eq 1 ] || [ "$check_rc" -eq 2 ]
grep -q '^WATCHDOG state=' /tmp/pg-real-worker/watch.log
if grep -q 'state=HEALTHY_SAMPLED' /tmp/pg-real-worker/watch.log; then
    echo 'FAIL: false HEALTHY without a Podkop runtime' >&2
    exit 1
fi
echo PASS_REAL_WATCHDOG_NO_FALSE_HEALTH

# This starts the actual LKG worker with the VM's real dependencies. With no
# LKG snapshot and a 300-second grace it will not perform any network refresh.
: > /etc/config/podkop_guard
uci set podkop_guard.settings=guard
uci set podkop_guard.settings.watchdog_enabled=0
/etc/init.d/podkop-guard start
sleep 3
/etc/init.d/podkop-guard running
ubus call service list '{"name":"podkop-guard"}' | grep -q '"instance1"'
[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
echo PASS_REAL_WORKER_PROCD

uci set podkop_guard.settings.watchdog_enabled=1
/etc/init.d/podkop-guard restart
sleep 3
ubus call service list '{"name":"podkop-guard"}' | grep -q '"instance1"'
ubus call service list '{"name":"podkop-guard"}' | grep -q '"watchdog"'
/etc/init.d/podkop-guard running
echo PASS_REAL_OBSERVER_PROCD_OPT_IN

uci set podkop_guard.settings.watchdog_enabled=0
/etc/init.d/podkop-guard restart
ubus call service list '{"name":"podkop-guard"}' | grep -q '"instance1"'
if ubus call service list '{"name":"podkop-guard"}' | grep -q '"watchdog"'; then
    echo 'FAIL: opt-out left a watchdog instance' >&2
    exit 1
fi
/etc/init.d/podkop-guard stop
echo PASS_REAL_OBSERVER_PROCD_OPT_OUT
echo OPENWRT_REAL_WORKER_PASS
