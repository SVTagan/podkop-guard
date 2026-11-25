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
    supervisors_stopped|supervisors_lost)
        # Test-only injection: all targets must be members of OUR new
        # isolated session. Keep only this fixture and its immediate
        # wrapper alive; dash may have an additional sleep/timer subtree.
        IFS= read -r stat < /proc/self/stat || exit 19
        self=${stat%% *}; rest=${stat##*) }; set -- $rest
        wrapper=$2; group=$3
        [ "$#" -ge 20 ] && [ "$3" = "$4" ] && [ "$group" -gt 1 ] &&
            [ "$self" != "$group" ] && [ "$wrapper" != "$group" ] || exit 19
        read -r dir < "$B5_CASE_DIR" || exit 19
        read -r leader leader_birth < "$dir/pid" || exit 19
        read -r guard < "$dir/guard" || exit 19
        [ "$leader" = "$group" ] && [ "$guard" != "$wrapper" ] &&
            [ "$guard" != "$self" ] || exit 19
        member_signal() {
            member=$2
            case "$member" in ""|*[!0-9]*) return 1 ;; esac
            [ "$member" -gt 1 ] && [ "$member" != "$self" ] &&
                [ "$member" != "$wrapper" ] || return 1
            { IFS= read -r stat < "/proc/$member/stat"; } 2>/dev/null || return 1
            rest=${stat##*) }; set -- "$1" $rest
            [ "$#" -ge 5 ] && [ "$4" = "$group" ] && [ "$5" = "$group" ] || return 1
            case "$2" in Z|X|x) return 1 ;; esac
            kill "-$1" "$member"
        }
        # Freeze both supervisors before scanning their auxiliary children,
        # so they cannot spawn more timer processes during the scan.
        member_signal STOP "$leader" && member_signal STOP "$guard" || exit 19
        for entry in /proc/[0-9]*/stat; do
            target=${entry#/proc/}; target=${target%/stat}
            member_signal STOP "$target" 2>/dev/null || :
        done
        if [ "$DEADLINE_FIXTURE" = supervisors_lost ]; then
            for entry in /proc/[0-9]*/stat; do
                target=${entry#/proc/}; target=${target%/stat}
                member_signal KILL "$target" 2>/dev/null || :
            done
        fi
        printf '%s %s %s\n' "$self" "$leader" "$guard" > "$B5_FAULT_READY"
        # This independent TEST fixture stays alive until the observer
        # returns, proving its timeout did not depend on our natural exit.
        # Always release/kill the disposable group even if the test fails.
        read -r now unused < /proc/uptime || exit 19
        until=$((${now%%.*} + 25))
        while [ ! -f "$B5_FAULT_RELEASE" ]; do
            read -r now unused < /proc/uptime || break
            [ "${now%%.*}" -lt "$until" ] || break
            sleep 1
        done
        if [ ! -f "$B5_FAULT_RELEASE" ]; then
            : > "$B5_FAULT_FALLBACK"
            kill -KILL 0
        fi
        if [ "$DEADLINE_FIXTURE" = supervisors_stopped ]; then
            # Only the test fixture resumes its OWN group. Surviving
            # production supervisors must detect expiry and reclaim it.
            kill -CONT 0
            sleep 6
            : > "$B5_FAULT_FALLBACK"
        fi
        # In the permanent-loss case this is explicitly TEST-ONLY cleanup,
        # not a capability or guarantee of the production watchdog.
        kill -KILL 0 ;;
    cpu_contention)
        # Three finite CPU-bound children, without stress-ng or extra
        # packages. Record each actual PID/birth before consuming CPU.
        for n in 1 2 3; do
            (
                IFS= read -r stat < /proc/self/stat || exit 19
                self=${stat%% *}; rest=${stat##*) }; set -- $rest
                printf '%s %s\n' "$self" "${20}" > "$B5_CPU_DIR/burner.$n"
                read -r now unused < /proc/uptime || exit 19
                until=$((${now%%.*} + 18))
                while :; do
                    i=0
                    while [ "$i" -lt 1000 ]; do i=$((i + 1)); done
                    read -r now unused < /proc/uptime || exit 19
                    [ "${now%%.*}" -lt "$until" ] || break
                done
            ) &
        done
        wait ;;
    invalid) exit 19 ;;
    empty) : ;;
    fd_isolation)
        IFS= read -r stat < /proc/self/stat || exit 19
        self=${stat%% *}
        # IPC FDs are private, but the containment lease MUST be inherited.
        [ "$(readlink "/proc/$self/fd/7" 2>/dev/null)" = /tmp/podkop-guard-probe.lock/lease ] || exit 19
        if [ "$DEADLINE_EXPECT_FIFO" = 1 ]; then
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

