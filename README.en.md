# podkop-guard

[Русский](README.md)

A small OpenWrt helper that keeps a validated **Last Known Good (LKG)** snapshot for [Podkop](https://github.com/itdoginfo/podkop) Community Lists and helps recover from cold starts when GitHub/`raw.githubusercontent.com` is unavailable.

The project was created after a real failure where Podkop could not download part of its lists, required IP subnets were missing from `PodkopTable/podkop_subnets`, and a reboot removed sing-box remote rule-set cache from `/tmp`.

`podkop-guard` does not replace or patch Podkop. It keeps a separately validated safety snapshot and only replaces that snapshot after all checks succeed.

This is an independent project and is not affiliated with the Podkop developers.

## Status

Current version: **0.2.1**.

The full pipeline has been validated on a real **Cudy TR3000 v1 / OpenWrt 24.10.5 / Podkop 0.7.21 / sing-box 1.12.22** system:

- `refresh-test` successfully processed all 14 Community Lists used on the test router;
- the combined LKG passed compile/decompile round-trip validation without differences;
- the Local Subnet LKG contained 1161 unconditional CIDRs, while 8 conditional CIDRs were intentionally skipped;
- the offline cold-start cache test passed with an intentionally unavailable download path;
- the full `refresh-test` took about 15 seconds and did not change the SHA-256 of any persistent LKG file;
- a real OpenWrt reboot was performed: `podkop-guard` at `START=98` restored the cache before Podkop started at `START=99`;
- after reboot, sing-box runtime came up, LKG subnets were loaded into nftables, and the tested routed services remained functional.

This validates the specific tested configuration; it is not a guarantee of compatibility with every OpenWrt, Podkop, or sing-box version.

## What it does

There are two independent protections.

### Boot recovery

Podkop/sing-box normally uses:

```text
/tmp/sing-box/cache.db
```

Since `/tmp` is volatile, `podkop-guard` keeps a validated copy at:

```text
/etc/podkop-guard/cache.db
```

Its OpenWrt init service runs at `START=98`, immediately before Podkop 0.7.21 (`START=99`), and restores the cache before Podkop starts. If sing-box is already running, the restore is skipped.

### Periodic validated refresh

The same procd service runs a lightweight worker:

- 300 second startup grace;
- state check once per hour;
- successful LKG refresh no more than once per 24 hours;
- failed refresh leaves the old LKG untouched and retries one hour later.

Most of the time the worker is sleeping. Heavier `jq` and `sing-box` operations run with `nice -n 10`.

## Persistent state

```text
/etc/podkop-guard/lkg.srs
/etc/podkop-guard/lkg-subnets.lst
/etc/podkop-guard/cache.db
```

- `lkg.srs` — combined validated binary SRS built from current `podkop.main.community_lists`;
- `lkg-subnets.lst` — Podkop Local Subnet List containing only unconditional `ip_cidr` rules;
- `cache.db` — validated sing-box remote rule-set cache for cold starts.

The `cache.db` mtime is also the marker for the last fully successful refresh, so no separate timestamp file is required. The age is read with BusyBox `date -r FILE +%s`; a separate `stat`/coreutils package is not required.

## Refresh logic

For every current Community List, the worker downloads:

```text
https://github.com/itdoginfo/allow-domains/releases/latest/download/<list>.srs
```

It first tries a normal `curl` with strict timeouts. If that fails and the main Podkop section is in VPN mode, it retries once through the current `podkop.main.interface` using `curl --interface`. For compatibility with Podkop UCI variants, both `podkop.main.connection_type` and `podkop.main.type` are understood.

The refresh aborts immediately if any required SRS cannot be downloaded. Partial snapshots are never accepted.

Before replacing persistent LKG data, all of the following must succeed:

```text
all current Community SRS downloaded
        ↓
each SRS decompiles with installed sing-box
        ↓
all source rules combined
        ↓
compile → candidate lkg.srs → decompile
        ↓
canonical source JSON matches byte-for-byte
        ↓
candidate lkg-subnets.lst built
        ↓
candidate cache.db copied from live sing-box
        ↓
offline cold-start test with an intentionally dead download path
        ↓
only then commit to flash
```

The cache validation launches a separate test sing-box with all expected current Community rule-sets configured as remote while their download detour points to dead SOCKS `127.0.0.1:9`. If the candidate cache is complete, the test process starts. If a required remote SRS is missing, validation fails and the old persistent LKG remains untouched.

## Conditional CIDRs

A plain Podkop Local Subnet List cannot represent conditions such as `network` or `port_range`.

Therefore only `ip_cidr` values from unconditional rules are exported. Conditional CIDRs are skipped with a warning instead of being silently broadened.

## Requirements

Tested on:

- Cudy TR3000 v1;
- OpenWrt 24.10.5;
- Podkop 0.7.21;
- sing-box 1.12.22.

Required components:

- Podkop;
- sing-box;
- `curl`;
- `jq`;
- standard BusyBox tools including `nice`, `date` with `-r` support, `sort`, `cmp`, and `logger`.

A separate `stat` utility is not required.

The installer currently targets OpenWrt systems using `opkg`.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-guard/main/install.sh \
  -o /tmp/podkop-guard-install.sh && \
sh /tmp/podkop-guard-install.sh
```

On first installation the service intentionally remains **STOPPED + DISABLED**.

With Podkop and sing-box working normally, run:

```sh
podkop-guard refresh-test
podkop-guard refresh
```

Then configure the generated file once as a Podkop Local Subnet List:

```sh
if ! uci -q get podkop.main.local_subnet_lists 2>/dev/null \
  | tr ' ' '\n' \
  | grep -Fxq '/etc/podkop-guard/lkg-subnets.lst'; then
    cp -p /etc/config/podkop /etc/config/podkop.pre-podkop-guard
    uci add_list podkop.main.local_subnet_lists='/etc/podkop-guard/lkg-subnets.lst'
    uci commit podkop
fi
```

Reload Podkop once:

```sh
/etc/init.d/podkop reload
```

After verifying the routed services, enable the guard:

```sh
/etc/init.d/podkop-guard enable
/etc/init.d/podkop-guard start
```

Starting the guard on an already running system will not overwrite live cache: boot restore is skipped when sing-box is running, while the periodic worker begins its normal startup grace.

## CLI

```text
podkop-guard status
podkop-guard verify-lkg
podkop-guard derive-subnets
podkop-guard refresh-test
podkop-guard refresh
podkop-guard cache-restore
podkop-guard boot-restore
podkop-guard version
```

`daemon` is intended for procd and normally should not be started manually.

## Logs

```sh
logread | grep podkop-guard
```

No persistent log file is written to flash.

## Intentionally out of scope

`podkop-guard` does not:

- patch Podkop;
- modify `community_lists`;
- enable Podkop `download_lists_via_proxy`;
- switch VPN interfaces;
- reload/restart Podkop during refresh;
- use cron;
- implement NORMAL/FALLBACK modes;
- keep the live sing-box cache on flash;
- run a local HTTP server.

Podkop remains responsible for normal routing and normal list updates.

## Limitations

The current implementation focuses on `podkop.main.community_lists`.

If Community Lists are changed while the current LKG is less than 24 hours old, run `podkop-guard refresh` manually rather than waiting for the next scheduled refresh.

VPN download fallback is used only when the main Podkop section is detected as VPN mode and `podkop.main.interface` is set.

The `START=98 → Podkop START=99` boot order was verified for Podkop 0.7.21. Re-check init order after major Podkop upgrades.

The project does not attempt to guarantee recovery from a corrupted persistent LKG or incompatible future changes to sing-box cache/rule-set formats.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
