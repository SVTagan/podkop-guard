#!/bin/sh
# Unit-test the actual LKG SRS helper functions without starting a router.
set -eu
worker="${1:-./podkop-guard}"
case "$worker" in /*) ;; *) worker="$(pwd)/${worker#./}" ;; esac
command -v jq >/dev/null || { echo 'jq required for SRS tests' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# Only source the three pure helper functions, never the worker dispatch.
awk '
  /^ruleset_canonicalize\(\) \{/ {emit=1}
  /^ruleset_extract_plain_cidrs\(\) \{/ {emit=1}
  /^ruleset_conditional_metrics\(\) \{/ {emit=1}
  emit {print}
  emit && /^}$/ {emit=0}
' "$worker" > "$tmp/functions"
[ "$(grep -c '^ruleset_.*() {' "$tmp/functions")" -eq 3 ] || {
    echo 'FAIL: could not extract exactly three SRS helpers' >&2
    exit 1
}
run_nice() { "$@"; }
. "$tmp/functions"

cat > "$tmp/arrays.json" <<'EOF'
{"version":3,"rules":[{"domain_suffix":["example.test"]},{"ip_cidr":["192.0.2.0/24"]}]}
EOF
cat > "$tmp/scalars.json" <<'EOF'
{"version":2,"rules":[{"domain_suffix":"example.test"},{"ip_cidr":"192.0.2.0/24"}]}
EOF
ruleset_canonicalize "$tmp/arrays.json" "$tmp/one"
ruleset_canonicalize "$tmp/scalars.json" "$tmp/two"
cmp -s "$tmp/one" "$tmp/two"
echo PASS_SRS_SCALAR_ARRAY_CANONICAL

cat > "$tmp/changed.json" <<'EOF'
{"version":2,"rules":[{"domain_suffix":"example.test"},{"ip_cidr":"192.0.3.0/24"}]}
EOF
ruleset_canonicalize "$tmp/changed.json" "$tmp/changed.out"
if cmp -s "$tmp/one" "$tmp/changed.out"; then
    echo 'FAIL: semantic change incorrectly accepted' >&2
    exit 1
fi
echo PASS_SRS_SEMANTIC_CHANGE_DETECTED

ruleset_extract_plain_cidrs "$tmp/arrays.json" > "$tmp/cidrs"
[ "$(cat "$tmp/cidrs")" = '192.0.2.0/24' ]
echo PASS_SRS_UNCONDITIONAL_CIDR

cat > "$tmp/or-group.json" <<'EOF'
{"version":3,"rules":[{"domain_suffix":["example.test"],"ip_cidr":["192.0.2.0/24"]}]}
EOF
[ "$(ruleset_extract_plain_cidrs "$tmp/or-group.json")" = '192.0.2.0/24' ]
[ "$(ruleset_conditional_metrics "$tmp/or-group.json")" = '0 0' ]
echo PASS_SRS_DOMAIN_IP_OR_GROUP

cat > "$tmp/conditional.json" <<'EOF'
{"version":3,"rules":[{"domain_suffix":["example.test"],"ip_cidr":["192.0.2.0/24"],"network":"tcp"}]}
EOF
[ -z "$(ruleset_extract_plain_cidrs "$tmp/conditional.json")" ]
[ "$(ruleset_conditional_metrics "$tmp/conditional.json")" = '1 1' ]
echo PASS_SRS_AND_CONSTRAINT_CIDR_EXCLUDED

cat > "$tmp/default.json" <<'EOF'
{"version":4,"rules":[{"type":"default","ip_cidr":"203.0.113.0/24"},{"ip_cidr":"192.0.2.0/24","network":"tcp"}]}
EOF
[ "$(ruleset_extract_plain_cidrs "$tmp/default.json")" = '203.0.113.0/24' ]
[ "$(ruleset_conditional_metrics "$tmp/default.json")" = '1 1' ]
echo PASS_SRS_DEFAULT_TYPE_AND_EXTRA_FIELD

echo 'PASS: 6 deterministic SRS compatibility scenarios'
