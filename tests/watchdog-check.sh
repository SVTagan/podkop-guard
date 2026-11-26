#!/bin/sh
# Deterministic one-shot observer tests. No network, router or root required.
set -eu
script=$1
[ -n "$script" ] || script="./podkop-guard"
case "$script" in /*) ;; *) script="$(pwd)/$script" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"
mkdir -p "$tmp/proc" "$tmp/netfilter"
fixture_command_id=$(printf '%s' '2f7573722f62696e2f73696e672d626f780072756e00' | sha256sum)
fixture_command_id=${fixture_command_id%% *}
: > "$tmp/list.pid"
make_birth() {
    mkdir -p "$tmp/proc/$1"
    { printf '%s (sing box) %s' "$1" "$3"
      n=0; while [ "$n" -lt 18 ]; do printf ' 0'; n=$((n + 1)); done
      printf ' %s 0\n' "$2"
    } > "$tmp/proc/$1/stat"
}
printf '{}\n' > "$tmp/config.json"
printf '10\n' > "$tmp/netfilter/nf_conntrack_count"
printf '100\n' > "$tmp/netfilter/nf_conntrack_max"

cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
[ "$1 $2 $3 $4" = '-t 5 call service' ] || exit 9
[ "$WATCH_TEST_PROCD" != down ] || exit 1
if [ "$WATCH_TEST_PROCD" = down_after_dns ] && [ -e "$WATCH_TEST_DNS_CALLED" ]; then exit 1; fi
case "$WATCH_TEST_PROCD" in
    absent) echo '{}'; exit 0 ;;
    empty_service) echo '{"sing-box":{}}'; exit 0 ;;
    malformed_service) echo '{"sing-box":null}'; exit 0 ;;
    malformed_instances) echo '{"sing-box":{"instances":[]}}'; exit 0 ;;
    malformed_instance) echo '{"sing-box":{"instances":{"sing-box.main":null}}}'; exit 0 ;;
    malformed_json) echo '{'; exit 0 ;;
    multi_reply) printf '{}\n{}\n'; exit 0 ;;
    wrong_command) echo '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":12345,"command":["/usr/bin/sing-box","check"]}}}}'; exit 0 ;;
    missing_pid) echo '{"sing-box":{"instances":{"sing-box.main":{"running":true,"command":["/usr/bin/sing-box","run"]}}}}'; exit 0 ;;
esac
pid=$WATCH_TEST_PID
running=$WATCH_TEST_RUNNING
if [ "${WATCH_TEST_PID_RETURN:-0}" = 1 ]; then
    n=$(cat "$WATCH_TEST_PID_COUNTER" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$WATCH_TEST_PID_COUNTER"
    if [ "$n" -ge 2 ]; then pid=54321; running=true; else pid=none; running=false; fi
elif [ "$WATCH_TEST_PROCD" = pid_after_dns ] && [ -e "$WATCH_TEST_DNS_CALLED" ]; then
    pid=54321
elif [ "$WATCH_TEST_PROCD" = stopped_after_dns ] && [ -e "$WATCH_TEST_DNS_CALLED" ]; then
    running=false
fi
if [ "$running" = false ]; then
    printf '{"sing-box":{"instances":{"sing-box.main":{"running":false,"command":["/usr/bin/sing-box","run"],"exit_code":0}}}}\n'
else
    printf '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":%s,"command":["/usr/bin/sing-box","run"]}}}}\n' "$pid"
fi
SH
cat > "$tmp/bin/nft" <<'SH'
#!/bin/sh
[ "$1 $2" = 'list tables' ] || exit 9
case "$WATCH_TEST_NFT" in
    present) printf 'table inet PodkopTable\n' ;;
    absent) printf 'table inet fw4\n' ;;
    error) exit 1 ;;
    *) exit 9 ;;
esac
SH
cat > "$tmp/bin/uci" <<'SH'
#!/bin/sh
[ "$1 $2 $3" = '-q get podkop.settings.shutdown_correctly' ] || exit 9
printf '%s\n' "$WATCH_TEST_SHUTDOWN"
SH
cat > "$tmp/bin/nslookup" <<'SH'
#!/bin/sh
[ "$1 $2 $3 $4" = '-timeout=3 -retry=1 -type=A fakeip.podkop.fyi' ] || exit 9
[ "$5" = 127.0.0.42 ] || exit 9
: > "$WATCH_TEST_DNS_CALLED"
case "${WATCH_TEST_ID_CHANGE:-}" in
    birth) sed 's/ 1000 0$/ 1001 0/' "$PODKOP_GUARD_WATCH_PROC_ROOT/12345/stat" > "$WATCH_TEST_DNS_CALLED.stat"
        mv "$WATCH_TEST_DNS_CALLED.stat" "$PODKOP_GUARD_WATCH_PROC_ROOT/12345/stat" ;;
    birth_lost) rm -f "$PODKOP_GUARD_WATCH_PROC_ROOT/12345/stat" ;;
    argv) printf '/usr/bin/sing-box\000run\000-c\000/other config.json\000' > "$PODKOP_GUARD_WATCH_PROC_ROOT/12345/cmdline" ;;
    exe) rm -f "$PODKOP_GUARD_WATCH_PROC_ROOT/12345/exe"
        ln -s /bin/busybox "$PODKOP_GUARD_WATCH_PROC_ROOT/12345/exe" ;;
    bus) printf '700:2001\n' > "$PODKOP_GUARD_PROCD_BUS_FILE" ;;
    bus_lost) printf 'DOWN\n' > "$PODKOP_GUARD_PROCD_BUS_FILE" ;;
esac
case "${WATCH_TEST_DNS_MAINTENANCE:-}" in
    reload) mkdir -p "$PODKOP_GUARD_WATCH_PROC_ROOT/321"
        printf '/bin/sh\000/usr/bin/podkop\000reload\000' > "$PODKOP_GUARD_WATCH_PROC_ROOT/321/cmdline" ;;
    list_update) mkdir -p "$PODKOP_GUARD_WATCH_PROC_ROOT/321"
        printf '/bin/sh\000/usr/bin/podkop\000list_update\000' > "$PODKOP_GUARD_WATCH_PROC_ROOT/321/cmdline" ;;
esac
case "$WATCH_TEST_DNS" in
    healthy) printf 'Server: 127.0.0.42\nAddress: 127.0.0.42:53\n\nName: fakeip.podkop.fyi\nAddress: 198.18.0.194\n' ;;
    highrange) printf 'Name: fakeip.podkop.fyi\nAddress: 198.19.255.255\n' ;;
    terminal_dot) printf 'Name: fakeip.podkop.fyi.\nAddress: 198.18.0.194\n' ;;
    timeout) printf ';; connection timed out; no servers could be reached\n' >&2; exit 1 ;;
    invalid) printf 'Name: fakeip.podkop.fyi\nAddress: 203.0.113.9\n' ;;
    banner) printf 'Server: 127.0.0.42\nAddress: 198.18.0.194\n'; exit 0 ;;
    nxdomain) printf "server can't find fakeip.podkop.fyi: NXDOMAIN\n" >&2; exit 1 ;;
    servfail) printf 'server failure: SERVFAIL\n' >&2; exit 1 ;;
    refused) printf 'response REFUSED\n' >&2; exit 1 ;;
    unreachable) printf 'read: Connection refused\n' >&2; exit 1 ;;
    contradicted) printf 'Name: fakeip.podkop.fyi\nAddress: 198.18.0.194\nSERVFAIL\n'; exit 0 ;;
    wrong_name) printf 'Name: other.example\nAddress: 198.18.0.194\n'; exit 0 ;;
    *) exit 9 ;;
esac
SH
cat > "$tmp/bin/ping" <<'SH'
#!/bin/sh
[ "$#" -eq 5 ] && [ "$1 $2 $3 $4 $5" = '-c 1 -W 1 127.0.0.42' ] || exit 9
[ "${WATCH_TEST_PING:-up}" = up ] && exit 0
exit 1
SH
chmod +x "$tmp/bin"/*

tests=0
case_run() {
    name=$1 expected=$2 expected_rc=$3 dns=$4 nft=$5 pid=$6 running=$7 shutdown=$8 config=$9
    shift 9
    procd=$1
    rm -f "$tmp/pid-counter" "$tmp/dns-called"
    if [ "$config" = valid ]; then
        printf '%s\n' '{"inbounds":[{"tag":"dns-in","listen":"127.0.0.42","listen_port":53}]}' > "$tmp/config.json"
    else
        printf '{}\n' > "$tmp/config.json"
    fi
    make_birth 12345 1000 S
    make_birth 54321 1001 S
    for fixture_pid in 12345 54321; do
        rm -f "$tmp/proc/$fixture_pid/exe" "$tmp/proc/$fixture_pid/cmdline"
        ln -s /usr/bin/sing-box "$tmp/proc/$fixture_pid/exe"
        printf '/usr/bin/sing-box\000run\000' > "$tmp/proc/$fixture_pid/cmdline"
    done
    printf '700:2000\n' > "$tmp/bus"
    case "$name" in
        wrong_exe) rm -f "$tmp/proc/12345/exe"; ln -s /bin/busybox "$tmp/proc/12345/exe" ;;
        deleted_exe) rm -f "$tmp/proc/12345/exe"; ln -s '/usr/bin/sing-box (deleted)' "$tmp/proc/12345/exe" ;;
        missing_exe) rm -f "$tmp/proc/12345/exe" ;;
        wrong_argv) printf '/usr/bin/sing-box\000check\000' > "$tmp/proc/12345/cmdline" ;;
        missing_argv) rm -f "$tmp/proc/12345/cmdline" ;;
        truncated_argv) printf '/usr/bin/sing-box\000run' > "$tmp/proc/12345/cmdline" ;;
        extra_argv) printf '/usr/bin/sing-box\000run\000\000' > "$tmp/proc/12345/cmdline" ;;
        missing_birth) rm -f "$tmp/proc/12345/stat" ;;
        zombie_birth) make_birth 12345 1000 Z ;;
        malformed_birth) printf '12345 (sing box) S 0\n' > "$tmp/proc/12345/stat" ;;
        missing_bus_identity) printf 'DOWN\n' > "$tmp/bus" ;;
    esac
    set +e
    output=$(env PATH="$tmp/bin:$PATH" \
        PODKOP_GUARD_WATCH_CONFIG="$tmp/config.json" \
        PODKOP_GUARD_WATCH_PROC_ROOT="$tmp/proc" PODKOP_GUARD_PROCD_BUS_FILE="$tmp/bus" \
        PODKOP_GUARD_WATCH_LIST_PID_FILE="$tmp/list.pid" \
        PODKOP_GUARD_WATCH_CONNTRACK_ROOT="$tmp/netfilter" \
        WATCH_TEST_DNS="$dns" WATCH_TEST_NFT="$nft" WATCH_TEST_PID="$pid" \
        WATCH_TEST_RUNNING="$running" WATCH_TEST_SHUTDOWN="$shutdown" \
        WATCH_TEST_CONFIG="$config" WATCH_TEST_PROCD="$procd" \
        WATCH_TEST_PID_COUNTER="$tmp/pid-counter" WATCH_TEST_DNS_CALLED="$tmp/dns-called" \
        sh "$script" watchdog-check 2>&1)
    rc=$?
    set -e
    case "$output" in
        *"state=$expected "*) ;;
        *) printf 'FAIL %s: unexpected output: %s\n' "$name" "$output" >&2; exit 1 ;;
    esac
    if [ "$rc" -ne "$expected_rc" ]; then
        printf 'FAIL %s: rc=%s expected=%s: %s\n' "$name" "$rc" "$expected_rc" "$output" >&2
        exit 1
    fi
    case "$dns" in
        nxdomain|servfail|refused)
            case "$output" in *" dns=$dns "*) ;; *)
                echo "FAIL $name: incorrect DNS response classification: $output" >&2; exit 1 ;;
            esac ;;
        unreachable)
            case "$output" in *' dns=refused '*) ;; *)
                echo "FAIL $name: refused packet classification: $output" >&2; exit 1 ;;
            esac ;;
        contradicted)
            case "$output" in *' dns=servfail '*) ;; *)
                echo "FAIL $name: contradictory DNS reply marked healthy: $output" >&2; exit 1 ;;
            esac ;;
        wrong_name)
            case "$output" in *' dns=unconfirmed '*) ;; *)
                echo "FAIL $name: foreign DNS name marked healthy: $output" >&2; exit 1 ;;
            esac ;;
    esac
    case "$name" in
        conntrack_unavailable|conntrack_invalid)
            case "$output" in *'reason=conntrack_unverified '*) ;; *)
                echo "FAIL $name: missing unverified reason $output" >&2; exit 1 ;;
            esac ;;
        conntrack_pressure)
            case "$output" in *'reason=conntrack_pressure '*) ;; *)
                echo "FAIL $name: pressure reason missing $output" >&2; exit 1 ;;
            esac ;;
        control_suppresses_suspect)
            case "$output" in *'reason=loopback_unresponsive '*) ;; *)
                echo "FAIL $name: loopback control did not suppress timeout $output" >&2; exit 1 ;;
            esac ;;
        procd_rapid_respawn)
            case "$output" in *'reason=procd_returned '*) ;; *)
                echo "FAIL $name: procd replacement not treated as transition $output" >&2; exit 1 ;;
            esac ;;
        premaintenance_*)
            case "$output" in *'reason=list_update '*|*'reason=podkop_lifecycle '*) ;; *)
                echo "FAIL $name: missing maintenance reason $output" >&2; exit 1 ;;
            esac
            [ ! -e "$tmp/dns-called" ] || { echo "FAIL $name: DNS ran during maintenance" >&2; exit 1; } ;;
        maintenance_started_*)
            case "$output" in *'reason=list_update '*|*'reason=podkop_lifecycle '*) ;; *)
                echo "FAIL $name: missing transition after DNS $output" >&2; exit 1 ;;
            esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        procd_lost_during_*)
            case "$output" in *'reason=procd_unavailable '*) ;; *)
                echo "FAIL $name: RPC failure not UNKNOWN $output" >&2; exit 1 ;;
            esac ;;
        pid_changed_during_*|process_stopped_during_dns)
            case "$output" in *'reason=procd_pid_changed '*) ;; *)
                echo "FAIL $name: stale DNS evidence $output" >&2; exit 1 ;;
            esac ;;
    esac
    case "$name" in
        no_process) case "$output" in *'reason=procd_stopped '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac ;;
        unregistered|empty_service) case "$output" in *'reason=procd_unregistered '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac ;;
        malformed_service|malformed_instances|malformed_instance|malformed_json|multi_reply|wrong_command|missing_pid)
            case "$output" in *'reason=procd_invalid_reply '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
    esac
    case "$name" in
        healthy) case "$output" in *" birth=1000 bus=700:2000 command_id=$fixture_command_id") ;; *) echo "FAIL identity fields: $output" >&2; exit 1 ;; esac ;;
        same_pid_birth_changed*) case "$output" in *'reason=runtime_identity_changed '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac ;;
        bus_identity_changed*) case "$output" in *'reason=ubusd_changed '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac ;;
        wrong_exe|deleted_exe|missing_exe|wrong_argv|missing_argv|truncated_argv|extra_argv)
            case "$output" in *'reason=runtime_identity_unavailable '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
        missing_birth|zombie_birth|malformed_birth|birth_lost_during_dns|argv_changed_during_dns|exe_changed_during_dns) case "$output" in *'reason=runtime_identity_unavailable '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac ;;
        missing_bus_identity|bus_lost_during_dns) case "$output" in *'reason=ubusd_identity_unavailable '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac ;;
    esac
    tests=$((tests + 1))
    printf 'PASS %s\n' "$name"
}
case_run healthy          HEALTHY_SAMPLED         0 healthy   present 12345 true  0 valid up
case_run last_fakeip      HEALTHY_SAMPLED         0 highrange present 12345 true  0 valid up
case_run trailing_dot     HEALTHY_SAMPLED         0 terminal_dot present 12345 true 0 valid up
case_run dns_timeout      SUSPECT_DNS_TIMEOUT     1 timeout   present 12345 true  0 valid up
case_run dns_invalid      UNKNOWN                 2 invalid   present 12345 true  0 valid up
case_run server_only      UNKNOWN                 2 banner    present 12345 true  0 valid up
case_run dns_nxdomain     UNKNOWN                 2 nxdomain  present 12345 true  0 valid up
case_run dns_servfail     UNKNOWN                 2 servfail  present 12345 true  0 valid up
case_run dns_refused      UNKNOWN                 2 refused   present 12345 true  0 valid up
case_run dns_port_refused UNKNOWN                 2 unreachable present 12345 true 0 valid up
case_run contradicted     UNKNOWN                 2 contradicted present 12345 true 0 valid up
case_run wrong_name       UNKNOWN                 2 wrong_name present 12345 true 0 valid up
case_run no_process       UNKNOWN                 2 healthy   present none  false 0 valid up
case_run manual_stop      INACTIVE                0 healthy   absent  none  false 1 valid up
case_run nft_missing      UNKNOWN                 2 healthy   absent  12345 true  0 valid up
case_run nft_unavailable  UNKNOWN                 2 healthy   error   12345 true  0 valid up
case_run procd_error      UNKNOWN                 2 healthy   present 12345 true  0 valid down
case_run unsupported_cfg  UNKNOWN                 2 healthy   present 12345 true  0 bad   up


# A stale PID file is not proof of a running updater.
printf '321\n' > "$tmp/list.pid"
case_run stale_updater_pid SUSPECT_DNS_TIMEOUT 1 timeout present 12345 true 0 valid up

# Validate PID identity: only an actual podkop list_update job is maintenance.
mkdir -p "$tmp/proc/321"
printf '/bin/sh\000/usr/bin/podkop\000list_update\000' > "$tmp/proc/321/cmdline"
case_run updater_during_dns_timeout TRANSITION 0 timeout present 12345 true 0 valid up
case_run updater_during_proc_absence TRANSITION 0 healthy present none false 0 valid up
rm -f "$tmp/list.pid"
case_run cron_updater_no_pidfile TRANSITION 0 timeout present 12345 true 0 valid up

# A reused PID containing an unrelated command must not mask the failure.
printf '/bin/sh\000/usr/bin/some-other-tool\000' > "$tmp/proc/321/cmdline"
printf '321\n' > "$tmp/list.pid"
case_run recycled_pid_not_maintenance SUSPECT_DNS_TIMEOUT 1 timeout present 12345 true 0 valid up

# Protect actual reload/start processes without trusting a stale PID file.
printf '/bin/sh\000/usr/bin/podkop\000reload\000' > "$tmp/proc/321/cmdline"
case_run podkop_reload_in_progress TRANSITION 0 timeout present 12345 true 0 valid up

rm -f "$tmp/proc/321/cmdline" "$tmp/list.pid"
printf '95\n' > "$tmp/netfilter/nf_conntrack_count"
printf '100\n' > "$tmp/netfilter/nf_conntrack_max"
case_run conntrack_pressure UNKNOWN 2 timeout present 12345 true 0 valid up
printf '90\n' > "$tmp/netfilter/nf_conntrack_count"
case_run conntrack_not_full SUSPECT_DNS_TIMEOUT 1 timeout present 12345 true 0 valid up

rm -f "$tmp/netfilter/nf_conntrack_count"
case_run conntrack_unavailable UNKNOWN 2 timeout present 12345 true 0 valid up
printf 'bad\n' > "$tmp/netfilter/nf_conntrack_count"
case_run conntrack_invalid UNKNOWN 2 timeout present 12345 true 0 valid up
printf '10\n' > "$tmp/netfilter/nf_conntrack_count"

PODKOP_GUARD_WATCH_CONTROL_PROBE=1
WATCH_TEST_PING=up
export PODKOP_GUARD_WATCH_CONTROL_PROBE WATCH_TEST_PING
case_run control_healthy HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
WATCH_TEST_PING=down
case_run control_filtered HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
PODKOP_GUARD_WATCH_LOOPBACK_BASELINE_ID="12345:1000:700:2000:$fixture_command_id"
export PODKOP_GUARD_WATCH_LOOPBACK_BASELINE_ID
case_run control_suppresses_suspect UNKNOWN 2 timeout present 12345 true 0 valid up
WATCH_TEST_PING=up
case_run control_recovers SUSPECT_DNS_TIMEOUT 1 timeout present 12345 true 0 valid up
PODKOP_GUARD_WATCH_LOOPBACK_BASELINE_ID="12345:999:700:2000:$fixture_command_id"
case_run old_pid_no_control SUSPECT_DNS_TIMEOUT 1 timeout present 12345 true 0 valid up
unset PODKOP_GUARD_WATCH_CONTROL_PROBE PODKOP_GUARD_WATCH_LOOPBACK_BASELINE_ID WATCH_TEST_PING

# A new procd instance between samples is a transition, not missing process.
WATCH_TEST_PID_RETURN=1
export WATCH_TEST_PID_RETURN
case_run procd_rapid_respawn TRANSITION 0 healthy present none true 0 valid up
unset WATCH_TEST_PID_RETURN

# B5.2c.1: bracket both successful and failed DNS observations with
# lifecycle checks. FakeIP success is not a baseline during maintenance.
mkdir -p "$tmp/proc/321"
printf '/bin/sh\000/usr/bin/podkop\000list_update\000' > "$tmp/proc/321/cmdline"
case_run premaintenance_list_healthy TRANSITION 0 healthy present 12345 true 0 valid up
printf '/bin/sh\000/usr/bin/podkop\000reload\000' > "$tmp/proc/321/cmdline"
case_run premaintenance_reload_healthy TRANSITION 0 healthy present 12345 true 0 valid up
rm -f "$tmp/proc/321/cmdline"
WATCH_TEST_DNS_MAINTENANCE=reload
export WATCH_TEST_DNS_MAINTENANCE
case_run maintenance_started_healthy TRANSITION 0 healthy present 12345 true 0 valid up
rm -f "$tmp/proc/321/cmdline"
WATCH_TEST_DNS_MAINTENANCE=list_update
case_run maintenance_started_timeout TRANSITION 0 timeout present 12345 true 0 valid up
unset WATCH_TEST_DNS_MAINTENANCE
rm -f "$tmp/proc/321/cmdline"
case_run procd_lost_during_healthy UNKNOWN 2 healthy present 12345 true 0 valid down_after_dns
case_run procd_lost_during_timeout UNKNOWN 2 timeout present 12345 true 0 valid down_after_dns
case_run pid_changed_during_healthy TRANSITION 0 healthy present 12345 true 0 valid pid_after_dns
case_run pid_changed_during_timeout TRANSITION 0 timeout present 12345 true 0 valid pid_after_dns
case_run process_stopped_during_dns TRANSITION 0 healthy present 12345 true 0 valid stopped_after_dns

# B5.2c.3: same numerical PID with a different birth, and bus generation.
case_run missing_birth UNKNOWN 2 healthy present 12345 true 0 valid up
case_run zombie_birth UNKNOWN 2 healthy present 12345 true 0 valid up
case_run malformed_birth UNKNOWN 2 healthy present 12345 true 0 valid up
case_run missing_bus_identity UNKNOWN 2 healthy present 12345 true 0 valid up
export WATCH_TEST_ID_CHANGE=birth
case_run same_pid_birth_changed_healthy TRANSITION 0 healthy present 12345 true 0 valid up
case_run same_pid_birth_changed_timeout TRANSITION 0 timeout present 12345 true 0 valid up
WATCH_TEST_ID_CHANGE=birth_lost
case_run birth_lost_during_dns UNKNOWN 2 healthy present 12345 true 0 valid up
WATCH_TEST_ID_CHANGE=bus
case_run bus_identity_changed_healthy TRANSITION 0 healthy present 12345 true 0 valid up
case_run bus_identity_changed_timeout TRANSITION 0 timeout present 12345 true 0 valid up
WATCH_TEST_ID_CHANGE=bus_lost
case_run bus_lost_during_dns UNKNOWN 2 timeout present 12345 true 0 valid up
unset WATCH_TEST_ID_CHANGE
# Actual JSON structure, not a simulated jsonfilter match.
case_run unregistered UNKNOWN 2 healthy present none false 0 valid absent
case_run empty_service UNKNOWN 2 healthy present none false 0 valid empty_service
case_run malformed_service UNKNOWN 2 healthy present none false 0 valid malformed_service
case_run malformed_instances UNKNOWN 2 healthy present none false 0 valid malformed_instances
case_run malformed_instance UNKNOWN 2 healthy present none false 0 valid malformed_instance
case_run malformed_json UNKNOWN 2 healthy present none false 0 valid malformed_json
case_run multi_reply UNKNOWN 2 healthy present none false 0 valid multi_reply
case_run wrong_command UNKNOWN 2 healthy present 12345 true 0 valid wrong_command
case_run missing_pid UNKNOWN 2 healthy present none true 0 valid missing_pid
# Actual byte layout is independently checked, not inferred from procd.
for scenario in wrong_exe deleted_exe missing_exe wrong_argv missing_argv truncated_argv extra_argv; do
    case_run "$scenario" UNKNOWN 2 healthy present 12345 true 0 valid up
done
export WATCH_TEST_ID_CHANGE=argv
case_run argv_changed_during_dns UNKNOWN 2 timeout present 12345 true 0 valid up
WATCH_TEST_ID_CHANGE=exe
case_run exe_changed_during_dns UNKNOWN 2 healthy present 12345 true 0 valid up
unset WATCH_TEST_ID_CHANGE
# Force the check/use gap in a private copy of the actual maintenance
# function. No scheduling lottery, actual PID signals or production hook.
awk '
    /^watch_maintenance_active\(\) \{/ { active=1 }
    active { print }
    active && /if \[ -n "\$pid" \] && \[ -r / {
        print "            rm -f \"$proc_root/$pid/cmdline\""; marker++
    }
    active && /\[ -r "\$proc" \] \|\| continue/ {
        print "        rm -f \"$proc\""; scan++
    }
    active && /^}$/ { active=0; found++ }
    END { if (found != 1 || marker != 1 || scan != 1) exit 1 }
' "$script" > "$tmp/maintenance-race.sh"
mkdir -p "$tmp/race-proc/321" "$tmp/race-proc/322"
printf '321\n' > "$tmp/race-marker"
printf '/bin/sh\000/usr/bin/podkop\000list_update\000' > "$tmp/race-proc/321/cmdline"
printf '/bin/sh\000/usr/bin/podkop\000reload\000' > "$tmp/race-proc/322/cmdline"
race_rc=0
race_output=$(PODKOP_GUARD_WATCH_PROC_ROOT="$tmp/race-proc" \
    PODKOP_GUARD_WATCH_LIST_PID_FILE="$tmp/race-marker" \
    sh -c '. "$1"; watch_maintenance_active' race "$tmp/maintenance-race.sh" 2>&1) || race_rc=$?
[ "$race_rc" -eq 1 ] && [ -z "$race_output" ] &&
    [ ! -e "$tmp/race-proc/321/cmdline" ] && [ ! -e "$tmp/race-proc/322/cmdline" ] || {
    printf 'FAIL maintenance_proc_disappeared: rc=%s output=%s\n' "$race_rc" "$race_output" >&2; exit 1
}
tests=$((tests + 1))
echo PASS maintenance_proc_disappeared
printf 'PASS: %s observer-only scenarios\n' "$tests"
