#!/bin/sh
# B6.1b.1: real FakeIP DNS and stopped-process liveness in a disposable VM.
# No Podkop install, real WAN/VPN, external DNS or routing changes.
set -eu
. /mnt/pg-bundle/openwrt-vm-common.sh
worker=/usr/bin/podkop-guard
[ -x "$worker" ]
[ "$(cat /etc/podkop-guard/lkg-marker)" = unchanged-LKG ]
tmp=$(mktemp -d /tmp/pg-fakeip.XXXXXX)
owned=0
box=
box_birth=
monitor=
monitor_birth=
subscriber=
subscriber_birth=
maint_dir=
maint_pid=
maint_birth=
maint_link=0
# Return live state and starttime; refuse malformed/dead proc records.
proc_identity() (
    case "$1" in ''|*[!0-9]*) exit 1 ;; esac
    [ "$1" -gt 1 ] || exit 1
    { IFS= read -r line < "/proc/$1/stat"; } 2>/dev/null || exit 1
    [ "${line%% *}" = "$1" ] || exit 1
    case "$line" in *') '*) rest=${line##*) } ;; *) exit 1 ;; esac
    set -- $rest
    [ "$#" -ge 20 ] || exit 1
    case "$1" in R|S|D|T|t|I|W|P) ;; *) exit 1 ;; esac
    case "${20}" in ''|*[!0-9]*) exit 1 ;; esac
    printf '%s %s\n' "$1" "${20}"
)
registered() {
    ubus -t 3 call service list '{"name":"sing-box"}'
}
# The registration and unique config path must still belong to this fixture.
our_registration() {
    raw=$(registered) || return 1
    printf '%s\n' "$raw" | jq -e --arg path "$tmp/box.json" '
        type == "object" and (keys == ["sing-box"]) and
        (.["sing-box"].instances | type == "object" and keys == ["sing-box.main"]) and
        .["sing-box"].instances["sing-box.main"].command ==
            ["/usr/bin/sing-box","run","-c",$path]
    ' >/dev/null
}
our_box() {
    [ -n "$box" ] && [ -n "$box_birth" ] || return 1
    our_registration || return 1
    p=$(printf '%s\n' "$raw" | jq -er '
        .["sing-box"].instances["sing-box.main"] |
        select(.running == true and (.pid|type) == "number") | .pid
    ') || return 1
    [ "$p" = "$box" ] || return 1
    [ "$(readlink "/proc/$box/exe" 2>/dev/null)" = /usr/bin/sing-box ] || return 1
    identity=$(proc_identity "$box") || return 1
    [ "${identity#* }" = "$box_birth" ]
}
resume_box() {
    our_box || return 1
    case "$identity" in T\ *|t\ *) kill -CONT "$box" ;; esac
}
stop_events() {
    [ -n "$subscriber" ] || return 0
    id=$(proc_identity "$subscriber" || :)
    if [ -n "$subscriber_birth" ] && [ "${id#* }" = "$subscriber_birth" ] &&
       [ "$(readlink -f "/proc/$subscriber/exe" 2>/dev/null)" = "$(readlink -f "$(command -v ubus)")" ]; then
        kill -TERM "$subscriber" 2>/dev/null || :
        wait "$subscriber" 2>/dev/null || :
    fi
    subscriber=
    subscriber_birth=
}
cleanup() {
    # Release only the finite shell fixture we created; never signal a
    # marker PID. Keep its gate alive until it has had time to exit.
    if [ -n "$maint_dir" ]; then
        : > "$maint_dir/release"
        n=0
        while [ -n "$maint_pid" ] && [ "$n" -lt 4 ]; do
            id=$(proc_identity "$maint_pid" || :)
            [ "${id#* }" = "$maint_birth" ] || break
            n=$((n + 1)); sleep 1
        done
    fi
    if [ "$maint_link" = 1 ] &&
       [ "$(readlink /usr/bin/podkop 2>/dev/null)" = "$tmp/podkop-fixture" ]; then
        rm -f /usr/bin/podkop
    fi
    stop_events
    if [ -n "$monitor" ] && [ -n "$monitor_birth" ]; then
        id=$(proc_identity "$monitor" || :)
        if [ "${id#* }" = "$monitor_birth" ]; then
            kill -TERM "$monitor" 2>/dev/null || :
            # Monitor has its own bounded sample deadline.
            wait "$monitor" 2>/dev/null || :
        fi
    fi
    if [ "$owned" = 1 ]; then
        resume_box || :
        if our_registration; then
            ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null 2>&1 || :
        fi
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() {
    echo "FAIL_VM_B6_FAKEIP $*" >&2
    for f in ready.log monitor.log recovered.log respawn-monitor.log notifications.log respawn-check.log exhausted.log manual-stop.log maintenance.log; do
        if [ -f "$tmp/$f" ]; then cat "$tmp/$f" >&2; fi
    done
    exit 1
}
# Run after the previous B5 lifecycle fixture has removed its service.
initial=$(registered)
printf '%s\n' "$initial" | jq -e 'type == "object" and (has("sing-box") | not)' >/dev/null ||
    fail existing_registration
if pidof sing-box >/dev/null 2>&1; then fail existing_process; fi
[ "$(readlink -f "$(command -v nslookup)")" = "$(readlink -f /bin/busybox)" ] ||
    fail not_busybox_nslookup
sha256sum /etc/podkop-guard/lkg-marker /etc/podkop-guard/lkg.srs \
    /etc/podkop-guard/lkg-subnets.lst > "$tmp/lkg.before"
cat > "$tmp/box.json" <<'JSON'
{
  "log": {"level": "warn"},
  "dns": {
    "servers": [
      {"type": "udp", "tag": "unused-local", "server": "127.0.0.1", "server_port": 9},
      {"type": "fakeip", "tag": "fakeip-server", "inet4_range": "198.18.0.0/15"}
    ],
    "rules": [
      {"domain": ["fakeip.podkop.fyi"], "action": "route", "server": "fakeip-server"}
    ],
    "final": "unused-local",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {"type": "direct", "tag": "dns-in", "listen": "127.0.0.42", "listen_port": 53}
  ],
  "outbounds": [{"type": "direct", "tag": "direct-out"}],
  "route": {
    "rules": [
      {"inbound": ["dns-in"], "action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"}
    ],
    "final": "direct-out",
    "default_domain_resolver": "unused-local"
  }
}
JSON
/usr/bin/sing-box check -c "$tmp/box.json"
service=$(jq -cn --arg path "$tmp/box.json" \
    '{name:"sing-box",instances:{"sing-box.main":{command:["/usr/bin/sing-box","run","-c",$path],stdout:true,stderr:true}}}')
owned=1
ubus -t 3 call service set "$service" >/dev/null
attempt=0
while [ "$attempt" -lt 10 ]; do
    if our_registration; then
        box=$(printf '%s\n' "$raw" | jq -er '
            .["sing-box"].instances["sing-box.main"] |
            select(.running == true and (.pid|type) == "number") | .pid
        ' 2>/dev/null) || box=
        if [ -n "$box" ]; then
            id=$(proc_identity "$box" || :)
            box_birth=${id#* }
            if our_box; then break; fi
        fi
    fi
    attempt=$((attempt + 1)); sleep 1
done
[ "$attempt" -lt 10 ] || fail startup
echo "VM_B6_FAKEIP_BOX pid=$box starttime=$box_birth"

# Only nft structure and conntrack pressure are fixtures. nslookup,
# ping, ubus, procd, /proc and the DNS config are real.
mkdir "$tmp/bin" "$tmp/conntrack"
cat > "$tmp/bin/nft" <<'SH'
#!/bin/sh
[ "$*" = 'list tables' ] || exit 19
echo 'table inet PodkopTable'
SH
chmod +x "$tmp/bin/nft"
printf '1\n' > "$tmp/conntrack/nf_conntrack_count"
printf '1000\n' > "$tmp/conntrack/nf_conntrack_max"
export PATH="$tmp/bin:$PATH"
export PODKOP_GUARD_WATCH_CONFIG="$tmp/box.json"
export PODKOP_GUARD_WATCH_CONNTRACK_ROOT="$tmp/conntrack"
export PODKOP_GUARD_WATCH_GRACE=0 PODKOP_GUARD_WATCH_THRESHOLD=3
export PODKOP_GUARD_WATCH_MAX_SAMPLE=8 PODKOP_GUARD_WATCH_CHANGES_ONLY=0

# Readiness must come from the actual bounded worker, not a forged reply.
attempt=0
while [ "$attempt" -lt 5 ]; do
    rc=0
    sh "$worker" watchdog-check-bounded 8 > "$tmp/ready.log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && grep -Fq "WATCHDOG state=HEALTHY_SAMPLED pid=$box dns=fakeip nft=present" "$tmp/ready.log"; then break; fi
    attempt=$((attempt + 1)); sleep 1
done
cat "$tmp/ready.log"
[ "$attempt" -lt 5 ] && our_box || fail real_dns_readiness
echo PASS_VM_B6_REAL_FAKEIP_BASELINE

# The monitor is unmodified. Give the external harness a small interval
# to stop/resume between samples; exact assertions detect a missed window.
sh "$worker" watchdog-monitor 5 6 > "$tmp/monitor.log" 2>&1 &
monitor=$!
id=$(proc_identity "$monitor") || fail monitor_identity
monitor_birth=${id#* }
wait_sample() {
    local sample seconds
    sample=$1; seconds=0
    while ! grep -Fq "MONITOR sample=$sample/5 " "$tmp/monitor.log"; do
        [ "$seconds" -lt 65 ] || fail "sample_$sample"
        id=$(proc_identity "$monitor" || :)
        [ "${id#* }" = "$monitor_birth" ] || fail monitor_exited
        seconds=$((seconds + 1)); sleep 1
    done
}
wait_sample 1
grep -Fxq "MONITOR sample=1/5 state=HEALTHY_SAMPLED phase=HEALTHY pid=$box streak=0" "$tmp/monitor.log" ||
    fail monitor_baseline
our_box || fail before_stop_identity
kill -STOP "$box"
attempt=0
while :; do
    our_box || fail stopped_identity
    case "$identity" in T\ *) break ;; esac
    [ "$attempt" -lt 3 ] || fail not_stopped
    attempt=$((attempt + 1)); sleep 1
done
echo "VM_B6_STOPPED pid=$box starttime=$box_birth"
wait_sample 4
our_box || fail during_stop_identity
case "$identity" in T\ *) ;; *) fail unexpected_resume ;; esac
for n in 2 3; do
    streak=$((n - 1))
    grep -Fxq "MONITOR sample=$n/5 state=SUSPECT_DNS_TIMEOUT phase=SUSPECT pid=$box streak=$streak" "$tmp/monitor.log" ||
        fail "real_timeout_$n"
done
grep -Fxq "MONITOR sample=4/5 state=SUSPECT_DNS_TIMEOUT phase=CONFIRMED pid=$box streak=3" "$tmp/monitor.log" ||
    fail real_timeout_confirmation
echo PASS_VM_B6_REAL_SIGSTOP_TIMEOUT
resume_box || fail resume_identity
wait_sample 5
wait "$monitor" || fail monitor_rc
monitor=
cat "$tmp/monitor.log"
grep -Fxq "MONITOR sample=5/5 state=HEALTHY_SAMPLED phase=HEALTHY pid=$box streak=0" "$tmp/monitor.log" ||
    fail real_dns_after_continue
grep -Fxq 'MONITOR_END completed=5 confirmations=1 action=none' "$tmp/monitor.log" || fail monitor_end
[ "$(grep -c '^MONITOR_EVENT confirmed=' "$tmp/monitor.log")" -eq 1 ] ||
    fail extra_confirmation
grep -Fxq "MONITOR_EVENT confirmed=1 state=SUSPECT_DNS_TIMEOUT pid=$box samples=3 action=none" "$tmp/monitor.log" ||
    fail event_authority
our_box || fail after_continue_identity
case "$identity" in T\ *|t\ *) fail still_stopped ;; esac
sh "$worker" watchdog-check-bounded 8 > "$tmp/recovered.log" 2>&1 || fail recovered_probe
cat "$tmp/recovered.log"
grep -Fq "WATCHDOG state=HEALTHY_SAMPLED pid=$box dns=fakeip nft=present" "$tmp/recovered.log" ||
    fail recovered_dns