# B5.2b: signal the actual controller rather than the outer CLI. The
# setsid wrapper gates pre-arm progress by stopping its verified parent;
# it never stops an unrelated process. No production fault hook.
mkdir "$tmp/actual-bin"
B5_REAL_SETSID=$(command -v setsid)
export B5_REAL_SETSID
cat > "$tmp/actual-bin/setsid" <<'SH'
#!/bin/sh
[ "$4" = b5 ] || exit 19
dir=$6
read -r owner birth < "$dir/owner" || exit 19
verify_parent() {
    IFS= read -r stat < /proc/self/stat || return 1
    rest=${stat##*) }; set -- $rest
    [ "$2" = "$owner" ] || return 1
    IFS= read -r stat < "/proc/$owner/stat" || return 1
    rest=${stat##*) }; set -- $rest
    [ "$#" -ge 20 ] && [ "${20}" = "$birth" ]
}
verify_parent || exit 19
if [ "$B5_PHASE" = prearm ]; then
    kill -STOP "$owner" || exit 19
fi
printf '%s\n' "$dir" > "$B5_CASE_DIR"
exec "$B5_REAL_SETSID" "$@"
SH
chmod +x "$tmp/actual-bin/setsid"

# Return success only for the original, non-zombie controller identity.
b5_controller_alive() {
    { IFS= read -r stat < "/proc/$owner/stat"; } 2>/dev/null || return 1
    rest=${stat##*) }; set -- $rest
    [ "$#" -ge 20 ] && [ "${20}" = "$birth" ] || return 1
    case "$1" in Z|X|x) return 1 ;; esac
    return 0
}
b5_session_live() {
    for entry in /proc/[0-9]*/stat; do
        { IFS= read -r stat < "$entry"; } 2>/dev/null || continue
        rest=${stat##*) }; set -- $rest
        [ "$#" -ge 4 ] || continue
        case "$1" in Z|X|x) continue ;; esac
        [ "$3" = "$session" ] && [ "$4" = "$session" ] && return 0
    done
    return 1
}
for phase in prearm active; do
    for signal in TERM KILL; do
        rm -f "$tmp/actual-dir" "$tmp/childpid"
        DEADLINE_FIXTURE=hung
        export DEADLINE_FIXTURE
        PATH="$tmp/actual-bin:$PATH" B5_PHASE="$phase" B5_CASE_DIR="$tmp/actual-dir" \
            sh "$worker" watchdog-check-bounded 8 > "$tmp/actual.out" 2>&1 &
        cli=$!
        started=$(date +%s)
        dir=
        while :; do
            if [ -s "$tmp/actual-dir" ]; then
                read -r dir < "$tmp/actual-dir"
                if [ -s "$dir/owner" ] && [ -s "$dir/pid" ] &&
                   { [ "$phase" = prearm ] || [ -s "$tmp/childpid" ]; }; then break; fi
            fi
            [ "$(( $(date +%s) - started ))" -lt 7 ] || {
                echo "FAIL actual_${phase}_${signal}: setup" >&2
                cat "$tmp/actual.out" >&2
                exit 1
            }
            sleep 0.1 2>/dev/null || sleep 1
        done
        read -r owner birth < "$dir/owner"
        read -r session session_birth < "$dir/pid"
        case "$owner:$birth:$session:$session_birth" in *[!0-9:]*|:*|*:) exit 1 ;; esac
        [ "$owner" -gt 1 ] && [ "$session" -gt 1 ] && [ "$owner" != "$session" ] &&
            b5_controller_alive || { echo 'FAIL actual controller identity' >&2; exit 1; }
        if [ "$phase" = prearm ]; then
            [ ! -f "$dir/armed" ] || { echo 'FAIL prearm gate already armed' >&2; exit 1; }
            IFS= read -r stat < "/proc/$owner/stat"
            rest=${stat##*) }
            case "$rest" in 'T '*) ;; *) echo 'FAIL controller was not stopped' >&2; exit 1 ;; esac
        else
            [ -f "$dir/armed" ] || exit 1
        fi
        kill "-$signal" "$owner"
        if [ "$phase" = prearm ] && [ "$signal" = TERM ] && b5_controller_alive; then
            kill -CONT "$owner"
        fi
        started=$(date +%s)
        while b5_controller_alive || b5_session_live ||
              [ -e "$dir" ] || [ -e "$dir.abandoned" ]; do
            [ "$(( $(date +%s) - started ))" -lt 16 ] || {
                echo "FAIL actual_${phase}_${signal}: cleanup dir=$dir owner=$owner session=$session" >&2
                cat "$tmp/actual.out" >&2
                exit 1
            }
            sleep 0.1 2>/dev/null || sleep 1
        done
        wait "$cli" 2>/dev/null || :
        if [ "$phase" = prearm ]; then
            [ ! -e "$tmp/childpid" ] || { echo 'FAIL diagnostic launched before arm' >&2; exit 1; }
        fi
        passed=$((passed + 1))
        echo "PASS actual_${phase}_${signal}_cleanup"
    done
