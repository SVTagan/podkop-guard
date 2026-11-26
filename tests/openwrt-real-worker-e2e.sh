#!/bin/sh
# Actual podkop-guard 0.3.0-dev source under REAL procd in disposable QEMU.
# No real Podkop/VPN routing. No network configuration changes.
set -eu
. /mnt/pg-bundle/openwrt-vm-common.sh

# Both serial phases run in the same disposable guest. The B6 suite must
# inherit the completed core fixture, not recreate or repair its state.
boundary_manifest=/tmp/pg-worker-b6.sha256
verify_split_boundary() {
    local service raw
    cmp -s /usr/bin/podkop-guard /mnt/pg-bundle/podkop-guard
    [ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
    for service in sing-box podkop-guard; do
        raw=$(ubus -t 3 call service list "{\"name\":\"$service\"}")
        printf '%s\n' "$raw" | jq -e 'type == "object" and length == 0' >/dev/null
    done
    if pidof sing-box >/dev/null 2>&1; then
        echo FAIL_VM_SPLIT_SING_BOX_ALIVE >&2; return 1
    fi
    [ ! -e /usr/bin/podkop ] && [ ! -L /usr/bin/podkop ]
    [ ! -e /var/run/podkop_list_update.pid ] && [ ! -L /var/run/podkop_list_update.pid ]
    [ ! -e /tmp/podkop-guard-probe.lock/active ]
    [ ! -e /tmp/podkop-guard-probe.lock/active.abandoned ]
    [ -f /tmp/podkop-guard-probe.lock/lease ]
    (
        exec 7>>/tmp/podkop-guard-probe.lock/lease
        flock -n 7
    )
}
case "$#" in 1) ;; *) echo 'FAIL VM worker phase required' >&2; exit 1 ;; esac
case "$1" in
    core)
        [ ! -e "$boundary_manifest" ] && [ ! -L "$boundary_manifest" ]
        ;;
    finalize)
        verify_split_boundary
        [ -f "$boundary_manifest" ] && [ ! -L "$boundary_manifest" ]
        sha256sum -c "$boundary_manifest"
        echo PASS_VM_B6_SPLIT_FINAL_PRECONDITIONS
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
        rm -f "$boundary_manifest"
        exit 0 ;;
    *) echo 'FAIL invalid VM worker phase' >&2; exit 1 ;;
esac

[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
[ -r /mnt/pg-bundle/podkop-guard ]
grep -q '^VERSION="0.3.0-dev"' /mnt/pg-bundle/podkop-guard
[ -r /mnt/pg-bundle/podkop-guard.init ]

# Give this disposable guest an outbound route through QEMU user-mode NAT.
# Stock OpenWrt images often treat their only NIC as static LAN (192.168.1.1),
# so a networkless boot test cannot reach official package repositories.
guest_if=br-lan
ip link show "$guest_if" >/dev/null 2>&1 || guest_if=eth0
ip link set "$guest_if" up
ip addr add 10.0.2.15/24 dev "$guest_if" 2>/dev/null || true
ip route replace default via 10.0.2.2 dev "$guest_if"
printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf
printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf.d/resolv.conf.auto
echo "VM_NAT_READY interface=$guest_if"

# Use the real release-specific package database and real dependencies.
# Preserve the package checks of the original 25.12 test.
vm_pkg_update
# Test-only module; let the release package manager enforce the kernel ABI.
vm_pkg_install curl jq sing-box kmod-nft-tproxy

for dep in curl jq sing-box kmod-nft-tproxy; do
    vm_pkg_installed "$dep" || {
        echo "FAIL_REAL_DEP_MISSING $dep" >&2
        exit 1
    }
done
command -v curl
command -v jq
command -v sing-box
sing-box version | head -n 1
case "$PG_VM_PKG" in
    apk) echo PASS_VM_REAL_APK_DEPENDENCIES ;;
    opkg) echo PASS_VM_REAL_OPKG_DEPENDENCIES ;;