echo PASS_VM_B6_REAL_SIGCONT_RECOVERY

our_registration || fail cleanup_registration
ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null
attempt=0
while :; do
    id=$(proc_identity "$box" || :)
    [ "${id#* }" = "$box_birth" ] || break
    [ "$attempt" -lt 8 ] || fail cleanup_live_process
    attempt=$((attempt + 1)); sleep 1
done
initial=$(registered)
printf '%s\n' "$initial" | jq -e 'type == "object" and (has("sing-box") | not)' >/dev/null ||
    fail cleanup_service
if pidof sing-box >/dev/null 2>&1; then fail cleanup_any_process; fi
owned=0
[ ! -e /tmp/podkop-guard-probe.lock/active ] &&
    [ ! -e /tmp/podkop-guard-probe.lock/active.abandoned ] || fail probe_slot_leak
sha256sum /etc/podkop-guard/lkg-marker /etc/podkop-guard/lkg.srs \
    /etc/podkop-guard/lkg-subnets.lst > "$tmp/lkg.after"
cmp -s "$tmp/lkg.before" "$tmp/lkg.after" || fail lkg_changed
echo PASS_VM_B6_REAL_FAKEIP_LIFECYCLE

# B6.1b.2: real procd respawn and exhaustion. The previously verified
# FakeIP fixture is reused; this is NOT an installed Podkop instance.
# The respawn policy here is test-only, not a proposed production policy.
respawn_service=$(printf '%s\n' "$service" | jq -c '
    .instances["sing-box.main"].respawn = ["60","2","2"]')
assert_absent() {
    initial=$(registered) || return 1
    printf '%s\n' "$initial" | jq -e 'type == "object" and (has("sing-box") | not)' >/dev/null &&
        ! pidof sing-box >/dev/null 2>&1
}
await_running() {
    local previous attempt id
    previous=$1
    attempt=0
    while [ "$attempt" -lt 12 ]; do
        if our_registration; then
            box=$(printf '%s\n' "$raw" | jq -er '
                .["sing-box"].instances["sing-box.main"] |
                select(.running == true and (.pid|type) == "number") | .pid
            ' 2>/dev/null) || box=
            if [ -n "$box" ]; then
                id=$(proc_identity "$box" || :)
                box_birth=${id#* }
                if [ "$box:$box_birth" != "$previous" ] && our_box; then
                    # Use the actual running process and actual DNS, not
                    # merely the successful return of service list.
                    if sh "$worker" watchdog-check-bounded 8 > "$tmp/respawn-check.log" 2>&1 &&
                       grep -Fq "WATCHDOG state=HEALTHY_SAMPLED pid=$box dns=fakeip nft=present" "$tmp/respawn-check.log" &&
                       our_box; then
                        cat "$tmp/respawn-check.log"
                        return 0
                    fi
                fi
            fi
        fi
        attempt=$((attempt + 1)); sleep 1
    done
    return 1
}
start_respawn_service() {
    assert_absent || fail respawn_preexisting
    owned=1
    ubus -t 3 call service set "$respawn_service" >/dev/null
    await_running none || fail respawn_initial_health
    our_registration || fail respawn_registration
    printf '%s\n' "$raw" | jq -e '
        .["sing-box"].instances["sing-box.main"].respawn |
        .threshold == 60 and .timeout == 2 and .retry == 2
    ' >/dev/null || fail wrong_respawn_policy
}
old_gone() {
    local id
    id=$(proc_identity "$1" || :)
    [ "${id#* }" != "$2" ]
}
wait_absent() {
    local attempt
    attempt=0
    while ! assert_absent; do
        [ "$attempt" -lt 8 ] || return 1
        attempt=$((attempt + 1)); sleep 1
    done
}
# Capture actual notifications of the service object (not broadcast
# events). No claim of complete history, even when capture succeeds.
ubus -S subscribe service > "$tmp/notifications.log" 2>&1 &
subscriber=$!
id=$(proc_identity "$subscriber") || fail subscriber_identity
subscriber_birth=${id#* }
sleep 1
start_respawn_service
first_pid=$box
first_birth=$box_birth
echo "VM_B6_RESPAWN_INITIAL pid=$box birth=$box_birth"

# First exit while an independent observer is sampling. Use real grace
# (shortened only for fixture). A transient absence must not confirm.
PODKOP_GUARD_WATCH_GRACE=10 sh "$worker" watchdog-monitor 5 2 > "$tmp/respawn-monitor.log" 2>&1 &
monitor=$!
id=$(proc_identity "$monitor") || fail respawn_monitor_identity
monitor_birth=${id#* }
attempt=0
while ! grep -Fxq "MONITOR sample=1/5 state=HEALTHY_SAMPLED phase=HEALTHY pid=$box streak=0" "$tmp/respawn-monitor.log"; do
    [ "$attempt" -lt 8 ] || fail respawn_monitor_baseline
    attempt=$((attempt + 1)); sleep 1
done
our_box || fail before_first_exit
kill -TERM "$box"
# Avoid competing for the bounded probe lease while the monitor is active.
wait "$monitor" || fail respawn_monitor_rc
monitor=
cat "$tmp/respawn-monitor.log"
grep -Fxq 'MONITOR_END completed=5 confirmations=0 action=none' "$tmp/respawn-monitor.log" ||
    fail respawn_false_confirmation
if grep -q '^MONITOR_EVENT confirmed=' "$tmp/respawn-monitor.log"; then fail respawn_extra_confirmation; fi
await_running "$first_pid:$first_birth" || fail first_respawn
old_gone "$first_pid" "$first_birth" || fail first_process_still_alive
grep -Fxq "MONITOR sample=5/5 state=HEALTHY_SAMPLED phase=HEALTHY pid=$box streak=0" "$tmp/respawn-monitor.log" ||
    fail monitor_no_fresh_health
echo "PASS_VM_B6_NATIVE_RESPAWN old=$first_pid:$first_birth new=$box:$box_birth"

# Second exit consumes the second allowed retry. No service set/start
# between exits: only procd may create the replacement.
old_pid=$box; old_birth=$box_birth
our_box || fail before_second_exit
kill -TERM "$box"
await_running "$old_pid:$old_birth" || fail second_respawn
old_gone "$old_pid" "$old_birth" || fail second_process_still_alive
echo "VM_B6_SECOND_RESPAWN old=$old_pid:$old_birth new=$box:$box_birth"

# Third exit within threshold exceeds retry=2. The exact upstream
# instances retain STOPPED registration and disable respawn.
old_pid=$box; old_birth=$box_birth
our_box || fail before_third_exit
kill -TERM "$box"
attempt=0
while :; do
    if our_registration && old_gone "$old_pid" "$old_birth" &&
       printf '%s\n' "$raw" | jq -e '
           .["sing-box"].instances["sing-box.main"] |
           .running == false and (has("respawn") | not)
       ' >/dev/null; then break; fi
    [ "$attempt" -lt 8 ] || fail exhaustion_not_observed
    attempt=$((attempt + 1)); sleep 1
done
echo "VM_B6_EXHAUSTED_REGISTRATION $raw"
# Observe longer than two respawn delays; ensure no replacement.
for n in 1 2 3 4 5; do
    sleep 1
    our_registration && printf '%s\n' "$raw" | jq -e '
        .["sing-box"].instances["sing-box.main"] |
        .running == false and (has("respawn") | not)
    ' >/dev/null && ! pidof sing-box >/dev/null 2>&1 ||
        fail unexpected_respawn_after_exhaustion
done
snapshot=$(sh "$worker" watchdog-procd-snapshot)
echo "$snapshot"
case "$snapshot" in 'PROCD_SNAPSHOT state=STOPPED '*'action=none') ;; *) fail exhausted_snapshot ;; esac
# Record the actual resident classification. There is not yet a
# contract distinguishing exhausted respawn from all manual stops.
sh "$worker" watchdog-monitor 3 0 > "$tmp/exhausted.log" 2>&1 || fail exhausted_monitor
cat "$tmp/exhausted.log"
grep -Eq '^MONITOR_END completed=3 confirmations=[01] action=none$' "$tmp/exhausted.log" ||
    fail exhausted_monitor_end
if grep -q 'state=HEALTHY_SAMPLED' "$tmp/exhausted.log"; then fail exhausted_false_health; fi
echo PASS_VM_B6_NATIVE_RESPAWN_EXHAUSTION

# Remove only our retained registration, then test an explicit operator
# stop of a fresh owned instance with respawn enabled.
our_registration || fail exhausted_ownership
ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null
wait_absent || fail exhausted_cleanup
owned=0
start_respawn_service
manual_pid=$box; manual_birth=$box_birth
our_box || fail manual_stop_ownership
ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null
wait_absent && old_gone "$manual_pid" "$manual_birth" || fail manual_stop_cleanup
owned=0
sleep 3
assert_absent || fail manual_stop_respawned
snapshot=$(sh "$worker" watchdog-procd-snapshot)
echo "$snapshot"
case "$snapshot" in 'PROCD_SNAPSHOT state=UNREGISTERED '*'action=none') ;; *) fail manual_stop_snapshot ;; esac
# This is an explicit procd delete, not Podkop stop_main: the synthetic
# nft table remains present. Record any missing-process confirmation
# as diagnostic evidence for B6.2, never as an approved recovery gate.
sh "$worker" watchdog-monitor 3 0 > "$tmp/manual-stop.log" 2>&1 || fail manual_stop_monitor
cat "$tmp/manual-stop.log"
grep -Eq '^MONITOR_END completed=3 confirmations=[01] action=none$' "$tmp/manual-stop.log" ||
    fail manual_stop_monitor_end
if grep -q 'state=HEALTHY_SAMPLED' "$tmp/manual-stop.log"; then fail manual_stop_false_health; fi
echo PASS_VM_B6_MANUAL_PROCD_STOP_EVIDENCE

# Capture/inspect notifications only for this service and instance.
# Both pinned procd sources emit thin instance.* payloads. The current
# Guard decoder requires richer exit fields: log actual decoder output
# for B6.2 without treating a thin payload as permission to act.
stop_events
for kind in instance.respawn instance.fail instance.stop; do
    jq -c --arg k "$kind" '
        select(type == "object" and has($k)) |
        select(.[$k].service == "sing-box" and .[$k].instance == "sing-box.main")
    ' "$tmp/notifications.log" > "$tmp/$kind.jsonl" || fail notification_parse
    [ -s "$tmp/$kind.jsonl" ] || fail "missing_notification_$kind"
    while IFS= read -r event; do
        printf 'VM_B6_NOTIFICATION %s\n' "$event"
        decoded=$(printf '%s\n' "$event" | sh "$worker" watchdog-procd-event)
        printf 'VM_B6_DECODED %s\n' "$decoded"
        case "$decoded" in 'PROCD_EVENT '*'action=none') ;; *) fail notification_authority ;; esac
    done < "$tmp/$kind.jsonl"
