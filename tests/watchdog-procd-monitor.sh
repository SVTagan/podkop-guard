#!/bin/sh
# Stage B2: synthetic subscribe/rebind/state reconciliation, no real network.
set -eu
worker="${1:-./podkop-guard}"
case "$worker" in /*) ;; *) worker="$(pwd)/${worker#./}" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/ram"
printf 'BUS1\n' > "$tmp/bus"

cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
if [ "$#" -eq 3 ] && [ "$1 $2 $3" = '-S subscribe service' ]; then
    printf 'subscribe\n' >> "$PROCD_B2_SUB_LOG"
    [ "$PROCD_B2_MODE" != fail_subscription ] || exit 9
    if [ "$PROCD_B2_MODE" = event ]; then
        printf '%s\n' '{"instance.respawn":{"service":"sing-box","instance":"sing-box.main","pid":100,"exit_code":1,"respawn_count":1,"command":["/usr/bin/sing-box","run"]}}'
    fi
    exec sleep 60
fi
if [ "$#" -eq 6 ] && [ "$1 $2 $3 $4 $5 $6" = '-t 5 call service list {"name":"sing-box"}' ]; then
    count=$(cat "$PROCD_B2_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$PROCD_B2_COUNT"
    if [ "$PROCD_B2_MODE" = rebind ] && [ "$count" -ge 2 ]; then
        printf 'BUS2\n' > "$PROCD_B2_BUS_FILE"
    fi
    if [ "$PROCD_B2_MODE" = bus_outage ]; then
        if [ "$count" -eq 2 ]; then printf 'DOWN\n' > "$PROCD_B2_BUS_FILE"; fi
        if [ "$count" -eq 3 ]; then printf 'BUS2\n' > "$PROCD_B2_BUS_FILE"; fi
    fi
    pid=100
    if [ "$PROCD_B2_MODE" = pid_change ] && [ "$count" -ge 2 ]; then pid=200; fi
    printf '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":%s,"command":["/usr/bin/sing-box","run"]}}}}\n' "$pid"
    exit 0
fi
printf 'FORBIDDEN_UBUS_CALL\n' >> "$PROCD_B2_FORBIDDEN"
exit 9
SH
for cmd in podkop-vpn-failover netguard-wan-check curl; do
    cat > "$tmp/bin/$cmd" <<'SH'
#!/bin/sh
printf 'FORBIDDEN_EXTERNAL_CALL\n' >> "$PROCD_B2_FORBIDDEN"
exit 9
SH
done
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
export PODKOP_GUARD_PROCD_BUS_FILE="$tmp/bus"
export PODKOP_GUARD_PROCD_TMP_DIR="$tmp/ram"
export PROCD_B2_COUNT="$tmp/snapshot-count"
export PROCD_B2_SUB_LOG="$tmp/subscriptions"
export PROCD_B2_BUS_FILE="$tmp/bus"
export PROCD_B2_FORBIDDEN="$tmp/forbidden"
passed=0

case_run() {
    name=$1 mode=$2 expected=$3 cycles=$4
    PROCD_B2_MODE="$mode"; export PROCD_B2_MODE
    printf 'BUS1\n' > "$PROCD_B2_BUS_FILE"
    rm -f "$PROCD_B2_COUNT" "$PROCD_B2_SUB_LOG" "$PROCD_B2_FORBIDDEN"
    # Bash is used for the Linux CI host; OpenWrt QEMU tests actual BusyBox ash.
    output=$(bash "$worker" watchdog-procd-monitor "$cycles" 1) || {
        printf 'FAIL %s command failed: %s\n' "$name" "$output" >&2
        exit 1
    }
    case "$output" in *"$expected"*) ;; *)
        printf 'FAIL %s missing=%s\n%s\n' "$name" "$expected" "$output" >&2
        exit 1 ;;
    esac
    case "$output" in *"PROCD_MONITOR_END completed=$cycles "*" action=none"*) ;; *)
        printf 'FAIL %s missing end:\n%s\n' "$name" "$output" >&2; exit 1;;
    esac
    [ ! -s "$PROCD_B2_FORBIDDEN" ] || { echo "FAIL forbidden call: $name" >&2; exit 1; }
    [ -z "$(find "$tmp/ram" -mindepth 1 -print -quit)" ] || {
        printf 'FAIL %s leaked RAM FIFO\n' "$name" >&2; exit 1;
    }
    passed=$((passed+1))
    printf 'PASS %s\n' "$name"
}
case_run normal quiet 'snapshot=RUNNING pid=100 history=INCOMPLETE action=none' 2
case_run rebind rebind 'subscription=RESET reason=ubusd_changed' 4
case_run event event 'event=RESPAWN_REPORTED diagnosis=UNCONFIRMED history=INCOMPLETE action=none' 3
# A live Podkop list update/reload is not a license to call a procd event a
# confirmed runtime defect, even when its type is instance.respawn.
mkdir -p "$tmp/proc/321"
printf '/bin/sh\000/usr/bin/podkop\000reload\000' > "$tmp/proc/321/cmdline"
PODKOP_GUARD_WATCH_PROC_ROOT="$tmp/proc"
export PODKOP_GUARD_WATCH_PROC_ROOT
case_run maintenance event 'event=RESPAWN_REPORTED diagnosis=MAINTENANCE history=INCOMPLETE action=none' 2
rm -f "$tmp/proc/321/cmdline"
unset PODKOP_GUARD_WATCH_PROC_ROOT

case_run missing_event pid_change 'state_change=UNEXPLAINED snapshot=RUNNING history=INCOMPLETE' 3
case_run dead_subscriber fail_subscription 'subscription=RESET reason=subscriber_exit' 3
case_run bus_outage bus_outage 'subscription=LOST reason=ubusd_unavailable' 5
[ "$(wc -l < "$PROCD_B2_SUB_LOG")" -eq 2 ] || { echo 'FAIL bus outage did not resubscribe' >&2; exit 1; }


# When the ubus daemon disappears, the current snapshot remains diagnostic,
# but neither the subscription nor history is treated as healthy.
PROCD_B2_MODE=quiet; export PROCD_B2_MODE
printf 'DOWN\n' > "$PROCD_B2_BUS_FILE"
rm -f "$PROCD_B2_COUNT" "$PROCD_B2_SUB_LOG" "$PROCD_B2_FORBIDDEN"
output=$(bash "$worker" watchdog-procd-monitor 2 1)
case "$output" in *'subscription=UNKNOWN snapshot=RUNNING'*'PROCD_MONITOR_END completed=2 attempts=0 resets=0 action=none'*) ;; *)
    printf 'FAIL disconnected-bus case:\n%s\n' "$output" >&2; exit 1;;
esac
[ ! -s "$PROCD_B2_FORBIDDEN" ] || exit 1
passed=$((passed+1))
printf 'PASS disconnected_bus\n'

# The explicit continuous observer must honor SIGTERM and reap its own
# subscriber without leaving a FIFO in tmpfs.
PROCD_B2_MODE=quiet; export PROCD_B2_MODE
printf 'BUS1\n' > "$PROCD_B2_BUS_FILE"
rm -f "$PROCD_B2_COUNT" "$PROCD_B2_SUB_LOG" "$PROCD_B2_FORBIDDEN"
bash "$worker" watchdog-procd-follow > "$tmp/follow.log" 2>&1 &
follow_pid=$!
sleep 2
kill -TERM "$follow_pid" 2>/dev/null || :
loops=0
while kill -0 "$follow_pid" 2>/dev/null && [ "$loops" -lt 9 ]; do
    sleep 1
    loops=$((loops + 1))
done
if kill -0 "$follow_pid" 2>/dev/null; then
    kill -KILL "$follow_pid" 2>/dev/null || :
    wait "$follow_pid" 2>/dev/null || :
    echo 'FAIL follow SIGTERM not handled' >&2
    exit 1
fi
wait "$follow_pid" 2>/dev/null || :
grep -Fq 'PROCD_MONITOR_END completed=' "$tmp/follow.log" || {
    echo 'FAIL follow did not exit cleanly' >&2; exit 1;
}
[ -z "$(find "$tmp/ram" -mindepth 1 -print -quit)" ] || {
    echo 'FAIL follow left FIFO in tmpfs' >&2; exit 1;
}
passed=$((passed + 1))
printf 'PASS follow_sigterm_cleanup\n'

for args in '--restart' '0 1' '31 1' '2 0' '2 31' 'oops 1'; do
    set +e
    bash "$worker" watchdog-procd-monitor $args >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || {
        printf 'FAIL invalid_args [%s] returned %s\n' "$args" "$rc" >&2; exit 1;
    }
    passed=$((passed+1))
done
printf 'PASS: %s bounded procd subscription scenarios\n' "$passed"
