#!/bin/sh
# Mock rc.common/procd/UCI and verify disabled-by-default opt-in.
set -eu
init="${1:-./podkop-guard.init}"
case "$init" in /*) ;; *) init="$(pwd)/${init#./}" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"

cat > "$tmp/prog" <<'SH'
#!/bin/sh
[ "$1" = boot-restore ] || exit 9
exit 0
SH

cat > "$tmp/bin/uci" <<'SH'
#!/bin/sh
[ "$1 $2 $3" = '-q get podkop_guard.settings.watchdog_enabled' ] || exit 9
[ "$WATCH_INIT_ENABLED" = 1 ] || exit 1
printf '1\n'
SH
chmod +x "$tmp/prog" "$tmp/bin/uci"

sed "s|^PROG=\"/usr/bin/podkop-guard\"|PROG=\"$tmp/prog\"|" "$init" > "$tmp/init"

procd_open_instance() { printf 'open:%s\n' "${1:-unnamed}" >> "$WATCH_INIT_LOG"; }
procd_close_instance() { printf 'close\n' >> "$WATCH_INIT_LOG"; }
procd_set_param() { printf '%s\n' "param:$*" >> "$WATCH_INIT_LOG"; }
logger() { printf 'unexpected logger call\n' >&2; exit 9; }
export PATH="$tmp/bin:$PATH"

# Sourcing does not run the init script; functions above isolate procd.
. "$tmp/init"
WATCH_INIT_LOG="$tmp/log"
export WATCH_INIT_LOG
WATCH_INIT_ENABLED=0
export WATCH_INIT_ENABLED
: > "$WATCH_INIT_LOG"
start_service

grep -q '^open:unnamed$' "$WATCH_INIT_LOG"
grep -q 'param:command .* daemon' "$WATCH_INIT_LOG"
if grep -q 'open:watchdog' "$WATCH_INIT_LOG"; then
    echo 'FAIL: unexpected watchdog when UCI is disabled' >&2
    exit 1
fi
echo 'PASS: disabled default preserves original LKG worker'

WATCH_INIT_ENABLED=1
export WATCH_INIT_ENABLED
: > "$WATCH_INIT_LOG"
start_service
grep -q '^open:unnamed$' "$WATCH_INIT_LOG"
grep -q '^open:watchdog$' "$WATCH_INIT_LOG"
grep -q 'param:command .* watchdog-observe' "$WATCH_INIT_LOG"
grep -q '^param:term_timeout 30$' "$WATCH_INIT_LOG"
grep -q '^param:stdout 1$' "$WATCH_INIT_LOG"
[ "$(grep -c '^close$' "$WATCH_INIT_LOG")" -eq 2 ]
echo 'PASS: opt-in creates isolated observe-only procd instance'
