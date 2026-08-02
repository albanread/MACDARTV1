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

## Scoreboard (2026-08-02, M-series, best of 7 rounds — current)

The three-way suite (MACDART, MACVM, and Cog), best-of-7 interleaved rounds,
30 warmup iterations + 41 single-workload microsecond samples per bench, JIT hot
on every VM — µs per iteration, warm (lower is better):

| bench     | MACDART | Cog (Pharo 13) | MACVM | noise |
|-----------|--------:|------:|------:|------:|
| arith     | **715** |  5224 |  1411 | 1% |
| fib       | **6935** | 18726 |  9034 | 1% |
| sieve     |     196 |   362 | **180** | 2% |
| dict      |     457 |  1024 | **255** | 4% |
| alloc     | **384** |   701 |   587 | 3% |
| richards  | **628** |  2223 |  1087 | 1% |
| deltablue |     300 |   280 | **150** | 3% |

## What this says

**MACDART's Smalltalk beats Cog — the production Squeak/Pharo JIT — on six of the
seven** (arith by 7.5×, richards by 3.5×, fib 2.7×, dict 2.1×, sieve 1.8×, alloc
1.7×) **and ties the seventh**: deltablue at 300 vs 280 is a 7% difference against
3% measurement noise — a statistical tie, not a win for either. Cog is not
meaningfully ahead of MACDART anywhere in the suite.

Against **MACVM** (the sibling Rust VM running the *same* Smalltalk) it remains a
genuine 4–3 split: MACDART wins the compute/dispatch-bound benches (arith, fib,
alloc, richards), MACVM the allocation-bound ones (sieve, dict, deltablue).
MACVM's columns moved between the previous stamp and this one — its own
register-allocator arc took richards 1440 → 1087 and fib 10790 → 9034 — so
MACDART's compute lead narrowed from 2.3× to 1.7× on richards without anything
changing on this side. These are two moving targets, measured together.

**The deltablue arc, 1271 → 300 µs (−76%).** This was MACDART's one real weakness —
4.6× behind Cog, 7× behind MACVM. A twelve-commit **front-end** arc closed it with
**no VM source changed**: the cost was never the compiler or the garbage collector
(measured: zero scavenges per run, and forcing full inlining moved nothing, then
later *hurt*). It was the Smalltalk dispatch layer — `"<Type> ext"` holder classes
re-resolved **by name string on every send** to a native receiver, plus per-send
cache-key construction, plus symbol literals re-interned per evaluation. Fixes:
`(isolate, cid, selector)` dispatch caches (positive *and* negative), selector
identity keys, compile-time symbol interning, helper fast-paths, per-site block
lowering. The generalized laws are in
[`dart_engine_laws.md`](dart_engine_laws.md).

What remains is structural, not tuning: MACVM's generational scavenger beats a
boxing runtime on allocation churn, which is why it still holds sieve, dict, and
deltablue. Closing *that* would mean changing how Smalltalk objects are
represented, not how they are dispatched.

> **A correction, on the record.** An earlier version of this doc claimed MACDART
> "wins all seven against Cog" and, via a transitive argument, that Dart beat MACVM
> on six of seven. Both were wrong. The MACVM figures behind that argument were a
> Linux-under-Lima Dart build in one place and — the real error — **MACVM running
> with its JIT switched off** (the harness omitted `MACVM_JIT=threshold`, leaving
> MACVM in its interpreter, ~50–170× slower). With every VM JIT-hot under one honest
> protocol, MACVM is *ahead of Cog on all seven* and trades wins with MACDART 4–3.
> The canonical three-way harness is now MACVM's `scripts/xvm-bench.sh`; this repo's
> `macdart/scripts/cog-bench.sh` remains the MACDART-vs-Cog two-way.

## Under the hood — three investigations

> **Note:** the specific margins in this section (e.g. richards "6.01×", and
> DeltaBlue framed as a *winning* margin) reference the earlier two-way run that
> has since been superseded — see the correction above; under the fair three-way
> protocol DeltaBlue is a *loss* to both Cog and MACVM. The *qualitative* findings
> below hold and are sharper now: which benchmarks are allocation- vs
> dispatch-bound, the richards switch-vs-subclass port artifact, and the DeltaBlue
> SP-patch payoff.

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