esac

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
# Emit actual per-suite timings and full test diagnostics, including failures.
run_watch_suite() {
    local name log started rc
    name=$1; log=$2; started=$(date +%s); rc=0
    sh "/mnt/pg-bundle/$name" /usr/bin/podkop-guard > "$log" 2>&1 || rc=$?
    cat "$log"
    printf 'VM_WATCH_TIMING suite=%s elapsed_s=%s rc=%s\n' "$name" "$(( $(date +%s) - started ))" "$rc"
    [ "$rc" -eq 0 ]
}
# Exercise the full procd event/snapshot fixture on actual guest jq/ash,
# not just selected real procd RPCs. The fixture mocks ubus locally.
run_watch_suite watchdog-procd.sh /tmp/pg-b6-procd-tests
grep -Eq '^PASS: [0-9]+ procd event/snapshot scenarios, all observe-only$' /tmp/pg-b6-procd-tests
echo PASS_VM_B6_PROCD_FULL_FIXTURES
run_watch_suite watchdog-check.sh /tmp/pg-b3-watch-tests
grep -Fq 'observer-only scenarios' /tmp/pg-b3-watch-tests
run_watch_suite watchdog-monitor.sh /tmp/pg-b3-monitor-tests
grep -Fq 'deterministic monitor scenarios' /tmp/pg-b3-monitor-tests
echo PASS_VM_B3_LOCAL_NEGATIVE_FIXTURES
for marker in premaintenance_list_healthy premaintenance_reload_healthy maintenance_started_healthy maintenance_started_timeout procd_lost_during_healthy procd_lost_during_timeout pid_changed_during_healthy pid_changed_during_timeout process_stopped_during_dns; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-watch-tests
done
for marker in procd_gap_invalidates_baseline unknown_gap_invalidates_baseline missing_invalidates_baseline maintenance_invalidates_baseline procd_gap_fresh_baseline_rearms procd_gap_discards_loopback; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-monitor-tests
done
echo PASS_VM_B5_LIFECYCLE_BASELINE
for marker in missing_birth zombie_birth malformed_birth missing_bus_identity same_pid_birth_changed_healthy same_pid_birth_changed_timeout birth_lost_during_dns bus_identity_changed_healthy bus_identity_changed_timeout bus_lost_during_dns; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-watch-tests
done
for marker in same_pid_new_birth bus_generation_new_baseline bus_generation_rearmed bus_generation_missing_streak identity_missing_rejected bus_missing_rejected birth_change_discards_loopback bus_change_discards_loopback; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-monitor-tests
done
echo PASS_VM_B5_RUNTIME_IDENTITY
for marker in unregistered empty_service malformed_service malformed_instances malformed_instance malformed_json multi_reply wrong_command missing_pid; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-watch-tests
done
echo PASS_VM_B6_PROCD_SCHEMA_FIXTURES
for marker in wrong_exe deleted_exe missing_exe wrong_argv missing_argv truncated_argv extra_argv argv_changed_during_dns exe_changed_during_dns; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-watch-tests
done
echo PASS_VM_B6_PROC_IDENTITY_FIXTURES
for marker in command_changed command_rearmed command_missing command_invalid command_change_discards_loopback; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-monitor-tests
done
echo PASS_VM_B6_COMMAND_GENERATION_FIXTURES
for marker in premaintenance_direct premaintenance_shell maintenance_prefix_marker maintenance_prefix_lifecycle maintenance_embedded_command maintenance_wrong_path maintenance_truncated_token maintenance_proc_disappeared; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-watch-tests
done
for marker in maintenance_prolonged prolonged_requires_baseline maintenance_window_resets; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-monitor-tests
done
echo PASS_VM_B6_MAINTENANCE_FIXTURES
for marker in structure_partial structure_missing_set structure_wrong_hook structure_wrong_type structure_wrong_priority structure_dormant structure_duplicate structure_bad_json structure_multi_json structure_read_error structure_partial_after_healthy structure_partial_after_timeout structure_wrong_after_healthy structure_wrong_after_timeout structure_extra; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-watch-tests
done
echo PASS_VM_B6_NFT_CHAINS_SETS_FIXTURES
for marker in rules_empty rules_wrong_mark rules_missing_udp rules_wrong_range rules_missing_common rules_wrong_interface rules_wrong_port rules_wrong_addr rules_wrong_mask rules_missing_bypass rules_split_signature rules_wrong_chain rules_after_healthy rules_after_timeout rules_numeric; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-watch-tests
done
echo PASS_VM_B6_NFT_RULES_FIXTURES
for marker in path_missing_uci path_missing_conffile path_relative path_uci_mismatch path_argv_mismatch path_no_config path_extra_config path_relative_workdir path_config_prefix path_file_missing path_directory path_changed_after_dns path_file_lost_after_dns path_layout_changed_after_dns path_no_workdir path_space; do
    grep -Fxq "PASS $marker" /tmp/pg-b3-watch-tests
