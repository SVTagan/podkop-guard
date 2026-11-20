#!/bin/sh
# Actual podkop-guard 0.3.0-dev source under REAL procd in disposable QEMU.
# No real Podkop/VPN routing. No network configuration changes.
set -eu

[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
[ -r /mnt/pg-bundle/podkop-guard ]
grep -q '^VERSION="0.3.0-dev"' /mnt/pg-bundle/podkop-guard
[ -r /mnt/pg-bundle/podkop-guard.init ]

# Give this disposable guest an outbound route through QEMU user-mode NAT.
# Stock OpenWrt images often treat their only NIC as static LAN (192.168.1.1),
# so a networkless boot test cannot reach official APK repositories.
guest_if=br-lan
ip link show "$guest_if" >/dev/null 2>&1 || guest_if=eth0
ip link set "$guest_if" up
ip addr add 10.0.2.15/24 dev "$guest_if" 2>/dev/null || true
ip route replace default via 10.0.2.2 dev "$guest_if"
printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf
printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf.d/resolv.conf.auto
echo "VM_NAT_READY interface=$guest_if"

# Use the real OpenWrt 25.12 APK database and install the real dependencies
# instead of simulating 'apk info -e'. This is inside QEMU only.
apk update
apk add curl jq sing-box

for dep in curl jq sing-box; do
    apk info -e "$dep" >/dev/null || {
        echo "FAIL_REAL_DEP_MISSING $dep" >&2
        exit 1
    }
done
command -v curl
command -v jq
command -v sing-box
sing-box version | head -n 1
echo PASS_VM_REAL_APK_DEPENDENCIES

# Stop the earlier harmless fixture worker before replacing its source.
# The init file remains the exact dev init from the checked-out branch.
/etc/init.d/podkop-guard stop
cp /mnt/pg-bundle/podkop-guard /usr/bin/podkop-guard
chmod 0755 /usr/bin/podkop-guard
[ "$(/usr/bin/podkop-guard version)" = 0.3.0-dev ]
[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
echo PASS_VM_REAL_WORKER_VERSION

# No LKG snapshot in this VM: boot-restore must skip safely. The real status
# command should report missing LKG and the expected configured interval.
/usr/bin/podkop-guard boot-restore
/usr/bin/podkop-guard status > /tmp/pg-real-status
grep -q '^podkop-guard 0.3.0-dev$' /tmp/pg-real-status
grep -q '^cache_snapshot=missing$' /tmp/pg-real-status
grep -q '^startup_grace=300$' /tmp/pg-real-status
echo PASS_VM_REAL_WORKER_LKG_NO_SNAPSHOT

# Verify real sing-box SRS and the Guard LKG verification/derivation APIs.
cat > /tmp/pg-real-srs.json <<'SH'
{"version":3,"rules":[{"domain_suffix":["example.test"]},{"ip_cidr":["192.0.2.0/24"]}]}
SH
if ! sing-box rule-set compile --output /etc/podkop-guard/lkg.srs /tmp/pg-real-srs.json; then
    echo FAIL_VM_SRS_COMPILE >&2
    exit 1
fi
echo PASS_VM_SRS_COMPILE
echo VM_SRS_INPUT
cat /tmp/pg-real-srs.json
sing-box rule-set decompile --output /tmp/pg-real-inspected.json /etc/podkop-guard/lkg.srs
echo VM_SRS_DECOMPILED
cat /tmp/pg-real-inspected.json
if ! /usr/bin/podkop-guard verify-lkg > /tmp/pg-real-verify 2>&1; then
    cat /tmp/pg-real-verify >&2
    echo FAIL_VM_GUARD_VERIFY >&2
    exit 1
fi
cat /tmp/pg-real-verify
if ! grep -q '^cidrs=1$' /tmp/pg-real-verify; then
    echo FAIL_VM_SRS_CIDR_COUNT >&2
    exit 1
fi
echo PASS_VM_SRS_VERIFY
if ! /usr/bin/podkop-guard derive-subnets; then
    echo FAIL_VM_GUARD_DERIVE >&2
    exit 1
fi
if ! grep -Fxq '192.0.2.0/24' /etc/podkop-guard/lkg-subnets.lst; then
    echo FAIL_VM_CIDR_DERIVE >&2
    exit 1
fi
[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
echo PASS_VM_REAL_SINGBOX_SRS_ROUNDTRIP

# Regression: domain/IP rule with an additional network constraint is
# conditional; a failed derivation must preserve the prior CIDR snapshot.
mkdir -p /tmp/pg-conditional-lkg
printf '198.51.100.0/24\n' > /tmp/pg-conditional-lkg/lkg-subnets.lst
cat > /tmp/pg-conditional-srs.json <<'SH'
{"version":3,"rules":[{"domain_suffix":["example.test"],"ip_cidr":["192.0.2.0/24"],"network":"tcp"}]}
SH
sing-box rule-set compile --output /tmp/pg-conditional-lkg/lkg.srs /tmp/pg-conditional-srs.json
if PODKOP_GUARD_DIR=/tmp/pg-conditional-lkg /usr/bin/podkop-guard derive-subnets     > /tmp/pg-conditional-derive.log 2>&1; then
    echo FAIL_VM_EXPORTED_CONDITIONAL_CIDR >&2
    exit 1
fi
grep -Fxq '198.51.100.0/24' /tmp/pg-conditional-lkg/lkg-subnets.lst
if grep -Fq '192.0.2.0/24' /tmp/pg-conditional-lkg/lkg-subnets.lst; then
    echo FAIL_VM_CONDITIONAL_SUBNET_LEAK >&2
    exit 1
fi
echo PASS_VM_CONDITIONAL_CIDR_SKIPPED

# No real Podkop or sing-box service is running. A one-shot observation must
# not fabricate HEALTHY. UNKNOWN or missing-process are valid here.
set +e
/usr/bin/podkop-guard watchdog-check > /tmp/pg-real-watch-check 2>&1
rc=$?
set -e
case "$rc" in 1|2) ;; *) echo "FAIL_REAL_CHECK_RC $rc" >&2; cat /tmp/pg-real-watch-check; exit 1 ;; esac
grep -q '^WATCHDOG state=' /tmp/pg-real-watch-check
if grep -q 'state=HEALTHY_SAMPLED' /tmp/pg-real-watch-check; then
    echo "FAIL_REAL_FALSE_HEALTHY" >&2
    exit 1
fi
# Stage 6B1: exercise metadata-only evidence on real OpenWrt/BusyBox.
# The QEMU guest has no usable Podkop or VPN. No live network probes.
if ! /usr/bin/podkop-guard watchdog-evidence > /tmp/pg-real-evidence 2>&1; then
    cat /tmp/pg-real-evidence >&2
    echo FAIL_VM_REAL_EVIDENCE >&2
    exit 1
fi
grep -q '^EVIDENCE local=' /tmp/pg-real-evidence
grep -Fq 'doh=UNKNOWN doh_source=not_probed mode=metadata' /tmp/pg-real-evidence
grep -Fq 'authority=observe-only action=none' /tmp/pg-real-evidence
grep -q '^CLASSIFY local_class=' /tmp/pg-real-evidence
# Local process suspicion must survive UNKNOWN WAN/VPN/DoH on real BusyBox.
sh /usr/bin/podkop-guard watchdog-classify SUSPECT_DNS_TIMEOUT UNKNOWN UNKNOWN UNKNOWN > /tmp/pg-local-classify
grep -Fq 'local_class=BOX_DNS_HUNG_CANDIDATE local_evidence=SUSPECT external_class=EXTERNAL_UNKNOWN' /tmp/pg-local-classify
grep -Fq 'authority=observe-only action=none' /tmp/pg-local-classify
echo PASS_VM_TWO_AXIS_LOCAL_INDEPENDENCE
[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
echo PASS_VM_REAL_EVIDENCE_METADATA_ONLY
# Actual OpenWrt procd service is queried, no sing-box instance is started.
# An unregistered instance must not be interpreted as a crash-loop.
procd_snapshot=$(/usr/bin/podkop-guard watchdog-procd-snapshot)
case "$procd_snapshot" in
    'PROCD_SNAPSHOT state=UNREGISTERED '* | 'PROCD_SNAPSHOT state=STOPPED '* | 'PROCD_SNAPSHOT state=UNKNOWN '* | 'PROCD_SNAPSHOT state=RUNNING '*) ;;
    *) echo "FAIL_VM_PROCD_UNEXPECTED $procd_snapshot" >&2; exit 1 ;;