done
echo PASS_VM_B6_REAL_PROCD_NOTIFICATION_EVIDENCE
assert_absent || fail final_respawn_cleanup
[ ! -e /tmp/podkop-guard-probe.lock/active ] &&
    [ ! -e /tmp/podkop-guard-probe.lock/active.abandoned ] || fail respawn_probe_slot_leak
sha256sum /etc/podkop-guard/lkg-marker /etc/podkop-guard/lkg.srs \
    /etc/podkop-guard/lkg-subnets.lst > "$tmp/lkg.after"
cmp -s "$tmp/lkg.before" "$tmp/lkg.after" || fail respawn_lkg_changed
echo PASS_VM_B6_REAL_RESPAWN_LIFECYCLE

# B6.1b.3: reproduce the pinned Podkop 0.7.24 shell invocation shapes
# on real BusyBox ash. The body is deliberately inert and finite.
# Do not run the actual Podkop script, modify cron/UCI or send a signal
# to a PID from a marker. The real sing-box and real DNS remain healthy.
assert_absent || fail maintenance_preexisting_box
[ ! -e /usr/bin/podkop ] && [ ! -L /usr/bin/podkop ] ||
    fail maintenance_preexisting_podkop
[ ! -e /var/run/podkop_list_update.pid ] &&
    [ ! -L /var/run/podkop_list_update.pid ] || fail maintenance_preexisting_marker
