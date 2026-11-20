#!/bin/sh
# Independent metadata-only collector: all dependencies are mocked.
# No network requests, VPN health checks, UCI writes, route or service changes.
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
count=$(cat "$TEST_LOCAL_COUNTER" 2>/dev/null || echo 0)
count=$((count+1))
printf '%s\n' "$count" > "$TEST_LOCAL_COUNTER"
if [ -n "${TEST_LOCAL_CHANGED:-}" ] && [ "$count" -ge 2 ]; then
    printf 'WATCHDOG state=%s pid=888\n' "$TEST_LOCAL_CHANGED"
    exit 0
fi
printf 'WATCHDOG state=%s pid=%s\n' "$TEST_LOCAL" "$TEST_PID"
exit "$TEST_LOCAL_RC"
SH

cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
[ "$#" -eq 5 ] && [ "$1 $2 $3 $5" = '-t 5 call status' ] || exit 9
case "$4" in
    network.interface.wan)
        [ "$TEST_WAN_UBUS" != fail ] || exit 1
        printf '{"mock":"wan"}\n'
        ;;
    network.interface.awg0_2)
        [ "$TEST_VPN_UBUS" != fail ] || exit 1
        printf '{"mock":"vpn"}\n'
        ;;
    *) exit 9 ;;
esac
SH

cat > "$tmp/bin/jsonfilter" <<'SH'
#!/bin/sh
[ "$#" -eq 4 ] && [ "$1" = -s ] && [ "$3" = -e ] || exit 9
case "$2:$4" in
    *wan*:'@.up') printf '%s\n' "$TEST_WAN_UP" ;;
    *wan*:'@.pending') printf '%s\n' "$TEST_WAN_PENDING" ;;
    *wan*:'@.l3_device') printf 'wan\n' ;;
    *vpn*:'@.up') printf '%s\n' "$TEST_VPN_UP" ;;
    *vpn*:'@.pending') printf '%s\n' "$TEST_VPN_PENDING" ;;
    *) exit 9 ;;
esac
SH

cat > "$tmp/bin/uci" <<'SH'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = -q ] && [ "$2" = get ] || {
    printf 'FORBIDDEN_UCI_WRITE\n' >> "$TEST_FORBIDDEN_LOG"; exit 9;
}
case "$3" in
    podkop.main.connection_type) printf '%s\n' "$TEST_CONN" ;;
    podkop.main.interface)
        count=$(cat "$TEST_IFACE_COUNTER" 2>/dev/null || echo 0)
        count=$((count+1))
        printf '%s\n' "$count" > "$TEST_IFACE_COUNTER"
        if [ -n "${TEST_IFACE_CHANGED:-}" ] && [ "$count" -ge 2 ]; then
            printf '%s\n' "$TEST_IFACE_CHANGED"
        else
            printf '%s\n' "$TEST_IFACE"
        fi
        ;;
    *) exit 9 ;;
esac
SH

for name in curl netguard-wan-check podkop-vpn-failover; do
    cat > "$tmp/bin/$name" <<'SH'
#!/bin/sh
printf 'FORBIDDEN_EXTERNAL_HELPER\n' >> "$TEST_FORBIDDEN_LOG"
exit 9
SH
done

chmod +x "$tmp/local-check" "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
export PODKOP_GUARD_EVIDENCE_CHECK_SCRIPT="$tmp/local-check"
export PODKOP_GUARD_EVIDENCE_NET_ROOT="$tmp/net"
export TEST_LOCAL_COUNTER="$tmp/local-count"
export TEST_IFACE_COUNTER="$tmp/iface-count"
export TEST_FORBIDDEN_LOG="$tmp/forbidden"
TEST_LOCAL=HEALTHY_SAMPLED TEST_LOCAL_RC=0 TEST_PID=12345
TEST_LOCAL_CHANGED=
TEST_WAN_UBUS=ready TEST_WAN_UP=true TEST_WAN_PENDING=false
TEST_VPN_UBUS=ready TEST_VPN_UP=true TEST_VPN_PENDING=false
TEST_CONN=vpn TEST_IFACE=awg0_2 TEST_IFACE_CHANGED=
export TEST_LOCAL TEST_LOCAL_RC TEST_PID TEST_LOCAL_CHANGED TEST_WAN_UBUS
export TEST_WAN_UP TEST_WAN_PENDING TEST_VPN_UBUS TEST_VPN_UP
export TEST_VPN_PENDING TEST_CONN TEST_IFACE TEST_IFACE_CHANGED