esac
[ "${procd_snapshot##*action=}" = none ]
printf '%s\n' '{"instance.fail":{"service":"sing-box","instance":"sing-box.main","pid":1253,"exit_code":137,"respawn_count":6,"command":["/usr/bin/sing-box","run"]}}' |
    /usr/bin/podkop-guard watchdog-procd-event > /tmp/pg-real-procd-event
grep -Fq 'state=CRASH_LOOP_REPORTED source=procd pid=1253 exit_code=137 respawn_count=6 action=none' /tmp/pg-real-procd-event
echo PASS_VM_PROCD_EVENT_DECODER
# B2 actual BusyBox ash read -t + ubus subscriber + periodic procd status.
# The guest has no deployed Podkop runtime. No exit or restart is induced.
PODKOP_GUARD_PROCD_TMP_DIR=/tmp \
    /usr/bin/podkop-guard watchdog-procd-monitor 2 1 > /tmp/pg-procd-monitor
grep -q '^PROCD_MONITOR_END completed=2 attempts=' /tmp/pg-procd-monitor
grep -Fq 'history=INCOMPLETE action=none' /tmp/pg-procd-monitor
# BusyBox find may lack -quit; check the actual result and its exit status.
find /tmp -type d -name 'podkop-guard-procd.*' -print > /tmp/pg-procd-leftovers
[ ! -s /tmp/pg-procd-leftovers ]
echo PASS_VM_PROCD_SUBSCRIBE_BOUNDED



