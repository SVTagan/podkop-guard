#!/bin/sh
# Deterministic pure classifier matrix. Never contacts the router or network.
set -eu
worker="${1:-./podkop-guard}"
case "$worker" in /*) ;; *) worker="$(pwd)/${worker#./}" ;; esac
passed=0

check() {
    name=$1 expected=$2 local_state=$3 wan=$4 vpn=$5 doh=$6
    output=$(sh "$worker" watchdog-classify "$local_state" "$wan" "$vpn" "$doh") || {
        echo "FAIL $name: command failed" >&2
        exit 1
    }
    expected_line="CLASSIFY class=$expected local=$local_state wan=$wan vpn=$vpn doh=$doh authority=observe-only action=none"
    [ "$output" = "$expected_line" ] || {
        printf 'FAIL %s\nexpected: %s\nactual:   %s\n' "$name" "$expected_line" "$output" >&2
        exit 1
    }
    passed=$((passed + 1))
    printf 'PASS %s\n' "$name"
}

# WAN loss, tunnel failures, DNS and local runtime faults are distinct.
check healthy                    HEALTHY                           HEALTHY_SAMPLED UP      HEALTHY HEALTHY
check isp_failure                WAN_OUTAGE                        HEALTHY_SAMPLED DOWN    FAILED  UNKNOWN
check isp_down_vpn_still_up      CONFLICTING_EVIDENCE              HEALTHY_SAMPLED DOWN    HEALTHY UNKNOWN
check wan_down_dns_timeout       WAN_OUTAGE_LOCAL_UNCERTAIN        SUSPECT_DNS_TIMEOUT DOWN UNKNOWN UNKNOWN
check wan_down_process           WAN_OUTAGE_LOCAL_UNCERTAIN        SUSPECT_PROCESS_MISSING DOWN FAILED UNKNOWN
check wan_unknown_process        LOCAL_FAULT_WAN_UNVERIFIED        SUSPECT_PROCESS_MISSING UNKNOWN FAILED UNKNOWN
check wan_unknown_dns            LOCAL_FAULT_WAN_UNVERIFIED        SUSPECT_DNS_TIMEOUT UNKNOWN UNKNOWN HEALTHY
check vpn_bad_local_healthy      VPN_UNAVAILABLE                   HEALTHY_SAMPLED UP      FAILED  HEALTHY
check vpn_bad_wan_unknown        VPN_FAILURE_WAN_UNVERIFIED        HEALTHY_SAMPLED UNKNOWN FAILED HEALTHY
check wan_unknown_healthy        LOCAL_HEALTHY_WAN_UNVERIFIED      HEALTHY_SAMPLED UNKNOWN HEALTHY UNKNOWN
check doh_bad_local_healthy      DOH_UPSTREAM_UNAVAILABLE          HEALTHY_SAMPLED UP      HEALTHY FAILED
check both_external_bad         MIXED_EXTERNAL_FAILURES          HEALTHY_SAMPLED UP      FAILED  FAILED
check dns_local_timeout         BOX_DNS_HUNG_CANDIDATE            SUSPECT_DNS_TIMEOUT UP HEALTHY HEALTHY
check dns_timeout_doh_bad       MIXED_DNS_FAILURES                SUSPECT_DNS_TIMEOUT UP HEALTHY FAILED
check box_process_missing       BOX_PROCESS_MISSING_CANDIDATE     SUSPECT_PROCESS_MISSING UP FAILED UNKNOWN
check box_missing_vpn_ok        CONFLICTING_EVIDENCE              SUSPECT_PROCESS_MISSING UP HEALTHY HEALTHY
check local_unknown             INSUFFICIENT_EVIDENCE            UNKNOWN UP HEALTHY HEALTHY
check external_unknown          LOCAL_HEALTHY_EXTERNAL_UNVERIFIED HEALTHY_SAMPLED UP UNKNOWN UNKNOWN
check manual_stop               MANUAL_STOP                       INACTIVE DOWN FAILED FAILED
check manual_stop_up            MANUAL_STOP                       INACTIVE UP HEALTHY HEALTHY
check reload                    MAINTENANCE                       TRANSITION DOWN FAILED FAILED
check reload_up                 MAINTENANCE                       TRANSITION UP HEALTHY HEALTHY

# No arbitrary free-text inputs, fake CONFIRMED states or missing evidence.
invalid() {
    name=$1
    shift
    set +e
    output=$(sh "$worker" watchdog-classify "$@" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || {
        printf 'FAIL %s: unexpected rc=%s output=%s\n' "$name" "$rc" "$output" >&2
        exit 1
    }
    case "$output" in *'CLASSIFY class='*) echo "FAIL $name: invalid input classified" >&2; exit 1 ;; esac
    passed=$((passed + 1))
}
invalid missing_args
invalid too_many HEALTHY_SAMPLED UP HEALTHY HEALTHY extra
invalid unsupported_state CONFIRMED UP HEALTHY HEALTHY
invalid invalid_wan HEALTHY_SAMPLED WAN_UP HEALTHY HEALTHY
invalid invalid_vpn HEALTHY_SAMPLED UP healthy HEALTHY
invalid invalid_doh HEALTHY_SAMPLED UP HEALTHY 9.9.9.9
printf 'PASS: %s conservative classification scenarios\n' "$passed"
