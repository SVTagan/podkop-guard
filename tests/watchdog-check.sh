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
WATCH_TEST_NFT_FIXTURE="$(cd "$(dirname "$0")" && pwd)/nft-structure-fixture.json"
[ -r "$WATCH_TEST_NFT_FIXTURE" ]
export WATCH_TEST_NFT_FIXTURE
fixture_command_id=$(printf '%s\000' /usr/bin/sing-box run -c "$tmp/config.json" -D "$tmp" | LC_ALL=C hexdump -v -e '1/1 "%02x"' | sha256sum)
fixture_command_id=${fixture_command_id%% *}
fixture_config='{"log":{"level":"warn"},"dns":{"servers":[{"type":"udp","tag":"unused-local","server":"127.0.0.1","server_port":9},{"type":"fakeip","tag":"fakeip-server","inet4_range":"198.18.0.0/15"}],"rules":[{"domain":["fakeip.podkop.fyi","ip.podkop.fyi"],"action":"route","server":"fakeip-server","rewrite_ttl":60}],"final":"unused-local","strategy":"ipv4_only"},"inbounds":[{"type":"direct","tag":"dns-in","listen":"127.0.0.42","listen_port":53}],"outbounds":[{"type":"direct","tag":"direct-out"}],"route":{"rules":[{"inbound":["dns-in"],"action":"sniff"},{"protocol":"dns","action":"hijack-dns"}],"final":"direct-out","default_domain_resolver":"unused-local"}}'
fixture_config_id=$(printf '%s\n' "$fixture_config" | jq -cS .)
fixture_config_id=$(printf '%s' "$fixture_config_id" | sha256sum)
fixture_config_id=${fixture_config_id%% *}
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
    printf '{"sing-box":{"instances":{"sing-box.main":{"running":false,"command":%s,"exit_code":0}}}}\n' "$WATCH_TEST_ARGV_JSON"
else
    printf '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":%s,"command":%s}}}}\n' "$pid" "$WATCH_TEST_ARGV_JSON"