owned=1
ubus -t 3 call service set "$service" >/dev/null
await_running none || fail maintenance_initial_health
maint_box=$box
maint_box_birth=$box_birth
export PODKOP_GUARD_WATCH_LIST_PID_FILE="$tmp/maintenance-marker"
# Use the real /proc and the normal executable path recognized by the
# worker. The symlink is created only in the guarded disposable guest.
cat > "$tmp/podkop-fixture" <<'SH'
#!/bin/sh
set -eu
[ -n "${PG_MAINT_CASE_DIR:-}" ] && [ -d "$PG_MAINT_CASE_DIR" ]
list_update() {
    : > "$PG_MAINT_CASE_DIR/ready"
    n=0
    while [ ! -e "$PG_MAINT_CASE_DIR/release" ] && [ "$n" -lt 24 ]; do
        n=$((n + 1)); sleep 1
    done
}
case "$1" in
    start|reload)
        # Match upstream start_main: fork a function and record $!.
        list_update &
        printf '%s\n' "$!" > "$PODKOP_GUARD_WATCH_LIST_PID_FILE"
        ;;
    list_update|stop|restart|list_update_extra|start_extra|unrelated)
        # Match separate CLI invocation or a deliberately similar name.
        list_update ;;
    *) exit 19 ;;
esac
SH
chmod 700 "$tmp/podkop-fixture"
ln -s "$tmp/podkop-fixture" /usr/bin/podkop
maint_link=1
begin_maintenance() {
    local mode kind attempt id cmd stat rest
    mode=$1; kind=$2
    [ -z "$maint_dir" ] || fail overlapping_fixture
    rm -f "$PODKOP_GUARD_WATCH_LIST_PID_FILE"
    maint_dir=$(mktemp -d "$tmp/maintenance.XXXXXX")
    PG_MAINT_CASE_DIR="$maint_dir" /usr/bin/podkop "$mode" > "$maint_dir/child.log" 2>&1 &
    maint_launcher=$!
    if [ "$kind" = background ]; then
        wait "$maint_launcher" || fail maintenance_parent
        maint_launcher=
        read -r maint_pid < "$PODKOP_GUARD_WATCH_LIST_PID_FILE" || fail maintenance_marker
    else
        maint_pid=$maint_launcher
    fi
    attempt=0
    while [ ! -e "$maint_dir/ready" ]; do
        [ "$attempt" -lt 5 ] || fail maintenance_not_ready
        attempt=$((attempt + 1)); sleep 1
    done
    id=$(proc_identity "$maint_pid") || fail maintenance_identity
    maint_birth=${id#* }
    [ "$(readlink -f "/proc/$maint_pid/exe")" = "$(readlink -f /bin/busybox)" ] ||
        fail maintenance_not_busybox
    cmd=$(tr '\000' ' ' < "/proc/$maint_pid/cmdline")
    # The full argument must be the actual mode, not the function name.
    case "$cmd" in *"/usr/bin/podkop $mode ") ;; *) fail "unexpected_cmdline:$mode:$cmd" ;; esac
    IFS= read -r stat < "/proc/$maint_pid/stat" || fail maintenance_stat
    rest=${stat##*) }; set -- $rest
    printf 'VM_B6_MAINT_PROCESS mode=%s kind=%s pid=%s birth=%s ppid=%s cmdline=%s\n' \
        "$mode" "$kind" "$maint_pid" "$maint_birth" "$2" "$cmd"
    if [ "$kind" = background ]; then
        [ "$(cat "$PODKOP_GUARD_WATCH_LIST_PID_FILE")" = "$maint_pid" ] || fail marker_mismatch
    else
        [ ! -e "$PODKOP_GUARD_WATCH_LIST_PID_FILE" ] || fail unexpected_marker
    fi
}
end_maintenance() {
    local attempt
    : > "$maint_dir/release"
    if [ -n "$maint_launcher" ]; then
        wait "$maint_launcher" || fail maintenance_child
    fi
    attempt=0
    while ! old_gone "$maint_pid" "$maint_birth"; do
        [ "$attempt" -lt 5 ] || fail maintenance_child_alive
        attempt=$((attempt + 1)); sleep 1
    done
    maint_dir=
    maint_pid=
    maint_birth=
    maint_launcher=
}
maintenance_probe() {
    local label expected output rc
    label=$1; expected=$2
    rc=0
    output=$(sh "$worker" watchdog-check-bounded 8) || rc=$?
    printf 'VM_B6_MAINT_SAMPLE case=%s rc=%s %s\n' "$label" "$rc" "$output"
    [ "$rc" -eq 0 ] || fail "maintenance_probe_rc:$label"
    case "$expected:$output" in
        'lifecycle:WATCHDOG state=TRANSITION reason=podkop_lifecycle '*) ;;
        'list:WATCHDOG state=TRANSITION reason=list_update '*) ;;
        'healthy:WATCHDOG state=HEALTHY_SAMPLED '*) ;;
        *) fail "maintenance_probe_state:$label:$output" ;;
    esac
    our_box && [ "$box:$box_birth" = "$maint_box:$maint_box_birth" ] ||
        fail maintenance_changed_box
}

