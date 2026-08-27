# podkop-guard

`podkop-guard` is a small OpenWrt helper for keeping a persistent **Last Known Good (LKG)** state for Podkop routing lists.

The project exists to solve a concrete failure mode: Podkop may start normally while downloads from `raw.githubusercontent.com` fail, leaving IP-based service subnets absent from the `PodkopTable/podkop_subnets` nftables set. In that state domain-routed services may still work while native applications that connect directly to service IP ranges can fail.

## Confirmed failure case

On Podkop 0.7.21 + sing-box 1.12.22:

- direct access to `raw.githubusercontent.com` timed out;
- the same Telegram subnet list downloaded successfully through an AmneziaWG interface;
- Telegram CIDRs were absent from `PodkopTable/podkop_subnets`;
- manually inserting those CIDRs into the nft set immediately restored Telegram.

This is why subnet persistence is treated separately from sing-box remote rule-set caching.

## Design goals

- Keep Podkop configuration and normal Community Lists intact.
- Do not patch Podkop or generated sing-box configuration.
- Prefer persistent LKG data over complex NORMAL/FALLBACK state machines.
- Make writes atomic and avoid replacing a good LKG with partial/invalid data.
- Do not silently flatten conditional sing-box rules into unconditional nft routes.
- Keep recovery actions minimal and independently testable.

## Proven recovery behaviour

### Persistent Local Subnet LKG

A full LKG snapshot built from 14 selected Community Lists contained:

```text
rules:   16
domains: 1562
cidrs:   1169
```

It was round-tripped through:

```text
JSON -> sing-box rule-set compile -> SRS -> decompile -> canonical JSON
```

The canonical JSON before and after the round-trip had identical SHA-256 hashes and `cmp` returned `IDENTICAL`.

A plain Local Subnet List was then derived only from unconditional `ip_cidr` rules. Eight conditional Discord CIDRs were intentionally skipped, leaving:

```text
1161 CIDRs
```

The file was configured as:

```text
podkop.main.local_subnet_lists='/etc/podkop-guard/lkg-subnets.lst'
```

A real Podkop reload proved that Podkop imported the LKG before its asynchronous Community list update:

```text
Processing local subnets routing rules for 'main'
Adding 1000 elements to ruleset ...
Adding 161 elements to ruleset ...
Adding 1161 elements to nft set podkop_subnets
```

Telegram CIDRs were present after the reload and the native Telegram client worked.

### Persistent sing-box remote rule-set cache

A saved `/tmp/sing-box/cache.db` was copied to persistent storage as `/etc/podkop-guard/cache.db`.

A controlled A/B test used the real Telegram remote SRS while forcing its download detour to a dead SOCKS endpoint (`127.0.0.1:9`):

```text
A: saved cache + dead download -> sing-box remained running
B: no cache + same dead download -> sing-box exited with FATAL initial rule-set error
```

The same test was then repeated with **all 14 currently configured remote Community rule-sets**. With the saved cache and every network download forced through the dead detour, sing-box started successfully and remained running. No remote download was required for startup.

A separate stale-cache test forced every cached remote rule-set to expire immediately with `update_interval = 1s` while every refresh attempt still used the dead detour. sing-box started successfully and stayed running while logging repeated refresh errors. Therefore an expired cached ruleset remains usable as LKG data; failed background refreshes do not invalidate it or turn startup failure into a fatal condition.

This proves that the saved cache can satisfy the current remote Community SRS set during a cold start when GitHub is unavailable, even if the cached entries are older than their configured refresh interval.

### Boot restore simulation

The OpenWrt init script was installed as:

```text
/etc/rc.d/S98podkop-guard -> ../init.d/podkop-guard
/etc/rc.d/S99podkop       -> ../init.d/podkop
```

A controlled power-loss simulation was then performed without rebooting the router:

1. Podkop was stopped and sing-box confirmed stopped.
2. `/tmp/sing-box/cache.db` was deleted to emulate volatile RAM loss.
3. `podkop-guard start` restored the persistent snapshot.
4. SHA-256 of the restored runtime cache exactly matched `/etc/podkop-guard/cache.db`.
5. Podkop was started again.
6. The Local Subnet LKG was rebuilt into Podkop's local ruleset and nft set.
7. Telegram, YouTube and Gemini all worked after startup.

Observed restore log:

```text
podkop-guard: restored persistent sing-box cache snapshot before Podkop startup
```

One operational detail: `/etc/init.d/podkop start` returns after handing the service to procd, while `/usr/bin/podkop start` continues building its configuration. With a 1161-entry Local Subnet LKG, the first 12-second status check occurred before sing-box had started. This was not a startup failure; the subsequent working services confirmed completion. Startup checks should therefore allow more time or inspect Podkop logs instead of assuming that an immediate empty `pgrep` means failure.

## Current architecture

Persistent state:

```text
/etc/podkop-guard/lkg.srs
/etc/podkop-guard/lkg-subnets.lst
/etc/podkop-guard/cache.db
```

Normal operation remains owned by Podkop. `podkop-guard` adds only two safety nets:

1. `lkg-subnets.lst` is configured once as a normal Podkop Local Subnet List, so known-good IP CIDRs are loaded into `podkop_subnets` on every start/reload even if Community subnet downloads fail.
2. A tiny OpenWrt init script restores the saved sing-box `cache.db` into `/tmp/sing-box/cache.db` before Podkop starts, so cached remote Community SRS can be used after a power loss.

Podkop 0.7.21 starts at `START=99`; the guard init script uses `START=98`.

There is intentionally no NORMAL/FALLBACK mode, no automatic mutation of `community_lists`, no Podkop patch, and no custom HTTP server.

## Helper commands

The repository contains a conservative helper script with these commands:

```text
podkop-guard status
podkop-guard verify-lkg
podkop-guard derive-subnets
podkop-guard cache-save
podkop-guard cache-restore
```

### Persistent files

Default state directory:

```text
/etc/podkop-guard/
```

Files:

- `lkg.srs` — canonical full sing-box ruleset snapshot;
- `lkg-subnets.lst` — derived plain CIDR list containing only **unconditional** `ip_cidr` rules;
- `cache.db` — saved sing-box remote rule-set cache snapshot.

### Conditional rules

A Podkop Local Subnet List can only express plain IP/CIDR entries. It cannot preserve conditions such as `network` or `port_range`.

`derive-subnets` therefore exports an `ip_cidr` only when the source sing-box rule contains no keys other than `domain_suffix` and `ip_cidr`. Conditional CIDRs are skipped and reported as a warning rather than being broadened silently.

This matters for the current `discord.srs`, whose IP rules contain UDP/port restrictions.

## Remaining work

The minimal recovery mechanism is now proven on the target router. Remaining work is operational rather than emergency recovery:

1. Decide how and when a newer cache snapshot and `lkg.srs` should replace the persistent LKG. Refresh must be transactional and must never replace a known-good snapshot with an incomplete one.
2. Add an installation/update path so the project can be deployed and upgraded reproducibly from the repository.
3. Observe real power-loss events and confirm the same recovery behaviour outside controlled tests.
4. Revisit special conditional rules such as Discord only if support for them is actually needed.

The intended end state remains deliberately small: Podkop owns routing and normal list updates; `podkop-guard` only preserves a known-good local safety net.