fi
SH
cat > "$tmp/bin/nft" <<'SH'
#!/bin/sh
if [ "$*" = '-j -t list table inet PodkopTable' ]; then
    case "$WATCH_TEST_NFT" in
        absent|error) exit 1 ;;
        absent_after_dns|error_after_dns) [ ! -e "$WATCH_TEST_DNS_CALLED" ] || exit 1 ;;
        structure_read_error) exit 1 ;;
        structure_bad_json) printf '{\n'; exit 0 ;;
        structure_multi_json) printf '{}\n{}\n'; exit 0 ;;
    esac
    fixture=$(cat "$WATCH_TEST_NFT_FIXTURE") || exit 1
    case "$WATCH_TEST_NFT" in
        structure_partial) filter='.nftables |= map(select(.chain.name? != "proxy"))' ;;
        structure_wrong_hook) filter='(.nftables[] | select(.chain.name? == "proxy") | .chain.hook) = "output"' ;;
        structure_wrong_type) filter='(.nftables[] | select(.set.name? == "interfaces") | .set.type) = "ipv4_addr"' ;;
        structure_wrong_priority) filter='(.nftables[] | select(.chain.name? == "mangle") | .chain.prio) = -100' ;;
        structure_dormant) filter='(.nftables[] | select(.table.name? == "PodkopTable") | .table.flags) = ["dormant"]' ;;
        structure_duplicate) filter='.nftables += [.nftables[] | select(.chain.name? == "proxy")]' ;;
        structure_missing_set) filter='.nftables |= map(select(.set.name? != "podkop_subnets"))' ;;
        structure_partial_after_dns)
            if [ -e "$WATCH_TEST_DNS_CALLED" ]; then filter='.nftables |= map(select(.chain.name? != "proxy"))'; else filter=.; fi ;;
        structure_wrong_after_dns)
            if [ -e "$WATCH_TEST_DNS_CALLED" ]; then filter='(.nftables[] | select(.chain.name? == "mangle") | .chain.prio) = -100'; else filter=.; fi ;;
        rules_empty) filter='.nftables |= map(select(has("rule")|not))' ;;
        rules_wrong_mark) filter='(.nftables[] | select(.rule.chain? == "mangle_output") | .rule.expr[] | select(.mangle?) | .mangle.value) = 1048577' ;;
        rules_missing_udp) filter='.nftables |= map(select((.rule.chain? == "proxy" and any(.rule.expr[]; .match.right? == "udp"))|not))' ;;
        rules_wrong_range) filter='(.nftables[] | select(.rule.chain? == "mangle") | .rule.expr[] | select(.match.right.prefix?) | .match.right.prefix.len) = 16' ;;
        rules_missing_common) filter='.nftables |= map(select((.rule.chain? == "mangle_output" and any(.rule.expr[]; .match.right? == "@podkop_subnets"))|not))' ;;
        rules_wrong_interface) filter='(.nftables[] | select(.rule.chain? == "mangle") | .rule.expr[] | select(.match.right? == "@interfaces") | .match.right) = "@other"' ;;
        rules_wrong_port) filter='(.nftables[] | select(.rule.chain? == "proxy") | .rule.expr[] | select(.tproxy?) | .tproxy.port) = 1603' ;;
        rules_wrong_addr) filter='(.nftables[] | select(.rule.chain? == "proxy") | .rule.expr[] | select(.tproxy?) | .tproxy.addr) = "127.0.0.2"' ;;
        rules_wrong_mask) filter='(.nftables[] | select(.rule.chain? == "proxy") | .rule.expr[] | select(.match.left["&"]?) | .match.left["&"][1]) = 2097152' ;;
        rules_missing_bypass) filter='.nftables |= map(select((.rule.chain? == "mangle_output" and any(.rule.expr[]; has("return")))|not))' ;;
        rules_split_signature) filter='.nftables |= (map(if .rule.chain? == "proxy" then .rule.expr |= map(select(has("tproxy")|not)) else . end) + [.[] | select(.rule.chain? == "proxy") | .rule.expr |= map(select(has("tproxy")))])' ;;
        rules_wrong_chain) filter='(.nftables[] | select(.rule.chain? == "proxy") | .rule.chain) = "mangle"' ;;
        rules_after_dns)
            if [ -e "$WATCH_TEST_DNS_CALLED" ]; then filter='.nftables |= map(select((.rule.chain? == "proxy" and any(.rule.expr[]; .match.right? == "udp"))|not))'; else filter=.; fi ;;
        rules_numeric) filter='(.nftables[] | .rule? | select(type == "object") | .expr[] | select(.match.left.meta.key? == "l4proto") | .match.right) |= (if . == "tcp" then 6 else 17 end) | (.nftables[] | select(.rule.chain? == "proxy") | .rule.expr[] | select(.match.left["&"]?) | .match) |= (.op = "!=" | .right = 0)' ;;
        structure_extra)
            filter='.nftables += [{"set":{"family":"inet","table":"PodkopTable","name":"optional","type":"ipv4_addr"}},{"rule":{"family":"inet","table":"PodkopTable","chain":"mangle","expr":[{"counter":{"packets":1,"bytes":42}}]}}]' ;;
        *) filter=. ;;
    esac
    printf '%s\n' "$fixture" | jq -c "$filter"
    exit $?
fi
[ "$*" = 'list tables' ] || exit 9
case "$WATCH_TEST_NFT" in
    present|structure_*|rules_*) printf 'table inet PodkopTable\n' ;;
    absent) printf 'table inet fw4\n' ;;
    error) exit 1 ;;
    absent_after_dns)
        if [ -e "$WATCH_TEST_DNS_CALLED" ]; then printf 'table inet fw4\n'
        else printf 'table inet PodkopTable\n'; fi ;;
    error_after_dns)
        [ ! -e "$WATCH_TEST_DNS_CALLED" ] || exit 1
        printf 'table inet PodkopTable\n' ;;
    *) exit 9 ;;