# Parent returns, but forked list_update remains with cmdline "start"
# or "reload". Check the stale marker remains harmless after child exit.
begin_maintenance start background
maintenance_probe background_start lifecycle
# No marker: the global process scan still detects the actual child.
mv "$PODKOP_GUARD_WATCH_LIST_PID_FILE" "$tmp/marker.saved"
maintenance_probe background_start_without_marker lifecycle
mv "$tmp/marker.saved" "$PODKOP_GUARD_WATCH_LIST_PID_FILE"
end_maintenance
[ -s "$PODKOP_GUARD_WATCH_LIST_PID_FILE" ] || fail stale_marker_not_retained
maintenance_probe stale_background_marker healthy
echo PASS_VM_B6_BACKGROUND_LIST_UPDATE_EVIDENCE
begin_maintenance reload background
maintenance_probe background_reload lifecycle
end_maintenance
maintenance_probe stale_reload_marker healthy

# Separate CLI, as used by cron and operators, with no PID marker.
begin_maintenance list_update direct
maintenance_probe standalone_list_update list
# Grace is shortened ONLY for the fixture. Record the current absence
# of a prolonged-maintenance limit; this is evidence, not a desired
# permanent acceptance contract. No healthy baseline during maintenance.
PODKOP_GUARD_WATCH_GRACE=1 sh "$worker" watchdog-monitor 4 1 > "$tmp/maintenance.log" 2>&1 ||
    fail maintenance_monitor
