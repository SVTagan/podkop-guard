# Third-party code notice

The experimental observe-only watchdog code in `podkop-guard` includes an
adaptation of the procd sing-box PID lookup from:

- Project: **podkop-net/podkop-engine**
- File: `openwrt/podkop-engine/files/failsafe`
- Reference: `aaf75d5397aaaf56a65a35f9ccebf35d3cbd48f3`
- Source: https://github.com/podkop-net/podkop-engine/blob/aaf75d5397aaaf56a65a35f9ccebf35d3cbd48f3/openwrt/podkop-engine/files/failsafe
- License: GNU General Public License version 3 (see `LICENSE`)

The code was adapted for a **read-only, one-shot diagnostic command**. No
service management, recovery, kill/restart logic or automatic fail-open was
copied. This is a technical attribution, not an endorsement or affiliation.

The original `podkop-guard` LKG code is Copyright (c) 2026 SVTagan and was
released under MIT. Its original license notice is retained in
`LICENSE.MIT`. The combined modified work is distributed under GPLv3.
