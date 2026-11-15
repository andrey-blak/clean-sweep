#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../clean-sweep"
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
exclude = .git, node_modules
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
run_fail() { if bash "$S" "$@"; then echo "FAIL: expected non-zero exit: $*"; fails=$((fails+1)); fi; }

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
exists "$H/projC/node_modules/.claude"       # exclude list
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

echo '=== T5: tilde expansion + unknown user ==='
T5="$HOME/sweep-t5"; rm -rf "$T5"; mkdir -p "$T5/.hermes"
touch -d '2 days ago' "$T5" "$T5/.hermes"
printf '[scan]\nroots = ~/sweep-t5\n[targets]\n.hermes = empty\n' > /tmp/sweep-t5.ini
run -c /tmp/sweep-t5.ini
gone "$T5/.hermes"
printf '[scan]\nroots = ~nosuchuserxyz/d\n[targets]\n.hermes = empty\n' > /tmp/sweep-t5b.ini
run_fail -c /tmp/sweep-t5b.ini
rm -rf "$T5"

echo '=== T6: dry-run cascading deletion == real run ==='
T6=/tmp/sweep-t6; rm -rf "$T6"
mkdir -p "$T6/projX/.claude/.cc-writes" "$T6/projY/.claude"
touch "$T6/projY/.claude/settings.json" "$T6/projX/.claude/.cc-writes/staged"
find "$T6" -type d -exec touch -d '2 days ago' {} +
printf '[scan]\nroots = %s\n[targets]\n.claude = empty\n.claude/.cc-writes = force, 6\n' "$T6" > /tmp/sweep-t6.ini
bash "$S" -c /tmp/sweep-t6.ini -n > /tmp/sweep-t6.dry
grep -q "would remove (empty): $T6/projX/.claude" /tmp/sweep-t6.dry || { echo 'FAIL: cascade not previewed'; fails=$((fails+1)); }
grep -q 'projY' /tmp/sweep-t6.dry && { echo 'FAIL: non-empty parent previewed'; fails=$((fails+1)); }
exists "$T6/projX/.claude/.cc-writes/staged"
run -c /tmp/sweep-t6.ini > /tmp/sweep-t6.real
sed 's/^would remove (empty): /removed (empty): /; s/^would FORCE-remove: /FORCE-removed: /' /tmp/sweep-t6.dry | grep -E '^(removed|FORCE)' | sort > /tmp/sweep-t6.dn
grep -E '^(removed|FORCE)' /tmp/sweep-t6.real | sort > /tmp/sweep-t6.rn
diff /tmp/sweep-t6.dn /tmp/sweep-t6.rn || { echo 'FAIL: dry-run != real run'; fails=$((fails+1)); }
rm -rf "$T6"

echo '=== T7: missing root + inaccessible scan ==='
T7=/tmp/sweep-t7; rm -rf "$T7"; mkdir -p "$T7/open/.hermes"
touch -d '2 days ago' "$T7" "$T7/open" "$T7/open/.hermes"
printf '[scan]\nroots = /tmp/definitely-missing-xyz, %s/open\n[targets]\n.hermes = empty\n' "$T7" > /tmp/sweep-t7.ini
run_fail -c /tmp/sweep-t7.ini
gone "$T7/open/.hermes"
if (( EUID == 0 )) && command -v setpriv >/dev/null; then
  mkdir -p "$T7/locked/.hermes"; touch -d '2 days ago' "$T7/locked" "$T7/locked/.hermes"
  mkdir -p "$T7/open/.hermes"; touch -d '2 days ago' "$T7/open/.hermes"
  chmod 777 "$T7" "$T7/open"; chmod 000 "$T7/locked"; chmod 644 /tmp/sweep-t7.ini
  printf '[scan]\nroots = %s\n[targets]\n.hermes = empty\n' "$T7" > /tmp/sweep-t7b.ini
  chmod 644 /tmp/sweep-t7b.ini
  if setpriv --reuid=65534 --regid=65534 --clear-groups bash "$S" -c /tmp/sweep-t7b.ini > /tmp/sweep-t7.out 2>/tmp/sweep-t7.err; then
    echo 'FAIL: partial scan exited 0'; fails=$((fails+1))
  fi
  grep -q 'scan incomplete' /tmp/sweep-t7.err || { echo 'FAIL: scan error not surfaced'; fails=$((fails+1)); }
  gone "$T7/open/.hermes"
  chmod 755 "$T7/locked"
elif (( EUID != 0 )); then
  mkdir -p "$T7/locked/.hermes"; chmod 000 "$T7/locked"
  printf '[scan]\nroots = %s\n[targets]\n.hermes = empty\n' "$T7" > /tmp/sweep-t7b.ini
  run_fail -c /tmp/sweep-t7b.ini
  chmod 755 "$T7/locked"
else
  echo 'note: skipping EACCES test (root without setpriv)'
fi
rm -rf "$T7"

