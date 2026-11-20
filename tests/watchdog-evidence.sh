#!/bin/sh
# Stage 6B1: deterministic one-shot evidence collector tests.
# Only mocks: NO router networking, UCI writes, service changes or real curl.
set -eu
worker="${1:-./podkop-guard}"
case "$worker" in /*) ;; *) worker="$(pwd)/${worker#./}" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/net/wan"
printf '1\n' > "$tmp/net/wan/carrier"

cat > "$tmp/local-check" <<'SH'
#!/bin/sh
[ "$1" = watchdog-check ] || exit 9
printf 'WATCHDOG state=%s pid=%s\n' "$TEST_LOCAL" "$TEST_PID"
exit "$TEST_LOCAL_RC"
SH

cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
[ "$#" -eq 5 ] && [ "$1 $2 $3 $4 $5" = '-t 5 call network.interface.wan status' ] || exit 9
[ "$TEST_NETIFD" != fail ] || exit 1
printf '{}\n'
SH

cat > "$tmp/bin/jsonfilter" <<'SH'
#!/bin/sh
[ "$1" = -s ] && [ "$3" = -e ] || exit 9
case "$4" in
    '@.up') printf '%s\n' "$TEST_WAN_UP" ;;
    '@.pending') printf '%s\n' "$TEST_WAN_PENDING" ;;
    '@.l3_device') printf 'wan\n' ;;
    *) exit 9 ;;
esac
SH

cat > "$tmp/bin/uci" <<'SH'
#!/bin/sh
[ "$1" = -q ] && [ "$2" = get ] || { echo "MUTATION_IGNORED" >&2; exit 9; }
case "$3" in
    podkop.main.connection_type) echo vpn ;;
    podkop.main.interface)
        if [ -n "${TEST_IFACE_CHANGED:-}" ]; then
            count=$(cat "$TEST_IFACE_COUNTER" 2>/dev/null || echo 0)
            count=$((count + 1))
            printf '%s\n' "$count" > "$TEST_IFACE_COUNTER"
            if [ "$count" -ge 2 ]; then
                echo "$TEST_IFACE_CHANGED"
            else
                echo "$TEST_IFACE"
            fi
        else
            echo "$TEST_IFACE"
        fi
        ;;
    *) exit 1 ;;
esac
SH

cat > "$tmp/wan-check" <<'SH'
#!/bin/sh
[ "$1" = check ] && [ "$#" -eq 1 ] || exit 9
printf 'wan\n' >> "$TEST_NETWORK_LOG"
case "$TEST_WAN_SAMPLE" in
    healthy) echo 'RESULT: HEALTHY_SAMPLED'; exit 0 ;;
    link_down) echo 'RESULT: WAN_LINK_DOWN'; exit 1 ;;
    unavailable) echo 'RESULT: EXTERNAL_REACHABILITY_UNCONFIRMED'; exit 0 ;;
    broken) echo 'RESULT: HEALTHY_SAMPLED'; exit 2 ;;
    duplicate) echo 'RESULT: HEALTHY_SAMPLED'; echo 'RESULT: WAN_LINK_DOWN'; exit 0 ;;
    *) exit 9 ;;
esac
SH

cat > "$tmp/vpn-check" <<'SH'
#!/bin/sh
[ "$1" = check ] && [ "$2" = "$TEST_IFACE" ] && [ "$#" -eq 2 ] || exit 9
printf 'vpn\n' >> "$TEST_NETWORK_LOG"
case "$TEST_VPN_SAMPLE" in
    healthy) echo "$2: HEALTHY via gstatic HTTP=204 time=0.1s"; exit 0 ;;
    failed) echo "$2: FAILED all targets (gstatic:curl=28,HTTP=000)"; exit 1 ;;
    broken) echo "$2: HEALTHY via gstatic HTTP=204"; exit 2 ;;
    *) exit 9 ;;
esac
SH

chmod +x "$tmp/local-check" "$tmp/bin"/* "$tmp/wan-check" "$tmp/vpn-check"

export PATH="$tmp/bin:$PATH"
export PODKOP_GUARD_EVIDENCE_CHECK_SCRIPT="$tmp/local-check"
export PODKOP_GUARD_EVIDENCE_NET_ROOT="$tmp/net"
export PODKOP_GUARD_EVIDENCE_WAN_CHECKER="$tmp/wan-check"
export PODKOP_GUARD_EVIDENCE_VPN_CHECKER="$tmp/vpn-check"
export TEST_NETWORK_LOG="$tmp/network.log"

tests=0
TEST_LOCAL=HEALTHY_SAMPLED
TEST_LOCAL_RC=0
TEST_PID=12345
TEST_NETIFD=ready
TEST_WAN_UP=true
TEST_WAN_PENDING=false
TEST_IFACE=awg0_2
TEST_WAN_SAMPLE=healthy
TEST_VPN_SAMPLE=healthy
export TEST_LOCAL TEST_LOCAL_RC TEST_PID TEST_NETIFD TEST_WAN_UP TEST_WAN_PENDING
export TEST_IFACE TEST_WAN_SAMPLE TEST_VPN_SAMPLE
export TEST_IFACE_COUNTER="$tmp/iface-count"
export TEST_IFACE_CHANGED=

run_case() {
    name=$1 mode=$2 evidence=$3 classified=$4 expected_probes=$5
    : > "$TEST_NETWORK_LOG"
    set +e
    if [ "$mode" = metadata ]; then
        output=$(sh "$worker" watchdog-evidence 2>&1)
    else
        output=$(sh "$worker" watchdog-evidence --live 2>&1)
    fi
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || { printf 'FAIL %s rc=%s: %s\n' "$name" "$rc" "$output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -Fq "$evidence" || {
        printf 'FAIL %s evidence: %s\n' "$name" "$output" >&2; exit 1;
    }
    printf '%s\n' "$output" | grep -Fq "CLASSIFY class=$classified " || {
        printf 'FAIL %s classification: %s\n' "$name" "$output" >&2; exit 1;
    }
    printf '%s\n' "$output" | grep -Fq 'authority=observe-only action=none' || exit 1
    actual=$(tr '\n' ' ' < "$TEST_NETWORK_LOG")
    [ "$actual" = "$expected_probes" ] || {
        printf 'FAIL %s unexpected probes: <%s> vs <%s>\n' "$name" "$actual" "$expected_probes" >&2
        exit 1
    }
    tests=$((tests + 1))
    printf 'PASS %s\n' "$name"
}

# Default must never invoke either external checker.
run_case metadata_healthy metadata 'local=HEALTHY_SAMPLED pid=12345 wan=UNKNOWN wan_source=netifd_unverified vpn=UNKNOWN' LOCAL_HEALTHY_WAN_UNVERIFIED ''
# A real link-loss observation is local evidence even without HTTP.
printf '0\n' > "$tmp/net/wan/carrier"
TEST_WAN_UP=false
run_case carrier_down metadata 'wan=DOWN wan_source=netifd_link_down' WAN_OUTAGE ''
TEST_WAN_PENDING=true
run_case pending_not_down metadata 'wan=UNKNOWN wan_source=netifd_unverified' LOCAL_HEALTHY_WAN_UNVERIFIED ''
TEST_WAN_PENDING=false
TEST_WAN_UP=true
printf '1\n' > "$tmp/net/wan/carrier"

run_case live_ok --live 'wan=UP wan_source=netguard_pinned_https vpn=HEALTHY vpn_source=failover_active_interface doh=UNKNOWN doh_source=not_probed' LOCAL_HEALTHY_EXTERNAL_UNVERIFIED 'wan vpn '
TEST_VPN_SAMPLE=failed
run_case current_vpn_unavailable --live 'wan=UP wan_source=netguard_pinned_https vpn=FAILED' VPN_UNAVAILABLE 'wan vpn '
TEST_WAN_SAMPLE=unavailable
run_case wan_targets_failed --live 'wan=UNKNOWN wan_source=netguard_unconfirmed vpn=FAILED' VPN_FAILURE_WAN_UNVERIFIED 'wan vpn '
TEST_WAN_SAMPLE=broken
run_case erroneous_wan_helper --live 'wan=UNKNOWN wan_source=netguard_unconfirmed vpn=FAILED' VPN_FAILURE_WAN_UNVERIFIED 'wan vpn '
TEST_WAN_SAMPLE=duplicate
run_case contradictory_wan_helper --live 'wan=UNKNOWN wan_source=netguard_invalid vpn=FAILED' VPN_FAILURE_WAN_UNVERIFIED 'wan vpn '

TEST_WAN_SAMPLE=healthy
TEST_LOCAL=SUSPECT_DNS_TIMEOUT
TEST_LOCAL_RC=1
TEST_VPN_SAMPLE=healthy
run_case local_dns_suspect --live 'local=SUSPECT_DNS_TIMEOUT pid=12345 wan=UP' BOX_DNS_HUNG_CANDIDATE 'wan vpn '
TEST_LOCAL=INACTIVE
TEST_LOCAL_RC=0
run_case manual_shutdown --live 'local=INACTIVE pid=12345 wan=UP' MANUAL_STOP 'wan vpn '
TEST_LOCAL=TRANSITION
run_case podkop_reload --live 'local=TRANSITION pid=12345 wan=UP' MAINTENANCE 'wan vpn '
TEST_LOCAL=HEALTHY_SAMPLED

TEST_IFACE='awg0_2;id'
run_case unsafe_interface --live 'vpn=UNKNOWN vpn_source=invalid_interface' LOCAL_HEALTHY_EXTERNAL_UNVERIFIED 'wan '
TEST_IFACE=awg0_2
TEST_VPN_SAMPLE=broken
run_case invalid_vpn_checker --live 'vpn=UNKNOWN vpn_source=failover_unconfirmed' LOCAL_HEALTHY_EXTERNAL_UNVERIFIED 'wan '

# A slow active VPN probe must be invalidated when Failover changes UCI.
TEST_VPN_SAMPLE=healthy
TEST_IFACE_CHANGED=awg0_3
export TEST_IFACE_CHANGED
rm -f "$TEST_IFACE_COUNTER"
run_case concurrent_failover --live 'local=TRANSITION pid=none wan=UNKNOWN wan_source=changed_during_sample vpn=UNKNOWN vpn_source=changed_during_sample' MAINTENANCE 'wan vpn '
TEST_IFACE_CHANGED=
export TEST_IFACE_CHANGED

# Any argument not explicitly allowed must be refused before probes.
: > "$TEST_NETWORK_LOG"
set +e
output=$(sh "$worker" watchdog-evidence --enable-recovery 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] && [ ! -s "$TEST_NETWORK_LOG" ] || {
    printf 'FAIL invalid mode rc=%s output=%s\n' "$rc" "$output" >&2; exit 1;
}
tests=$((tests + 1))
printf 'PASS invalid_mode\nPASS: %s evidence collection scenarios\n' "$tests"