done

# B5.2b.2: validate the observer's outer bound even when NO supervisor can
# currently act. A single UNKNOWN sample must never confirm a Podkop fault.
# The test fixture has its own finite emergency lifetime and, if needed,
# reclaims its own disposable group. Never force global PID reuse or
# signal a real Podkop/sing-box process.
export B5_FAULT_READY="$tmp/fault-ready"
export B5_FAULT_RELEASE="$tmp/fault-release"
export B5_FAULT_FALLBACK="$tmp/fault-fallback"
export B5_CPU_DIR="$tmp"
b5_member_state() {
    { IFS= read -r stat < "/proc/$1/stat"; } 2>/dev/null || return 1
    rest=${stat##*) }; set -- $rest
    [ "$#" -ge 4 ] && [ "$3" = "$session" ] && [ "$4" = "$session" ] || return 1
    case "$1" in Z|X|x) return 1 ;; esac
    printf '%s\n' "$1"
}
for fixture in supervisors_stopped supervisors_lost; do
    rm -f "$tmp/actual-dir" "$tmp/fault.rc" "$B5_FAULT_READY" \
        "$B5_FAULT_RELEASE" "$B5_FAULT_FALLBACK"
    DEADLINE_FIXTURE="$fixture"
    export DEADLINE_FIXTURE
    started=$(date +%s)
    (
        set +e
        PATH="$tmp/actual-bin:$PATH" B5_PHASE=active B5_CASE_DIR="$tmp/actual-dir" \
            PODKOP_GUARD_WATCH_MAX_SAMPLE=5 PODKOP_GUARD_WATCH_GRACE=0 \
            sh "$worker" watchdog-monitor 1 0 > "$tmp/fault.out" 2>&1
        printf '%s\n' "$?" > "$tmp/fault.rc"
    ) &
    runner=$!
    while [ ! -s "$B5_FAULT_READY" ]; do
        [ "$(( $(date +%s) - started ))" -lt 8 ] || {
            echo "FAIL $fixture: injection not ready" >&2; cat "$tmp/fault.out" >&2; exit 1;
        }
        sleep 0.1 2>/dev/null || sleep 1
    done
    read -r dir < "$tmp/actual-dir"
    read -r session session_birth < "$dir/pid"
    read -r mock leader guard < "$B5_FAULT_READY"
    [ "$session" = "$leader" ] && [ "$session" -gt 1 ] || exit 1
    while [ ! -s "$tmp/fault.rc" ]; do
        [ "$(( $(date +%s) - started ))" -lt 18 ] || {
            echo "FAIL $fixture: controller exceeded outer bound" >&2; cat "$tmp/fault.out" >&2; exit 1;
        }
        sleep 0.1 2>/dev/null || sleep 1
    done
    elapsed=$(( $(date +%s) - started ))
    wait "$runner"
    # All of the following checks precede TEST cleanup. The surviving
    # fixture and the still-present private dir prove the controller did
    # not wait for its diagnostic to exit or falsely report group cleanup.
    [ "$elapsed" -lt 18 ] && [ "$(cat "$tmp/fault.rc")" = 0 ] &&
        grep -Fq 'state=UNKNOWN phase=UNKNOWN pid=none streak=0 reason=probe_uncontained' "$tmp/fault.out" &&
        grep -Fxq 'MONITOR_END completed=1 confirmations=0 action=none' "$tmp/fault.out" &&
        [ -d "$dir" ] && b5_member_state "$mock" >/dev/null &&
        [ ! -e "$B5_FAULT_FALLBACK" ] || {
        echo "FAIL $fixture: unsafe or unbounded result elapsed=$elapsed" >&2
        cat "$tmp/fault.out" >&2; exit 1
    }
    if [ "$fixture" = supervisors_stopped ]; then
        [ "$(b5_member_state "$leader")" = T ] && [ "$(b5_member_state "$guard")" = T ] || {
            echo 'FAIL supervisors_stopped: not both stopped' >&2; exit 1;
        }
    else
        if b5_member_state "$leader" >/dev/null || b5_member_state "$guard" >/dev/null; then
            echo 'FAIL supervisors_lost: a supervisor survived injection' >&2; exit 1
        fi
    fi
    printf 'PASS %s_unknown_bounded elapsed_s=%s\n' "$fixture" "$elapsed"
    passed=$((passed + 1))
    # Both manual invocation and a NEW monitor must refuse to launch a
    # probe while the old group remains, even after its controller exited.
    rm -f "$tmp/blocked-dir"
    lease_inode=$(stat -c '%i' /tmp/podkop-guard-probe.lock/lease)
    set +e
    blocked=$(PATH="$tmp/actual-bin:$PATH" B5_PHASE=active B5_CASE_DIR="$tmp/blocked-dir" \
        DEADLINE_FIXTURE=healthy sh "$worker" watchdog-check-bounded 3)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] && [ "$blocked" = 'WATCHDOG state=UNKNOWN reason=probe_blocked' ] || {
        echo "FAIL $fixture: manual containment rc=$rc out=$blocked" >&2; exit 1;
    }
    blocked=$(PATH="$tmp/actual-bin:$PATH" B5_PHASE=active B5_CASE_DIR="$tmp/blocked-dir" \
        DEADLINE_FIXTURE=healthy PODKOP_GUARD_WATCH_MAX_SAMPLE=3 PODKOP_GUARD_WATCH_GRACE=0 \
        sh "$worker" watchdog-monitor 3 0)
    [ "$(printf '%s\n' "$blocked" | grep -c 'state=UNKNOWN phase=UNKNOWN pid=none streak=0 reason=probe_blocked')" -eq 3 ] &&
        printf '%s\n' "$blocked" | grep -Fxq 'MONITOR_END completed=3 confirmations=0 action=none' || {
        echo "FAIL $fixture: fresh monitor containment: $blocked" >&2; exit 1;
    }
    [ ! -e "$tmp/blocked-dir" ] && [ "$(cat "$dir/pid")" = "$session $session_birth" ] &&
        b5_member_state "$mock" >/dev/null && [ ! -e "$B5_FAULT_FALLBACK" ] || {
        echo "FAIL $fixture: probe launched while blocked" >&2; exit 1;
    }
    passed=$((passed + 1))
    echo "PASS ${fixture}_reentry_blocked"
    : > "$B5_FAULT_RELEASE"
    released=$(date +%s)
    while b5_session_live; do
        [ "$(( $(date +%s) - released ))" -lt 10 ] || {
            echo "FAIL $fixture: test group did not terminate" >&2; exit 1;
        }
        sleep 0.1 2>/dev/null || sleep 1
    done
    if [ "$fixture" = supervisors_stopped ]; then
        # Production cleanup, not the fixture's emergency kill.
        [ ! -e "$dir" ] && [ ! -e "$dir.abandoned" ] && [ ! -e "$B5_FAULT_FALLBACK" ] || {
            echo 'FAIL supervisors_stopped: no autonomous cleanup after CONT' >&2; exit 1;
        }
        echo 'PASS supervisors_resumed_cleanup'
    else
        # The TEST fixture terminated its own group, not the worker.
        # Leave the old slot for production to reclaim on the next probe.
        [ -d "$dir" ] || { echo 'FAIL lost supervisor slot unexpectedly absent' >&2; exit 1; }
        echo 'PASS supervisors_lost_test_only_cleanup'
    fi
    passed=$((passed + 1))
    verify "${fixture}_reentry_released" \
        'WATCHDOG state=HEALTHY_SAMPLED pid=123 dns=fakeip nft=present' 0 healthy
    [ ! -e "$dir" ] && [ ! -e "$dir.abandoned" ] &&
        [ "$(stat -c '%i' /tmp/podkop-guard-probe.lock/lease)" = "$lease_inode" ] || {
        echo "FAIL $fixture: stale slot or replaced lock inode" >&2; exit 1;
    }
