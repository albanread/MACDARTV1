#!/usr/bin/env bash
# The Smalltalk A/B benchmark (ST_PLAN.md Sprint 8): the SAME .mst workloads
#   1. as Smalltalk JIT-compiled by the MACDART (Dart 1.24.3) VM,
#   2. as the line-for-line native Dart mirror on the same VM (the ST tax),
#   3. as Smalltalk on MACVM itself (if a release binary is present).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACDART="$(cd "$HERE/../.." && pwd)"   # the macdart/ dir

DART="$MACDART/build-st-rel/dart"
[ -x "$DART" ] || DART="$MACDART/build-release/dart"
[ -x "$DART" ] || { echo "run.sh: no release dart with ST support (build macdart/build-st-rel)" >&2; exit 1; }

echo "== MACDART: Smalltalk vs native Dart (same VM, same algorithms) =="
"$DART" "$HERE/run_macdart.dart" "$HERE/stbench.mst"

MACVM="${MACVM:-$HOME/claudeprojects/MACVM}"
if [ -x "$MACVM/target/release/macvm" ]; then
  echo
  echo "== MACVM: the same stbench.mst on its own VM =="
  combined="/tmp/stbench_combined.$$.mst"
  cat "$HERE/stbench.mst" "$HERE/macvm_driver.mst" > "$combined"
  ( cd "$MACVM" && ./target/release/macvm run "$combined" )
  rm -f "$combined"
else
  echo "(no MACVM release binary at $MACVM — skipping the MACVM leg)"
fi