cat "$tmp/maintenance.log"
for n in 1 2 3 4; do
    grep -Fxq "MONITOR sample=$n/4 state=TRANSITION phase=TRANSITION pid=$box streak=0 reason=list_update" "$tmp/maintenance.log" ||
        fail "maintenance_monitor_sample_$n"
done
grep -Fxq 'MONITOR_END completed=4 confirmations=0 action=none' "$tmp/maintenance.log" ||
    fail maintenance_monitor_end
echo PASS_VM_B6_PROLONGED_MAINTENANCE_EVIDENCE
end_maintenance
maintenance_probe after_list_update healthy
echo PASS_VM_B6_STANDALONE_LIST_UPDATE_EVIDENCE

# Actual process argument matching, without performing real lifecycle
# operations. No UCI/network configuration is changed by the fixture.
for mode in stop restart; do
    begin_maintenance "$mode" direct
    maintenance_probe "manual_$mode" lifecycle
    end_maintenance
done
echo PASS_VM_B6_MANUAL_LIFECYCLE_EVIDENCE

# Simulate a stale marker now referring to an unrelated live process.
# Do not force kernel PID recycling. The marker alone must not suppress.
begin_maintenance unrelated direct
printf '%s\n' "$maint_pid" > "$PODKOP_GUARD_WATCH_LIST_PID_FILE"
maintenance_probe unrelated_live_marker healthy
end_maintenance
printf 'not-a-pid\n' > "$PODKOP_GUARD_WATCH_LIST_PID_FILE"
maintenance_probe malformed_marker healthy
echo PASS_VM_B6_STALE_MARKER_EVIDENCE

