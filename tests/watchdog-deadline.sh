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
    background_result)
        (sleep 35) &
        echo $! > "$DEADLINE_CHILD_PID_FILE"
        echo 'WATCHDOG state=HEALTHY_SAMPLED pid=123 dns=fakeip nft=present' ;;
    leader_gone|guard_gone)
        (sleep 35) &
        echo $! > "$DEADLINE_CHILD_PID_FILE"
        IFS= read -r stat < /proc/self/stat || exit 19
        rest=${stat##*) }; set -- $rest; group=$3
        [ "$3" = "$4" ] && [ "$group" -gt 1 ] || exit 19
        target=$group
        if [ "$DEADLINE_FIXTURE" = guard_gone ]; then
            dir=$(tr '\000' '\n' < "/proc/$group/cmdline" | grep '^/tmp/podkop-guard-probe\.' | tail -n 1)
            read -r target < "$dir/guard" || exit 19
        fi
        case "$target" in ''|*[!0-9]*) exit 19 ;; esac
        [ "$target" -gt 1 ] || exit 19
        IFS= read -r stat < "/proc/$target/stat" || exit 19
        rest=${stat##*) }; set -- $rest
        # Fault injection may target ONLY the test's own isolated session.
        [ "$3" = "$group" ] && [ "$4" = "$group" ] || exit 19
        kill -KILL "$target" || exit 19
        wait ;;
    invalid) exit 19 ;;
    empty) : ;;
    fd_isolation)
        if [ "$DEADLINE_EXPECT_FIFO" = 1 ]; then
            IFS= read -r stat < /proc/self/stat || exit 19
            self=${stat%% *}
            rest=${stat##*) }
            set -- $rest
            parent=$2
            # ash may temporarily save redirections on FD 10/11 or other
            # numbers while running a child. Identify the actual FIFO pair,
            # not the original FD numbers. Check ALL child FD aliases.
            notify=; arm=
            for fd in /proc/"$parent"/fd/[0-9]*; do
                target=$(readlink "$fd" 2>/dev/null) || continue
                [ -p "$fd" ] || continue
                case "$target" in
                    /tmp/podkop-guard-probe.*/notify) notify=$target ;;
                    /tmp/podkop-guard-probe.*/arm) arm=$target ;;
                esac
            done
            [ -n "$notify" ] && [ -n "$arm" ] &&
                [ "${notify%/notify}" = "${arm%/arm}" ] || {
                printf 'FIFO parent pair not verified\n' > "$DEADLINE_CHILD_PID_FILE.fd_error"
                exit 19
            }
            for fd in /proc/"$self"/fd/[0-9]*; do
                target=$(readlink "$fd" 2>/dev/null) || continue
                case "$target" in "$notify"|"$arm")
                    printf 'Inherited FIFO: %s\n' "$fd" > "$DEADLINE_CHILD_PID_FILE.fd_error"
                    exit 19 ;;
                esac
            done
        fi
        echo 'WATCHDOG state=HEALTHY_SAMPLED pid=123 dns=fakeip nft=present' ;;
esac
SH
chmod +x "$tmp/check"
export PODKOP_GUARD_WATCH_CHECK_SCRIPT="$tmp/check"
export DEADLINE_CHILD_PID_FILE="$tmp/childpid"
DEADLINE_EXPECT_FIFO=0
if command -v mkfifo >/dev/null 2>&1 &&
   (IFS= read -r -t 1 wake 2>/dev/null <<'PG_TIMED_READ'
ready
PG_TIMED_READ
    [ "$wake" = ready ]); then
    DEADLINE_EXPECT_FIFO=1
fi
export DEADLINE_EXPECT_FIFO
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
        echo "FAIL $name: rc=$rc expected=$rc_expected; out=$out expected=$expected" >&2
        if [ -s "$DEADLINE_CHILD_PID_FILE.fd_error" ]; then
            cat "$DEADLINE_CHILD_PID_FILE.fd_error" >&2
        fi
        exit 1;
    }
    passed=$((passed + 1))
    printf 'PASS %s\n' "$name"
}
quick_start=$(date +%s)
verify healthy 'WATCHDOG state=HEALTHY_SAMPLED pid=123 dns=fakeip nft=present' 0 healthy
verify suspect 'WATCHDOG state=SUSPECT_DNS_TIMEOUT pid=123 dns=timeout nft=present' 1 suspect
verify invalid_exit 'WATCHDOG state=UNKNOWN reason=probe_invalid_exit' 2 invalid
verify empty_output 'WATCHDOG state=UNKNOWN reason=probe_empty_output' 2 empty
verify fd_isolation 'WATCHDOG state=HEALTHY_SAMPLED pid=123 dns=fakeip nft=present' 0 fd_isolation
printf 'TIMING quick_probes=5 elapsed_s=%s fifo=%s\n' "$(( $(date +%s) - quick_start ))" "$DEADLINE_EXPECT_FIFO"
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
        sleep 0.1 2>/dev/null || sleep 1
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
        sleep 0.1 2>/dev/null || sleep 1
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
# B5.2: a completed probe must not leave a running descendant, and
# loss of either session leader or independent guard must remain bounded.
for fixture in background_result leader_gone guard_gone; do
    rm -f "$tmp/childpid"
    expected='WATCHDOG state=UNKNOWN reason=probe_hard_deadline'
    expect_rc=2
    if [ "$fixture" = background_result ]; then
        expected='WATCHDOG state=HEALTHY_SAMPLED pid=123 dns=fakeip nft=present'
        expect_rc=0
    fi
    started=$(date +%s)
    verify "$fixture" "$expected" "$expect_rc" "$fixture"
    elapsed=$(( $(date +%s) - started ))
    [ "$elapsed" -lt 15 ] || { echo "FAIL $fixture elapsed=$elapsed" >&2; exit 1; }
    read -r child < "$tmp/childpid"
    case "$child" in ''|*[!0-9]*) exit 1 ;; esac
    if [ -r "/proc/$child/stat" ]; then
        stat=$(cat "/proc/$child/stat")
        case "$stat" in *') Z '*) ;; *)
            echo "FAIL $fixture running child $child" >&2; exit 1 ;;
        esac
    fi
    passed=$((passed + 1))
    printf 'PASS %s_no_running_orphan\n' "$fixture"
