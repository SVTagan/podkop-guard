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
- Keep recovery actions explicit until their behaviour has been proven on real hardware.

## Current state — 0.1.0

The repository currently contains the conservative core helper only. It intentionally does **not** change UCI configuration or restart/reload Podkop.

Commands:

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
- `cache.db` — optional manual snapshot of the sing-box cache.

### Conditional rules

A Podkop Local Subnet List can only express plain IP/CIDR entries. It cannot preserve conditions such as `network` or `port_range`.

`derive-subnets` therefore exports an `ip_cidr` only when the source sing-box rule contains no keys other than `domain_suffix` and `ip_cidr`. Conditional CIDRs are skipped and reported as a warning rather than being broadened silently.

This matters for the current `discord.srs`, whose IP rules contain UDP/port restrictions.

## Proven LKG experiment

A snapshot built from 14 Community Lists was merged into one binary `lkg.srs` and round-tripped:

```text
JSON -> sing-box rule-set compile -> SRS -> decompile -> canonical JSON
```

The canonical JSON before and after the round-trip had identical SHA-256 hashes and `cmp` returned `IDENTICAL`.

The snapshot contained:

```text
rules:   16
domains: 1562
cidrs:   1169
```

and preserved `domain_suffix`, `ip_cidr`, `network`, and `port_range` fields.

## Next work

1. Install and test the derived local subnet LKG with Podkop's existing `local_subnet_lists` option.
2. Test whether a saved sing-box `cache.db` can satisfy a remote Community SRS on cold start while its network download path is deliberately unavailable.
3. Only after that test, decide whether cache persistence should use Podkop's built-in flash cache path or a small boot-time restore mechanism.
4. Add snapshot refresh/update automation after the failure behaviour is fully verified.

The intended end state is deliberately small: Podkop remains responsible for normal routing and list updates; `podkop-guard` only preserves a known-good local safety net.