# Existing substring checks mistake these non-operations for maintenance.
# Pin the observed limitation for B6.2; later replace these expectations
# with strict argument matching, not with skipped assertions.
begin_maintenance list_update_extra direct
maintenance_probe list_update_prefix_collision list
end_maintenance
begin_maintenance start_extra direct
maintenance_probe lifecycle_prefix_collision lifecycle
end_maintenance
echo PASS_VM_B6_CMDLINE_PREFIX_COLLISION_EVIDENCE
rm -f "$PODKOP_GUARD_WATCH_LIST_PID_FILE"
maintenance_probe final_healthy healthy

[ "$(readlink /usr/bin/podkop)" = "$tmp/podkop-fixture" ] ||
    fail maintenance_link_changed
rm -f /usr/bin/podkop
maint_link=0
[ ! -e /usr/bin/podkop ] && [ ! -L /usr/bin/podkop ] &&
    [ ! -e /var/run/podkop_list_update.pid ] || fail maintenance_fixture_leak
our_box || fail maintenance_cleanup_ownership
ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null
wait_absent && old_gone "$maint_box" "$maint_box_birth" || fail maintenance_cleanup
owned=0
[ ! -e /tmp/podkop-guard-probe.lock/active ] &&
    [ ! -e /tmp/podkop-guard-probe.lock/active.abandoned ] || fail maintenance_probe_slot_leak
sha256sum /etc/podkop-guard/lkg-marker /etc/podkop-guard/lkg.srs \
    /etc/podkop-guard/lkg-subnets.lst > "$tmp/lkg.after"
cmp -s "$tmp/lkg.before" "$tmp/lkg.after" || fail maintenance_lkg_changed
echo PASS_VM_B6_REAL_MAINTENANCE_EVIDENCE
