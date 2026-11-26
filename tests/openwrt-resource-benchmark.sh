# Sourced only inside the guarded real FakeIP fixture in a disposable guest.
resource_benchmark() (
    set -eu
    meter=/mnt/pg-bundle/resource-meter
    [ -x "$meter" ] || exit 1
    original="$tmp/resource-original.json"
    cp "$tmp/box.json" "$original"
    sleepers=
    maint=
    maint_script="$tmp/resource-maintenance"
    cleanup_resource() {
        resume_box || :
        if [ -f "$original" ]; then mv "$original" "$tmp/box.json"; fi
        if [ -n "$maint" ]; then
            : > "$tmp/resource-release"
            wait "$maint" || :
        fi
        if [ "$(readlink /usr/bin/podkop 2>/dev/null || :)" = "$maint_script" ]; then rm -f /usr/bin/podkop; fi
        for pid in $sleepers; do kill -TERM "$pid" 2>/dev/null || :; done
        for pid in $sleepers; do wait "$pid" 2>/dev/null || :; done
    }
    trap cleanup_resource EXIT
    trap 'exit 1' HUP INT TERM
    printf 'PG_RESOURCE_META release=%s worker_bytes=%s nft_json_bytes=%s mem_total_kib=%s\n' \
        "$PG_VM_RELEASE" "$(wc -c < "$worker")" "$(wc -c < "$tmp/nft-terse.json")" \
        "$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    sample_series() {
        local label count expected expected_rc n rc procs
        label=$1 count=$2 expected=$3 expected_rc=$4 n=1
        while [ "$n" -le "$count" ]; do
            set -- /proc/[0-9]*/stat
            procs=$#
            rc=0
            "$meter" "$worker" watchdog-check-bounded 8 > "$tmp/resource-sample.log" 2>&1 || rc=$?
            printf 'PG_RESOURCE_SAMPLE case=%s index=%s config_bytes=%s guest_proc_entries=%s\n' \
                "$label" "$n" "$(wc -c < "$tmp/box.json")" "$procs"
            cat "$tmp/resource-sample.log"
            [ "$rc" -eq "$expected_rc" ] && grep -Fq "$expected" "$tmp/resource-sample.log" &&
                [ "$(grep -c '^PG_RESOURCE ' "$tmp/resource-sample.log")" -eq 1 ] || exit 1
            [ ! -e /tmp/podkop-guard-probe.lock/active ] && [ ! -e /tmp/podkop-guard-probe.lock/active.abandoned ] || exit 1
            (exec 7>>/tmp/podkop-guard-probe.lock/lease; flock -n 7) || exit 1
            our_box || exit 1
            n=$((n + 1))
        done
    }
    sample_series healthy 20 'state=HEALTHY_SAMPLED ' 0
    # Valid enlarged disk JSON, not a loaded-config or packet-path benchmark.
    jq '.route.rules += [range(0;2048) | {domain:["pg-bench-\(.).invalid"],action:"route",outbound:"direct-out"}]' \
        "$original" > "$tmp/resource-large.json"
    /usr/bin/sing-box check -c "$tmp/resource-large.json"
    cp "$tmp/resource-large.json" "$tmp/box.json"
    sample_series large_disk_config 10 'state=HEALTHY_SAMPLED ' 0
    cp "$original" "$tmp/box.json"
    # Finite, idle child processes. Only this fixture's own children are stopped.
    n=0
    while [ "$n" -lt 32 ]; do sleep 120 & sleepers="$sleepers $!"; n=$((n + 1)); done
    sample_series extra_processes 10 'state=HEALTHY_SAMPLED ' 0
    for pid in $sleepers; do kill -TERM "$pid" 2>/dev/null || :; done
    for pid in $sleepers; do wait "$pid" 2>/dev/null || :; done
    sleepers=
    # Real local DNS silence with explicit conntrack evidence fixtures.
    # The minimal guest need not expose usable native conntrack counters.
    for key in nf_conntrack_count nf_conntrack_max; do
        value=$(cat "/proc/sys/net/netfilter/$key" 2>/dev/null) || value=unavailable
        case "$value" in unavailable) ;; ''|*[!0-9]*) value=invalid ;; esac
        printf 'PG_RESOURCE_CONNTRACK source=native key=%s value=%s\n' "$key" "$value"
    done
    mkdir "$tmp/conntrack-missing"
    printf '1\n' > "$tmp/conntrack/nf_conntrack_count"
    printf '1000\n' > "$tmp/conntrack/nf_conntrack_max"
    our_box || exit 1
    kill -STOP "$box"
    export PODKOP_GUARD_WATCH_CONNTRACK_ROOT="$tmp/conntrack-missing"
    sample_series dns_timeout_unverified 1 'state=UNKNOWN reason=conntrack_unverified ' 2
    export PODKOP_GUARD_WATCH_CONNTRACK_ROOT="$tmp/conntrack"
    sample_series dns_timeout_normal_fixture 3 'state=SUSPECT_DNS_TIMEOUT ' 1
    unset PODKOP_GUARD_WATCH_CONNTRACK_ROOT
    resume_box || exit 1
    sample_series restored 1 'state=HEALTHY_SAMPLED ' 0
    [ ! -e /usr/bin/podkop ] && [ ! -L /usr/bin/podkop ] || exit 1
    cat > "$maint_script" <<'SH'
#!/bin/sh
n=0
while [ ! -e "$PG_RESOURCE_RELEASE" ] && [ "$n" -lt 30 ]; do n=$((n + 1)); sleep 1; done
SH
    chmod 700 "$maint_script"
    ln -s "$maint_script" /usr/bin/podkop
    PG_RESOURCE_RELEASE="$tmp/resource-release" /usr/bin/podkop list_update & maint=$!
    sleep 1
    sample_series maintenance 3 'state=TRANSITION reason=list_update ' 0
    : > "$tmp/resource-release"
    wait "$maint"; maint=
    rm -f /usr/bin/podkop
    # Monitor sleep and active samples; outside_slot_* is a sampled proxy, not PSS.
    printf 'PG_RESOURCE_SAMPLE case=monitor_3x5 index=1 config_bytes=%s\n' "$(wc -c < "$tmp/box.json")"
    PODKOP_GUARD_WATCH_GRACE=0 PODKOP_GUARD_WATCH_CHANGES_ONLY=0 \
        "$meter" "$worker" watchdog-monitor 3 5 > "$tmp/resource-monitor.log" 2>&1
    cat "$tmp/resource-monitor.log"
    grep -Fxq 'MONITOR_END completed=3 confirmations=0 action=none' "$tmp/resource-monitor.log"
    [ "$(grep -c 'state=HEALTHY_SAMPLED phase=HEALTHY' "$tmp/resource-monitor.log")" -eq 3 ]
    grep -q '^PG_RESOURCE ' "$tmp/resource-monitor.log"
    [ ! -e /tmp/podkop-guard-probe.lock/active ] && [ ! -e /tmp/podkop-guard-probe.lock/active.abandoned ] || exit 1
    (exec 7>>/tmp/podkop-guard-probe.lock/lease; flock -n 7) || exit 1
    our_box || exit 1
    echo PASS_VM_RESOURCE_BENCHMARK
)
