#!/bin/sh
# Stage B1 pure procd event decoding + independent read-only procd snapshot.
# No real ubus subscriptions, networking or destructive fault injection.
set -eu
worker="${1:-./podkop-guard}"
case "$worker" in /*) ;; *) worker="$(pwd)/${worker#./}" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
[ "$#" -eq 6 ] && [ "$1 $2 $3 $4 $5 $6" = '-t 5 call service list {"name":"sing-box"}' ] || {
    echo forbidden > "$PROCD_TEST_FORBIDDEN"; exit 9;
}
[ "$PROCD_TEST_UBUS" != fail ] || exit 1
n=$(cat "$PROCD_TEST_COUNTER" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$PROCD_TEST_COUNTER"
if [ "$n" -eq 2 ]; then
    case "${PROCD_TEST_RACE:-}" in
        registration) printf '{}\n'; exit 0 ;;
        bus) printf '700:2001\n' > "$PODKOP_GUARD_PROCD_BUS_FILE" ;;
        birth) sed 's/ 1000 0$/ 1001 0/' "$PODKOP_GUARD_WATCH_PROC_ROOT/24430/stat" > "$PODKOP_GUARD_WATCH_PROC_ROOT/newstat"
            mv "$PODKOP_GUARD_WATCH_PROC_ROOT/newstat" "$PODKOP_GUARD_WATCH_PROC_ROOT/24430/stat" ;;
        rpc) exit 1 ;;
        argv) printf '/usr/bin/sing-box\000run\000-c\000/other.json\000' > "$PODKOP_GUARD_WATCH_PROC_ROOT/24430/cmdline" ;;
    esac
fi
printf '%s\n' "$PROCD_TEST_REPLY"
SH
chmod +x "$tmp/bin/ubus"
export PATH="$tmp/bin:$PATH" PROCD_TEST_FORBIDDEN="$tmp/forbidden"
# Fake /proc only for deterministic snapshots; real VM separately checks
# the executable and NUL-separated argv of the actual sing-box.
mkdir -p "$tmp/proc/24430"
ln -s /usr/bin/sing-box "$tmp/proc/24430/exe"
printf '/usr/bin/sing-box\000run\000' > "$tmp/proc/24430/cmdline"
{ printf '24430 (sing box) S'; n=0
  while [ "$n" -lt 18 ]; do printf ' 0'; n=$((n + 1)); done
  printf ' 1000 0\n'
} > "$tmp/proc/24430/stat"
export PODKOP_GUARD_WATCH_PROC_ROOT="$tmp/proc"
export PODKOP_GUARD_PROCD_BUS_FILE="$tmp/bus" PROCD_TEST_COUNTER="$tmp/count"
passed=0
event_case() {
    name=$1 expected=$2 input=$3
    : > "$PROCD_TEST_FORBIDDEN"
    actual=$(printf '%s\n' "$input" | sh "$worker" watchdog-procd-event) || {
        echo "FAIL $name: nonzero rc" >&2; exit 1;
    }
    [ "$actual" = "$expected" ] || {
        printf 'FAIL %s\nexpected=%s\nactual=%s\n' "$name" "$expected" "$actual" >&2; exit 1;
    }
    [ ! -s "$PROCD_TEST_FORBIDDEN" ] || exit 1
    passed=$((passed+1))
}
real='{"service":"sing-box","instance":"sing-box.main","pid":16524,"exit_code":137,"respawn_count":3,"command":["/usr/bin/sing-box","run","-c","/etc/sing-box/config.json"]}'
event_case respawn 'PROCD_EVENT state=RESPAWN_REPORTED source=procd pid=16524 exit_code=137 respawn_count=3 action=none' "{\"instance.respawn\":$real}"
event_case crash_loop 'PROCD_EVENT state=CRASH_LOOP_REPORTED source=procd pid=16524 exit_code=137 respawn_count=3 action=none' "{\"instance.fail\":$real}"
# Exact thin notifications captured on both OpenWrt guests.
event_case thin_respawn 'PROCD_EVENT state=RESPAWN_REPORTED source=procd detail=notification_only action=none' '{"instance.respawn":{"service":"sing-box","instance":"sing-box.main"}}'
event_case thin_fail 'PROCD_EVENT state=CRASH_LOOP_REPORTED source=procd detail=notification_only action=none' '{"instance.fail":{"service":"sing-box","instance":"sing-box.main"}}'
event_case thin_foreign 'PROCD_EVENT state=IGNORED reason=other_instance action=none' '{"instance.fail":{"service":"sing-box","instance":"validator"}}'
event_case thin_partial_pid 'PROCD_EVENT state=UNKNOWN reason=invalid_exit_fields action=none' '{"instance.respawn":{"service":"sing-box","instance":"sing-box.main","pid":null}}'
event_case thin_partial_command 'PROCD_EVENT state=UNKNOWN reason=invalid_exit_fields action=none' '{"instance.fail":{"service":"sing-box","instance":"sing-box.main","command":["/usr/bin/sing-box","run"]}}'
event_case start 'PROCD_EVENT state=STARTED source=procd action=none' '{"instance.start":{"service":"sing-box","instance":"sing-box.main"}}'
event_case stop 'PROCD_EVENT state=STOPPED source=procd reason=undetermined action=none' '{"instance.stop":{"service":"sing-box","instance":"sing-box.main"}}'
event_case other_service 'PROCD_EVENT state=IGNORED reason=other_instance action=none' '{"instance.fail":{"service":"podkop-guard","instance":"instance1","pid":1}}'
event_case other_instance 'PROCD_EVENT state=IGNORED reason=other_instance action=none' '{"instance.respawn":{"service":"sing-box","instance":"validator","pid":1}}'
event_case other_event 'PROCD_EVENT state=IGNORED reason=other_event action=none' '{"network.interface":{"interface":"wan"}}'
event_case invalid_json 'PROCD_EVENT state=UNKNOWN reason=invalid_json action=none' '{bad-json'
event_case invalid_array 'PROCD_EVENT state=UNKNOWN reason=invalid_envelope action=none' '[]'
event_case invalid_null 'PROCD_EVENT state=UNKNOWN reason=invalid_payload action=none' '{"instance.fail":null}'
event_case wrong_command 'PROCD_EVENT state=UNKNOWN reason=invalid_exit_fields action=none' '{"instance.fail":{"service":"sing-box","instance":"sing-box.main","pid":2,"exit_code":1,"respawn_count":3,"command":["/tmp/validator","run"]}}'
event_case no_exit_code 'PROCD_EVENT state=UNKNOWN reason=invalid_exit_fields action=none' '{"instance.fail":{"service":"sing-box","instance":"sing-box.main","pid":2,"respawn_count":3,"command":["/usr/bin/sing-box"]}}'
event_case spoofed_code 'PROCD_EVENT state=UNKNOWN reason=invalid_exit_fields action=none' '{"instance.fail":{"service":"sing-box","instance":"sing-box.main","pid":2,"exit_code":"137","respawn_count":3,"command":["/usr/bin/sing-box"]}}'
event_case negative_count 'PROCD_EVENT state=UNKNOWN reason=invalid_exit_fields action=none' '{"instance.fail":{"service":"sing-box","instance":"sing-box.main","pid":2,"exit_code":1,"respawn_count":-1,"command":["/usr/bin/sing-box"]}}'
event_case bad_pid 'PROCD_EVENT state=UNKNOWN reason=invalid_exit_fields action=none' '{"instance.fail":{"service":"sing-box","instance":"sing-box.main","pid":0,"exit_code":1,"respawn_count":2,"command":["/usr/bin/sing-box"]}}'
event_case foreign_service 'PROCD_EVENT state=IGNORED reason=other_instance action=none' '{"instance.start":{"service":"dnsmasq","instance":"instance1"}}'
event_case empty_data 'PROCD_EVENT state=UNKNOWN reason=empty_input action=none' ''
# Oversized event must not be logged verbatim or parsed.
big=$(awk 'BEGIN {printf "%9000s", "x"}')
event_case too_long 'PROCD_EVENT state=UNKNOWN reason=oversize action=none' "$big"

snapshot_case() {
    name=$1 expected=$2 response=$3 status=$4
    : > "$PROCD_TEST_FORBIDDEN"
    printf '0\n' > "$PROCD_TEST_COUNTER"
    printf '700:2000\n' > "$PODKOP_GUARD_PROCD_BUS_FILE"
    PROCD_TEST_REPLY="$response" PROCD_TEST_UBUS="$status" export PROCD_TEST_REPLY PROCD_TEST_UBUS
    actual=$(sh "$worker" watchdog-procd-snapshot) || {
        echo "FAIL snapshot $name: rc" >&2; exit 1;
    }
    [ "$actual" = "$expected" ] || {
        printf 'FAIL %s expected=%s actual=%s\n' "$name" "$expected" "$actual" >&2; exit 1;
    }
    [ ! -s "$PROCD_TEST_FORBIDDEN" ] || { echo "FAIL forbidden action" >&2; exit 1; }
    passed=$((passed+1))
}
snapshot_case active 'PROCD_SNAPSHOT state=RUNNING pid=24430 action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":24430,"command":["/usr/bin/sing-box","run"]}}}}' ok
snapshot_case exited 'PROCD_SNAPSHOT state=STOPPED exit_code=1 reason=undetermined action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":false,"exit_code":1,"command":["/usr/bin/sing-box","run"]}}}}' ok
snapshot_case missing_exit 'PROCD_SNAPSHOT state=STOPPED exit_code=unknown reason=undetermined action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":false,"command":["/usr/bin/sing-box","run"]}}}}' ok
snapshot_case missing_instance 'PROCD_SNAPSHOT state=UNREGISTERED reason=not_listed action=none' '{"sing-box":{"instances":{}}}' ok
snapshot_case missing_service 'PROCD_SNAPSHOT state=UNREGISTERED reason=not_listed action=none' '{}' ok
snapshot_case false_running 'PROCD_SNAPSHOT state=UNKNOWN reason=incomplete_instance action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":true,"command":["/usr/bin/sing-box","run"]}}}}' ok
snapshot_case wrong_process 'PROCD_SNAPSHOT state=UNKNOWN reason=wrong_command action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":1,"command":["/tmp/sing-box-validator"]}}}}' ok
snapshot_case bus_error 'PROCD_SNAPSHOT state=UNKNOWN reason=ubus_unavailable action=none' '{}' fail
snapshot_case invalid_reply 'PROCD_SNAPSHOT state=UNKNOWN reason=invalid_json action=none' '{' ok
snapshot_case empty_reply 'PROCD_SNAPSHOT state=UNKNOWN reason=empty_reply action=none' '' ok

# B6.2a.1: missing keys and invalid types must not be conflated.
snapshot_case empty_service 'PROCD_SNAPSHOT state=UNREGISTERED reason=not_listed action=none' '{"sing-box":{}}' ok
snapshot_case malformed_service 'PROCD_SNAPSHOT state=UNKNOWN reason=invalid_service action=none' '{"sing-box":null}' ok
snapshot_case malformed_instances 'PROCD_SNAPSHOT state=UNKNOWN reason=invalid_instances action=none' '{"sing-box":{"instances":[]}}' ok
snapshot_case malformed_instance 'PROCD_SNAPSHOT state=UNKNOWN reason=invalid_instance action=none' '{"sing-box":{"instances":{"sing-box.main":null}}}' ok
snapshot_case multi_reply 'PROCD_SNAPSHOT state=UNKNOWN reason=invalid_reply action=none' '{} {}' ok
snapshot_case wrong_operation 'PROCD_SNAPSHOT state=UNKNOWN reason=wrong_command action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":24430,"command":["/usr/bin/sing-box","check"]}}}}' ok
snapshot_case stopped_with_pid 'PROCD_SNAPSHOT state=UNKNOWN reason=incomplete_instance action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":false,"pid":24430,"command":["/usr/bin/sing-box","run"]}}}}' ok
# A complete run command is required independently of exit metadata.
snapshot_case stopped_missing_operation 'PROCD_SNAPSHOT state=UNKNOWN reason=wrong_command action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":false,"command":["/usr/bin/sing-box"]}}}}' ok
snapshot_case running_missing_operation 'PROCD_SNAPSHOT state=UNKNOWN reason=wrong_command action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":24430,"command":["/usr/bin/sing-box"]}}}}' ok
# Exact argv boundaries: same flattened words are not the same argv.
printf '/usr/bin/sing-box\000run\000-c\000/a b.json\000' > "$tmp/proc/24430/cmdline"
snapshot_case spaced_argument 'PROCD_SNAPSHOT state=RUNNING pid=24430 action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":24430,"command":["/usr/bin/sing-box","run","-c","/a b.json"]}}}}' ok
snapshot_case split_argument 'PROCD_SNAPSHOT state=UNKNOWN reason=runtime_identity_unavailable action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":24430,"command":["/usr/bin/sing-box","run","-c","/a","b.json"]}}}}' ok
printf '/usr/bin/sing-box\000run\000' > "$tmp/proc/24430/cmdline"
rm -f "$tmp/proc/24430/exe"
ln -s '/usr/bin/sing-box (deleted)' "$tmp/proc/24430/exe"
snapshot_case deleted_executable 'PROCD_SNAPSHOT state=UNKNOWN reason=runtime_identity_unavailable action=none' '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":24430,"command":["/usr/bin/sing-box","run"]}}}}' ok
# A second observation must agree with the first before reporting RUNNING.
rm -f "$tmp/proc/24430/exe"
ln -s /usr/bin/sing-box "$tmp/proc/24430/exe"
running='{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":24430,"command":["/usr/bin/sing-box","run"]}}}}'
export PROCD_TEST_RACE=registration
snapshot_case registration_changed 'PROCD_SNAPSHOT state=UNKNOWN reason=runtime_identity_changed action=none' "$running" ok
PROCD_TEST_RACE=rpc
snapshot_case second_rpc_failed 'PROCD_SNAPSHOT state=UNKNOWN reason=runtime_identity_changed action=none' "$running" ok
PROCD_TEST_RACE=bus
snapshot_case bus_changed 'PROCD_SNAPSHOT state=UNKNOWN reason=ubusd_identity_changed action=none' "$running" ok
PROCD_TEST_RACE=argv
snapshot_case second_argv_changed 'PROCD_SNAPSHOT state=UNKNOWN reason=runtime_identity_unavailable action=none' "$running" ok
printf '/usr/bin/sing-box\000run\000' > "$tmp/proc/24430/cmdline"
PROCD_TEST_RACE=birth
snapshot_case birth_changed 'PROCD_SNAPSHOT state=UNKNOWN reason=runtime_identity_unavailable action=none' "$running" ok
unset PROCD_TEST_RACE
snapshot_case fresh_identity 'PROCD_SNAPSHOT state=RUNNING pid=24430 action=none' "$running" ok
# Disallow arguments that could accidentally request service actions.
for cmd in watchdog-procd-event watchdog-procd-snapshot; do
    set +e
    sh "$worker" "$cmd" --restart >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { echo "FAIL $cmd invalid arguments rc=$rc" >&2; exit 1; }
    passed=$((passed+1))
done
printf 'PASS: %s procd event/snapshot scenarios, all observe-only\n' "$passed"
