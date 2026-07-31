#!/usr/bin/env bash
# ab.sh — run the SAME .mst on MACVM and MACDART and diff the output
# (ST_PORTING_PLAN.md §2 D4). MACVM is the semantic oracle: a divergence is an
# engine bug, a missing port, or a deviation to document in DEVIATIONS.md —
# never ignorable. A probe file should print deterministic, self-describing
# lines (no timings, no addresses).
#
#   ./ab.sh probe1.mst probe2.mst ...
#   MACVM=/path/to/macvm ./ab.sh ...      override the oracle binary
#
# Exit 0 iff every file matches. Files MACVM can't run (platform-only) are
# reported as SKIP, not FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACDART="$(cd "$HERE/../.." && pwd)"
MACVM="${MACVM:-$HOME/claudeprojects/MACVM/target/release/macvm}"

DART="${DART:-}"
if [ -z "$DART" ]; then
  for c in build-st-rel build-release build-st; do
    [ -x "$MACDART/$c/dart" ] && DART="$MACDART/$c/dart" && break
  done
fi
[ -x "$DART" ]  || { echo "ab.sh: no dart-with-ST" >&2; exit 1; }
[ -x "$MACVM" ] || { echo "ab.sh: no macvm oracle at $MACVM" >&2; exit 1; }
[ $# -ge 1 ]    || { echo "usage: ab.sh probe.mst ..." >&2; exit 2; }

# MACDART prints a one-line "st: world loaded …" banner on stderr; drop it.
norm() { grep -vE "^st: world loaded"; }

fails=0
for f in "$@"; do
  name="$(basename "$f")"
  a="$("$MACVM" run "$f" 2>&1)"
  arc=$?
  b="$("$DART" --with-st "$HERE/run_mst.dart" "$f" 2>&1 | norm)"
  if [ $arc -ne 0 ] && echo "$a" | grep -qiE "unknown|no such|primitive|platform"; then
    printf "  \033[33mSKIP\033[0m  %s (macvm can't run it)\n" "$name"; continue
  fi
  if [ "$a" = "$b" ]; then
    printf "  \033[32mMATCH\033[0m %s\n" "$name"
  else
    printf "  \033[31mDIFF\033[0m  %s\n" "$name"; fails=$((fails+1))
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -12 | sed 's/^/        /'
  fi
done
echo "== $([ $fails = 0 ] && echo 'A/B CLEAN' || echo "$fails DIVERGENCE(S)") =="
exit $([ $fails = 0 ] && echo 0 || echo 1)