done

# Real, unrelated disposable session + a deliberately stale birth marker.
# This exercises authorization without forcing global PID reuse.
setsid sh -c '
    outfile=$1
    IFS= read -r stat < /proc/self/stat || exit 1
    pid=${stat%% *}; rest=${stat##*) }; set -- $rest
    [ "$3" = "$pid" ] && [ "$4" = "$pid" ] || exit 1
    printf "%s %s\n" "$pid" "${20}" > "$outfile"
    exec sleep 40
' fixture "$tmp/sentinel" >/dev/null 2>&1 &
sentinel_launcher=$!
start=$(date +%s)
while [ ! -s "$tmp/sentinel" ]; do
    [ "$(( $(date +%s) - start ))" -lt 6 ] || { echo 'FAIL sentinel startup' >&2; exit 1; }
    sleep 0.1 2>/dev/null || sleep 1
done
read -r sentinel birth < "$tmp/sentinel"
case "$sentinel:$birth" in *[!0-9:]*|:*|*:) exit 1 ;; esac
[ "$sentinel" -gt 1 ] && [ "$birth" -gt 0 ] || exit 1
mkdir "$tmp/bin"
cat > "$tmp/bin/setsid" <<'SH'
#!/bin/sh
[ "$4" = b5 ] || exit 19
printf '%s\n' "$6" > "$DEADLINE_FAKE_DIR"
if [ "$DEADLINE_FAKE_MODE" = missing ]; then exit 19; fi
printf '%s 0\n' "$DEADLINE_SENTINEL" > "$6/pid"
if [ "$7" = fifo ]; then printf 'pid\n' >&8; fi
SH
chmod +x "$tmp/bin/setsid"
set +e
out=$(PATH="$tmp/bin:$PATH" DEADLINE_FAKE_MODE=stale DEADLINE_FAKE_DIR="$tmp/fake-dir" \
    DEADLINE_SENTINEL="$sentinel" sh "$worker" watchdog-check-bounded 3)
rc=$?
set -e
sentinel_alive=0
if IFS= read -r stat < "/proc/$sentinel/stat" 2>/dev/null; then
    rest=${stat##*) }; set -- $rest
    if [ "$3" = "$sentinel" ] && [ "$4" = "$sentinel" ] &&
       [ "${20}" = "$birth" ] && [ "$1" != Z ]; then
        sentinel_alive=1
        kill -TERM "$sentinel" 2>/dev/null || :
    fi
fi
wait "$sentinel_launcher" 2>/dev/null || :
[ "$rc" -eq 2 ] && [ "$out" = 'WATCHDOG state=UNKNOWN reason=probe_isolation_unverified' ] &&
    [ "$sentinel_alive" -eq 1 ] && [ ! -e "$(cat "$tmp/fake-dir")" ] || {
    echo "FAIL stale_identity rc=$rc alive=$sentinel_alive out=$out" >&2; exit 1;
}
passed=$((passed + 1))
echo 'PASS stale_identity_no_signal'

# Failed startup before arming must clean its private resources.
set +e
out=$(PATH="$tmp/bin:$PATH" DEADLINE_FAKE_MODE=missing DEADLINE_FAKE_DIR="$tmp/fake-dir" \
    sh "$worker" watchdog-check-bounded 3)
rc=$?
set -e
[ "$rc" -eq 2 ] && [ "$out" = 'WATCHDOG state=UNKNOWN reason=probe_start_unverified' ] &&
    [ ! -e "$(cat "$tmp/fake-dir")" ] || {
    echo "FAIL prearm_failure rc=$rc out=$out" >&2; exit 1;
}
passed=$((passed + 1))
echo 'PASS prearm_failure_cleanup'
printf 'PASS: %s B4 bounded cases\n' "$passed"
