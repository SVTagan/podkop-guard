#!/bin/sh
# B4.1: mock isolated worker; no actual sing-box, VPN or firewall.
set -eu
worker=$1
case "$worker" in /*) ;; *) worker="$(pwd)/$worker" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat > "$tmp/check" <<'SH'
#!/bin/sh
case "$DEADLINE_FIXTURE" in
    healthy) echo 'WATCHDOG state=HEALTHY_SAMPLED pid=123 dns=fakeip nft=present' ;;
    suspect) echo 'WATCHDOG state=SUSPECT_DNS_TIMEOUT pid=123 dns=timeout nft=present'; exit 1 ;;
    hung)
        (sleep 35) &
        echo $! > "$DEADLINE_CHILD_PID_FILE"
        wait ;;
    invalid) exit 19 ;;
    empty) : ;;
esac
SH
chmod +x "$tmp/check"
export PODKOP_GUARD_WATCH_CHECK_SCRIPT="$tmp/check"
export DEADLINE_CHILD_PID_FILE="$tmp/childpid"
passed=0
verify() {
    name=$1 expected=$2 rc_expected=$3
    DEADLINE_FIXTURE=$4
    export DEADLINE_FIXTURE
    set +e
    out=$(sh "$worker" watchdog-check-bounded 3)
    rc=$?
    set -e
    [ "$rc" -eq "$rc_expected" ] && [ "$out" = "$expected" ] || {
        echo "FAIL $name: rc=$rc expected=$rc_expected; out=$out expected=$expected" >&2; exit 1;
    }
    passed=$((passed + 1))
    printf 'PASS %s\n' "$name"
}
verify healthy 'WATCHDOG state=HEALTHY_SAMPLED pid=123 dns=fakeip nft=present' 0 healthy
verify suspect 'WATCHDOG state=SUSPECT_DNS_TIMEOUT pid=123 dns=timeout nft=present' 1 suspect
verify invalid_exit 'WATCHDOG state=UNKNOWN reason=probe_invalid_exit' 2 invalid
verify empty_output 'WATCHDOG state=UNKNOWN reason=probe_empty_output' 2 empty
deadline_start=$(date +%s)
verify hard_deadline 'WATCHDOG state=UNKNOWN reason=probe_hard_deadline' 2 hung
deadline_elapsed=$(( $(date +%s) - deadline_start ))
[ "$deadline_elapsed" -lt 15 ] || {
    echo "FAIL hard deadline took ${deadline_elapsed}s (child may have exited naturally)" >&2
    exit 1
}
read -r pid < "$tmp/childpid"
case "$pid" in ''|*[!0-9]*) echo 'FAIL invalid child PID' >&2; exit 1 ;; esac
if [ -r "/proc/$pid/stat" ]; then
    stat=$(cat "/proc/$pid/stat")
    case "$stat" in *') Z '*) ;; *)
        echo "FAIL diagnostic child remains running: $pid" >&2; exit 1 ;;
    esac
fi
passed=$((passed + 1))
echo 'PASS no_running_orphan'
for bad in 0 2 121 abc; do
    set +e
    sh "$worker" watchdog-check-bounded "$bad" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { echo "FAIL invalid argument $bad rc=$rc" >&2; exit 1; }
    passed=$((passed + 1))
done
# SIGTERM must clean immediately. SIGKILL cannot be trapped: the independent
# timer must still kill the diagnostic subtree at the hard deadline.
for signal in TERM KILL; do
    rm -f "$tmp/childpid"
    DEADLINE_FIXTURE=hung
    export DEADLINE_FIXTURE
    sh "$worker" watchdog-check-bounded 3 > "$tmp/signal.out" 2>&1 &
    controller=$!
    tries=0
    while [ ! -s "$tmp/childpid" ] && [ "$tries" -lt 50 ]; do
        tries=$((tries + 1))
        sleep 0.1
    done
    [ -s "$tmp/childpid" ] || {
        echo "FAIL signal_${signal}: child did not start" >&2; exit 1;
    }
    read -r child < "$tmp/childpid"
    case "$child" in ''|*[!0-9]*) echo "FAIL signal_${signal}: invalid PID" >&2; exit 1 ;; esac
    signal_start=$(date +%s)
    kill "-$signal" "$controller" 2>/dev/null || :
    wait "$controller" 2>/dev/null || :
    tries=0
    while [ "$tries" -lt 55 ]; do
        alive=0
        if [ -r "/proc/$child/stat" ]; then
            stat=$(cat "/proc/$child/stat")
            case "$stat" in *') Z '*) ;; *) alive=1 ;; esac
        fi
        [ "$alive" -eq 0 ] && break
        tries=$((tries + 1))
        sleep 0.1
    done
    [ "$alive" -eq 0 ] || {
        echo "FAIL signal_${signal}: child survived deadline" >&2; exit 1;
    }
    signal_elapsed=$(( $(date +%s) - signal_start ))
    [ "$signal_elapsed" -lt 15 ] || {
        echo "FAIL signal_${signal} cleanup took ${signal_elapsed}s" >&2; exit 1;
    }
    passed=$((passed + 1))
    echo "PASS signal_${signal}_no_running_orphan"
done
printf 'PASS: %s B4 bounded cases\n' "$passed"
