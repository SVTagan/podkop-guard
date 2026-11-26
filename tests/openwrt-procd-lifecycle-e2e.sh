#!/bin/sh
# B5.2c.2: real procd, real ubusd and a disposable sing-box instance.
# DNS/nft/conntrack are controlled inputs, not a functional VPN test.
set -eu
. /mnt/pg-bundle/openwrt-vm-common.sh
[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
worker=/usr/bin/podkop-guard
tmp=$(mktemp -d /tmp/pg-lifecycle.XXXXXX)
owned=0
monitor=
follower=
cleanup() {
    if [ -n "$monitor" ]; then
        kill -TERM "$monitor" 2>/dev/null || :
    fi
    if [ -n "$follower" ]; then
        kill -TERM "$follower" 2>/dev/null || :
    fi
    if [ "$owned" = 1 ]; then
        ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null 2>&1 || :
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() {
    echo "FAIL_VM_B5_LIFECYCLE $*" >&2
    for log in monitor.log procd.log; do
        if [ -r "$tmp/$log" ]; then cat "$tmp/$log" >&2; fi
    done
    exit 1
}
# Package post-install may register an empty service even when disabled:
# rc.common opens/closes a procd service around start_service(), and
# procd omits "instances" from an empty service dump. Log actual evidence.
# Never replace a registered instance or a running process, even in QEMU.
initial=$(ubus -t 3 call service list '{"name":"sing-box"}')
printf 'VM_B5_INITIAL_SERVICE %s\n' "$initial"
printf '%s\n' "$initial" | jq -e '
    type == "object" and
    ((keys - ["sing-box"]) | length == 0) and
    (if has("sing-box") then
        (.["sing-box"] | type == "object" and
            ((has("instances") | not) or .instances == {}))
     else true end)
' >/dev/null || fail existing_service_instance
if pidof sing-box >/dev/null 2>&1; then
    fail existing_live_process
fi
if printf '%s\n' "$initial" | jq -e 'has("sing-box")' >/dev/null; then
    [ "$(uci -q get sing-box.main.enabled)" = 0 ] ||
        fail existing_service_not_disabled
    # Only an empty, disabled package registration in this disposable
    # guest can be removed. Do not change UCI or installed package files.
    ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null ||
        fail empty_service_delete
    echo PASS_VM_B5_EMPTY_DISABLED_REGISTRATION
fi
initial=$(ubus -t 3 call service list '{"name":"sing-box"}')
printf '%s\n' "$initial" | jq -e 'type == "object" and (has("sing-box") | not)' >/dev/null ||
    fail service_not_absent_after_preflight
if pidof sing-box >/dev/null 2>&1; then
    fail live_process_after_preflight
fi
cat > "$tmp/box.json" <<'JSON'
{"log":{"disabled":true},"inbounds":[{"type":"socks","tag":"test-in","listen":"127.0.0.1","listen_port":17893},{"type":"direct","tag":"dns-in","listen":"127.0.0.42","listen_port":53}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
/usr/bin/sing-box check -c "$tmp/box.json"
# The worker must read the actual runtime file, not a second fixture.
# DNS replies below remain synthetic; no real FakeIP health claim.
service_json=$(jq -cn --arg config "$tmp/box.json" \
    '{name:"sing-box",instances:{"sing-box.main":{command:["/usr/bin/sing-box","run","-c",$config]}}}')
start_box() {
    owned=1
    ubus -t 3 call service set "$service_json" >/dev/null
}
snapshot() { sh "$worker" watchdog-procd-snapshot; }
snapshot_pid() {
    snap=$(snapshot) || return 1
    case "$snap" in 'PROCD_SNAPSHOT state=RUNNING pid='*)
        pid=${snap#* pid=}; pid=${pid%% *}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        [ "$pid" -gt 1 ] || return 1
        [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = /usr/bin/sing-box ] || return 1
        printf '%s\n' "$pid" ;;
        *) return 1 ;;
    esac
}
birth() (
    IFS= read -r line < "/proc/$1/stat" || exit 1
    rest=${line##*) }; set -- $rest
    [ "$#" -ge 20 ] || exit 1
    case "$1" in Z|X|x) exit 1 ;; esac
    case "${20}" in ''|*[!0-9]*) exit 1 ;; esac
    printf '%s\n' "${20}"
)
wait_box() {
    local previous attempt p
    previous=$1; attempt=0
    while [ "$attempt" -lt 12 ]; do
        p=$(snapshot_pid) || p=
        if [ -n "$p" ] && [ "$p" != "$previous" ] && birth "$p" >/dev/null 2>&1; then
            printf '%s\n' "$p"; return 0
        fi
        attempt=$((attempt + 1)); sleep 1
    done
    return 1
}
start_box
first=$(wait_box none) || fail initial_process
first_birth=$(birth "$first") || fail initial_birth
echo "VM_B5_BOX_INITIAL pid=$first starttime=$first_birth"

mkdir "$tmp/bin" "$tmp/conntrack"
# Isolate UCI settings from the guest's real config. Only these reads use
# the private directory; all other queries retain the real UCI behavior.
mkdir "$tmp/uci" "$tmp/uci-delta"
printf "config settings 'settings'\n\toption config_path '%s'\n" "$tmp/box.json" > "$tmp/uci/podkop"
printf "config sing-box 'main'\n\toption conffile '%s'\n" "$tmp/box.json" > "$tmp/uci/sing-box"
export PG_TEST_UCI_ROOT="$tmp" PG_TEST_REAL_UCI="$(command -v uci)"
cat > "$tmp/bin/uci" <<'SH'
#!/bin/sh
case "$*" in
    '-q get podkop.settings.config_path'|'-q get sing-box.main.conffile')
        exec "$PG_TEST_REAL_UCI" -c "$PG_TEST_UCI_ROOT/uci" -P "$PG_TEST_UCI_ROOT/uci-delta" "$@" ;;
    *) exec "$PG_TEST_REAL_UCI" "$@" ;;
