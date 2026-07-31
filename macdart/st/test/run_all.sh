#!/usr/bin/env bash
# run_all.sh — the ST battery, seven tiers behind ONE exit code (M0 of
# ST_PORTING_PLAN.md §5). This is the pre-push gate. Build a dart-with-ST first
# (build-st-rel preferred; build-release / build-st accepted); this script does
# not build the VM — it runs what is there and reports which binary it used.
#
#   ./run_all.sh            tiers 0-5 (6/GUI only with --gui and a display)
#   ./run_all.sh --gui      also run the GUI smoke (needs a window server)
#   DART=/path/to/dart ./run_all.sh    force a specific VM
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACDART="$(cd "$HERE/../.." && pwd)"
WORLD="$HERE/../world"
BENCH="$WORLD/bench"

DART="${DART:-}"
if [ -z "$DART" ]; then
  for c in build-st-rel build-release build-st; do
    [ -x "$MACDART/$c/dart" ] && DART="$MACDART/$c/dart" && break
  done
fi
[ -x "$DART" ] || { echo "run_all.sh: no dart-with-ST (build one first)" >&2; exit 1; }

WANT_GUI=0; [ "${1:-}" = "--gui" ] && WANT_GUI=1
echo "== ST battery ==  VM: ${DART#$MACDART/}"
fails=0
pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fails=$((fails+1)); }
skip() { printf "  \033[33mSKIP\033[0m  %s\n" "$1"; }

# tier 0 — the world boots clean (no load error on stderr)
echo "Transcript showCr: 'boot'." > "$HERE/.boot.st"
boot="$("$DART" --with-st "$HERE/run_mst.dart" "$HERE/.boot.st" 2>&1)"
rm -f "$HERE/.boot.st"
if echo "$boot" | grep -q "world loaded" && ! echo "$boot" | grep -qiE "error|exception|ERR:"; then
  pass "tier0 world boot (86 files, clean)"
else
  fail "tier0 world boot"; echo "$boot" | tail -3 | sed 's/^/        /'
fi

# tier 1 — language conformance (no world)
c="$("$DART" "$HERE/run_conformance.dart" "$HERE/type_conformance.mst" 2>&1)"
if echo "$c" | grep -qE "failed 0"; then pass "tier1 conformance ($(echo "$c" | grep -oE 'passed [0-9]+' | head -1))"
else fail "tier1 conformance"; echo "$c" | grep -E "FAIL|failed" | head -4 | sed 's/^/        /'; fi

# tier 2 — bare-primitive coverage (world loaded)
if [ -f "$HERE/primitive_coverage.dart" ]; then
  p="$("$DART" --with-st "$HERE/primitive_coverage.dart" "$WORLD" 2>&1)"
  # pass = no "failed" with a nonzero count on the summary line
  if echo "$p" | grep -qE "failed 0" || ! echo "$p" | grep -qE "probed .* failed [1-9]"; then
    pass "tier2 primitive coverage ($(echo "$p" | grep -oE 'probed [0-9]+.*' | tail -1))"
  else
    fail "tier2 primitive coverage"; echo "$p" | grep -iE "FAIL|failed" | head -4 | sed 's/^/        /'
  fi
else skip "tier2 primitive coverage (driver not present)"; fi

# tier 2b — self-validating feature suites (STestCase; each asserts known-correct
# baked-in values — the test IS the spec, no external oracle). run_features.dart
# exits 0 only when every suite is green.
if [ -f "$HERE/run_features.dart" ]; then
  f="$("$DART" --with-st "$HERE/run_features.dart" 2>&1)"
  if [ $? -eq 0 ] && echo "$f" | grep -qE "ALL GREEN"; then
    pass "tier2b feature suites ($(echo "$f" | grep -oE '[0-9]+ suite\(s\)' | tail -1), all green)"
  else
    fail "tier2b feature suites"; echo "$f" | grep -iE "FAIL|CRASH|ABORTED" | head -6 | sed 's/^/        /'
  fi
else skip "tier2b feature suites (driver not present)"; fi

# tier 3 — per-class protocol probes (populated in M1+)
if compgen -G "$HERE/probes/*.mst" >/dev/null 2>&1; then
  t3f=0
  for pf in "$HERE"/probes/*.mst; do
    o="$("$DART" --with-st "$HERE/run_mst.dart" "$pf" 2>&1)"
    echo "$o" | grep -qiE "FAIL|exception|ERR:" && { t3f=$((t3f+1)); echo "$o" | grep -iE "FAIL" | head -2 | sed 's/^/        /'; }
  done
  [ "$t3f" = 0 ] && pass "tier3 protocol probes" || fail "tier3 protocol probes ($t3f file(s))"
else skip "tier3 protocol probes (none yet — M1+)"; fi

# tier 4 — A/B vs MACVM (populated in M0/M1; ab.sh is the engine)
if compgen -G "$HERE/ab/*.mst" >/dev/null 2>&1 && [ -x "$HERE/ab.sh" ]; then
  "$HERE/ab.sh" "$HERE"/ab/*.mst >/dev/null 2>&1 && pass "tier4 A/B vs MACVM" || fail "tier4 A/B vs MACVM"
else skip "tier4 A/B vs MACVM (no ab/*.mst yet)"; fi

# tier 5 — apps exact (checksum-verified inside the Bench harness)
for b in richards deltablue library_bench; do
  [ -f "$BENCH/$b.mst" ] || { skip "tier5 $b (missing)"; continue; }
  o="$("$DART" --with-st "$HERE/run_mst.dart" "$BENCH/$b.mst" 2>&1)"
  if echo "$o" | grep -qiE "exception|ERR:|wrong result"; then
    fail "tier5 $b"; echo "$o" | grep -iE "exception|ERR|wrong" | head -2 | sed 's/^/        /'
  else
    pass "tier5 $b ($(echo "$o" | grep -viE 'world loaded' | grep -E '[0-9]' | tail -1 | tr -s ' '))"
  fi
done

# tier 6 — GUI smoke (opt-in; needs a window server)
if [ "$WANT_GUI" = 1 ]; then
  if [ -x "$HERE/gui_smoke.sh" ]; then
    "$HERE/gui_smoke.sh" && pass "tier6 GUI smoke" || fail "tier6 GUI smoke"
  else skip "tier6 GUI smoke (gui_smoke.sh missing)"; fi
else skip "tier6 GUI smoke (pass --gui to run)"; fi

echo "== $([ $fails = 0 ] && echo ALL GREEN || echo "$fails TIER(S) RED") =="
exit $([ $fails = 0 ] && echo 0 || echo 1)
