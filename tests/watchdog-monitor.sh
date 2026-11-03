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
read -r state pid rc simulated_uptime <<EOF
$line
EOF
IFS=$oldifs
if [ -n "$simulated_uptime" ]; then
    printf '%s\n' "$simulated_uptime" > "$MONITOR_TEST_UPTIME_FILE"
fi
printf 'WATCHDOG state=%s pid=%s mock=yes\n' "$state" "$pid"
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
      PODKOP_GUARD_WATCH_CHECK_SCRIPT="$tmp/mock-check" \
      PODKOP_GUARD_WATCH_UPTIME_FILE="$tmp/uptime" \
      PODKOP_GUARD_WATCH_GRACE=0 \
      sh "$script" watchdog-monitor "$#" 0 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL %s: unexpected rc=%s\n%s\n' "$name" "$rc" "$output" >&2
        exit 1
    fi
    case "$output" in
        *"$expected"*) ;;
        *) printf 'FAIL %s: expected %s, got:\n%s\n' "$name" "$expected" "$output" >&2; exit 1 ;;
    esac
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
run_case late_probe_rejected 'reason=probe_late' 0 \
    "$H|100.00" "$T|120.00" "$T|121.00" "$T|122.00"

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

for args in '0 0' '31 0' '2 301' 'abc 0'; do
    set +e
    sh "$script" watchdog-monitor $args >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { printf 'FAIL invalid arguments %s rc=%s\n' "$args" "$rc" >&2; exit 1; }
done
passed=$((passed + 1))
printf 'PASS numeric-validation\nPASS: %s deterministic monitor scenarios\n' "$passed"
