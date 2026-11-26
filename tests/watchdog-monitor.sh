#!/bin/sh
# Offline, bounded, deterministic monitor checks. Never interacts with OpenWrt.
set -eu
script="${1:-./podkop-guard}"
case "$script" in /*) ;; *) script="$(pwd)/${script#./}" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
: > "$tmp/counter"
printf '100.00 200.00\n' > "$tmp/uptime"

cat > "$tmp/mock-check" <<'SH'
#!/bin/sh
[ "$1" = watchdog-check ] || exit 9
counter=$(cat "$MONITOR_TEST_COUNTER")
case "$counter" in ''|*[!0-9]*) exit 9 ;; esac
counter=$((counter + 1))
printf '%s\n' "$counter" > "$MONITOR_TEST_COUNTER"
line=$(sed -n "${counter}p" "$MONITOR_TEST_FIXTURE")
[ -n "$line" ] || exit 9
oldifs=$IFS
IFS='|'
read -r state pid rc simulated_uptime reason birth bus command_id config_id <<EOF
$line
EOF
IFS=$oldifs
if [ -n "$simulated_uptime" ]; then
    printf '%s\n' "$simulated_uptime" > "$MONITOR_TEST_UPTIME_FILE"
fi
if [ "$state" = HANG ]; then
    (sleep 35) &
    printf '%s\n' "$!" > "$MONITOR_TEST_CHILD_PID_FILE"
    wait
    exit 9
fi
birth=${birth:-1000}
bus=${bus:-700:2000}
command_id=${command_id:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
config_id=${config_id:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}
suffix=
if [ "${MONITOR_TEST_CONTROL_MODE:-0}" = 1 ]; then
    if [ "$state" = HEALTHY_SAMPLED ] &&
       [ "${PODKOP_GUARD_WATCH_CONTROL_PROBE:-0}" = 1 ]; then
        suffix=' loopback=ok'
    fi
    if [ "$state" = SUSPECT_DNS_TIMEOUT ] &&
       [ "${PODKOP_GUARD_WATCH_LOOPBACK_BASELINE_ID:-}" = "$pid:$birth:$bus:$command_id:$config_id" ]; then
        state=UNKNOWN
        rc=2
        suffix=' reason=loopback_unresponsive'
    fi
fi
if [ -n "$reason" ]; then suffix="$suffix reason=$reason"; fi
[ "$birth" = - ] || suffix="$suffix birth=$birth"
[ "$bus" = - ] || suffix="$suffix bus=$bus"
[ "$command_id" = - ] || suffix="$suffix command_id=$command_id"
[ "$config_id" = - ] || suffix="$suffix config_id=$config_id"
printf 'WATCHDOG state=%s pid=%s mock=yes%s\n' "$state" "$pid" "$suffix"
exit "$rc"
SH
chmod +x "$tmp/mock-check"

passed=0
run_case() {
    name=$1
    expected=$2
    confirmations=$3
    shift 3
    printf '%s\n' "$@" > "$tmp/fixture"
    printf '0\n' > "$tmp/counter"
    set +e
    output=$(env \
      MONITOR_TEST_FIXTURE="$tmp/fixture" \
      MONITOR_TEST_COUNTER="$tmp/counter" \
      MONITOR_TEST_UPTIME_FILE="$tmp/uptime" \
      MONITOR_TEST_CHILD_PID_FILE="$tmp/childpid" \
      PODKOP_GUARD_WATCH_MAX_SAMPLE="${MONITOR_TEST_DEADLINE:-8}" \
      PODKOP_GUARD_WATCH_CHECK_SCRIPT="$tmp/mock-check" \
      PODKOP_GUARD_WATCH_UPTIME_FILE="$tmp/uptime" \
      PODKOP_GUARD_WATCH_GRACE=0 \
      PODKOP_GUARD_WATCH_MAINTENANCE_MAX="${MONITOR_TEST_MAINTENANCE_MAX:-900}" \
      sh "$script" watchdog-monitor "$#" 0 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL %s: unexpected rc=%s\n%s\n' "$name" "$rc" "$output" >&2
        exit 1
    fi
    case "$output" in
        *"$expected"*) ;;
        *) printf 'FAIL %s: expected %s, got:\n%s\n' "$name" "$expected" "$output" >&2
           # On a real BusyBox guest reveal the standalone bounded result
           # with identical mock environment, without changing the worker.
           printf '0\n' > "$tmp/counter"
           set +e
           diag=$(env MONITOR_TEST_FIXTURE="$tmp/fixture" \
               MONITOR_TEST_COUNTER="$tmp/counter" \
               MONITOR_TEST_UPTIME_FILE="$tmp/uptime" \
               MONITOR_TEST_CHILD_PID_FILE="$tmp/childpid" \
               PODKOP_GUARD_WATCH_CHECK_SCRIPT="$tmp/mock-check" \
               sh "$script" watchdog-check-bounded 8 2>&1)
           diag_rc=$?
           set -e
           printf 'DIAG bounded rc=%s output=%s\n' "$diag_rc" "$diag" >&2
           exit 1 ;;
    esac
    case "$output" in *'command_id='*|*'config_id='*) echo "FAIL $name leaked runtime identity" >&2; exit 1 ;; esac
    case "$output" in
        *"MONITOR_END completed=$# confirmations=$confirmations action=none"*) ;;
        *) printf 'FAIL %s: wrong confirmations:\n%s\n' "$name" "$output" >&2; exit 1 ;;
    esac
    passed=$((passed + 1))
    printf 'PASS %s\n' "$name"
}
H='HEALTHY_SAMPLED|101|0'
T='SUSPECT_DNS_TIMEOUT|101|1'
M='SUSPECT_PROCESS_MISSING|none|1'
U='UNKNOWN|none|2'
X='TRANSITION|none|0'
I='INACTIVE|none|0'
T2='SUSPECT_DNS_TIMEOUT|202|1'
H2='HEALTHY_SAMPLED|202|0'

run_case healthy         'phase=HEALTHY' 0 "$H" "$H" "$H"
run_case dns_debounce    'state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED' 1 "$H" "$T" "$T" "$T" "$T"
run_case one_timeout     'phase=SUSPECT' 0 "$H" "$T" "$H"
run_case unknown_breaks  'phase=UNKNOWN' 0 "$H" "$T" "$T" "$U" "$T" "$T"
run_case different_kind  'phase=SUSPECT' 0 "$H" "$T" "$T" "$M" "$T" "$T"
run_case process_missing 'state=SUSPECT_PROCESS_MISSING phase=CONFIRMED' 1 "$H" "$M" "$M" "$M"
run_case manual_stop     'phase=INACTIVE' 0 "$H" "$T" "$I"
run_case transition      'phase=TRANSITION' 0 "$H" "$T" "$X" "$T" "$T"
run_case pid_change      'phase=WAITING_FOR_BASELINE' 0 "$H" "$T" "$T2" "$T2" "$T2"
run_case pid_rearmed     'state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED' 1 "$H" "$T" "$H2" "$T2" "$T2" "$T2"
run_case no_baseline     'phase=WAITING_FOR_BASELINE' 0 "$T" "$T" "$T"
run_case bad_rc          'phase=UNKNOWN' 0 "$H" "SUSPECT_DNS_TIMEOUT|101|0"
run_case wan_vpn_unknown 'phase=HEALTHY' 0 "$H" "$H" "$H"
MONITOR_TEST_CONTROL_MODE=1
export MONITOR_TEST_CONTROL_MODE
run_case validated_loopback_suppression 'reason=loopback_unresponsive' 0 "$H" "$T" "$T" "$T"
unset MONITOR_TEST_CONTROL_MODE
# The same numeric PID after a gap is NOT a fresh healthy baseline.
# Assert the final sample phase as well as zero confirmations. Three
# consecutive timeouts would have confirmed against the old baseline.
U_PROCD='UNKNOWN|none|2||procd_unavailable'
X_MAINT='TRANSITION|101|0||list_update'
run_case procd_gap_invalidates_baseline \
    'sample=6/6 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T" "$U_PROCD" "$T" "$T" "$T"
run_case unknown_gap_invalidates_baseline \
    'sample=5/5 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$U" "$T" "$T" "$T"
run_case missing_invalidates_baseline \
    'sample=5/5 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$M" "$T" "$T" "$T"
run_case maintenance_invalidates_baseline \
    'sample=5/5 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$X_MAINT" "$T" "$T" "$T"
run_case procd_gap_fresh_baseline_rearms \
    'sample=6/6 state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED pid=101 streak=3' 1 \
    "$H" "$U_PROCD" "$H" "$T" "$T" "$T"
MONITOR_TEST_CONTROL_MODE=1
export MONITOR_TEST_CONTROL_MODE
run_case procd_gap_discards_loopback \
    'sample=3/3 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$U_PROCD" "$T"
unset MONITOR_TEST_CONTROL_MODE
# Same PID, new process birth or ubusd generation: no old evidence.
T_BIRTH='SUSPECT_DNS_TIMEOUT|101|1|||1001|700:2000'
T_BUS='SUSPECT_DNS_TIMEOUT|101|1|||1000|700:2001'
H_BUS='HEALTHY_SAMPLED|101|0|||1000|700:2001'
M_BUS='SUSPECT_PROCESS_MISSING|none|1|||1000|700:2001'
run_case same_pid_new_birth 'sample=5/5 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T" "$T_BIRTH" "$T_BIRTH" "$T_BIRTH"
run_case bus_generation_new_baseline 'sample=5/5 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T" "$T_BUS" "$T_BUS" "$T_BUS"
run_case bus_generation_rearmed 'sample=6/6 state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED pid=101 streak=3' 1 \
    "$H" "$T" "$H_BUS" "$T_BUS" "$T_BUS" "$T_BUS"
run_case bus_generation_missing_streak 'sample=3/3 state=SUSPECT_PROCESS_MISSING phase=SUSPECT pid=none streak=1' 0 \
    "$M" "$M" "$M_BUS"
run_case identity_missing_rejected 'sample=4/4 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    'HEALTHY_SAMPLED|101|0|||-|700:2000' "$T" "$T" "$T"
run_case bus_missing_rejected 'sample=4/4 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    'HEALTHY_SAMPLED|101|0|||1000|-' "$T" "$T" "$T"
MONITOR_TEST_CONTROL_MODE=1
export MONITOR_TEST_CONTROL_MODE
run_case birth_change_discards_loopback 'sample=2/2 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T_BIRTH"
run_case bus_change_discards_loopback 'sample=2/2 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T_BUS"
unset MONITOR_TEST_CONTROL_MODE
# Same PID, birth and bus do not make a changed command the same runtime.
H_CMD='HEALTHY_SAMPLED|101|0|||1000|700:2000|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
T_CMD='SUSPECT_DNS_TIMEOUT|101|1|||1000|700:2000|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
run_case command_changed 'sample=5/5 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T" "$T_CMD" "$T_CMD" "$T_CMD"
run_case command_rearmed 'sample=6/6 state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED pid=101 streak=3' 1 \
    "$H" "$T" "$H_CMD" "$T_CMD" "$T_CMD" "$T_CMD"
run_case command_missing 'sample=4/4 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    'HEALTHY_SAMPLED|101|0|||1000|700:2000|-' "$T" "$T" "$T"
run_case command_invalid 'sample=4/4 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    'HEALTHY_SAMPLED|101|0|||1000|700:2000|invalid' "$T" "$T" "$T"
MONITOR_TEST_CONTROL_MODE=1
export MONITOR_TEST_CONTROL_MODE
run_case command_change_discards_loopback 'sample=2/2 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T_CMD"
unset MONITOR_TEST_CONTROL_MODE
# Same process and argv, changed sampled disk generation.
H_CFG='HEALTHY_SAMPLED|101|0|||1000|700:2000|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
T_CFG='SUSPECT_DNS_TIMEOUT|101|1|||1000|700:2000|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
run_case config_changed 'sample=5/5 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T" "$T_CFG" "$T_CFG" "$T_CFG"
run_case config_rearmed 'sample=6/6 state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED pid=101 streak=3' 1 \
    "$H" "$T" "$H_CFG" "$T_CFG" "$T_CFG" "$T_CFG"
run_case config_missing 'sample=4/4 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    'HEALTHY_SAMPLED|101|0|||1000|700:2000|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|-' "$T" "$T" "$T"
run_case config_invalid 'sample=4/4 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    'HEALTHY_SAMPLED|101|0|||1000|700:2000|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|invalid' "$T" "$T" "$T"
MONITOR_TEST_CONTROL_MODE=1
export MONITOR_TEST_CONTROL_MODE
run_case config_change_discards_loopback 'sample=2/2 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H" "$T_CFG"
unset MONITOR_TEST_CONTROL_MODE
run_case config_transition_reason 'reason=dns_config_changed' 0 "$H" 'TRANSITION|101|0||dns_config_changed' "$T"
run_case nft_reason_preserved 'reason=nft_rules_incomplete' 0 "$H" 'UNKNOWN|101|2||nft_rules_incomplete' "$T"
run_case config_path_reason_preserved 'reason=dns_config_path_mismatch' 0 "$H" 'UNKNOWN|101|2||dns_config_path_mismatch' "$T"
# Advance the private monotonic clock by one second per sample.
printf '100.00\n' > "$tmp/uptime"
MONITOR_TEST_MAINTENANCE_MAX=2 run_case maintenance_prolonged \
    'sample=4/4 state=UNKNOWN phase=UNKNOWN pid=101 streak=0 reason=maintenance_prolonged' 0 \
    'TRANSITION|101|0|100.00|list_update' 'TRANSITION|101|0|101.00|list_update' \
    'TRANSITION|101|0|102.00|podkop_lifecycle' 'TRANSITION|101|0|103.00|list_update'
printf '100.00\n' > "$tmp/uptime"
MONITOR_TEST_MAINTENANCE_MAX=1 run_case prolonged_requires_baseline \
    'sample=6/6 state=SUSPECT_DNS_TIMEOUT phase=WAITING_FOR_BASELINE pid=101 streak=0' 0 \
    "$H|100.00" 'TRANSITION|101|0|101.00|list_update' \
    'TRANSITION|101|0|102.00|list_update' "$T|103.00" "$T|104.00" "$T|105.00"
printf '100.00\n' > "$tmp/uptime"
MONITOR_TEST_MAINTENANCE_MAX=1 run_case maintenance_window_resets \
    'sample=5/5 state=TRANSITION phase=TRANSITION pid=101 streak=0 reason=list_update' 0 \
    'TRANSITION|101|0|101.00|list_update' 'TRANSITION|101|0|102.00|list_update' \
    'TRANSITION|101|0|103.00|list_update' "$H|104.00" 'TRANSITION|101|0|105.00|list_update'
printf '100.00\n' > "$tmp/uptime"
run_case late_probe_rejected 'reason=probe_late' 0 \
    "$H|100.00" "$T|120.00" "$T|121.00" "$T|122.00"
# A hard deadline is UNKNOWN, and the suspect streak must restart from zero.
deadline_start=$(date +%s)
MONITOR_TEST_DEADLINE=3 run_case deadline_breaks_streak 'reason=probe_hard_deadline' 0 \
    "$H" "$T" "$T" "HANG|101|1" "$T" "$T"
deadline_elapsed=$(( $(date +%s) - deadline_start ))
# Six samples include normal scheduling and per-sample polling. On stock
# OpenWrt integer-only sleep they can take ~20s. Still reject waiting for
# the injected sleep 35 to end naturally (that would exceed this bound).
[ "$deadline_elapsed" -lt 45 ] || {
    echo "FAIL monitor bounded sequence took ${deadline_elapsed}s" >&2; exit 1;
}
read -r child < "$tmp/childpid"
case "$child" in ''|*[!0-9]*) echo "FAIL invalid monitor child PID" >&2; exit 1 ;; esac
if [ -r "/proc/$child/stat" ]; then
    stat=$(cat "/proc/$child/stat")
    case "$stat" in *') Z '*) ;; *)
        echo "FAIL monitor child remains running: $child" >&2; exit 1 ;;
    esac
fi
passed=$((passed + 1))
echo 'PASS deadline_no_running_orphan'

# A missing process during the initial boot grace is not confirmed.
printf '%s\n' "$M" "$M" "$M" > "$tmp/fixture"
printf '0\n' > "$tmp/counter"
output=$(env MONITOR_TEST_FIXTURE="$tmp/fixture" \
    MONITOR_TEST_COUNTER="$tmp/counter" \
    PODKOP_GUARD_WATCH_CHECK_SCRIPT="$tmp/mock-check" \
    PODKOP_GUARD_WATCH_UPTIME_FILE="$tmp/uptime" \
    PODKOP_GUARD_WATCH_GRACE=180 \
    sh "$script" watchdog-monitor 3 0)
case "$output" in
    *'phase=STARTUP_GRACE'*'MONITOR_END completed=3 confirmations=0 action=none'*) passed=$((passed + 1)); printf 'PASS startup_grace\n' ;;
    *) printf 'FAIL startup_grace:\n%s\n' "$output" >&2; exit 1 ;;
esac

for invalid in 0 86401 abc; do
    set +e
    PODKOP_GUARD_WATCH_MAINTENANCE_MAX="$invalid" sh "$script" watchdog-monitor 1 0 >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { echo "FAIL invalid maintenance threshold $invalid rc=$rc" >&2; exit 1; }
done
for args in '0 0' '31 0' '2 301' 'abc 0'; do
    set +e
    sh "$script" watchdog-monitor $args >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { printf 'FAIL invalid arguments %s rc=%s\n' "$args" "$rc" >&2; exit 1; }
done
passed=$((passed + 1))
printf 'PASS numeric-validation\n'

# In continuous mode an invalid interval must fail before entering the loop.
for seconds in 0 4 301 abc; do
    set +e
    PODKOP_GUARD_WATCH_INTERVAL="$seconds" sh "$script" watchdog-observe >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || {
        printf 'FAIL continuous interval %s returned %s\n' "$seconds" "$rc" >&2
        exit 1
    }
done
passed=$((passed + 1))
set +e
PODKOP_GUARD_WATCH_MAX_SAMPLE=21 sh "$script" watchdog-observe >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL continuous deadline boundary rc=$rc" >&2; exit 1; }
passed=$((passed + 1))
printf 'PASS continuous-interval-safety\nPASS resident-deadline-safety\nPASS: %s deterministic monitor scenarios\n' "$passed"
