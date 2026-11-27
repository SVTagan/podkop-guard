#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Historical research helpers. Test/lab only: not installed by install.sh.
# Local and external observations are independent; no recovery authority.
err() { printf '[watchdog-research] ERROR: %s\n' "$*" >&2; }

watchdog_evidence() {
    local check_script first first_rc local_state local_pid payload
    local wan wan_source wan_link wjson wup wpending wdev carrier carrier_file
    local vpn vpn_source vpn_link vjson vup vpending iface conn_type
    local last last_rc last_conn last_iface

    [ "$#" -eq 0 ] || { err "usage: watchdog-evidence (local-only)"; return 2; }
    check_script="${PODKOP_GUARD_EVIDENCE_CHECK_SCRIPT:-}"
    [ -r "$check_script" ] || { err "watchdog-check script unavailable"; return 2; }
    first=$(sh "$check_script" watchdog-check 2>/dev/null)
    first_rc=$?
    local_state=UNKNOWN
    local_pid=none
    case "$first:$first_rc" in
        'WATCHDOG state='*)
            payload=${first#WATCHDOG state=}
            local_state=${payload%% *}
            case "$first" in *' pid='*) local_pid=${first#* pid=}; local_pid=${local_pid%% *} ;; esac
            ;;
    esac
    case "$local_state:$first_rc" in
        HEALTHY_SAMPLED:0|SUSPECT_DNS_TIMEOUT:1|SUSPECT_PROCESS_MISSING:1|INACTIVE:0|TRANSITION:0|UNKNOWN:2) ;;
        *) local_state=UNKNOWN; local_pid=none ;;
    esac
    case "$local_pid" in ''|*[!0-9]*) local_pid=none ;; esac

    wan=UNKNOWN
    wan_source=netifd_unverified
    wan_link=UNKNOWN
    if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        wjson=$(ubus -t 5 call network.interface.wan status 2>/dev/null)
        if [ "$?" -eq 0 ] && [ -n "$wjson" ]; then
            wup=$(jsonfilter -s "$wjson" -e '@.up' 2>/dev/null)
            wpending=$(jsonfilter -s "$wjson" -e '@.pending' 2>/dev/null)
            wdev=$(jsonfilter -s "$wjson" -e '@.l3_device' 2>/dev/null)
            case "$wdev" in
                ''|*[!a-zA-Z0-9_.:@-]*) ;;
                *)
                    carrier_file="${PODKOP_GUARD_EVIDENCE_NET_ROOT:-/sys/class/net}/$wdev/carrier"
                    carrier=
                    [ -r "$carrier_file" ] && read -r carrier < "$carrier_file"
                    case "$carrier" in
                        1) wan_link=UP ;;
                        0)
                            wan_link=DOWN
                            if [ "$wup" != true ] && [ "$wpending" != true ]; then
                                wan=DOWN
                                wan_source=netifd_link_down
                            fi ;;
                    esac
                    ;;
            esac
        else
            wan_source=netifd_unavailable
        fi
    else
        wan_source=netifd_tools_missing
    fi

    # An AWG interface may be UP while its remote peer is unreachable.
    vpn=UNKNOWN
    vpn_source=not_verified
    vpn_link=UNKNOWN
    iface=
    conn_type=
    if command -v uci >/dev/null 2>&1; then
        conn_type=$(uci -q get podkop.main.connection_type 2>/dev/null)
        iface=$(uci -q get podkop.main.interface 2>/dev/null)
    fi
    if [ "$conn_type" = vpn ]; then
        case "$iface" in
            awg[0-9]*)
                case "$iface" in
                    *[!a-zA-Z0-9_]*) vpn_source=invalid_interface ;;
                    *)
                        if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
                            vjson=$(ubus -t 5 call "network.interface.$iface" status 2>/dev/null)
                            if [ "$?" -eq 0 ] && [ -n "$vjson" ]; then
                                vup=$(jsonfilter -s "$vjson" -e '@.up' 2>/dev/null)
                                vpending=$(jsonfilter -s "$vjson" -e '@.pending' 2>/dev/null)
                                case "$vup:$vpending" in
                                    true:*) vpn_link=UP ;;
                                    false:false) vpn_link=DOWN ;;
                                esac
                                vpn_source=netifd_unverified
                            else
                                vpn_source=netifd_unavailable
                            fi
                        else
                            vpn_source=netifd_tools_missing
                        fi ;;
                esac ;;
            *) vpn_source=unsupported_interface ;;
        esac
    else
        vpn_source=not_in_vpn_mode
    fi

    # Second local sample + UCI snapshot detects concurrent Podkop changes.
    last=$(sh "$check_script" watchdog-check 2>/dev/null)
    last_rc=$?
    last_conn=$(uci -q get podkop.main.connection_type 2>/dev/null)
    last_iface=$(uci -q get podkop.main.interface 2>/dev/null)
    if [ "$last:$last_rc" != "$first:$first_rc" ] ||
       [ "$last_conn" != "$conn_type" ] ||
       [ "$last_iface" != "$iface" ]; then
        local_state=TRANSITION
        local_pid=none
        wan=UNKNOWN
        wan_source=changed_during_sample
        vpn=UNKNOWN
        vpn_source=changed_during_sample
    fi

    # DoH, WAN path and VPN endpoint health remain unverified.
    printf 'EVIDENCE local=%s pid=%s wan=%s wan_source=%s wan_link=%s vpn=%s vpn_source=%s vpn_link=%s doh=UNKNOWN doh_source=not_probed mode=metadata\n' \
        "$local_state" "$local_pid" "$wan" "$wan_source" "$wan_link" "$vpn" "$vpn_source" "$vpn_link"
    watchdog_classify "$local_state" "$wan" "$vpn" UNKNOWN
}