done
echo PASS_VM_B6_DNS_CONFIG_PATH_FIXTURES
run_watch_suite watchdog-deadline.sh /tmp/pg-b4-deadline
grep -Fq 'B4 bounded cases' /tmp/pg-b4-deadline
grep -Fq 'PASS fd_isolation' /tmp/pg-b4-deadline
grep -Eq '^TIMING quick_probes=5 elapsed_s=[0-9]+ fifo=1$' /tmp/pg-b4-deadline
grep -Fq 'signal_KILL_no_running_orphan' /tmp/pg-b4-deadline
for marker in background_result_no_running_orphan leader_gone_no_running_orphan guard_gone_no_running_orphan stale_identity_no_signal prearm_failure_cleanup; do
    grep -Fq "PASS $marker" /tmp/pg-b4-deadline
done
echo PASS_VM_B5_SESSION_LIFECYCLE
for marker in actual_prearm_TERM_cleanup actual_prearm_KILL_cleanup actual_active_TERM_cleanup actual_active_KILL_cleanup; do
    grep -Fq "PASS $marker" /tmp/pg-b4-deadline
done
echo PASS_VM_B5_ACTUAL_CONTROLLER
for marker in supervisors_stopped_unknown_bounded supervisors_resumed_cleanup supervisors_lost_unknown_bounded supervisors_lost_test_only_cleanup cpu_contention_unknown_cleanup; do
    grep -Fq "PASS $marker" /tmp/pg-b4-deadline
done
echo PASS_VM_B5_SUPERVISOR_LOSS
for marker in supervisors_stopped_reentry_blocked supervisors_lost_reentry_blocked supervisors_stopped_reentry_released supervisors_lost_reentry_released; do
    grep -Fq "PASS $marker" /tmp/pg-b4-deadline
done
echo PASS_VM_B5_PROBE_CONTAINMENT
for marker in flock_missing_no_start flock_error_no_start armed_absent_blocked armed_malformed_blocked live_session_without_lease_blocked no_lease_session_reclaimed concurrent_start_single_winner; do
    grep -Fxq "PASS $marker" /tmp/pg-b4-deadline
done
echo PASS_VM_B5_CONTAINMENT_EDGE_CASES
echo PASS_VM_B4_ISOLATED_DEADLINE
grep -Fq 'deadline_breaks_streak' /tmp/pg-b3-monitor-tests
grep -Fq 'deadline_no_running_orphan' /tmp/pg-b3-monitor-tests
# The default OpenWrt BusyBox may not support fractional sleep.
if grep -Fq 'sleep: invalid number' /tmp/pg-b3-monitor-tests; then
    echo FAIL_VM_B4_FRACTIONAL_SLEEP >&2; exit 1
fi
echo PASS_VM_B4_RESIDENT_BOUNDED

# B5.2c.2: destructive lifecycle tests only inside this disposable guest.
PG_DISPOSABLE_VM=1 sh /mnt/pg-bundle/openwrt-procd-lifecycle-e2e.sh


# The next serial command uses the exact same guest and worker, but a
# separate bounded timeout. Preserve the LKG baseline across the split.
verify_split_boundary
sha256sum /usr/bin/podkop-guard /etc/podkop-guard/lkg-marker \
    /etc/podkop-guard/lkg.srs /etc/podkop-guard/lkg-subnets.lst > "$boundary_manifest"
echo PASS_VM_B6_SPLIT_CORE_PRECONDITIONS
echo OPENWRT_REAL_WORKER_CORE_E2E_PASS
