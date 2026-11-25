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
cleanup() {
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
    for f in ready.log monitor.log recovered.log; do
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
    "final": "direct-out"
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
