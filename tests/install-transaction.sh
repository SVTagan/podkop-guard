#!/bin/sh
# Functional sandbox tests for the transactional OpenWrt installer.
# These tests never use /etc/init.d, actual opkg/apk, UCI or the network.
set -eu

installer="${1:-./install.sh}"
case "$installer" in /*) ;; *) installer="$(pwd)/${installer#./}" ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
root="$tmp/root"
mock="$tmp/mock"
fixture="$tmp/fixture"
mkdir -p "$root" "$mock" "$fixture"

cat > "$mock/opkg" <<'SH'
#!/bin/sh
case "$1" in
    status)
        case "$2" in
            curl|jq)
                if [ "$2" = jq ] && [ "${MOCK_MISSING_JQ:-0}" = 1 ] &&
                   [ ! -f "$MOCK_PKG_DIR/jq" ]; then exit 1; fi
                printf 'Status: install user installed\n'
                exit 0 ;;
            luci-base|luci-app-commands)
                [ "${MOCK_LUCI:-0}" = 1 ] && {
                    printf 'Status: install user installed\n'
                    exit 0
                }
                exit 1 ;;
        esac
        exit 1 ;;
    update) printf 'opkg update\n' >> "$MOCK_PKG_LOG"; exit 0 ;;
    install)
        printf 'opkg install %s\n' "$2" >> "$MOCK_PKG_LOG"
        : > "$MOCK_PKG_DIR/$2"
        exit 0 ;;
    *) exit 9 ;;
esac
SH

cat > "$tmp/apk-stub" <<'SH'
#!/bin/sh
case "$1" in
    info)
        [ "$2" = -e ] || exit 9
        case "$3" in
            curl|jq)
                if [ "$3" = jq ] && [ "${MOCK_MISSING_JQ:-0}" = 1 ] &&
                   [ ! -f "$MOCK_PKG_DIR/jq" ]; then exit 1; fi
                exit 0 ;;
            luci-base|luci-app-commands) [ "${MOCK_LUCI:-0}" = 1 ]; exit $? ;;
        esac
        exit 1 ;;
    update) printf 'apk update\n' >> "$MOCK_PKG_LOG"; exit 0 ;;
    add)
        printf 'apk add %s\n' "$2" >> "$MOCK_PKG_LOG"
        : > "$MOCK_PKG_DIR/$2"
        exit 0 ;;
    *) exit 9 ;;
esac
SH

cat > "$mock/curl" <<'SH'
#!/bin/sh
url=""
dst=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift; dst=$1 ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
[ -n "$url" ] && [ -n "$dst" ] || exit 9
case "$url" in
    */podkop-guard.init)
        [ "${MOCK_DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
        cp "$MOCK_FIXTURE/new_init" "$dst"
        ;;
    */podkop-guard)
        cp "$MOCK_FIXTURE/new_worker" "$dst"
        ;;
    *) exit 9 ;;
esac
SH

cat > "$mock/uci" <<'SH'
#!/bin/sh
case "$1" in
    -q) exit 1 ;;
    set) printf 'set:%s\n' "$2" >> "$MOCK_UCI_LOG"; exit 0 ;;
    commit)
        printf 'commit:%s\n' "$2" >> "$MOCK_UCI_LOG"
        [ "${MOCK_LUCI_COMMIT_FAIL:-0}" = 0 ]
        exit $? ;;
    *) exit 9 ;;
esac
SH

cat > "$mock/sing-box" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$mock/podkop" <<'SH'
#!/bin/sh
exit 0
SH

cat > "$fixture/new_worker" <<'SH'
#!/bin/sh
# podkop-guard - persistent Last Known Good protection for Podkop/OpenWrt
VERSION="0.2.4"
# fixture=new-worker
case "${1:-}" in
    status) printf 'new fixture is healthy\n' ;;
    *) exit 0 ;;
esac
SH
cat > "$fixture/old_worker" <<'SH'
#!/bin/sh
# podkop-guard - persistent Last Known Good protection for Podkop/OpenWrt
VERSION="0.2.4"
# fixture=old-worker
case "${1:-}" in
    status) printf 'old fixture is healthy\n' ;;
    *) exit 0 ;;
esac
SH