esac
SH
chmod +x "$tmp/bin/uci"
printf '1\n' > "$tmp/conntrack/nf_conntrack_count"
printf '1000\n' > "$tmp/conntrack/nf_conntrack_max"
printf '0\n' > "$tmp/count"
cat > "$tmp/bin/nft" <<'SH'
#!/bin/sh
case "$*" in
    'list tables') echo 'table inet PodkopTable' ;;
    '-j -t list table inet PodkopTable') cat /mnt/pg-bundle/nft-structure-fixture.json ;;
    *) exit 19 ;;
esac
SH
cat > "$tmp/bin/ping" <<'SH'
#!/bin/sh
[ "$*" = '-c 1 -W 1 127.0.0.42' ] || exit 19
exit 0
SH
cat > "$tmp/bin/nslookup" <<'SH'
#!/bin/sh
set -eu
[ "$*" = '-timeout=3 -retry=1 -type=A fakeip.podkop.fyi 127.0.0.42' ] || exit 19
read -r n < "$PG_LIFECYCLE_DIR/count"
n=$((n + 1))
printf '%s\n' "$n" > "$PG_LIFECYCLE_DIR/count"
case "$n" in
    2)
        # External test harness, not the watchdog, controls the restart.
        : > "$PG_LIFECYCLE_DIR/restart-ready"
        tries=0
        while [ ! -e "$PG_LIFECYCLE_DIR/restart-done" ]; do
            [ "$tries" -lt 15 ] || exit 19
            tries=$((tries + 1)); sleep 1
        done ;;
esac
case "$n" in
    1|2|6)
        printf 'Name: fakeip.podkop.fyi\nAddress: 198.18.0.194\n' ;;
    3|4|5|7|8|9)
        echo 'connection timed out; no servers could be reached'; exit 1 ;;
    *) exit 19 ;;
esac
SH
chmod +x "$tmp/bin/"*
# Genuine runtime lookup through ubus/jsonfilter, synthetic DNS and nft.
# No production hook or change to the actual guest routing table.
PATH="$tmp/bin:$PATH" PG_LIFECYCLE_DIR="$tmp" \
    PODKOP_GUARD_WATCH_CONNTRACK_ROOT="$tmp/conntrack" \
    PODKOP_GUARD_WATCH_GRACE=0 PODKOP_GUARD_WATCH_MAX_SAMPLE=20 \
    sh "$worker" watchdog-monitor 9 0 > "$tmp/monitor.log" 2>&1 &
