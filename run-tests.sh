#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean-sweep"
H=/tmp/sweep-home; X=/tmp/sweep-extra
rm -rf "$H" "$X" /tmp/sweep-fallback
bash -n "$S" || { echo 'SYNTAX FAIL'; exit 1; }

# --- fixtures ---
mkdir -p "$H/projA/.claude/.cc-writes" \
         "$H/projB/.claude" \
         "$H/.hermes" \
         "$H/.config/Claude/Code/.cc-writes" \
         "$H/other/.cc-writes" \
         "$H/other2/.cc-writes" \
         "$H/projC/node_modules/.claude" \
         "$H/spec/.claude/.cc-writes" \
         "$H/age30/.claude" \
         "$H/ weird " \
         "$X/proj,jects/.hermes" \
         /tmp/sweep-fallback/.hermes
touch "$H/projB/.claude/settings.json" "$H/.hermes/config.yaml" \
      "$H/.config/Claude/Code/.cc-writes/staged.tmp" \
      "$H/other2/.cc-writes/data" "$H/spec/.claude/.cc-writes/leftover"
# age everything to 2 days, then special cases
find "$H" "$X" /tmp/sweep-fallback -type d -exec touch -d '2 days ago' {} +
touch -d '30 hours ago' "$H/age30/.claude"
mkdir -p "$H/fresh/.claude/.cc-writes"   # created after aging => fresh

cat > /tmp/sweep-test.ini <<EOF
[scan]
roots = $H, "$X/proj,jects"
skip = .git, node_modules
min_age_hours = 24
dry_run = false

[targets]
.claude = empty, 48
.hermes = empty
.cc-writes = empty
.claude/.cc-writes = force, 6
$H/.config/Claude/Code/.cc-writes = force, 6
" weird " = empty
EOF

fails=0
gone()    { if [[ -e "$1" ]]; then echo "FAIL: should be gone: $1"; fails=$((fails+1)); fi; }
exists()  { if [[ ! -e "$1" ]]; then echo "FAIL: should exist: $1"; fails=$((fails+1)); fi; }
run()     { if ! bash "$S" "$@"; then echo "FAIL: sweep exited $? : $*"; fails=$((fails+1)); fi; }

echo '=== T1: CLI -n dry run (config says false) ==='
run -c /tmp/sweep-test.ini -n
exists "$H/projA/.claude/.cc-writes"   # nothing actually deleted
exists "$H/.config/Claude/Code/.cc-writes/staged.tmp"

echo '=== T2: real run ==='
run -c /tmp/sweep-test.ini
gone   "$H/projA/.claude/.cc-writes"   # same-pass cascade: child + parent
gone   "$H/projA/.claude"
gone   "$H/.config/Claude/Code/.cc-writes"   # absolute force target
exists "$H/.config/Claude/Code"              # parent not a target
gone   "$X/proj,jects/.hermes"         # quoted root containing commas
gone   "$H/ weird "                    # quoted key with edge spaces
gone   "$H/spec/.claude/.cc-writes"    # most-specific wins: force over bare empty
exists "$H/projB/.claude/settings.json"      # non-empty config dir survives
exists "$H/.hermes/config.yaml"              # real-home analog survives
gone   "$H/other/.cc-writes"           # bare .cc-writes=empty, empty+old => removed
exists "$H/other2/.cc-writes/data"           # non-empty, bare empty-mode => survives
exists "$H/projC/node_modules/.claude"       # skip list
exists "$H/fresh/.claude/.cc-writes"         # age guard
exists "$H/age30/.claude"                    # per-target 48h override (30h old)

echo '=== T3: ${VAR:-default} expansion ==='
printf '[scan]\nroots = ${SWEEP_TEST_ROOT:-/tmp/sweep-fallback}\n[targets]\n.hermes = empty\n' > /tmp/sweep-exp.ini
SWEEP_TEST_ROOT=/tmp/sweep-fallback run -c /tmp/sweep-exp.ini
gone /tmp/sweep-fallback/.hermes
mkdir -p /tmp/sweep-fallback/.hermes && touch -d '2 days ago' /tmp/sweep-fallback/.hermes
run -c /tmp/sweep-exp.ini      # var unset => fallback path
gone /tmp/sweep-fallback/.hermes

echo '=== T4: config dry_run=true ==='
mkdir -p "$H/t4/.hermes" && touch -d '2 days ago' "$H/t4/.hermes"
sed 's/dry_run = false/dry_run = true/' /tmp/sweep-test.ini > /tmp/sweep-test-dry.ini
run -c /tmp/sweep-test-dry.ini
exists "$H/t4/.hermes"

echo
if (( fails )); then echo "RESULT: $fails FAILURE(S)"; exit 1; else echo 'RESULT: ALL TESTS PASSED'; fi