cat > "$fixture/old_init" <<'SH'
#!/bin/sh
MODE=old
case "${1:-}" in
    running) [ -f "$MOCK_STATE/running" ] ;;
    enabled) [ -f "$MOCK_STATE/enabled" ] ;;
    stop)
        printf 'stop:%s\n' "$MODE" >> "$MOCK_SERVICE_LOG"
        rm -f "$MOCK_STATE/running"
        ;;
    start)
        printf 'start:%s\n' "$MODE" >> "$MOCK_SERVICE_LOG"
        [ "$MODE" != new ] || [ "${MOCK_INIT_FAIL_START_NEW:-0}" = 0 ] || exit 6
        : > "$MOCK_STATE/running"
        ;;
    enable)
        printf 'enable:%s\n' "$MODE" >> "$MOCK_SERVICE_LOG"
        : > "$MOCK_STATE/enabled"
        ;;
    disable)
        printf 'disable:%s\n' "$MODE" >> "$MOCK_SERVICE_LOG"
        rm -f "$MOCK_STATE/enabled"
        ;;
    *) exit 9 ;;
esac
SH
sed 's/^MODE=old$/MODE=new/' "$fixture/old_init" > "$fixture/new_init"
chmod +x "$mock"/* "$fixture"/* "$tmp/apk-stub"

export MOCK_FIXTURE="$fixture"
export MOCK_STATE="$tmp/state"
export MOCK_SERVICE_LOG="$tmp/service.log"
export MOCK_UCI_LOG="$tmp/uci.log"
export MOCK_PKG_LOG="$tmp/packages.log"
export MOCK_PKG_DIR="$tmp/pkg"
export MOCK_MISSING_JQ=0
export PODKOP_GUARD_INSTALL_TEST_ROOT="$root"
export PODKOP_GUARD_BASE_URL="https://fixtures.example.invalid/guard"
export MOCK_INIT_FAIL_START_NEW=0 MOCK_DOWNLOAD_FAIL=0 MOCK_LUCI=0 MOCK_LUCI_COMMIT_FAIL=0
PATH="$mock:$PATH"
export PATH
passed=0

setup() {
    old=$1 running=$2 enabled=$3
    rm -rf "$root" "$MOCK_STATE" "$MOCK_PKG_DIR"
    mkdir -p "$root/etc/init.d" "$root/usr/bin" "$MOCK_STATE" "$MOCK_PKG_DIR"
    : > "$MOCK_PKG_LOG"
    printf 'DISTRIB_ID=OpenWrt\n' > "$root/etc/openwrt_release"
    printf '#!/bin/sh\nexit 0\n' > "$root/etc/init.d/podkop"
    chmod +x "$root/etc/init.d/podkop"
    : > "$MOCK_SERVICE_LOG"
    : > "$MOCK_UCI_LOG"
    if [ "$old" = 1 ]; then
        mkdir -p "$root/etc/podkop-guard"
        printf 'known-good-lkg-marker\n' > "$root/etc/podkop-guard/lkg-untouched.txt"
        cp "$fixture/old_worker" "$root/usr/bin/podkop-guard"
        cp "$fixture/old_init" "$root/etc/init.d/podkop-guard"
        chmod +x "$root/usr/bin/podkop-guard" "$root/etc/init.d/podkop-guard"
    fi
    [ "$running" = 0 ] || : > "$MOCK_STATE/running"
    [ "$enabled" = 0 ] || : > "$MOCK_STATE/enabled"
}

run_install() {
    set +e
    output=$(sh "$installer" 2>&1)
    result=$?
    set -e
}
assert_files() {
    marker=$1
    grep -q "fixture=$marker-worker" "$root/usr/bin/podkop-guard" || {
        printf 'FAIL: worker marker expected %s\n' "$marker" >&2; exit 1
    }
    grep -q "^MODE=$marker$" "$root/etc/init.d/podkop-guard" || {
        printf 'FAIL: init marker expected %s\n' "$marker" >&2; exit 1
    }
}
assert_state() {
    running=$1 enabled=$2
    if [ "$running" = 1 ]; then [ -f "$MOCK_STATE/running" ]; else [ ! -e "$MOCK_STATE/running" ]; fi
    if [ "$enabled" = 1 ]; then [ -f "$MOCK_STATE/enabled" ]; else [ ! -e "$MOCK_STATE/enabled" ]; fi
}
assert_lkg() {
    [ -r "$root/etc/podkop-guard/lkg-untouched.txt" ] &&
    [ "$(cat "$root/etc/podkop-guard/lkg-untouched.txt")" = 'known-good-lkg-marker' ]
}
assert_no_stage() {
    [ ! -e "$root/usr/bin/podkop-guard.stage" ]
    [ "$(find "$root" -name '*.stage.*' -o -name '*.rollback.*' | wc -l)" -eq 0 ]
}
ok() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# Existing installations: all four running/autostart combinations.
for states in '0 0' '0 1' '1 0' '1 1'; do
    set -- $states
    setup 1 "$1" "$2"
    run_install
    [ "$result" -eq 0 ] || { printf '%s\n' "$output" >&2; exit 1; }
    assert_files new
    assert_state "$1" "$2"
    assert_lkg
    assert_no_stage
    ok "upgrade_running_${1}_enabled_${2}"
done

# First install must not start or enable LKG recovery without a snapshot.
setup 0 0 0
run_install
[ "$result" -eq 0 ] || { printf '%s\n' "$output" >&2; exit 1; }
assert_files new
assert_state 0 0
[ -d "$root/etc/podkop-guard" ]
ok 'first_install_inert'

# Atomic rollback on two partial install stages.
for stage in after_worker after_init after_start; do
    setup 1 1 1
    PODKOP_GUARD_TEST_FAILURE="$stage"
    export PODKOP_GUARD_TEST_FAILURE
    run_install
    unset PODKOP_GUARD_TEST_FAILURE
    [ "$result" -ne 0 ] || { printf 'FAIL injection %s unexpectedly succeeded\n' "$stage" >&2; exit 1; }
    assert_files old
    assert_state 1 1
    assert_lkg
    assert_no_stage
    ok "rollback_${stage}"
done

# New init can fail to restart the worker: restore the old copy and state.
setup 1 1 1
MOCK_INIT_FAIL_START_NEW=1
export MOCK_INIT_FAIL_START_NEW
run_install
MOCK_INIT_FAIL_START_NEW=0
export MOCK_INIT_FAIL_START_NEW
[ "$result" -ne 0 ]
assert_files old
assert_state 1 1
ok 'rollback_when_new_service_fails'

# Never disturb a functioning old instance on failed download.
setup 1 1 1
MOCK_DOWNLOAD_FAIL=1
export MOCK_DOWNLOAD_FAIL
run_install
MOCK_DOWNLOAD_FAIL=0
export MOCK_DOWNLOAD_FAIL
[ "$result" -ne 0 ]
assert_files old
assert_state 1 1
[ ! -s "$MOCK_SERVICE_LOG" ]
ok 'download_failure_is_preflight_only'

# Refuse a partial old installation without destroying the remaining file.
setup 1 1 1
rm -f "$root/usr/bin/podkop-guard"
run_install
[ "$result" -ne 0 ]
[ -e "$root/etc/init.d/podkop-guard" ]
[ -f "$MOCK_STATE/running" ]
ok 'partial_installation_refused'

# A failing optional LuCI operation must not roll back committed core files.
setup 1 1 1
MOCK_LUCI=1
MOCK_LUCI_COMMIT_FAIL=1
export MOCK_LUCI MOCK_LUCI_COMMIT_FAIL
run_install
MOCK_LUCI=0
MOCK_LUCI_COMMIT_FAIL=0
export MOCK_LUCI MOCK_LUCI_COMMIT_FAIL
[ "$result" -eq 0 ]
assert_files new
assert_state 1 1
ok 'luci_optional_failure_does_not_rollback'

# Before touching a running worker, wrong version must fail preflight.
setup 1 1 1
cp "$fixture/new_worker" "$tmp/good-worker"
sed 's/VERSION="0.2.4"/VERSION="0.9.9"/' "$tmp/good-worker" > "$fixture/new_worker"
run_install
[ "$result" -ne 0 ]
assert_files old
assert_state 1 1
assert_lkg
[ ! -s "$MOCK_SERVICE_LOG" ]
cp "$tmp/good-worker" "$fixture/new_worker"
ok 'worker_version_mismatch_refused'

# Invalid shell syntax in a downloaded candidate is also a preflight failure.
setup 1 1 1
printf "\nif [ then\n" >> "$fixture/new_worker"
run_install
[ "$result" -ne 0 ]
assert_files old
assert_state 1 1
assert_lkg
[ ! -s "$MOCK_SERVICE_LOG" ]
cp "$tmp/good-worker" "$fixture/new_worker"
ok 'downloaded_script_syntax_invalid'

# The first-install rollback removes its partial worker+init instead of
# leaving a half-working, auto-enabled service.
setup 0 0 0
PODKOP_GUARD_TEST_FAILURE=after_worker
export PODKOP_GUARD_TEST_FAILURE
run_install
unset PODKOP_GUARD_TEST_FAILURE
[ "$result" -ne 0 ]
[ ! -e "$root/usr/bin/podkop-guard" ]
[ ! -e "$root/etc/init.d/podkop-guard" ]
assert_state 0 0
assert_no_stage
ok 'first_install_atomic_rollback'

# Ensure opkg was really selected in the tests above, not just coincidentally
# passing the package helper mocks.
setup 1 1 1
run_install
[ "$result" -eq 0 ]
case "$output" in *'Detected package manager: opkg'*) ;; *) echo 'FAIL: opkg not selected' >&2; exit 1 ;; esac
ok 'opkg_package_manager'

# Check the dependency install path, not only the installed-package query.
setup 1 1 1
MOCK_MISSING_JQ=1
export MOCK_MISSING_JQ
run_install
[ "$result" -eq 0 ]
[ -f "$MOCK_PKG_DIR/jq" ]
grep -q '^opkg install jq
# APK exists in PATH here; swap it into the test bin only for this scenario.
setup 1 1 1
run_install
[ "$result" -eq 0 ]
case "$output" in *'Detected package manager: apk'*) ;; *) echo 'FAIL: apk not selected' >&2; exit 1 ;; esac
assert_files new
assert_state 1 1
ok 'apk_package_manager'

setup 1 1 1
MOCK_MISSING_JQ=1
export MOCK_MISSING_JQ
run_install
[ "$result" -eq 0 ]
[ -f "$MOCK_PKG_DIR/jq" ]
grep -q '^apk add jq

printf 'PASS: %s installer scenarios\n' "$passed"
 "$MOCK_PKG_LOG"
assert_files new
assert_state 1 1
MOCK_MISSING_JQ=0
export MOCK_MISSING_JQ
ok 'opkg_missing_jq_install'

# Ensure the alternate apk path works (OpenWrt 25.12).
cp "$tmp/apk-stub" "$mock/apk"
# APK exists in PATH here; swap it into the test bin only for this scenario.
setup 1 1 1
run_install
[ "$result" -eq 0 ]
case "$output" in *'Detected package manager: apk'*) ;; *) echo 'FAIL: apk not selected' >&2; exit 1 ;; esac
assert_files new
assert_state 1 1
ok 'apk_package_manager'

printf 'PASS: %s installer scenarios\n' "$passed"
 "$MOCK_PKG_LOG"
assert_files new
assert_state 1 1
MOCK_MISSING_JQ=0
export MOCK_MISSING_JQ
ok 'apk_missing_jq_install'

printf 'PASS: %s installer scenarios\n' "$passed"
 "$MOCK_PKG_LOG"
assert_files new
assert_state 1 1
MOCK_MISSING_JQ=0
export MOCK_MISSING_JQ
ok 'opkg_missing_jq_install'

# Ensure the alternate apk path works (OpenWrt 25.12).
cp "$tmp/apk-stub" "$mock/apk"
# APK exists in PATH here; swap it into the test bin only for this scenario.
setup 1 1 1
run_install
[ "$result" -eq 0 ]
case "$output" in *'Detected package manager: apk'*) ;; *) echo 'FAIL: apk not selected' >&2; exit 1 ;; esac
assert_files new
assert_state 1 1
ok 'apk_package_manager'

printf 'PASS: %s installer scenarios\n' "$passed"