echo '=== T8: symlinked root + .. in root and target ==='
T8=/tmp/sweep-t8; rm -rf "$T8" /tmp/sweep-t8-link
mkdir -p "$T8/sub/.claude" "$T8/.hermes" "$T8/.claude"
find "$T8" -type d -exec touch -d '2 days ago' {} +
ln -s "$T8" /tmp/sweep-t8-link
printf '[scan]\nroots = /tmp/sweep-t8-link, %s/sub/../\n[targets]\n.hermes = empty\n%s/sub/../.claude = empty\n' "$T8" "$T8" > /tmp/sweep-t8.ini
run -c /tmp/sweep-t8.ini
gone "$T8/.hermes"
gone "$T8/.claude"          # sub/../.claude canonicalizes to T8/.claude
exists "$T8/sub/.claude"    # no target matches this one
rm -rf "$T8" /tmp/sweep-t8-link

echo '=== T9: symlink/dir replacement during run ==='
T9=/tmp/sweep-t9; rm -rf "$T9"; mkdir -p "$T9/.cc-writes"; touch "$T9/.cc-writes/staged"
find "$T9" -type d -exec touch -d '2 days ago' {} +
printf '[scan]\nroots = %s\nmin_age_hours = 0\n[targets]\n.cc-writes = force, 0\n' "$T9" > /tmp/sweep-t9.ini
sed 's|^# ---------- phase 2|sleep 2\n# ---------- phase 2|' "$S" > /tmp/sweep-t9-race
bash /tmp/sweep-t9-race -c /tmp/sweep-t9.ini > /tmp/sweep-t9.out 2>/tmp/sweep-t9.err &
T9PID=$!
sleep 0.5
rm -rf "$T9/.cc-writes"; mkdir "$T9/.cc-writes"; touch "$T9/.cc-writes/NEWWORK"
wait "$T9PID"
grep -q 'skipped (replaced since scan)' /tmp/sweep-t9.err || { echo 'FAIL: replacement not detected'; fails=$((fails+1)); }
exists "$T9/.cc-writes/NEWWORK"
rm -rf "$T9" /tmp/sweep-t9-race

echo '=== T10: overlapping + duplicate roots ==='
T10=/tmp/sweep-t10; rm -rf "$T10"; mkdir -p "$T10/sub/.hermes"
find "$T10" -type d -exec touch -d '2 days ago' {} +
printf '[scan]\nroots = %s, %s/sub, %s\n[targets]\n.hermes = empty\n' "$T10" "$T10" "$T10" > /tmp/sweep-t10.ini
bash "$S" -c /tmp/sweep-t10.ini > /tmp/sweep-t10.out
gone "$T10/sub/.hermes"
n=$(grep -c "removed (empty): $T10/sub/.hermes" /tmp/sweep-t10.out || true)
if [[ "$n" != 1 ]]; then echo "FAIL: deleted/logged $n times (want 1)"; fails=$((fails+1)); fi
rm -rf "$T10"

echo '=== T11: future mtime survives age guard ==='
T11=/tmp/sweep-t11; rm -rf "$T11"; mkdir -p "$T11/.hermes"
touch -d 'tomorrow' "$T11" "$T11/.hermes"
printf '[scan]\nroots = %s\n[targets]\n.hermes = empty\n' "$T11" > /tmp/sweep-t11.ini
run -c /tmp/sweep-t11.ini
exists "$T11/.hermes"
rm -rf "$T11"

echo '=== T12: oversized age values rejected ==='
printf '[scan]\nroots = /tmp\nmin_age_hours = 99999999999999999999\n[targets]\n.hermes = empty\n' > /tmp/sweep-t12.ini
run_fail -c /tmp/sweep-t12.ini
printf '[scan]\nroots = /tmp\n[targets]\n.hermes = empty, 99999999999999999999\n' > /tmp/sweep-t12b.ini
run_fail -c /tmp/sweep-t12b.ini

echo '=== T13: relative scan root + absolute target ==='
T13=/tmp/sweep-t13; rm -rf "$T13"; mkdir -p "$T13/.hermes"
find "$T13" -type d -exec touch -d '2 days ago' {} +
printf '[scan]\nroots = sweep-t13\n[targets]\n%s/.hermes = empty\n' "$T13" > /tmp/sweep-t13.ini
(cd /tmp && run -c /tmp/sweep-t13.ini)
gone "$T13/.hermes"
rm -rf "$T13"

echo '=== T14: relative-target specificity ladder ==='
T14=/tmp/sweep-t14; rm -rf "$T14"
mkdir -p "$T14/a/proj/.claude/.cc-writes" "$T14/b/.claude/.cc-writes" "$T14/c/.cc-writes"
touch "$T14/a/proj/.claude/.cc-writes/x" "$T14/b/.claude/.cc-writes/x" "$T14/c/.cc-writes/x"
find "$T14" -type d -exec touch -d '2 days ago' {} +
printf '[scan]\nroots = %s\n[targets]\n.cc-writes = empty\n.claude/.cc-writes = force\nproj/.claude/.cc-writes = empty\n' "$T14" > /tmp/sweep-t14.ini
run -c /tmp/sweep-t14.ini
exists "$T14/a/proj/.claude/.cc-writes/x"   # deepest (empty) wins over force
gone   "$T14/b/.claude/.cc-writes"          # mid (force) wins over bare empty
exists "$T14/c/.cc-writes/x"                # bare empty: non-empty survives
rm -rf "$T14"

echo
if (( fails )); then echo "RESULT: $fails FAILURE(S)"; exit 1; else echo 'RESULT: ALL TESTS PASSED'; fi