monitor=$!
attempt=0
while [ ! -e "$tmp/restart-ready" ]; do
    [ "$attempt" -lt 15 ] || fail dns_handshake
    attempt=$((attempt + 1)); sleep 1
done
# Stop and start only our registered fixture. Confirm original process
# disappears, so a change in metadata alone cannot pass this scenario.
ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null
attempt=0
while [ "$(birth "$first" 2>/dev/null || :)" = "$first_birth" ]; do
    [ "$attempt" -lt 8 ] || fail old_process_alive
    attempt=$((attempt + 1)); sleep 1
done
start_box
second=$(wait_box "$first") || fail replacement_process
second_birth=$(birth "$second") || fail replacement_birth
: > "$tmp/restart-done"
wait "$monitor" || fail monitor_rc
monitor=
cat "$tmp/monitor.log"
grep -Fxq "MONITOR sample=1/9 state=HEALTHY_SAMPLED phase=HEALTHY pid=$first streak=0" "$tmp/monitor.log" || fail first_baseline
grep -Fxq 'MONITOR sample=2/9 state=TRANSITION phase=TRANSITION pid=none streak=0 reason=procd_pid_changed' "$tmp/monitor.log" || fail stale_dns_accepted
for n in 3 4 5; do
    grep -Fxq "MONITOR sample=$n/9 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=$second streak=0" "$tmp/monitor.log" || fail "stale_baseline_$n"
done
grep -Fxq "MONITOR sample=6/9 state=HEALTHY_SAMPLED phase=HEALTHY pid=$second streak=0" "$tmp/monitor.log" || fail fresh_baseline
grep -Fxq "MONITOR sample=9/9 state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED pid=$second streak=3" "$tmp/monitor.log" || fail fresh_confirmation
grep -Fxq 'MONITOR_END completed=9 confirmations=1 action=none' "$tmp/monitor.log" || fail monitor_end
[ "$(grep -c '^MONITOR_EVENT confirmed=' "$tmp/monitor.log")" -eq 1 ] || fail extra_confirmation
[ "$(cat "$tmp/count")" = 9 ] || fail probe_count
echo "PASS_VM_B5_REAL_PID_LIFECYCLE old=$first new=$second"

# Exercise actual ubusd replacement while the same sing-box process is
# alive. procd PID 1 must respawn its own early ubus service.
bus_identity() (
    pids=$(pidof ubusd) || exit 1
    set -- $pids
    [ "$#" -eq 1 ] || exit 1
    p=$1
    case "$p" in ''|*[!0-9]*) exit 1 ;; esac
    [ "$p" -gt 1 ] || exit 1
    [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$(readlink -f /sbin/ubusd)" ] || exit 1
    IFS= read -r line < "/proc/$p/stat" || exit 1
    rest=${line##*) }; set -- $rest
    [ "$#" -ge 20 ] && [ "$2" = 1 ] || exit 1
    case "$1" in Z|X|x) exit 1 ;; esac
    printf '%s:%s\n' "$p" "${20}"
)
bus_before=$(bus_identity) || fail initial_ubusd
mkdir "$tmp/procd-ram"
PODKOP_GUARD_PROCD_TMP_DIR="$tmp/procd-ram" \
    sh "$worker" watchdog-procd-monitor 25 1 > "$tmp/procd.log" 2>&1 &
follower=$!
attempt=0
while ! grep -Fq "snapshot=RUNNING pid=$second history=INCOMPLETE action=none" "$tmp/procd.log"; do
    [ "$attempt" -lt 12 ] || fail first_subscription
    attempt=$((attempt + 1)); sleep 1
done
# Reuse the same nine-sample sequence while the REAL ubusd changes,
# keeping the sing-box process unchanged. No additional service restart.
mv "$tmp/monitor.log" "$tmp/pid-monitor.log"
printf '0\n' > "$tmp/count"
rm -f "$tmp/restart-ready" "$tmp/restart-done"
PATH="$tmp/bin:$PATH" PG_LIFECYCLE_DIR="$tmp" \
    PODKOP_GUARD_WATCH_CONNTRACK_ROOT="$tmp/conntrack" \
    PODKOP_GUARD_WATCH_GRACE=0 PODKOP_GUARD_WATCH_MAX_SAMPLE=20 \
    sh "$worker" watchdog-monitor 9 0 > "$tmp/monitor.log" 2>&1 &
