#!/usr/bin/env bash
# Minimal MACDART test runner: run a sample of upstream Dart tests directly and
# tally pass/fail/timeout. This is NOT the full test.py harness — it doesn't
# split multitests or interpret `/// nn: compile-time error` negative markers,
# so negative/multitests count as "fail". It's a coarse health signal.
#
# Usage: run.sh <suite-dir> [stride] [max]
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DART="$HERE/../build/dart"
PKGS="$HERE/.packages"
SUITE="${1:?usage: run.sh <suite-dir> [stride] [max]}"
STRIDE="${2:-1}"
MAX="${3:-100000}"
TIMEOUT="${TIMEOUT:-20}"

pass=0; fail=0; to=0; n=0; i=0
declare -a failures
while IFS= read -r t; do
  i=$((i+1))
  [ $((i % STRIDE)) -ne 0 ] && continue
  [ "$n" -ge "$MAX" ] && break
  n=$((n+1))
  # perl alarm gives us a portable per-test timeout on macOS.
  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
     "$DART" --packages="$PKGS" "$t" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then pass=$((pass+1))
  elif [ "$rc" -eq 142 ]; then to=$((to+1)); failures+=("TIMEOUT $t")
  else fail=$((fail+1)); failures+=("FAIL(rc=$rc) $t")
  fi
done < <(find "$SUITE" -name '*_test.dart' | sort)

echo "suite=$SUITE  ran=$n  PASS=$pass  FAIL=$fail  TIMEOUT=$to"
if [ "${SHOW_FAILURES:-0}" = "1" ] && [ ${#failures[@]} -gt 0 ]; then
  printf '  %s\n' "${failures[@]:0:25}"
fi
