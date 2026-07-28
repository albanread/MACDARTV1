# MACDART vs Cog — the honest head-to-head harness

`macdart/scripts/cog-bench.sh` runs the same seven-benchmark suite under
Pharo/Cog and MACDART back-to-back, on the same machine, same workloads,
same protocol, **microsecond clock on both sides**.

This mirrors [MACVM's own harness](../../MACVM/docs/cog_bench.md) of the
same name — the sibling Strongtalk-lineage VM this project's README already
cross-references — almost line for line, for the same reason: a millisecond
clock truncates on the sub-5ms benches (sieve, deltablue) badly enough to
*invert* verdicts, a bug MACVM's own harness documents finding and fixing.
Reusing its protocol exactly means MACDART's numbers and MACVM's numbers sit
in the same table without translation.

## What's being compared, and why it's an honest comparison

The seven benchmarks — arith, fib, sieve, dict, alloc, Richards, DeltaBlue —
are the exact same workloads MACDART's own [Benchmark
Dashboard](../macdart/cocoa/workspace/demos/16_benchdash.dart) demo runs,
which are themselves ported *literally* from MACVM's Smalltalk
(`world/41a_bench_workloads.mst`), not adapted from any other language's
version — see that demo's own header for why (the well-known JS/Dart-SDK
DeltaBlue lineage turns out to diverge from MACVM's algorithm in two real
ways, so it was rejected in favour of a literal port). Every run
checksum-verifies its own result on both sides — richards `2324609297`,
deltablue `224874`, sieve `1899`, and so on — so a wrong answer can never
masquerade as a fast time, and a source of divergence between the two ports
would be caught immediately as a checksum mismatch, not a silent skew.

`macdart/scripts/cog-bench.st` is a **checked-in artifact**: generated once
from MACVM's `world/41a_bench_workloads.mst` via that repo's `mst2st.py`
translator, then committed here. This repo's harness has no runtime
dependency on MACVM's tree at all — only the Pharo/Cog *install* is
external (point `COG_DIR` at one; MACVM's own `.cog/` works, since it is
the same Pharo/Cog either way).

**The one thing this harness does differently from MACVM's own Dart
comparison**: MACVM's `scripts/dart-bench.sh` runs a *separate* Dart 1.24.3
build inside a Lima Linux VM (`limactl shell ubuntu -- ...`) — a real but
indirect comparison, one virtualization layer removed from bare metal, and
not the same binary this whole project ports. This harness runs **MACDART's
own native macOS arm64 `dart` binary directly** — no VM layer, no
translation, the actual subject of this project.

## Protocol

- Each bench is timed as **10 inner reps**; **cold** = the first 10-rep
  batch (includes JIT tier-up/compilation), **warm** = the **median of 6**
  further 10-rep batches.
- **Interleaved rounds:** each round runs Cog then MACDART back-to-back (a
  same-thermal-state pair), for `ROUNDS` rounds (default 3); the report
  takes best-of across rounds.
- **No hard core pinning, and the harness says so** — Apple Silicon exposes
  no per-core affinity; the script refuses to start above a 1-min load of
  4.0 (override `FORCE=1`), and only same-round pairs are meaningful.
- Every scoreboard is **commit-stamped**, for the same reason MACVM's own
  harness learned to do this: a commit landing mid-comparison from a
  parallel session makes an otherwise-inexplicable delta perfectly
  explicable — see MACVM's own history of exactly this happening.

## Running it

```sh
cd macdart
ninja -C build-release dart      # if not already built
COG_DIR=/path/to/cog ROUNDS=3 ./scripts/cog-bench.sh
```

## Scoreboard (first run, M-series, best of 3 rounds)

```
load=2.15  rounds=3  commit=5a7e792+dirty  (microsecond clock, no hard pinning — Apple Silicon)
```

| bench     | MACDART ms | Cog ms | ratio | verdict               |
|-----------|-----------:|-------:|------:|------------------------|
| arith     |        7.3 |   51.1 |  0.14 | **MACDART 7.00x**      |
| fib       |       62.7 |  181.4 |  0.35 | **MACDART 2.89x**      |
| sieve     |        0.6 |    3.6 |  0.18 | **MACDART 5.65x**      |
| dict      |        2.1 |   12.3 |  0.17 | **MACDART 5.96x**      |
| alloc     |        5.0 |   14.4 |  0.35 | **MACDART 2.90x**      |
| richards  |        3.7 |   22.1 |  0.17 | **MACDART 6.01x**      |
| deltablue |        1.4 |    3.5 |  0.40 | **MACDART 2.51x**      |

(warm = median of 6 x10-rep batches, microsecond clock, interleaved
same-thermal-state rounds, all checksums held on every round.)

## What this says

**MACDART wins all seven benchmarks against Cog**, by 2.51x (deltablue) to
7.00x (arith) — and every margin here meets or exceeds MACVM's own
best-ever recorded margins against the same Cog/Pharo build (MACVM's best
scoreboard: 1.33x–4.29x; see MACVM's `docs/cog_bench.md`). That is not a
coincidence, and it cross-validates both harnesses against each other:

MACVM separately ran a three-way (MACVM vs Cog vs a **2017 Dart 1.24.3
build under Lima/Linux ARM64**, not this native macOS binary) and found
**Dart beating MACVM** on six of the seven benchmarks — richards 3.36x,
arith 1.81x, sieve 2.48x, dict 1.28x, alloc 2.22x, fib 1.77x — with
**deltablue the one row MACVM won against Dart**, by 1.37x. Since MACVM
already beats Cog outright, "Dart beats MACVM" and "MACVM beats Cog"
compound multiplicatively into "Dart beats Cog by a larger margin still" —
exactly the shape of this table. And **deltablue is, again, Dart's
narrowest margin here** (2.51x, the smallest of the seven) — the same
qualitative weak point MACVM's independent measurement found, reproduced
by a completely different harness on a different day. Two independent
measurements agreeing on which benchmark is relatively hardest for this
VM's dispatch machinery is a meaningfully stronger signal than either
alone.

**The one number this table cannot be directly reconciled against**:
MACVM's own Dart column is a *Linux-under-Lima* build, one virtualization
layer removed from bare metal, while this table's MACDART column is the
native macOS arm64 binary with no VM layer at all — so the two "Dart"
numbers are not the same measurement, and a naive transitive division
(Cog÷MACVM_vs_Cog×MACVM_vs_Dart) will not reproduce this table exactly.
The gap is in the direction you'd expect (native is faster than
Lima-hosted), which is itself a reasonable, if informal, sanity check.