esac
SH
cat > "$tmp/bin/uci" <<'SH'
#!/bin/sh
case "$*" in
    '-q get podkop.settings.shutdown_correctly') printf '%s\n' "$WATCH_TEST_SHUTDOWN" ;;
    '-q get podkop.settings.config_path')
        [ "$WATCH_TEST_CONFIG_CASE" != path_missing_uci ] || exit 1
        printf '%s\n' "$WATCH_TEST_POD_CONFIG" ;;
    '-q get sing-box.main.conffile')
        [ "$WATCH_TEST_CONFIG_CASE" != path_missing_conffile ] || exit 1
        if [ "$WATCH_TEST_CONFIG_CASE" = path_changed_after_dns ] && [ -e "$WATCH_TEST_DNS_CALLED" ]; then
            printf '%s\n' /other.json
        else
            printf '%s\n' "$WATCH_TEST_BOX_CONFIG"
        fi ;;
    *) exit 9 ;;
esac
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
case "$WATCH_TEST_CONFIG_CASE" in
    path_file_lost_after_dns) rm -f "$WATCH_TEST_POD_CONFIG" ;;
    path_layout_changed_after_dns|layout_invalid_after_dns) printf '{}\n' > "$WATCH_TEST_POD_CONFIG" ;;
    layout_changed_healthy|layout_changed_timeout)
        jq '.log.level = "error"' "$WATCH_TEST_POD_CONFIG" > "$WATCH_TEST_POD_CONFIG.next" || exit 9
        mv "$WATCH_TEST_POD_CONFIG.next" "$WATCH_TEST_POD_CONFIG" ;;
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
        printf '%s\n' "$fixture_config" > "$tmp/config.json"
    else
        printf '{}\n' > "$tmp/config.json"
    fi
    case "$name" in
        layout_wrong_inbound_type) filter='.inbounds[0].type = "socks"' ;;
        layout_tcp_only) filter='.inbounds[0].network = "tcp"' ;;
        layout_duplicate_inbound) filter='.inbounds += [.inbounds[0]]' ;;
        layout_wrong_listen) filter='.inbounds[0].listen = "127.0.0.1"' ;;
        layout_no_fakeip) filter='.dns.servers |= map(select(.tag != "fakeip-server"))' ;;
        layout_wrong_range) filter='.dns.servers[1].inet4_range = "198.18.0.0/16"' ;;
        layout_duplicate_server) filter='.dns.servers += [.dns.servers[1]]' ;;
        layout_wrong_domain) filter='.dns.rules[0].domain = ["other.example"]' ;;
        layout_wrong_server) filter='.dns.rules[0].server = "unused-local"' ;;
        layout_conditional_rule) filter='.dns.rules[0].rule_set = ["other"]' ;;
        layout_no_sniff) filter='.route.rules |= map(select(.action != "sniff"))' ;;
        layout_wrong_sniff) filter='.route.rules[0].inbound = ["other"]' ;;
        layout_no_hijack) filter='.route.rules |= map(select(.action != "hijack-dns"))' ;;
        layout_wrong_hijack) filter='.route.rules[1].protocol = "http"' ;;
        layout_reversed_route) filter='.route.rules |= reverse' ;;
        layout_scalar_fields) filter='.dns.rules[0].domain = "fakeip.podkop.fyi" | .route.rules[0].inbound = "dns-in" | .route.rules[1].protocol = ["dns"]' ;;
        layout_extra_rules) filter='.dns.rules += [{"action":"reject","domain":["other.example"]}] | .route.rules += [{"action":"route","outbound":"direct-out","inbound":["other"]}]' ;;
        *) filter= ;;
    esac
    if [ -n "$filter" ]; then
        jq "$filter" "$tmp/config.json" > "$tmp/config.next"
        mv "$tmp/config.next" "$tmp/config.json"
    fi
    cfg_path="$tmp/config.json"
    pod_path=$cfg_path
    box_path=$cfg_path
    case "$name" in
        path_space) cfg_path="$tmp/config space.json"; cp "$pod_path" "$cfg_path"; pod_path=$cfg_path; box_path=$cfg_path ;;
        path_uci_mismatch) box_path="$tmp/other.json" ;;
        path_argv_mismatch) cfg_path="$tmp/other.json" ;;
        path_relative) pod_path=config.json; box_path=$pod_path; cfg_path=$pod_path ;;
        path_file_missing) rm -f "$cfg_path" ;;
        path_directory) cfg_path="$tmp"; pod_path=$cfg_path; box_path=$cfg_path ;;
    esac
    set -- /usr/bin/sing-box run -c "$cfg_path" -D "$tmp"
    case "$name" in
        path_no_workdir|path_space) set -- /usr/bin/sing-box run -c "$cfg_path" ;;
        path_no_config) set -- /usr/bin/sing-box run ;;
        path_extra_config) set -- "$@" -c "$cfg_path" ;;
        path_relative_workdir) set -- /usr/bin/sing-box run -c "$cfg_path" -D relative ;;
        path_config_prefix) set -- /usr/bin/sing-box run -c "$cfg_path.extra" ;;
    esac
    argv_json=$(jq -cn --args '$ARGS.positional' -- "$@")
    make_birth 12345 1000 S
    make_birth 54321 1001 S
    for fixture_pid in 12345 54321; do
        rm -f "$tmp/proc/$fixture_pid/exe" "$tmp/proc/$fixture_pid/cmdline"
        ln -s /usr/bin/sing-box "$tmp/proc/$fixture_pid/exe"
        printf '%s\000' "$@" > "$tmp/proc/$fixture_pid/cmdline"
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
        WATCH_TEST_ARGV_JSON="$argv_json" WATCH_TEST_POD_CONFIG="$pod_path" \
        WATCH_TEST_BOX_CONFIG="$box_path" WATCH_TEST_CONFIG_CASE="$name" \
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
        nft_missing|nft_missing_timeout)
            case "$output" in *'reason=nft_table_absent '*'dns=skipped nft=absent') ;; *)
                echo "FAIL $name: missing table not rejected: $output" >&2; exit 1 ;;
            esac
            [ ! -e "$tmp/dns-called" ] || { echo "FAIL $name: DNS ran without table" >&2; exit 1; } ;;
        nft_unavailable|nft_unavailable_timeout)
            case "$output" in *'reason=nft_table_unavailable '*'dns=skipped nft=unknown') ;; *)
                echo "FAIL $name: unreadable table not rejected: $output" >&2; exit 1 ;;
            esac
            [ ! -e "$tmp/dns-called" ] || { echo "FAIL $name: DNS ran without table evidence" >&2; exit 1; } ;;
        nft_lost_during_*)
            case "$output" in *'reason=nft_table_absent '*'nft=absent') ;; *)
                echo "FAIL $name: stale table evidence: $output" >&2; exit 1 ;;
            esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        nft_error_during_*)
            case "$output" in *'reason=nft_table_unavailable '*'nft=unknown') ;; *)
                echo "FAIL $name: stale table evidence: $output" >&2; exit 1 ;;
            esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        structure_partial|structure_missing_set)
            case "$output" in *'reason=nft_structure_partial '*'dns=skipped nft=partial') ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
        structure_wrong_hook|structure_wrong_type|structure_wrong_priority|structure_dormant|structure_duplicate)
            case "$output" in *'reason=nft_structure_unsupported '*'dns=skipped nft=unsupported') ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
        structure_bad_json|structure_multi_json|structure_read_error)
            case "$output" in *'reason=nft_table_unavailable '*'dns=skipped nft=unknown') ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
        structure_partial_after_*)
            case "$output" in *'reason=nft_structure_partial '*'nft=partial') ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        structure_wrong_after_*)
            case "$output" in *'reason=nft_structure_unsupported '*'nft=unsupported') ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        rules_after_*)
            case "$output" in *'reason=nft_rules_incomplete '*'nft=partial') ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        rules_numeric) ;;
        rules_*)
            case "$output" in *'reason=nft_rules_incomplete '*'dns=skipped nft=partial') ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
        path_missing_uci|path_missing_conffile|path_relative)
            case "$output" in *'reason=dns_config_path_unavailable '*'dns=skipped '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
        path_uci_mismatch|path_argv_mismatch|path_no_config|path_extra_config|path_relative_workdir|path_config_prefix)
            case "$output" in *'reason=dns_config_path_mismatch '*'dns=skipped '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
        path_file_missing|path_directory)
            case "$output" in *'reason=dns_config_file_unavailable '*'dns=skipped '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
        path_changed_after_dns)
            case "$output" in *'reason=dns_config_path_mismatch '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        path_file_lost_after_dns)
            case "$output" in *'reason=dns_config_file_unavailable '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        path_layout_changed_after_dns)
            case "$output" in *'reason=unsupported_dns_config '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        layout_changed_*)
            case "$output" in *'reason=dns_config_changed '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        layout_invalid_after_dns)
            case "$output" in *'reason=unsupported_dns_config '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ -e "$tmp/dns-called" ] || exit 1 ;;
        layout_scalar_fields|layout_extra_rules) ;;
        layout_*)
            case "$output" in *'reason=unsupported_dns_config '*'dns=skipped '*) ;; *) echo "FAIL $name: $output" >&2; exit 1 ;; esac
            [ ! -e "$tmp/dns-called" ] || exit 1 ;;
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
        healthy) case "$output" in *" birth=1000 bus=700:2000 command_id=$fixture_command_id config_id=$fixture_config_id") ;; *) echo "FAIL identity fields: $output" >&2; exit 1 ;; esac ;;
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
case_run nft_missing_timeout UNKNOWN              2 timeout   absent 12345 true 0 valid up
case_run nft_unavailable_timeout UNKNOWN          2 timeout   error 12345 true 0 valid up
case_run nft_lost_during_success UNKNOWN           2 healthy   absent_after_dns 12345 true 0 valid up
case_run nft_lost_during_timeout UNKNOWN           2 timeout   absent_after_dns 12345 true 0 valid up
case_run nft_error_during_success UNKNOWN          2 healthy   error_after_dns 12345 true 0 valid up
case_run nft_error_during_timeout UNKNOWN          2 timeout   error_after_dns 12345 true 0 valid up
for scenario in structure_partial structure_missing_set structure_wrong_hook structure_wrong_type structure_wrong_priority structure_dormant structure_duplicate structure_bad_json structure_multi_json structure_read_error; do
    case_run "$scenario" UNKNOWN 2 timeout "$scenario" 12345 true 0 valid up