monitor=$!
attempt=0
while [ ! -e "$tmp/restart-ready" ]; do
    [ "$attempt" -lt 10 ] || fail bus_dns_handshake
    attempt=$((attempt + 1)); sleep 1
done
[ "$(bus_identity)" = "$bus_before" ] || fail unexpected_bus_change
kill -TERM "${bus_before%%:*}"
attempt=0
bus_after=
while [ "$attempt" -lt 20 ]; do
    bus_after=$(bus_identity) || bus_after=
    if [ -n "$bus_after" ] && [ "$bus_before" != "$bus_after" ] &&
        [ "$(snapshot_pid || :)" = "$second" ]; then break; fi
    attempt=$((attempt + 1)); sleep 1
done
[ "$attempt" -lt 20 ] || fail ubusd_not_recovered
[ "$(birth "$second")" = "$second_birth" ] || fail unexpected_box_replacement
: > "$tmp/restart-done"
wait "$monitor" || fail bus_monitor_rc
monitor=
cat "$tmp/monitor.log"
grep -Fxq "MONITOR sample=1/9 state=HEALTHY_SAMPLED phase=HEALTHY pid=$second streak=0" "$tmp/monitor.log" || fail bus_initial_baseline
grep -Fxq 'MONITOR sample=2/9 state=TRANSITION phase=TRANSITION pid=none streak=0 reason=ubusd_changed' "$tmp/monitor.log" || fail stale_bus_evidence
for n in 3 4 5; do
    grep -Fxq "MONITOR sample=$n/9 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=$second streak=0" "$tmp/monitor.log" || fail "stale_bus_baseline_$n"
done
grep -Fxq "MONITOR sample=6/9 state=HEALTHY_SAMPLED phase=HEALTHY pid=$second streak=0" "$tmp/monitor.log" || fail bus_fresh_baseline
grep -Fxq "MONITOR sample=9/9 state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED pid=$second streak=3" "$tmp/monitor.log" || fail bus_fresh_confirmation
grep -Fxq 'MONITOR_END completed=9 confirmations=1 action=none' "$tmp/monitor.log" || fail bus_monitor_end
[ "$(grep -c '^MONITOR_EVENT confirmed=' "$tmp/monitor.log")" -eq 1 ] || fail bus_extra_confirmation
[ "$(cat "$tmp/count")" = 9 ] || fail bus_probe_count
echo PASS_VM_B5_REAL_BUS_BASELINE
# A renewed subscription must be followed by a fresh RUNNING snapshot.
# Do not demand an observed outage: a quick respawn may be between samples.
wait "$follower" || fail follower_rc
follower=
cat "$tmp/procd.log"
grep -Eq 'subscription=(RESET|LOST) reason=(ubusd_changed|ubusd_unavailable|subscriber_exit)' "$tmp/procd.log" || fail missing_subscription_reset
awk -v pid="$second" '
    /subscription=ATTEMPT number=2 / { rebound=1 }
    rebound && index($0, "snapshot=RUNNING pid=" pid " history=INCOMPLETE action=none") { fresh=1 }
    END { exit !fresh }
' "$tmp/procd.log" || fail no_fresh_snapshot_after_rebind
grep -Eq '^PROCD_MONITOR_END completed=25 attempts=[2-9][0-9]* resets=[1-9][0-9]* action=none$' "$tmp/procd.log" || fail follower_end
find "$tmp/procd-ram" -mindepth 1 -print > "$tmp/procd-leftovers"
[ ! -s "$tmp/procd-leftovers" ] || fail procd_ram_leak
echo "PASS_VM_B5_REAL_UBUS_RECONNECT old=$bus_before new=$bus_after"
ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null
attempt=0
while [ "$(birth "$second" 2>/dev/null || :)" = "$second_birth" ]; do
    [ "$attempt" -lt 8 ] || fail final_process_alive
    attempt=$((attempt + 1)); sleep 1
done
owned=0
[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ] || fail lkg_changed
echo PASS_VM_B5_REAL_PROCD_LIFECYCLE
