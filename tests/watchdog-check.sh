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
: > "$tmp/list.pid"
printf '{}\n' > "$tmp/config.json"

cat > "$tmp/bin/ubus" <<'SH'
#!/bin/sh
[ "$1 $2 $3 $4" = '-t 5 call service' ] || exit 9
[ "$WATCH_TEST_PROCD" != down ] || exit 1
printf '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":12345}}}}\n'
SH
cat > "$tmp/bin/jsonfilter" <<'SH'
#!/bin/sh
case "$4" in
    *'"pid"'*) printf '%s\n' "$WATCH_TEST_PID" ;;
    *'"running"'*) printf '%s\n' "$WATCH_TEST_RUNNING" ;;
    *) exit 9 ;;
esac
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
cat > "$tmp/bin/jq" <<'SH'
#!/bin/sh
[ "$WATCH_TEST_CONFIG" = valid ] || exit 1
exit 0
SH
cat > "$tmp/bin/nslookup" <<'SH'
#!/bin/sh
[ "$1 $2 $3 $4" = '-timeout=3 -retry=1 -type=A fakeip.podkop.fyi' ] || exit 9
[ "$5" = 127.0.0.42 ] || exit 9
case "$WATCH_TEST_DNS" in
    healthy) printf 'Server: 127.0.0.42\nAddress: 127.0.0.42:53\n\nName: fakeip.podkop.fyi\nAddress: 198.18.0.194\n' ;;
    highrange) printf 'Name: fakeip.podkop.fyi\nAddress: 198.19.255.255\n' ;;
    timeout) printf ';; connection timed out; no servers could be reached\n' >&2; exit 1 ;;
    invalid) printf 'Name: fakeip.podkop.fyi\nAddress: 203.0.113.9\n' ;;
    banner) printf 'Server: 127.0.0.42\nAddress: 198.18.0.194\n'; exit 0 ;;
    nxdomain) printf "server can't find fakeip.podkop.fyi: NXDOMAIN\n" >&2; exit 1 ;;
    *) exit 9 ;;
esac
SH
chmod +x "$tmp/bin"/*

tests=0
case_run() {
    name=$1 expected=$2 expected_rc=$3 dns=$4 nft=$5 pid=$6 running=$7 shutdown=$8 config=$9
    shift 9
    procd=$1
    set +e
    output=$(env PATH="$tmp/bin:$PATH" \
        PODKOP_GUARD_WATCH_CONFIG="$tmp/config.json" \
        PODKOP_GUARD_WATCH_PROC_ROOT="$tmp/proc" \
        PODKOP_GUARD_WATCH_LIST_PID_FILE="$tmp/list.pid" \
        PODKOP_GUARD_WATCH_CONNTRACK_ROOT="$tmp/netfilter" \
        WATCH_TEST_DNS="$dns" WATCH_TEST_NFT="$nft" WATCH_TEST_PID="$pid" \
        WATCH_TEST_RUNNING="$running" WATCH_TEST_SHUTDOWN="$shutdown" \
        WATCH_TEST_CONFIG="$config" WATCH_TEST_PROCD="$procd" \
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
    tests=$((tests + 1))
    printf 'PASS %s\n' "$name"
}
case_run healthy          HEALTHY_SAMPLED         0 healthy   present 12345 true  0 valid up
case_run last_fakeip      HEALTHY_SAMPLED         0 highrange present 12345 true  0 valid up
case_run dns_timeout      SUSPECT_DNS_TIMEOUT     1 timeout   present 12345 true  0 valid up
case_run dns_invalid      UNKNOWN                 2 invalid   present 12345 true  0 valid up
case_run server_only      UNKNOWN                 2 banner    present 12345 true  0 valid up
case_run dns_nxdomain     UNKNOWN                 2 nxdomain  present 12345 true  0 valid up
case_run no_process       SUSPECT_PROCESS_MISSING 1 healthy   present none  false 0 valid up
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

printf 'PASS: %s observer-only scenarios\n' "$tests"