done
case_run structure_partial_after_healthy UNKNOWN 2 healthy structure_partial_after_dns 12345 true 0 valid up
case_run structure_partial_after_timeout UNKNOWN 2 timeout structure_partial_after_dns 12345 true 0 valid up
case_run structure_wrong_after_healthy UNKNOWN 2 healthy structure_wrong_after_dns 12345 true 0 valid up
case_run structure_wrong_after_timeout UNKNOWN 2 timeout structure_wrong_after_dns 12345 true 0 valid up
case_run structure_extra HEALTHY_SAMPLED 0 healthy structure_extra 12345 true 0 valid up
for scenario in rules_empty rules_wrong_mark rules_missing_udp rules_wrong_range rules_missing_common rules_wrong_interface rules_wrong_port rules_wrong_addr rules_wrong_mask rules_missing_bypass rules_split_signature rules_wrong_chain; do
    case_run "$scenario" UNKNOWN 2 timeout "$scenario" 12345 true 0 valid up
done
case_run rules_after_healthy UNKNOWN 2 healthy rules_after_dns 12345 true 0 valid up
case_run rules_after_timeout UNKNOWN 2 timeout rules_after_dns 12345 true 0 valid up
case_run rules_numeric HEALTHY_SAMPLED 0 healthy rules_numeric 12345 true 0 valid up
case_run procd_error      UNKNOWN                 2 healthy   present 12345 true  0 valid down
case_run unsupported_cfg  UNKNOWN                 2 healthy   present 12345 true  0 bad   up
# UCI path and actual argv are independent observations. The obsolete test
# override above must not allow a different file to validate the runtime.
for scenario in path_missing_uci path_missing_conffile path_relative path_uci_mismatch path_argv_mismatch path_no_config path_extra_config path_relative_workdir path_config_prefix path_file_missing path_directory; do
    case_run "$scenario" UNKNOWN 2 timeout present 12345 true 0 valid up