# Bounded observation has no recovery, regardless of missing VPN.
PODKOP_GUARD_WATCH_GRACE=180 \
    /usr/bin/podkop-guard watchdog-monitor 3 0 > /tmp/pg-real-monitor
grep -q '^MONITOR_END completed=3 confirmations=0 action=none$' /tmp/pg-real-monitor
echo PASS_VM_REAL_WORKER_OBSERVE_ONLY

# B3: deterministic local-fault fixtures under REAL OpenWrt BusyBox ash.
# No WAN, VPN, real DNS or service restarts are involved.
sh /mnt/pg-bundle/watchdog-check.sh /usr/bin/podkop-guard > /tmp/pg-b3-watch-tests
grep -Fq 'observer-only scenarios' /tmp/pg-b3-watch-tests
sh /mnt/pg-bundle/watchdog-monitor.sh /usr/bin/podkop-guard > /tmp/pg-b3-monitor-tests
grep -Fq 'deterministic monitor scenarios' /tmp/pg-b3-monitor-tests
echo PASS_VM_B3_LOCAL_NEGATIVE_FIXTURES
sh /mnt/pg-bundle/watchdog-deadline.sh /usr/bin/podkop-guard > /tmp/pg-b4-deadline
grep -Fq 'B4.1 bounded cases' /tmp/pg-b4-deadline
echo PASS_VM_B4_ISOLATED_DEADLINE


# The real LKG daemon starts with default 300s startup grace. It must remain
# running under real procd, without performing any refresh in this short test.
# The independent watchdog uses the same actual source, opt-in only.
uci -q set podkop_guard.settings.watchdog_enabled=1
/etc/init.d/podkop-guard start
sleep 2
svc=$(ubus call service list '{"name":"podkop-guard"}')
printf '%s\n' "$svc" | grep -q '"instance1"'
printf '%s\n' "$svc" | grep -q '"watchdog"'
printf '%s\n' "$svc" | grep -q '"running": true'
/etc/init.d/podkop-guard running
[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
echo PASS_VM_REAL_WORKER_PROCD_BOTH

# Do not wait 60 seconds to stop the long sleeping LKG worker: the bounded
# workflow terminates the disposable QEMU instance after the check.
echo OPENWRT_REAL_WORKER_E2E_PASS
