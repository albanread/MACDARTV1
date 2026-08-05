# The Smalltalk A/B benchmark — `.mst` on the Dart VM vs MACVM

The payoff measurement for [`ST_PLAN.md`](../../../ST_PLAN.md): the **same
Smalltalk source, byte for byte** ([`stbench.mst`](stbench.mst)), run three ways —

1. **MACDART‑ST** — JIT-compiled by the MACDART (Dart 1.24.3) VM through the
   `.mst` front-end (`stLoad` + `stNew`/`stSend`);
2. **native Dart** — the line-for-line mirror (`DBench` in
   [`run_macdart.dart`](run_macdart.dart)) on the *same* VM: the ST-front-end tax;
3. **MACVM** — the same file on MACVM itself (`macvm run`), the from-scratch
   Strongtalk-style research VM the `.mst` dialect comes from.

Run it:

```bash
bash macdart/st/bench/run.sh
```

(Uses `macdart/build-st-rel/` — a Release build with the ST front-end — and,
if present, `~/claudeprojects/MACVM/target/release/macvm`.)

## Results (2026-07-29, Apple Silicon, both VMs Release builds, best of 5, warmed)

| bench | what it stresses | MACDART‑ST | native Dart | MACVM | ST vs MACVM |
|---|---|---:|---:|---:|---:|
| `fib: 30` | ~2.7M dynamic sends (recursion) | 5 ms | 2 ms | 262 ms | **52×** |
| `sumTo: 50M` | Smi loop arithmetic | 22 ms | 22 ms | 5,066 ms | **230×** |
| `blocks: 2M` | 2M closure creations+calls | 4 ms | <1 ms | 331 ms | **83×** |
| `alloc: 2M` | 2M object allocations + ivar writes | 5 ms | 3 ms | 358 ms | **72×** |

## Reading the numbers

**The lineage thesis, measured.** The Dart VM is the production descendant of
Strongtalk (Strongtalk → HotSpot → V8 → Dart); MACVM is a from-scratch research
VM built to *understand* that lineage. Hosting MACVM's own Smalltalk dialect on
the descendant runs it **50–230× faster** — adaptive optimization, inline
caches, an SSA optimizer, and a generational GC doing exactly what that family
of VMs was invented to do. (This is not a knock on MACVM: it is a scaffold built
for insight, not throughput — its own `--help` says so. That contrast is the
point of the experiment.)

**The ST-front-end tax on MACDART is small to zero.**
- `sumTo:` is **1.00×** — the `.mst` front-end emits the *same IL* the Dart
  parser emits, so a loop is literally the same optimized machine code.
- `fib:` is 2.5× native Dart: ST methods are currently marked non-inlinable
  (the inliner would misroute an ST callee to the kernel builder —
  `st_loader.cc`), so Dart's fib benefits from inlining ST's cannot. Threading
  an `InlineExitCollector` through `st::BuildGraph` is the known future fix.
- `blocks:` at 2 ns/call shows the `value:` → `InstanceCall("call")` lowering is
  *not* a slow path: after the first miss the VM installs a lazy invoke-field
  dispatcher on `_Closure` and subsequent block calls are ordinary IC hits.
  (Correctness of that path is covered by a two-closures-through-one-send-site
  test — the dispatcher reads the function out of the closure, never a cached
  wrong target.)

## Method notes

- Instance methods deliberately — every recursion/iteration step is a real
  dynamic send (InstanceCall + inline cache) on both VMs.
- Identical protocol both sides: warmup pass, then best-of-5 wall-clock ms
  (`Stopwatch` on MACDART, `Time millisecondsToRun:` on MACVM).
- The MACDART runner cross-checks every workload's *answer* against the native
  Dart mirror before timing anything.
- `STCell` is declared before `STBench` because MACVM resolves class references
  at load time; MACDART's loader accepts either order.