**What it says about this port specifically**: a 2017 VM design, ported to
run its JIT on hardware it was never built to target, clears every one of
these seven classic benchmarks faster than a mature, actively-developed
production Smalltalk JIT — arith (a tight numeric loop, no polymorphism)
by 7x, and even the hardest case for this VM's dispatch (deltablue's
heavy constraint-graph polymorphism) by a comfortable 2.5x.

## Under the hood — three investigations

These came from reading the actual optimized ARM64 the JIT emits
(`dart --disassemble-optimized --code-comments --print-flow-graph-filter=<method>`)
and A/B-ing compiler flags. They explain *why* the margins are what they are —
and correct one of them.

### Richards' margin is ~14% inflated by a port artifact

The `richards` row overstates Dart's advantage. Richards is the canonical
*polymorphic-dispatch* benchmark, but `demos/richards.dart` folds the four
task types into one class with a `switch` on an integer tag, where Cog (and
MACVM's port) use four subclasses overriding `processWork`. Same checksum,
different mechanism — and with a single implementation, Dart's Class
Hierarchy Analysis devirtualizes the call to a direct `StaticCall` and inlines
the body. A faithful four-subclass port, timed in the same process, runs ~14%
slower (3.60 → 4.10 ms warm), so the honest figure is **~5.3x vs Cog, not
6.01x**. (The switch port is kept deliberately; this records the caveat.)

Even the faithful version is ~5.3x faster than Cog, and that is the real
story: Dart's optimizer inlines across method boundaries (`processWork →
queuePacket → findTask`, three deep) and uses type feedback to inline the
hottest receiver class behind a deopt guard, compiling the rest as a
compile-time class-id branch chain (`PolymorphicInstanceCall`). Cog is a
template JIT with polymorphic inline caches and, in default Pharo, no adaptive
method inlining — so each of Richards' many tiny methods stays a real send.

### Why DeltaBlue is the narrowest margin (2.51x)

DeltaBlue is the most dispatch-, allocation-, and pointer-chasing-bound
benchmark, with almost no arithmetic to inline (its hot `execute` bodies are
field copies reached *through* a virtual call). Two measurements pin it down:

- **Dispatch-bound**: running with `--no_polymorphic_with_deopt` costs
  **2.63x** (1.38 → 3.62 ms warm) — a benchmark whose runtime more than halves
  when you pessimize dispatch is spending most of its time dispatching. With
  the flag on (default) the hot `Plan.execute` loop inlines the constraint
  body behind a `CheckClass` deopt guard; with it off, the same site is a real
  `PolymorphicInstanceCall` through the IC dispatch stub, every iteration.
- **Allocation-bound**: 12 GC scavenges per suite run, vs **0** for arith and
  richards.

Those are exactly the costs a mature Smalltalk PIC JIT (Cog) was built to
handle, so its gap to Dart shrinks to the suite minimum — and DeltaBlue is the
one benchmark MACVM (with its poly-dispatch `PolyCmpFuse` work) actually beats
Dart on. The same property, three ways: it's why DeltaBlue crashed the stock
arm64 build hardest, why it's Dart's thinnest Cog margin, and why it's MACVM's
one win.

### Native vs Lima — a direct payoff of the port's own patch

Against the **2017 Dart 1.24.3 build under Lima/Linux ARM64** (the column
MACVM's three-way used), native MACDART is only ~1.1x faster on six benches —
but **3.77x** on DeltaBlue. That gap is not virtualization; it decomposes as
**2.63x** (the flag above) **× 1.4x** (Lima env/build). The stock 2017 arm64
build **SIGILLs** on DeltaBlue's deopt-guarded dispatch (reproduced: inner
exit 132), so it is *forced* to run `--no_polymorphic_with_deopt` and eat the
2.63x. The crashing instruction is the deoptimization stub's
`str SP, [SP, #-8]!` — **patch #2 of this very port** (`stub_code_arm64.cc`,
the SP-push special-case). So DeltaBlue's native-vs-Lima gap is a measured
payoff of one of the three port fixes, on the benchmark that leans on the
deopt path hardest. (Richards trips the *opposite* corner — it needs
poly-deopt *on* — so the stock build runs it full-strength; the port fixed
both.)

### VM build flags: -O3 + ThinLTO + apple-m1

The Release build now defaults to `-O3 -flto=thin -mcpu=apple-m1` (it was
silently `-O2` — an explicit flag overriding CMake's Release `-O3`; see
`macdart/CMakeLists.txt`). Interleaved best-of-3 vs the old binary: the
allocation/runtime-bound benches gain ~4-5% warm (alloc +4.6%, deltablue
+5.0%), dict +1.4%, and the pure-compute benches (arith/fib/sieve/richards)
are unchanged — because the JIT emits identical machine code regardless of how
the VM binary is compiled, so only the C++ runtime paths (allocation, GC,
write barriers) get faster. A third, independent confirmation that DeltaBlue
and alloc are runtime-bound.