passed=0
check() {
    name=$1 snippet=$2 class=$3
    : > "$TEST_FORBIDDEN_LOG"
    rm -f "$TEST_IFACE_COUNTER" "$TEST_LOCAL_COUNTER"
    set +e
    out=$(sh "$worker" watchdog-evidence 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || { printf 'FAIL %s rc=%s output=%s\n' "$name" "$rc" "$out" >&2; exit 1; }
    printf '%s\n' "$out" | grep -Fq "$snippet" || {
        printf 'FAIL %s missing=%s output=%s\n' "$name" "$snippet" "$out" >&2; exit 1;
    }
    printf '%s\n' "$out" | grep -Fq "CLASSIFY class=$class " || {
        printf 'FAIL %s classification=%s output=%s\n' "$name" "$class" "$out" >&2; exit 1;
    }
    printf '%s\n' "$out" | grep -Fq 'authority=observe-only action=none' || exit 1
    [ ! -s "$TEST_FORBIDDEN_LOG" ] || { printf 'FAIL %s invoked forbidden helper\n' "$name" >&2; exit 1; }
    passed=$((passed+1))
    printf 'PASS %s\n' "$name"
}

check healthy_links 'wan=UNKNOWN wan_source=netifd_unverified wan_link=UP vpn=UNKNOWN vpn_source=netifd_unverified vpn_link=UP' LOCAL_HEALTHY_WAN_UNVERIFIED

TEST_WAN_UP=false
printf '0\n' > "$tmp/net/wan/carrier"
check link_down 'wan=DOWN wan_source=netifd_link_down wan_link=DOWN vpn=UNKNOWN' WAN_OUTAGE
TEST_WAN_PENDING=true
check link_pending 'wan=UNKNOWN wan_source=netifd_unverified wan_link=DOWN' LOCAL_HEALTHY_WAN_UNVERIFIED
TEST_WAN_PENDING=false
TEST_WAN_UP=true
printf '1\n' > "$tmp/net/wan/carrier"

TEST_WAN_UBUS=fail
check wan_ubus_unavailable 'wan=UNKNOWN wan_source=netifd_unavailable wan_link=UNKNOWN' LOCAL_HEALTHY_WAN_UNVERIFIED
TEST_WAN_UBUS=ready

TEST_VPN_UP=false
check vpn_link_down 'vpn=UNKNOWN vpn_source=netifd_unverified vpn_link=DOWN' LOCAL_HEALTHY_WAN_UNVERIFIED
TEST_VPN_UP=true
TEST_VPN_UBUS=fail
check vpn_ubus_unavailable 'vpn=UNKNOWN vpn_source=netifd_unavailable vpn_link=UNKNOWN' LOCAL_HEALTHY_WAN_UNVERIFIED
TEST_VPN_UBUS=ready

TEST_CONN=proxy
check proxy_mode 'vpn=UNKNOWN vpn_source=not_in_vpn_mode vpn_link=UNKNOWN' LOCAL_HEALTHY_WAN_UNVERIFIED
TEST_CONN=vpn
TEST_IFACE='awg0_2;sh'
check invalid_iface 'vpn=UNKNOWN vpn_source=invalid_interface vpn_link=UNKNOWN' LOCAL_HEALTHY_WAN_UNVERIFIED
TEST_IFACE=wg0
check unsupported_iface 'vpn=UNKNOWN vpn_source=unsupported_interface vpn_link=UNKNOWN' LOCAL_HEALTHY_WAN_UNVERIFIED
TEST_IFACE=awg0_2

TEST_LOCAL=SUSPECT_DNS_TIMEOUT
TEST_LOCAL_RC=1
check dns_timeout 'local=SUSPECT_DNS_TIMEOUT' LOCAL_FAULT_WAN_UNVERIFIED
TEST_LOCAL=SUSPECT_PROCESS_MISSING
check missing_process 'local=SUSPECT_PROCESS_MISSING' LOCAL_FAULT_WAN_UNVERIFIED
TEST_LOCAL=INACTIVE
TEST_LOCAL_RC=0
check inactive 'local=INACTIVE' MANUAL_STOP
TEST_LOCAL=TRANSITION
check in_reload 'local=TRANSITION' MAINTENANCE
TEST_LOCAL=HEALTHY_SAMPLED

TEST_LOCAL_RC=9
check unexpected_local_rc 'local=UNKNOWN pid=none' INSUFFICIENT_EVIDENCE
TEST_LOCAL_RC=0
TEST_LOCAL_CHANGED=TRANSITION
check local_change 'local=TRANSITION pid=none wan=UNKNOWN wan_source=changed_during_sample' MAINTENANCE
TEST_LOCAL_CHANGED=
TEST_IFACE_CHANGED=awg0_3
check concurrent_failover 'local=TRANSITION pid=none wan=UNKNOWN wan_source=changed_during_sample vpn=UNKNOWN vpn_source=changed_during_sample' MAINTENANCE
TEST_IFACE_CHANGED=

: > "$TEST_FORBIDDEN_LOG"
set +e
out=$(sh "$worker" watchdog-evidence --live 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] && [ ! -s "$TEST_FORBIDDEN_LOG" ] || {
    printf 'FAIL rejected_deprecated_live rc=%s output=%s\n' "$rc" "$out" >&2
    exit 1
}
passed=$((passed+1))
printf 'PASS rejected_deprecated_live\nPASS: %s independent evidence scenarios\n' "$passed"