done
case_run path_changed_after_dns UNKNOWN 2 timeout present 12345 true 0 valid up
case_run path_file_lost_after_dns UNKNOWN 2 healthy present 12345 true 0 valid up
case_run path_layout_changed_after_dns UNKNOWN 2 healthy present 12345 true 0 valid up
case_run path_no_workdir HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
case_run path_space HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
for scenario in layout_wrong_inbound_type layout_tcp_only layout_duplicate_inbound layout_wrong_listen layout_no_fakeip layout_wrong_range layout_duplicate_server layout_wrong_domain layout_wrong_server layout_conditional_rule layout_no_sniff layout_wrong_sniff layout_no_hijack layout_wrong_hijack layout_reversed_route; do
    case_run "$scenario" UNKNOWN 2 timeout present 12345 true 0 valid up
done
for scenario in layout_scalar_fields layout_extra_rules; do
    case_run "$scenario" HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
done
case_run layout_changed_healthy TRANSITION 0 healthy present 12345 true 0 valid up
case_run layout_changed_timeout TRANSITION 0 timeout present 12345 true 0 valid up
case_run layout_invalid_after_dns UNKNOWN 2 healthy present 12345 true 0 valid up


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
PODKOP_GUARD_WATCH_LOOPBACK_BASELINE_ID="12345:1000:700:2000:$fixture_command_id:$fixture_config_id"
export PODKOP_GUARD_WATCH_LOOPBACK_BASELINE_ID
case_run control_suppresses_suspect UNKNOWN 2 timeout present 12345 true 0 valid up
WATCH_TEST_PING=up
case_run control_recovers SUSPECT_DNS_TIMEOUT 1 timeout present 12345 true 0 valid up
PODKOP_GUARD_WATCH_LOOPBACK_BASELINE_ID="12345:999:700:2000:$fixture_command_id:$fixture_config_id"
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
# Exact operation and argument boundaries: no flattened-string matches.
printf '/usr/bin/podkop\000list_update\000' > "$tmp/proc/321/cmdline"
case_run premaintenance_direct TRANSITION 0 healthy present 12345 true 0 valid up
printf 'sh\000/usr/bin/podkop\000reload\000' > "$tmp/proc/321/cmdline"
case_run premaintenance_shell TRANSITION 0 healthy present 12345 true 0 valid up
printf '/bin/sh\000/usr/bin/podkop\000list_update_extra\000' > "$tmp/proc/321/cmdline"
printf '321\n' > "$tmp/list.pid"
case_run maintenance_prefix_marker HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
rm -f "$tmp/list.pid"
printf '/bin/sh\000/usr/bin/podkop\000start_extra\000' > "$tmp/proc/321/cmdline"
case_run maintenance_prefix_lifecycle HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
printf '/bin/sh\000-c\000/usr/bin/podkop list_update\000' > "$tmp/proc/321/cmdline"
case_run maintenance_embedded_command HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
printf '/bin/sh\000/tmp/podkop\000list_update\000' > "$tmp/proc/321/cmdline"
case_run maintenance_wrong_path HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
printf '/bin/sh\000/usr/bin/podkop\000list_update' > "$tmp/proc/321/cmdline"
case_run maintenance_truncated_token HEALTHY_SAMPLED 0 healthy present 12345 true 0 valid up
rm -f "$tmp/proc/321/cmdline"
# Force the check/use gap in a private copy of the actual maintenance
# function. No scheduling lottery, actual PID signals or production hook.
awk '
    /^watch_maintenance_(command|active)\(\) \{/ { active=1 }
    active { print }
    active && /if \[ -n "\$pid" \] && \[ -r / {
        print "            rm -f \"$proc_root/$pid/cmdline\""; marker++
    }
    active && /\[ -r "\$proc" \] \|\| continue/ {
        print "        rm -f \"$proc\""; scan++
    }
    active && /^}$/ { active=0; found++ }
    END { if (found != 2 || marker != 1 || scan != 1) exit 1 }
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
