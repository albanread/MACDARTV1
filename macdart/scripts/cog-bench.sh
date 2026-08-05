#!/bin/sh
# cog-bench.sh — MACDART vs Cog (Pharo), same workloads, same protocol,
# microsecond clock on both sides, interleaved back-to-back for R rounds on
# THIS machine. Mirrors MACVM's own scripts/cog-bench.sh byte-for-byte in
# protocol (see docs/cog_bench.md and MACVM's docs/cog_bench.md, which this
# was adapted from) — same reason: a millisecond clock truncates on the
# sub-5ms benches (sieve, deltablue) badly enough to invert verdicts.
#
# Unlike MACVM's own Dart comparison (scripts/dart-bench.sh in that repo,
# which runs a SEPARATE Dart 1.24.3 build inside a Lima Linux VM), this runs
# MACDART'S OWN native macOS arm64 `dart` binary directly — no VM layer, no
# translation, the actual subject of this whole project.
#
# scripts/cog-bench.st is a CHECKED-IN artifact (generated once from MACVM's
# world/41a_bench_workloads.mst via that repo's mst2st.py — see the header
# comment in cog-bench.st itself) so this script has no runtime dependency
# on MACVM's tree at all; only the Pharo/Cog INSTALL is external (point
# COG_DIR at one — MACVM's own .cog/ works, since it is the same Pharo/Cog
# either way).
#
# Setup (once, if you do not already have one): install Pharo 13 headless
# into $COG_DIR (default ./.cog), so that "$COG_DIR/pharo" and
# "$COG_DIR/Pharo.image" exist:
#   curl -L https://get.pharo.org/64/130 | bash    # into $COG_DIR
#
# Usage:
#   COG_DIR=/path/to/cog ROUNDS=3 ./macdart/scripts/cog-bench.sh
set -eu
cd "$(dirname "$0")/.."   # macdart/

ROUNDS=${ROUNDS:-3}
DART=${DART:-./build-release/dart}
COG_DIR=${COG_DIR:-../../MACVM/.cog}
PHARO="$COG_DIR/pharo"
IMG="$COG_DIR/Pharo.image"
BENCH_ST="$(pwd)/scripts/cog-bench.st"
BENCH_DART="$(pwd)/scripts/cog-bench.dart"

[ -x "$DART" ] || { echo "no dart binary at $DART (build first: ninja -C build-release dart)"; exit 2; }
{ [ -x "$PHARO" ] && [ -f "$IMG" ]; } || {
    echo "no Pharo at COG_DIR=$COG_DIR (need ./pharo + Pharo.image) — see setup comment"; exit 2; }

# Quiet-machine gate: a loaded machine makes the comparison meaningless.
LOAD1=$(uptime | sed -E 's/.*load averages?: *([0-9.]+).*/\1/')
if [ "${FORCE:-0}" != "1" ] && [ "$(printf '%.0f' "$LOAD1")" -ge 4 ]; then
    echo "1-min load $LOAD1 is too high for a clean comparison; wait for it to settle (or FORCE=1)."
    exit 3
fi
# Attribution guard: name the exact tree this measured (MACDART_PLAN.md's
# own lesson from MACVM's cog_bench.md — a commit landing mid-comparison
# from a parallel session made an earlier delta look inexplicable).
GITDESC="$(git rev-parse --short HEAD 2>/dev/null || echo '?')$(git diff --quiet 2>/dev/null || echo '+dirty')"
echo "load=$LOAD1  rounds=$ROUNDS  commit=$GITDESC  (microsecond clock, no hard pinning — Apple Silicon)"

RAW=/tmp/macdart_cogbench_raw.txt
: > "$RAW"
i=1
while [ "$i" -le "$ROUNDS" ]; do
    # Cog then MACDART, back to back — a same-thermal-state pair.
    ( cd "$COG_DIR" && ./pharo Pharo.image st "$BENCH_ST" </dev/null 2>/dev/null ) \
        | grep 'warm_us=' | sed "s/^/cog /" >> "$RAW"
    "$DART" "$BENCH_DART" </dev/null 2>/dev/null \
        | grep 'warm_us=' | sed "s/^/macdart /" >> "$RAW"
    echo "  round $i done"
    i=$((i + 1))
done

python3 - "$RAW" <<'PY'
import sys, re, collections
best = collections.defaultdict(lambda: float('inf'))
order = []
for line in open(sys.argv[1]):
    m = re.match(r'(\w+)\s+(\S+)\s+.*warm_us=(\d+)', line)
    if not m: continue
    vm, bench, us = m.group(1), m.group(2), int(m.group(3))
    if bench not in order: order.append(bench)
    best[(vm, bench)] = min(best[(vm, bench)], us)
print(f"\n{'bench':10} {'MACDART ms':>10} {'Cog ms':>8} {'ratio':>7}  verdict")
print("-" * 52)
for b in order:
    mv, cg = best[('macdart', b)], best[('cog', b)]
    if mv == float('inf') or cg == float('inf'):
        print(f"{b:10} {'—':>10} {'—':>8}   (missing)"); continue
    r = mv / cg
    verdict = (f"MACDART {cg/mv:.2f}x faster" if r < 0.97 else
               f"Cog {r:.2f}x faster"          if r > 1.03 else "parity")
    print(f"{b:10} {mv/1000:>10.1f} {cg/1000:>8.1f} {r:>7.2f}  {verdict}")
print("\n(best-of-rounds, warm = median of 6 x10-rep batches, microsecond clock)")
PY
