#!/bin/sh
# Stage A: classifier has TWO independent axes. No source probes or actions.
set -eu
worker="${1:-./podkop-guard}"
case "$worker" in /*) ;; *) worker="$(pwd)/${worker#./}" ;; esac
passed=0

check() {
    name=$1 local_state=$2 wan=$3 vpn=$4 doh=$5 expected_local=$6 expected_evidence=$7 expected_external=$8 coverage=$9
    output=$(sh "$worker" watchdog-classify "$local_state" "$wan" "$vpn" "$doh") || {
        echo "FAIL $name: classifier exited nonzero" >&2; exit 1;
    }
    expected="CLASSIFY local_class=$expected_local local_evidence=$expected_evidence external_class=$expected_external external_coverage=$coverage/3 wan=$wan vpn=$vpn doh=$doh authority=observe-only action=none"
    [ "$output" = "$expected" ] || {
        printf 'FAIL %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$output" >&2; exit 1;
    }
    passed=$((passed+1))
    printf 'PASS %s\n' "$name"
}

# First: hand-reviewed, deterministic example matrix.
check healthy_all           HEALTHY_SAMPLED         UP      HEALTHY HEALTHY LOCAL_HEALTHY_SAMPLED         SAMPLED     EXTERNAL_HEALTHY_SAMPLED 3
check isp_outage            HEALTHY_SAMPLED         DOWN    FAILED  UNKNOWN LOCAL_HEALTHY_SAMPLED         SAMPLED     WAN_REPORTED_DOWN         2
check split_wan_vpn         HEALTHY_SAMPLED         DOWN    HEALTHY UNKNOWN LOCAL_HEALTHY_SAMPLED         SAMPLED     CONFLICTING_EVIDENCE      2
check split_wan_doh         HEALTHY_SAMPLED         DOWN    UNKNOWN HEALTHY LOCAL_HEALTHY_SAMPLED         SAMPLED     CONFLICTING_EVIDENCE      2
check all_unknown          HEALTHY_SAMPLED         UNKNOWN UNKNOWN UNKNOWN LOCAL_HEALTHY_SAMPLED         SAMPLED     EXTERNAL_UNKNOWN          0
check vpn_only_unknown_wan HEALTHY_SAMPLED         UNKNOWN FAILED  UNKNOWN LOCAL_HEALTHY_SAMPLED         SAMPLED     VPN_UNAVAILABLE           1
check doh_only_unknown_wan HEALTHY_SAMPLED         UNKNOWN UNKNOWN FAILED  LOCAL_HEALTHY_SAMPLED         SAMPLED     DOH_UPSTREAM_UNAVAILABLE  1
check both_external        HEALTHY_SAMPLED         UNKNOWN FAILED  FAILED  LOCAL_HEALTHY_SAMPLED         SAMPLED     MIXED_EXTERNAL_FAILURES   2
check vpn_dead             HEALTHY_SAMPLED         UP      FAILED  HEALTHY LOCAL_HEALTHY_SAMPLED         SAMPLED     VPN_UNAVAILABLE           3
check doh_dead             HEALTHY_SAMPLED         UP      HEALTHY FAILED  LOCAL_HEALTHY_SAMPLED         SAMPLED     DOH_UPSTREAM_UNAVAILABLE  3
check wan_only_up          HEALTHY_SAMPLED         UP      UNKNOWN UNKNOWN LOCAL_HEALTHY_SAMPLED         SAMPLED     EXTERNAL_PARTIAL          1
check vpn_doh_up_wan_na    HEALTHY_SAMPLED         UNKNOWN HEALTHY HEALTHY LOCAL_HEALTHY_SAMPLED         SAMPLED     EXTERNAL_PARTIAL          2
check dns_wan_unknown      SUSPECT_DNS_TIMEOUT     UNKNOWN UNKNOWN UNKNOWN BOX_DNS_HUNG_CANDIDATE      SUSPECT     EXTERNAL_UNKNOWN          0
check dns_all_healthy      SUSPECT_DNS_TIMEOUT     UP      HEALTHY HEALTHY BOX_DNS_HUNG_CANDIDATE      SUSPECT     EXTERNAL_HEALTHY_SAMPLED 3
check dns_wan_down         SUSPECT_DNS_TIMEOUT     DOWN    FAILED  UNKNOWN BOX_DNS_HUNG_CANDIDATE      SUSPECT     WAN_REPORTED_DOWN         2
check dns_doh_failed       SUSPECT_DNS_TIMEOUT     UNKNOWN UNKNOWN FAILED  BOX_DNS_HUNG_CANDIDATE      SUSPECT     DOH_UPSTREAM_UNAVAILABLE  1
check missing_wan_unknown  SUSPECT_PROCESS_MISSING UNKNOWN UNKNOWN UNKNOWN BOX_PROCESS_MISSING_CANDIDATE SUSPECT     EXTERNAL_UNKNOWN          0
check missing_vpn_down     SUSPECT_PROCESS_MISSING UP      FAILED  UNKNOWN BOX_PROCESS_MISSING_CANDIDATE SUSPECT     VPN_UNAVAILABLE           2
check missing_conflict     SUSPECT_PROCESS_MISSING DOWN    HEALTHY HEALTHY BOX_PROCESS_MISSING_CANDIDATE SUSPECT     CONFLICTING_EVIDENCE      3
check missing_external_ok  SUSPECT_PROCESS_MISSING UP      HEALTHY HEALTHY BOX_PROCESS_MISSING_CANDIDATE SUSPECT     EXTERNAL_HEALTHY_SAMPLED 3
check local_unknown        UNKNOWN                 UNKNOWN HEALTHY HEALTHY LOCAL_UNKNOWN                UNKNOWN     EXTERNAL_PARTIAL          2
check local_unknown_down   UNKNOWN                 DOWN    FAILED  FAILED  LOCAL_UNKNOWN                UNKNOWN     WAN_REPORTED_DOWN         3
check maintenance          TRANSITION              UP      HEALTHY HEALTHY MAINTENANCE                  TRANSITION  EXTERNAL_HEALTHY_SAMPLED 3
check inactive_wan_down    INACTIVE                DOWN    FAILED  FAILED  MANUAL_STOP                  INTENTIONAL WAN_REPORTED_DOWN         3
check dns_wan_down_only    SUSPECT_DNS_TIMEOUT     DOWN    UNKNOWN UNKNOWN BOX_DNS_HUNG_CANDIDATE      SUSPECT     WAN_REPORTED_DOWN         1
check missing_wan_na_vpnup SUSPECT_PROCESS_MISSING UNKNOWN HEALTHY UNKNOWN BOX_PROCESS_MISSING_CANDIDATE SUSPECT     EXTERNAL_PARTIAL          1
check inactive_unknown     INACTIVE                UNKNOWN UNKNOWN UNKNOWN MANUAL_STOP                  INTENTIONAL EXTERNAL_UNKNOWN          0
check unknown_everything   UNKNOWN                 UNKNOWN UNKNOWN UNKNOWN LOCAL_UNKNOWN                UNKNOWN     EXTERNAL_UNKNOWN          0
check doh_failure_mixed    HEALTHY_SAMPLED         UP      UNKNOWN FAILED  LOCAL_HEALTHY_SAMPLED         SAMPLED     DOH_UPSTREAM_UNAVAILABLE  2
check wan_na_vpn_up        HEALTHY_SAMPLED         UNKNOWN HEALTHY UNKNOWN LOCAL_HEALTHY_SAMPLED         SAMPLED     EXTERNAL_PARTIAL          1

# Exhaustive local-independence invariant: each local state must retain the
# SAME local classification across all 3x3x3 combinations of WAN/VPN/DoH.
for local_state in HEALTHY_SAMPLED SUSPECT_DNS_TIMEOUT SUSPECT_PROCESS_MISSING INACTIVE TRANSITION UNKNOWN; do
    case "$local_state" in
        HEALTHY_SAMPLED) expected_local=LOCAL_HEALTHY_SAMPLED; expected_evidence=SAMPLED ;;
        SUSPECT_DNS_TIMEOUT) expected_local=BOX_DNS_HUNG_CANDIDATE; expected_evidence=SUSPECT ;;
        SUSPECT_PROCESS_MISSING) expected_local=BOX_PROCESS_MISSING_CANDIDATE; expected_evidence=SUSPECT ;;
        INACTIVE) expected_local=MANUAL_STOP; expected_evidence=INTENTIONAL ;;
        TRANSITION) expected_local=MAINTENANCE; expected_evidence=TRANSITION ;;
        UNKNOWN) expected_local=LOCAL_UNKNOWN; expected_evidence=UNKNOWN ;;
    esac
    for wan in UP DOWN UNKNOWN; do
        for vpn in HEALTHY FAILED UNKNOWN; do
            for doh in HEALTHY FAILED UNKNOWN; do
                output=$(sh "$worker" watchdog-classify "$local_state" "$wan" "$vpn" "$doh") || exit 1
                case "$output" in
                    "CLASSIFY local_class=$expected_local local_evidence=$expected_evidence external_class="*" wan=$wan vpn=$vpn doh=$doh authority=observe-only action=none") ;;
                    *) printf 'FAIL invariant local=%s wan=%s vpn=%s doh=%s: %s\n' "$local_state" "$wan" "$vpn" "$doh" "$output" >&2; exit 1 ;;
                esac
                passed=$((passed+1))
            done
        done
    done
done

invalid() {
    name=$1; shift
    set +e
    output=$(sh "$worker" watchdog-classify "$@" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { echo "FAIL $name: expected rc2 got $rc" >&2; exit 1; }
    case "$output" in *'CLASSIFY '*) echo "FAIL $name: invalid evidence classified" >&2; exit 1 ;; esac
    passed=$((passed+1))
}
invalid missing_args
invalid too_many HEALTHY_SAMPLED UP HEALTHY HEALTHY extra
invalid rejected_confirmed CONFIRMED UP HEALTHY HEALTHY
invalid bad_wan HEALTHY_SAMPLED WAN_UP HEALTHY HEALTHY
invalid bad_vpn HEALTHY_SAMPLED UP healthy HEALTHY
invalid bad_doh HEALTHY_SAMPLED UP HEALTHY 9.9.9.9
printf 'PASS: %s two-axis classification scenarios (30 matrix + 162 invariants + 6 rejects)\n' "$passed"
