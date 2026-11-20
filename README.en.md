# podkop-guard

[Русский](README.md)

A small OpenWrt helper that keeps a validated **Last Known Good (LKG)** snapshot for [Podkop](https://github.com/itdoginfo/podkop) Community Lists and helps survive a bad cold start when GitHub/`raw.githubusercontent.com` is unavailable.

The project originated from a real failure: Podkop could not download part of its lists, required IP subnets were missing from `PodkopTable/podkop_subnets`, and after `/tmp` was lost sing-box could be left without its remote rule-set cache. Some domain-routed services still worked while applications connecting directly to IP addresses failed.

`podkop-guard` does not replace or patch Podkop. It keeps a separately validated safety snapshot and only updates it after the full validation pipeline succeeds.

This is an independent project and is not part of or affiliated with Podkop.

### Independent two-axis classification (stage A, experimental)

`podkop-guard watchdog-classify <local> <wan> <vpn> <doh>` is a **pure function**: it performs no network probes, recovery, or service actions. Its new result contains two separate axes: `local_class` / `local_evidence` for sing-box/Podkop health, and `external_class` / `external_coverage` for supplied WAN/VPN/DoH context. Coverage is only the number of non-`UNKNOWN` inputs out of three; **it is not a confidence or trust metric**.

`SUSPECT_DNS_TIMEOUT` always yields `BOX_DNS_HUNG_CANDIDATE`; `SUSPECT_PROCESS_MISSING` always yields `BOX_PROCESS_MISSING_CANDIDATE` **even when WAN is UNKNOWN or DOWN**. One local sample is a suspicion, not a confirmed fault or permission to restart. `HEALTHY_SAMPLED` means sampled *local* health only. Manual stop and maintenance take their respective local categories. A dead VPN with healthy local sing-box gives `local_class=LOCAL_HEALTHY_SAMPLED` and `external_class=VPN_UNAVAILABLE`.

`watchdog-evidence` remains independent metadata-only collection and now prints the new two-axis result. It never invokes Failover, NetGuard or curl. It does not assert WAN reachability, and VPN/DoH remain UNKNOWN without separately validated evidence. All results end in `authority=observe-only action=none`. The previous experimental `CLASSIFY class=...` format has been replaced; stable `v0.2.4` remains unchanged. Recovery/fail-open require a separate, future policy gate. This code has not been installed on Redmi AX6000.


### Stage B4.1: manually bounded local diagnostic

`watchdog-check-bounded [seconds]` runs the existing `watchdog-check` using `setsid` in a separate session and verifies its own diagnostic PID/PGID/SID. A deadline of 3–120 seconds kills **only the isolated diagnostic process group** on expiry and returns `UNKNOWN reason=probe_hard_deadline`, never confirmed failure. Temporary files use RAM (`/tmp`). If process isolation cannot be verified, the check fails conservatively with `UNKNOWN` and no unsafe group signal.

Not integrated into the resident observer or deployed on the Redmi AX6000. No action against actual sing-box, Podkop, VPN, LKG or routing. Pending CI/QEMU and fault-injection validation.

### Stage B3 — local DNS, loopback and conntrack (experimental)

`watchdog-check` accepts FakeIP only for the **exact queried name** `fakeip.podkop.fyi`, and distinguishes real DNS replies `NXDOMAIN`, `SERVFAIL`, `REFUSED` from a DNS timeout. Error responses are not considered a hung sing-box; they yield `UNKNOWN`.

A timeout is evaluated against `nf_conntrack_count/max`: saturated conntrack produces `UNKNOWN reason=conntrack_pressure`, while missing/invalid counters produce `UNKNOWN reason=conntrack_unverified`. Local ICMP to `127.0.0.42` is only a supplemental control: it must previously succeed for the **same sing-box PID** returning FakeIP before a later ICMP failure can suppress DNS-hang suspicion. If ICMP was always filtered, it is not treated as failure; up to five baseline attempts per PID. The control resets across PID transitions. A missing process is reconciled a second time against procd to exclude a fast respawn race.

This remains strictly `observe-only`: no recovery/fail-open, WAN/VPN/DoH external probes or dependency on Failover/NetGuard. The installed AX6000 worker is unchanged. Negative scenarios run in CI and under real OpenWrt BusyBox ash inside QEMU.

### Stage B2: bounded procd event subscription and reconciliation (experimental)

`watchdog-procd-monitor [cycles] [interval]` is a **manual-only, bounded**, read-only event supervisor: it subscribes to `ubus -S subscribe service`, detects `ubusd` changes using PID + process start time, rebinds if the subscriber dies, and independently reads a fresh `watchdog-procd-snapshot` each cycle. A bounded RAM-backed FIFO is created in `/tmp` and removed at exit. Missed events cannot be recovered: **history=INCOMPLETE always**, including after a successful resubscription or healthy snapshot. A PID change without a captured event is logged as `state_change=UNEXPLAINED`, never as a confirmed crash.

Observed respawn/fail events are diagnostics only; when local Podkop maintenance is detected they are marked `diagnosis=MAINTENANCE`. `watchdog-procd-follow` offers explicit continuous, change-only observation, but **is not enabled in procd init**, is not a recovery component and is not installed on the AX6000. The bounded monitor supports 1–30 cycles with 1–30 second interval. No UCI writes, service signals, restart, VPN switching or fail-open are performed. The subscriber is expected to be terminated on exit. This is still experimental until independent QEMU and hardware acceptance.

### Stage B1: procd event diagnostics without process control

Experimental `watchdog-procd-event` reads **one JSON event line** from `ubus -S subscribe service` on stdin. It recognizes only `sing-box` / `sing-box.main`, mapping `instance.respawn` to `RESPAWN_REPORTED` and `instance.fail` to `CRASH_LOOP_REPORTED`. Routine start/stop and unrelated services are not treated as crashes. Malformed events are `UNKNOWN`, with no raw event echoed to logs; every result is `action=none`.

`watchdog-procd-snapshot` independently reconciles the current procd instance through `ubus service list`: `RUNNING`, `STOPPED`, `UNREGISTERED`, or `UNKNOWN`. Exit codes alone do not establish a crash cause. This **does not yet subscribe continuously** or handle `ubusd` restart/event loss; those steps require further testing. The real `/usr/bin/sing-box` is distinguished from offline validation processes. Nothing is wired to the persistent observer or recovery, and no processes are signalled or restarted.


### Independent local evidence collection (stage 6B1.2, experimental)

`podkop-guard watchdog-evidence` runs two local `watchdog-check` samples around a read-only snapshot of the WAN and selected AWG interface through `netifd/ubus` (and the physical link `carrier` when available). It **does not invoke** `owrt-netguard`, `podkop-vpn-failover`, or `curl`. No external connectivity probes, service changes, route changes, or UCI writes occur, and no companion project is required. Interface names are validated before use.

The `up=true` and `carrier=1` indicators describe *local link state*, **not WAN Internet reachability or remote VPN health**. Without independent path checks, `WAN=UNKNOWN` (except an observed local carrier loss), `VPN=UNKNOWN` even when `vpn_link=UP`, and `DoH=UNKNOWN`. If the local health or selected VPN configuration changes during sampling, the result is `TRANSITION` / `MAINTENANCE`. Every classification reports `authority=observe-only action=none`.

The earlier experimental `--live` switch has been **removed** because it invoked external diagnostic tools; it now exits with code 2. Any future external probes will be small, explicitly bounded self-contained functions, not hard dependencies on companion projects. Existing Failover/NetGuard evidence may still be supplied manually to the pure `watchdog-classify` command, but those projects are not needed to install, operate, or recover Guard.

This collector is not connected to the persistent `watchdog-observe` loop or recovery logic. The Redmi AX6000 continues to run the previously installed `0.3.0-dev` code. Synthetic tests specifically assert that no companion executable is invoked.


## Status

Current stable version: **0.2.4**.

> The experimental `feature/watchdog-observe-only` branch includes `podkop-guard watchdog-check` (one-shot read-only probe) and `podkop-guard watchdog-monitor [cycles] [interval_seconds]` (bounded RAM-only observations, default 6 samples every 20s). `CONFIRMED` denotes repeated local evidence, not proof of a network outage cause. No restart, service stop, or persistent fault counters. A **continuous observe-only** `watchdog-observe` command and independent procd instance have been drafted, **disabled by default** unless `podkop_guard.settings.watchdog_enabled=1` is explicitly set. Continuous mode logs only on state changes. Hardware observation was completed on Redmi AX6000/OpenWrt 24.10.5 on 13–20 November 2026. This is still not a v0.3.0 release; other devices require independent backup and a controlled rollout.

> **Experimental installer:** supports `opkg`/`apk` (OpenWrt 24.10/25.12), same-filesystem staging, and recovery of worker/init files plus prior running/enabled state on ordinary errors. Verified with shell mocks and in **real OpenWrt 25.12.6 inside QEMU**, using real procd for upgrade, rollback and opt-in but fixture processes instead of the real LKG/Podkop/sing-box runtime. It is **not power-failure atomic**; package installation and optional LuCI custom commands are outside rollback. Persistent LKG files are not replaced or removed. The stable `v0.2.4` installer still targets `opkg`. Use the development installer only in a controlled, backed-up test deployment with a pinned commit.

Experimental worker and installer report **`0.3.0-dev`** and require an explicit SHA-pinned `PODKOP_GUARD_BASE_URL`. The watchdog remains opt-in; its standalone `/etc/config/podkop_guard` UCI file must be initialized before enabling it. The real worker was tested in QEMU and completed a week of observe-only operation on AX6000; the stage 2A classifier has not been deployed there. [QEMU E2E](https://github.com/SVTagan/podkop-guard/actions/runs/43312895095).

**Controlled upgrade:** setting `PODKOP_GUARD_SKIP_LUCI=1` explicitly disables optional `luci-app-commands` installation and any `luci` UCI modifications. It does **not** prevent worker/init replacement or the Guard service restart. Keep a separate persistent backup of the old worker, init, service state and LKG before upgrading; the installer's transactional backups reside in `/tmp` only.

**Safe installer audit:** `PODKOP_GUARD_PREFLIGHT_ONLY=1` validates downloaded worker/init, version, syntax, installed package manager/dependencies and current `running/enabled`. It does not replace binaries, modify UCI, install packages or stop any service. Temporary downloaded files remain under `/tmp` and are removed. The experimental `0.3.0-dev` installer has **no default download URL**; it requires an explicit commit-pinned `PODKOP_GUARD_BASE_URL`. The stable `v0.2.4` installer remains separate. `PREFLIGHT_PASS` validates preconditions only, **not** a subsequent live installation or rollback.

Validated real-world configurations:

| Device | OpenWrt | Podkop | sing-box | Community Lists | Validated |
| --- | --- | --- | --- | ---: | --- |
| Cudy TR3000 v1 | 24.10.5 | 0.7.21 | 1.12.22 | 14 | full `refresh-test`/`refresh`, Local Subnet LKG, offline cache validation, LuCI, reboot/cold start |
| Cudy TR3000 v1 | 24.10.4 | 0.7.22-r1 | 1.12.22-r1 | 14 | full pipeline, VPN download fallback, orphan-validator fix, two reboots |
| Xiaomi Redmi Router AX6000 (stock layout) | 24.10.5 | 0.7.21-r1 | 1.12.22-r1 | 21 | full pipeline, cache restore, Local Subnet LKG, reboot and controlled WAN bounce |

These results validate the listed configurations, not every OpenWrt, Podkop, or sing-box version. Upstream Community Lists change over time, so CIDR counts, SRS contents, and file sizes are not constants.

## What it does

The project has two independent functions.

### 1. Recovery after reboot/power loss

Podkop/sing-box normally uses:

```text
/tmp/sing-box/cache.db
```

`/tmp` is volatile. `podkop-guard` keeps a validated copy on flash:

```text
/etc/podkop-guard/cache.db
```

Its init service runs at `START=98`, immediately before Podkop (`START=99` on the tested versions), and restores the cache into `/tmp` before Podkop starts.

If sing-box is already running, boot restore does not overwrite the live cache.

### 2. Periodic validated LKG refresh

After boot the same service starts a lightweight procd worker:

- startup grace: 300 seconds;
- state check: once per hour;
- successful LKG refresh: no more than once per 24 hours;
- failed refresh leaves the old LKG untouched and retries one hour later.

Most of the time the worker sleeps. Heavier `jq`/`sing-box` work runs through `nice -n 10`.

## Persistent state

```text
/etc/podkop-guard/lkg.srs
/etc/podkop-guard/lkg-subnets.lst
/etc/podkop-guard/cache.db
```

- `lkg.srs` — combined validated binary SRS built from current `podkop.main.community_lists`;
- `lkg-subnets.lst` — a normal Podkop Local Subnet List containing only unconditional `ip_cidr` values;
- `cache.db` — validated sing-box remote rule-set cache for cold starts.

The `cache.db` mtime is also the marker of the last fully successful refresh. Snapshot age is read with BusyBox `date -r FILE +%s`; no separate timestamp file or `stat`/coreutils dependency is needed.

## Refresh pipeline

For every current Community List, `podkop-guard` downloads:

```text
https://github.com/itdoginfo/allow-domains/releases/latest/download/<list>.srs
```

It first tries a normal `curl` with strict timeouts. If that fails and the main section is in VPN mode, it retries once through the current `podkop.main.interface` using `curl --interface`. Both `podkop.main.connection_type` and `podkop.main.type` are understood for UCI compatibility.

If any required SRS cannot be downloaded, the refresh aborts immediately. Partial snapshots are never accepted.

Before persistent LKG data is replaced, every stage below must succeed:

```text
ALL current Community SRS downloaded
        ↓
each SRS successfully decompiled by installed sing-box
        ↓
all rules combined
        ↓
compile → candidate lkg.srs → decompile
        ↓
canonical JSON before/after matches byte-for-byte
        ↓
candidate lkg-subnets.lst built
        ↓
candidate cache.db copied from live sing-box
        ↓
offline cold-start test with intentionally dead download path
        ↓
only then commit to flash
```

The cache test starts a separate sing-box instance. All expected Community rule-sets are configured as remote while their download detour points to intentionally dead SOCKS `127.0.0.1:9`. Persistent LKG is only replaced after that validator starts successfully.

## Conditional CIDRs

A plain Podkop Local Subnet List can only store IP/CIDR values and cannot preserve conditions such as `network` or `port_range`. `podkop-guard` therefore exports only `ip_cidr` values from unconditional rules. Conditional CIDRs are skipped with a warning instead of being silently broadened.

## Requirements

Required components:

- Podkop;
- sing-box;
- `curl`;
- `jq`;
- OpenWrt with `opkg`;
- standard BusyBox tools: `nice`, `date` with `-r` support, `sort`, `cmp`, `logger`, `mktemp`, `grep`, `tail`, `touch`, `sync`.

If `curl` or `jq` is missing, the installer attempts to install it automatically.

### LuCI

LuCI integration is optional:

- when LuCI is already present, the installer checks `luci-app-commands` and attempts to install it if needed;
- four named Custom Commands are then created;
- failure to install `luci-app-commands` does not fail the core guard installation;
- headless OpenWrt systems do not pull LuCI packages;
- uninstall removes only the guard's UCI command sections and leaves `luci-app-commands` installed.

## Installation

For a stable version, use the installer from the release tag. It installs worker/init files from the same tag, so the installation is reproducible and does not depend on future changes to `main`.

With `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-guard/v0.2.4/install.sh \
  -o /tmp/podkop-guard-install.sh && \
sh /tmp/podkop-guard-install.sh
```

Or with `uclient-fetch`:

```sh
uclient-fetch -q -O /tmp/podkop-guard-install.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-guard/v0.2.4/install.sh && \
sh /tmp/podkop-guard-install.sh
```

On first installation the service deliberately remains **STOPPED + DISABLED**. Build and validate the initial LKG first.

For deliberate testing of another branch or mirror, the source can be overridden with `PODKOP_GUARD_BASE_URL`; normal users do not need this.

## First setup

Make sure Podkop and sing-box currently work, then run:

```sh
podkop-guard refresh-test
podkop-guard refresh
```

Add the generated file once to the `main` section as a normal Local Subnet List:

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

Verify the services you care about, then enable/start the guard:

```sh
/etc/init.d/podkop-guard enable
/etc/init.d/podkop-guard start
```

## Upgrading podkop-guard

Running a newer installer over an existing installation preserves persistent LKG and the current service state. If the guard was enabled/running, the installer restores that state after replacing worker/init.

Useful post-upgrade checks:

```sh
podkop-guard version
podkop-guard status
podkop-guard verify-lkg
```

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

## LuCI Custom Commands

On a normal LuCI installation the installer creates:

```text
Podkop Guard: Status       → /usr/bin/podkop-guard status
Podkop Guard: Verify LKG   → /usr/bin/podkop-guard verify-lkg
Podkop Guard: Refresh Test → /usr/bin/podkop-guard refresh-test
Podkop Guard: Refresh LKG  → /usr/bin/podkop-guard refresh
```

The sections use stable `podkop_guard_*` names, so reinstalling does not create duplicates. `param=0` and `public=0` are enforced, while an existing user-customized `description` is preserved.

## Podkop cold-start diagnostics

During v0.2.4 validation on Redmi AX6000 we observed a state that **did not indicate guard LKG/cache corruption**, but appeared after cold boot while Podkop's native WAN interface monitoring was enabled.

Observed sequence:

- `podkop.settings.enable_badwan_interface_monitoring='1'`;
- `podkop.settings.badwan_reload_delay='2000'`;
- after reboot Podkop and sing-box were running, Telegram CIDRs were present in `PodkopTable/podkop_subnets`, and persistent/runtime cache checks passed, but Telegram could still fail;
- in one bad state sing-box logged Telegram connections through `direct-out`; during another reboot with a longer delay, early connections through the correct `main-out` returned `network is unreachable` while `awg0` was not ready yet;
- `podkop-guard refresh-test`, executed while the bad state was present, successfully passed offline cold-start validation using the current runtime cache;
- increasing `badwan_reload_delay` to `20000` produced a clean cold boot;
- disabling `enable_badwan_interface_monitoring` also produced a clean cold boot;
- on this specific configuration a controlled `ifdown wan; sleep 10; ifup wan` restored both `wan` and `awg0`, while Podkop kept working without a manual reload.

This observation **does not prove a specific root cause inside Podkop**. It is consistent with the class of behavior described in open upstream issue [itdoginfo/podkop#360](https://github.com/itdoginfo/podkop/issues/360), which discusses a possible race between an unfinished `podkop start` and a `podkop reload` triggered by `WAN up`. We do not claim our case is definitively the same bug.

If Podkop appears to be running after a cold start but only some routed services fail, useful checks are:

```sh
uci -q get podkop.settings.enable_badwan_interface_monitoring
uci -q get podkop.settings.badwan_reload_delay
logread | grep -Ei 'podkop|sing-box' | tail -n 100
```

A practical diagnostic step is to increase `badwan_reload_delay` first and retest. Disable WAN monitoring only if you understand its purpose and have separately verified that your own setup recovers correctly after WAN loss/return without that trigger.

## Logs

```sh
logread | grep podkop-guard
```

No persistent log file is written to flash.

## Runtime cost

In normal operation:

- one sleeping `ash` process under procd;
- one cheap LKG age check per hour;
- roughly once per day, SRS downloads and several seconds of validation;
- heavier work runs with reduced CPU priority (`nice -n 10`);
- flash writes happen only after a fully successful refresh.

If GitHub is unavailable, the worker makes one direct request and at most one VPN retry for the first required file that fails, then sleeps for another hour.

## What podkop-guard intentionally does NOT do

- does not patch Podkop;
- does not change `community_lists`;
- does not enable Podkop `download_lists_via_proxy`;
- does not switch VPN tunnels;
- does not reload/restart Podkop during refresh;
- does not use cron;
- does not implement NORMAL/FALLBACK modes;
- does not keep the live sing-box cache on flash;
- does not run a local HTTP server.

Podkop remains responsible for normal routing and its own standard list updates.

## Limitations

The current implementation targets `podkop.main.community_lists`.

If the Community List set changes while the current LKG is less than 24 hours old, run `podkop-guard refresh` manually instead of waiting for the next scheduled refresh.

VPN download fallback is only used when the `main` section is detected as VPN mode and `podkop.main.interface` is configured.

The `START=98 → Podkop START=99` ordering was verified on the versions listed above. Check init ordering again after major Podkop upgrades.

The project cannot guarantee recovery from a corrupted persistent LKG or future incompatible changes to sing-box cache/rule-set formats.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

The experimental watchdog branch uses GPLv3 for the combined work; see [LICENSE](LICENSE). The original MIT notice is preserved in [LICENSE.MIT](LICENSE.MIT), and upstream attribution is in [THIRD_PARTY.md](THIRD_PARTY.md).