done

# Real CPU contention (not a guarantee of scheduler starvation).
rm -f "$tmp/burner.1" "$tmp/burner.2" "$tmp/burner.3" "$tmp/actual-dir"
DEADLINE_FIXTURE=cpu_contention
export DEADLINE_FIXTURE
started=$(date +%s)
out=$(PATH="$tmp/actual-bin:$PATH" B5_PHASE=active B5_CASE_DIR="$tmp/actual-dir" \
    PODKOP_GUARD_WATCH_MAX_SAMPLE=3 PODKOP_GUARD_WATCH_GRACE=0 \
    sh "$worker" watchdog-monitor 1 0)
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 15 ] &&
    printf '%s\n' "$out" | grep -Fq 'state=UNKNOWN phase=UNKNOWN pid=none streak=0 reason=probe_hard_deadline' || {
    echo "FAIL cpu_contention elapsed=$elapsed output=$out" >&2; exit 1;
}
printf '%s\n' "$out" | grep -Fxq 'MONITOR_END completed=1 confirmations=0 action=none'
for n in 1 2 3; do
    read -r child child_birth < "$tmp/burner.$n"
    case "$child:$child_birth" in *[!0-9:]*|:*|*:) exit 1 ;; esac
    if { IFS= read -r stat < "/proc/$child/stat"; } 2>/dev/null; then
        rest=${stat##*) }; set -- $rest
        if [ "${20}" = "$child_birth" ]; then
            case "$1" in Z|X|x) ;; *)
                echo "FAIL cpu_contention: live burner $child" >&2; exit 1 ;;
            esac
        fi
    fi
done
read -r dir < "$tmp/actual-dir"
[ ! -e "$dir" ] && [ ! -e "$dir.abandoned" ] || {
    echo 'FAIL cpu_contention: private resources remain' >&2; exit 1;
}
passed=$((passed + 1))
printf 'PASS cpu_contention_unknown_cleanup elapsed_s=%s\n' "$elapsed"
printf 'PASS: %s B4 bounded cases\n' "$passed"
