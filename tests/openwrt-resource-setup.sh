#!/bin/sh
# Test-only fresh guest setup; never run on a router.
set -eu
. /mnt/pg-bundle/openwrt-vm-common.sh
[ ! -e /usr/bin/podkop-guard ] && [ ! -L /usr/bin/podkop-guard ] || exit 1
[ ! -e /etc/podkop-guard ] && [ ! -L /etc/podkop-guard ] || exit 1
[ ! -e /tmp/podkop-guard-probe.lock ] && [ ! -L /tmp/podkop-guard-probe.lock ] || exit 1
[ ! -e /tmp/pg-worker-b6.sha256 ] && [ ! -L /tmp/pg-worker-b6.sha256 ] || exit 1
guest_if=br-lan
ip link show "$guest_if" >/dev/null 2>&1 || guest_if=eth0
ip link set "$guest_if" up
ip addr add 10.0.2.15/24 dev "$guest_if" 2>/dev/null || :
ip route replace default via 10.0.2.2 dev "$guest_if"
printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf
printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf.d/resolv.conf.auto
vm_pkg_update
vm_pkg_install jq sing-box kmod-nft-tproxy
for dep in jq sing-box kmod-nft-tproxy; do vm_pkg_installed "$dep"; vm_pkg_version "$dep"; done
raw=$(ubus -t 3 call service list '{"name":"sing-box"}')
printf '%s\n' "$raw" | jq -e 'type == "object" and (keys - ["sing-box"] | length == 0) and (if has("sing-box") then (."sing-box" | type == "object" and ((has("instances")|not) or .instances == {})) else true end)'
! pidof sing-box >/dev/null 2>&1 || exit 1
if printf '%s\n' "$raw" | jq -e 'has("sing-box")' >/dev/null; then
    [ "$(uci -q get sing-box.main.enabled)" = 0 ]
    ubus -t 3 call service delete '{"name":"sing-box"}' >/dev/null
fi
cp /mnt/pg-bundle/podkop-guard /usr/bin/podkop-guard
chmod 0755 /usr/bin/podkop-guard
mkdir -m 700 /etc/podkop-guard /tmp/podkop-guard-probe.lock
printf 'unchanged-LKG' > /etc/podkop-guard/lkg-marker
printf 'resource-fixture-not-a-real-LKG\n' > /etc/podkop-guard/lkg.srs
printf '192.0.2.0/24\n' > /etc/podkop-guard/lkg-subnets.lst
umask 077
: > /tmp/podkop-guard-probe.lock/lease
sha256sum /usr/bin/podkop-guard /etc/podkop-guard/lkg-marker /etc/podkop-guard/lkg.srs /etc/podkop-guard/lkg-subnets.lst > /tmp/pg-worker-b6.sha256
echo PASS_VM_RESOURCE_SETUP