# Stage A: independent local diagnosis and external connectivity context.
# Four inputs are externally supplied evidence, NOT implicit live probes.
# A one-shot sample NEVER confirms a failure or authorizes recovery.
watchdog_classify() {
    local local_state wan vpn doh local_class local_evidence
    local external_class external_coverage

    if [ "$#" -ne 4 ]; then
        err "usage: podkop-guard watchdog-classify <local_state> <wan:UP|DOWN|UNKNOWN> <vpn:HEALTHY|FAILED|UNKNOWN> <doh:HEALTHY|FAILED|UNKNOWN>"
        return 2
    fi
    local_state=$1
    wan=$2
    vpn=$3
    doh=$4

    case "$local_state" in
        HEALTHY_SAMPLED|SUSPECT_DNS_TIMEOUT|SUSPECT_PROCESS_MISSING|INACTIVE|TRANSITION|UNKNOWN) ;;
        *) err "invalid local evidence"; return 2 ;;
    esac
    case "$wan" in UP|DOWN|UNKNOWN) ;; *) err "invalid WAN evidence"; return 2 ;; esac
    case "$vpn" in HEALTHY|FAILED|UNKNOWN) ;; *) err "invalid VPN evidence"; return 2 ;; esac
    case "$doh" in HEALTHY|FAILED|UNKNOWN) ;; *) err "invalid DoH evidence"; return 2 ;; esac

    # This axis is deliberately INDEPENDENT of WAN/VPN/DoH. SUSPECT is
    # not CONFIRMED: only future local debounce/maintenance gates may confirm.
    case "$local_state" in
        HEALTHY_SAMPLED)         local_class=LOCAL_HEALTHY_SAMPLED;          local_evidence=SAMPLED ;;
        SUSPECT_DNS_TIMEOUT)     local_class=BOX_DNS_HUNG_CANDIDATE;       local_evidence=SUSPECT ;;
        SUSPECT_PROCESS_MISSING) local_class=BOX_PROCESS_MISSING_CANDIDATE;local_evidence=SUSPECT ;;
        INACTIVE)                local_class=MANUAL_STOP;                  local_evidence=INTENTIONAL ;;
        TRANSITION)              local_class=MAINTENANCE;                 local_evidence=TRANSITION ;;
        UNKNOWN)                 local_class=LOCAL_UNKNOWN;               local_evidence=UNKNOWN ;;
    esac

    # Count the explicitly supplied observations, not their trustworthiness.
    # Actual provenance/validation is the caller's responsibility.
    external_coverage=0
    [ "$wan" = UNKNOWN ] || external_coverage=$((external_coverage + 1))
    [ "$vpn" = UNKNOWN ] || external_coverage=$((external_coverage + 1))
    [ "$doh" = UNKNOWN ] || external_coverage=$((external_coverage + 1))

    # Preserve external evidence separately; never rewrite local diagnosis.
    # DOWN is a supplied WAN state, NOT proof of ISP responsibility.
    if [ "$wan" = DOWN ] && { [ "$vpn" = HEALTHY ] || [ "$doh" = HEALTHY ]; }; then
        external_class=CONFLICTING_EVIDENCE
    elif [ "$wan" = DOWN ]; then
        external_class=WAN_REPORTED_DOWN
    elif [ "$vpn" = FAILED ] && [ "$doh" = FAILED ]; then
        external_class=MIXED_EXTERNAL_FAILURES
    elif [ "$vpn" = FAILED ]; then
        external_class=VPN_UNAVAILABLE
    elif [ "$doh" = FAILED ]; then
        external_class=DOH_UPSTREAM_UNAVAILABLE
    elif [ "$wan" = UP ] && [ "$vpn" = HEALTHY ] && [ "$doh" = HEALTHY ]; then
        external_class=EXTERNAL_HEALTHY_SAMPLED
    elif [ "$external_coverage" -gt 0 ]; then
        external_class=EXTERNAL_PARTIAL
    else
        external_class=EXTERNAL_UNKNOWN
    fi

    printf 'CLASSIFY local_class=%s local_evidence=%s external_class=%s external_coverage=%s/3 wan=%s vpn=%s doh=%s authority=observe-only action=none\n' \
        "$local_class" "$local_evidence" "$external_class" "$external_coverage" "$wan" "$vpn" "$doh"
    return 0
}

case "${1:-}" in
    watchdog-evidence) shift; watchdog_evidence "$@" ;;
    watchdog-classify) shift; watchdog_classify "$@" ;;
    *) err "lab commands: watchdog-evidence or watchdog-classify"; exit 2 ;;
esac
