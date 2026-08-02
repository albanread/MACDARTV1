# Dart Engine Laws — making a hosted language fast on the frozen 1.24.3 VM

> **Companion to [`dart-vm-frontend-guide.md`](dart-vm-frontend-guide.md).** The
> guide tells you how to emit *correct* IL the shared optimizer will accept.
> This document tells you how to make it *fast* — the hard-won laws for getting
> a hosted language (here, Smalltalk via `macdart/st/`) to native-Dart-class
> speed **without touching the VM**.

The governing constraint: **the VM is inherited and frozen.** Every lever is in
the front end — the IL builder (`st_flow_graph_builder.cc`), the runtime helpers
(`cocoa/cocoa.dart`), the loader (`st_loader.cc`), the native dispatch layer
(`st_natives.cc`, which is *ours*, not the VM), and the world source. Nothing
below changes a line of `sdk/runtime/vm/`.

Every law here was bought with a measurement and locked behind two gates that
**must both stay green** for any change to land:

1. **Correctness** — `st/test/run_all.sh` (world boot, conformance, feature
   suites, game+app wire, richards/deltablue checksums).
2. **Speed** — `MACVM/scripts/xvm-bench.sh` (3-VM µs harness, best-of-rounds,
   quiet-machine gated).

The numbers cited are from the 2026-08-02 performance arc (commits `f9008c5` …
`d00ed48`). Net result, review-start → arc-end (µs/iter, warm, best-of):
sieve 410→195, dict 599→461, richards 799→631, **deltablue 1271→288**,
alloc 458→399 — **6 of 7 benches ahead of Cog** (the production Squeak/Pharo
JIT) **and the seventh a statistical tie**: deltablue closed from a 4.6× loss
to 288 vs Cog's 278 (within the harness's 4% noise). Cog is never faster than
MACDART's Smalltalk beyond noise on any of the seven.

---

## Law 0 — Profile before you optimize. The flow graph lies by omission.

The single most expensive mistake of the arc was trusting the optimized flow
graph. It showed a call-heavy cascade, so three changes chased inlining and
allocation — and moved the target bench by noise. The **actual** DeltaBlue cost
was ~⅓ of CPU spent in *runtime class-name resolution* inside a native helper —
a cost that **does not appear in `--print-flow-graph` at all**, because it lives
below the IL, in the C++ dispatch layer.

Only an OS-level sampler found it. The order of diagnosis is therefore:

1. **`sample <pid>`** on a long hot spin (≥10 s of one workload) — finds
   native-layer and runtime costs the IL hides. *Start here for a hosted
   language*, because your dispatch/marshalling helpers are C++.
2. **`--trace-inlining`** — per-call inline decisions with the exact bailout
   reason and the callee's size / call-site count.
3. **`--print-flow-graph-optimized --print-flow-graph-filter=<mangled_sel>`** —
   read what actually inlined and what stayed a call, at the IL level.
4. **A forced-inline experiment** (`--inlining_size_threshold=250`) — if forcing
   everything to inline *doesn't* move the bench, inlining is not the lever and
   no amount of front-end inlining work (devirtualization included) will help.
   This one experiment killed a planned CHA machine before a line was written.

> **Corollary.** For a hosted language the hot cost is very often in *your*
> dispatch/marshalling C++, not in the emitted IL. Sample first.

---

## 1. Dispatch laws

### 1.1 A shared helper "funnel" poisons specialization image-wide.

Routing many call sites for a selector through one shared static helper
(`stAt1`, `stAddU`, `stValueN`, …) means the helper's slow-path polymorphic
site aggregates **every receiver in the whole image** into one `ICData`. The
optimizer can then never specialize any individual site, and the shared
slow-site is permanently megamorphic.

- **Evidence.** `OrderedCollection>>add:` through the shared `stAddU` funnel
  measured **57 ns**; the *identical* body reached as a plain per-site
  `InstanceCall` (via `addLast:`) measured **15 ns** (commit `fe620eb`).
- **Fix.** Emit a per-site `InstanceCall` (or a per-site class-id split, §1.2)
  and keep the funnel only as the genuine slow-path / reflective fallback.
  `kHelperRewrites` in [`st_flow_graph_builder.cc`](../macdart/st/st_flow_graph_builder.cc)
  is the funnel table; removing a hot selector from it is often a win.

### 1.2 Per-site class-id split beats a shared funnel for the block family.

`value`…`value:value:value:value:` now lower per site to
`LoadClassId == kClosureCid ? ClosureCall : stValueN`. The funnel's
`r is Function` `InstanceOf` was an **escaping use for allocation sinking**, and
its shared `ICData` dragged every value-receiver in the image into every inlined
copy. Per-site, the class test constant-folds when the closure's creation is
visible, and the block sinks (commit `44d8909`).

> **Trap (cost the arc a SIGBUS the battery caught in minutes).**
> `ClosureCallInstr`'s input 0 is the closure's **Function**, loaded from
> `Closure::function_offset()` — *not* the closure object. Passing the closure
> makes codegen read `Function::code_offset()` off a `_Closure` and `blr` into
> garbage. Mirror the parser's `BuildClosureCall` (`kernel_to_il.cc`) exactly.

### 1.3 Cache runtime dispatch that re-resolves per call. (The biggest lever.)

Any native helper that resolves a target **by name or by chain-walk on every
call** is a memoization opportunity keyed on `(isolate, cid, selector-symbol)`.
Two landed instances:

- **`ST_eq`** — `=` on an ST object used to end in `stSend(a,'=',[b])`: a fresh
  args `List`, a per-call `MangleSelector` + `Symbols::New`, an **uncached**
  super-chain walk, and an *old-space* args `Array`. Cached: **158 ns → 73 ns**
  (commit `5268e1e`).
- **`ST_extSendTry`** — the emulation tax (§4.1). Symbol/String/Char/Integer
  aren't native-extensible Dart classes, so their ST methods live in
  `"<Type> ext"` holder classes, and every native-receiver send re-resolved the
  holder **by name** (`FindStClassByName` = a library scan + `ToCString` per
  candidate). `between:and:` on a Smi, from `OrderedCollection>>at:`'s bounds
  check, fired **~330× per iteration** (~30 000× over a benchmark process run),
  each a full scan. Cached on
  `(isolate, cid, sel)`: **deltablue 1132 → 729 µs, Cog gap 4.1× → 2.6×** — the
  single biggest move of the arc (commit `7d3a92e`).

**The cache pattern** (see [`st_natives.cc`](../macdart/st/st_natives.cc)):

- Key on `(Isolate*, cid, RawString* selector)`. The selector symbol is
  canonical (`Symbols::New` interns), so its `RawString*` is a **stable identity
  key** — no string compare.
- Store the raw `RawFunction*`. Safe **only** because of §5.1 (old space never
  moves). Store nothing that can move.
- **Flush on every load and every hot reload** — both can replace a class's
  methods. `st::ClearSendCache()` is called from `Loader::Load`
  ([`st_loader.cc`](../macdart/st/st_loader.cc)) and `Workspace_reload`. A weak
  no-op definition of `ClearSendCache` keeps loader-only binaries linking (§5.3).
- **Cache only what the key faithfully discriminates** — see the boolean guard,
  §4.2.

**Cache the misses too, when the miss is deterministic and its fallback is hot.**
A *hit-only* class-side cache on `STClassSendCommon` was **completely inert** —
because the hot residual was `basicNew` on inherited constraint factories
(`BinaryConstraint>>var:var:strength:` sent to an `EqualityConstraint`, so the
guarded-alloc slow path lands in the native with `thisCls` a subclass).
`basicNew` has *no* class-side method, so it always **misses** the lookup and
falls to `Instance::New` — and a hit-only cache never stored the miss, so it
re-scanned `FindStClassByName` ~5000×/class/run forever. Caching the **negative
result** (a null `Function`, meaning "no static method, take the fallback")
skipped the scan: **deltablue 729 → 537 µs** (commit `9438e4a`). The
resolution `(cls, sel) → Function-or-nothing` is deterministic within a load, so
the negative entry is as safe as a positive one and is flushed by the same
`ClearSendCache`. Watch for this whenever a hot dispatch *fails* its lookup and
falls to a default — the failing scan is pure waste and only a negative cache
removes it.

### 1.4 Comparisons cannot naively become `InstanceCall`s.

Dart 1's `int operator <(num other)` is `return other > this;` — a **reversal**.
The corpus `Fraction>>` reverses back (`^aNumber < self`), so an int-receiver
vs. an ST-numeric compare forms an infinite 2-cycle → stack overflow. And
`int.>` calls `other._greaterThanFromInteger(this)` → `NoSuchMethod` DNU on an
ST numeric. The safe shape is a helper with a **num–num fast path first**, the
cross-type work behind it (`stLess` in [`cocoa.dart`](../macdart/cocoa/cocoa.dart)),
and the same for the inlined loop guards (`to:do:`/`timesRepeat:` already emit
`InstanceCall(kLTE/kADD)` directly on smis, which is safe).

---

## 2. Inlining laws

### 2.1 The inline budget is real: hot helpers must be tiny, with a rare tail.

The optimizer's `ShouldWeInline` (`flow_graph_inliner.cc`) bails when a callee's
`instruction_count > inlining_callee_size_threshold` (80), and otherwise
auto-inlines only when the body is under `inlining_size_threshold` **or** has
`call_sites <= 1`. A medium body called generically sits in the dead zone and
does **not** inline.

- **Evidence.** A first cut merely *reordered* `stLess`'s type-test ladder; the
  bigger body fell out of the budget and **fib regressed 2.7×** on an
  out-of-line compare per recursion.
- **Fix.** Keep the hot function to **one type test + one branch**, with the
  rare cases in a split-out `_xxxRare` tail (`stAt1`/`stAtPut1`/`stDo`/`stLess`
  in `cocoa.dart`, commit `f9008c5`). Tiny fast function → always inlined; fib
  fully recovered.

### 2.2 Ladder order = measured receiver frequency.

Order the type tests in a dispatch helper by how often each receiver actually
occurs. `stAt1`/`stAtPut1`/`stDo` test `List` first (Array/OC backing dominates
every benchmark; sieve is nothing else). **sieve 410 → 191 µs** — flipping a Cog
*loss* into a 1.9× win (commit `f9008c5`).

### 2.3 The inliner strips nothing; the *parser* declines to attach.

The 1.24 inliner never removes a callee's function-entry `CheckStackOverflow`.
The stock parser simply **doesn't attach one when building for inlining** —
`flow_graph_builder.cc:3901` *constructs* it unconditionally (its ctor consumes
a deopt id, and deopt ids must match between inlined and standalone builds of a
method) but attaches it only when `!IsInlining()`.

Our builder attached unconditionally, so every spliced ST body kept its entry
check — an optimized `satisfy_` carried **nine**. `EntryStackCheck()` mirrors the
parser: construct always, attach only when `exit_collector_ == NULL` (the builder
already knows it is inlining). **richards −14%** (commit `57939de`). **Loop**
checks are untouched — a loop needs its interrupt/OSR point inlined or not.

### 2.4 OSR is dead for hosted loops by construction — know it before you chase it.

Our loop `CheckStackOverflow`s are emitted with `loop_depth = 0`, so
`in_loop()` is false, so the unoptimized backend **never records a `kOsrEntry`
descriptor** (`CheckStackOverflowSlowPath`, `intermediate_language_arm64.cc`).
On-stack replacement therefore cannot rescue a one-shot hosted loop — the
long-standing "our OSR never fires" mystery, explained. Enabling it needs honest
loop depths **and** the parser's OSR-prune step
(`flow_graph_builder.cc:4412-4432`) mirrored in `st::BuildGraph`. Payoff is
*cold* loops only — not warm benches. Documented, deferred.

---

## 3. Allocation laws

### 3.1 Never hand a hot Dart-1 helper a closure argument.

`Map.putIfAbsent(k, () => …)` allocates a **Context + Closure per call, even on
the hit path where the thunk never runs.** `stSymbol` used `putIfAbsent`; every
`#sym` literal in a hot method paid two heap objects. Reading the optimized
`satisfy_` graph showed **three of its four** Context+Closure pairs were this
thunk (inlined from `stSymbol`), not ST blocks. Thunk-free `stSymbol` (plain
lookup/store) → **deltablue −8%**, its first real movement (commit `b33286a`).
The same caution applies to `firstWhere`, `sort` comparators, any closure-taking
core method on a hot path.

### 3.2 A symbol is a unique interned object — resolve the literal ONCE, at compile time.

A symbol literal must lower to *the* canonical interned object, resolved once
and referenced directly — identity IS its meaning (`#foo == #foo`,
`#foo == 'foo' asSymbol`). `#foo` used to lower to `Constant("foo") +
StaticCall(stSymbol)`, re-discovering the object **by spelling on every
evaluation** — not how symbols work. Now the builder resolves it at compile time
(`st::InternStSymbol`) and bakes `Constant(<the StSymbol>)`; the runtime
`stSymbol`/`asSymbol` route through the same authority, so a compiled literal and
a runtime-computed symbol are the same object (commit `43d520b`).

Two requirements make the bake sound: the interned object is **old-space** (so
the `Constant` is stable, §5.1) and **persistent-rooted** (so the cache pointer
and the baked constant survive GC regardless of what references them). And
because `dart:cocoa` is compiled lazily, `Class::EnsureIsFinalized` is required
before its fields are materializable — a bare `LookupClass` hands back a class
with an empty `fields()`.

Expected bench-neutral (the optimizer hoists the lookup out of *inlined* loops);
it was a **26% DeltaBlue win** instead — the non-inlined cascade arms (§2.1's
`inputsDo_`, `execute`, `chooseMethod_`) do `direction == #forward` per call, and
the lookup can't hoist across an un-inlined call boundary. Baking removed it:
deltablue 537→399. `$c` and `#(…)` are the same shape and could be baked the same
way; neither appears in DeltaBlue.

---

## 4. Correctness invariants (never trade these for speed)

### 4.1 The Symbol/String/Char emulation is a correctness feature, not a wart.

Dart's Symbol/String/Character are a *different shape* than Strongtalk's. They
are emulated (`StSymbol`/`StChar` distinct classes; mutable-String hybrid; ext
holders) precisely so `#foo = 'foo'` → false, `$a = 'a'` → false, `$a == $a`
→ true all hold. The dispatch tax this imposes (§1.3) is real, but the fix is to
**memoize the resolution, never to flatten the representation.** The ext-cache
changes zero observable behavior — the green symbol/char/string-heavy
conformance and feature suites are the proof.

### 4.2 Cache only what the key faithfully discriminates. (The boolean guard.)

`ExtHolderCandidates` is a function of receiver *type* — **except booleans**:
`true` and `false` share `kBoolCid` but resolve to different holders
(`True ext` vs `False ext`), because the candidate list splits on the *value*.
A `(cid, …)` key would misdispatch them, so **booleans are never cached** — they
always take the full scan. Every other native type's holder list is a faithful
function of its cid. Before caching any dispatch, prove the key discriminates
every case the resolver does.

---

## 5. VM invariants the front end may rely on

These are properties of the frozen 1.24.3 VM that make the caches above sound.
If you ever un-freeze the VM, re-verify them.

### 5.1 Old space never moves.

1.24 is mark-sweep with **no compactor**, so a `RawFunction*`/`RawClass*`/
`RawString*` in old space is stable across GC. This is the whole license for the
raw-pointer dispatch caches (§1.3). Never cache a *new-space* pointer this way.

### 5.2 Symbols are canonical and retained.

`Symbols::New` returns the one canonical instance for a string, kept for the
isolate's life. So an interned selector's `RawString*` is a stable identity key
(pointer equality, no string compare) — used directly as a cache-key component.

### 5.3 The loader links everywhere; the natives link only into `dart_cocoa`.

`st_loader.cc` is pulled into every binary; `st_natives.cc` only into the ones
that link `dart_cocoa`. A symbol the loader references but the natives define
needs a **weak no-op default** in the loader TU so loader-only binaries link,
with the strong definition overriding it where ST actually runs. Same pattern as
`macdart_browser_stubs`. Verify `build-release dart` **and** `dartui` both link
after any such change.

> **Trap that cost two debugging cycles (worth its own line).** `st_natives.cc`
> is inside `namespace dart::bin`. A helper written as `namespace st { … }`
> *inside* that file becomes `dart::bin::st::foo`, which does **not** match the
> `::st::foo` the header declares and callers use — so the **weak `::st` stub
> silently wins** and the real definition is dead code. This bit both
> `InternStSymbol` (every symbol came back nil) and, latently, `ClearSendCache`
> (its flush was a no-op for weeks — caches never cleared on reload). Fixes:
> define such helpers in `st_loader.cc` (whose `namespace st` is already
> top-level), or close/reopen `dart::bin` around a genuine `::st` definition.
> **Confirm with `nm`:** the intended definition must show as `T __ZN2st…`
> (strong, top-level `st`), not `__ZN4dart3bin2st…`.

---

## 6. Methodology & harness traps

- **Both gates, every change.** A speed win that reddens the battery is not a
  win. A correctness-neutral refactor still runs the bench (the value-family
  change was structurally right but bench-neutral — say so).
- **The tiering trap in cross-VM probes.** Block-based `Bench`-style probes at
  ~200 reps run **unoptimized** on the Dart VM (closures tier at ~30 000 calls;
  MACVM tiers at 20). A probe measured 25 µs/op where a 2 M-rep hot loop
  measured 4 µs/op for the same work. **Cross-VM micro-probes must loop
  ≥100 000 inside one hot function**, or the Dart side is interpreter-class and
  the comparison is meaningless.
- **Bench wobble ≠ signal.** `dict`/`richards` wobble ±4 % across
  *identical-code* gate runs. Before believing a suite delta at that scale, do
  the **mechanism check**: does the benchmark even contain the selector you
  touched? If not, the move is noise. (This is how the value-family and ST_eq
  changes were correctly read as bench-neutral.)
- **JIT must be on for the baseline.** `MACVM_JIT=threshold=N` or you are timing
  the interpreter; the stock `run` path is interpreted and silently made an
  earlier scoreboard meaningless.
- **One lever per commit.** Keeps gate attribution clean — you always know which
  change moved which number, and which was noise.

---

## 7. Diagnostic toolbox (copy-paste recipes)

```bash
# 1. Sample the native layer (finds costs the IL hides — START HERE).
build-st-rel/dart --with-st st/test/run_mst.dart spin.mst &   # spin.mst = a ≥10s hot loop
sample $! 8 -file prof.txt; wait
awk '/Sort by top of stack/{f=1} f' prof.txt | grep -vE '\?\?\?|cvwait|kevent' | head

# 2. Why did the inliner decline this callee?
build-st-rel/dart --with-st --trace-inlining … | grep -A2 'Inlining calls in <Class>.<method>_'
#   → "Bailout: heuristics with code size: N, call sites: M"  ← the exact gate

# 3. Read the optimized IL of one method (what inlined / stayed a call).
build-st-rel/dart --with-st --print-flow-graph-optimized \
    --print-flow-graph-filter=satisfy_ st/test/run_mst.dart spin.mst

# 4. Is inlining even the lever? Force it and re-measure.
build-st-rel/dart --with-st --inlining_size_threshold=250 --inlining_callee_size_threshold=250 …
#   flat under forced inlining ⇒ inlining is NOT the bottleneck; stop here.

# 5. Name a hot dispatch combo (one-shot, env-gated, revert before commit).
#   Add to the hot native, keyed by receiver-class>>selector, print each 5000th:
#     if (getenv("ST_TRACE")) { static std::map<std::string,long> seen; … }

# 6. Micro-µs driver — 30 warm + N timed, median (≥100k-rep inner loop!).
```

---

## 8. The arc, as a ledger

| # | commit | change | law(s) | gate result |
|---|--------|--------|--------|-------------|
| 1 | `f9008c5` | fast/rare splits, ladder reorder, `~=`→1 call | 2.1, 2.2, 1.1 | sieve 410→191 (Cog loss→win), dict −23%, fib recovered |
| 2 | `fe620eb` | `add:` out of the funnel | 1.1 | dict 462→428; proved funnel = 3.9× |
| 3 | `5268e1e` | `ST_eq` cached dispatch | 1.3, 5.1 | fraction-eq 158→73 ns |
| 4 | `57939de` | skip entry checks when inlining | 2.3 | richards −14% (satisfy_ 9 checks→1) |
| 5 | `b33286a` | thunk-free `stSymbol` | 3.1 | deltablue −8% (first real move) |
| 6 | `44d8909` | per-site value-family `ClosureCall` | 1.2 | bench-neutral, poison removed (honest) |
| 7 | `7d3a92e` | ext-holder dispatch cache | 1.3, 4.2, 5.1 | **deltablue 1132→729, Cog 4.1×→2.6×** |
| 8 | `9438e4a` | class-side dispatch cache (negative) | 1.3 | **deltablue 729→537, Cog 2.6×→1.9×** |
| 9 | `43d520b` | compile-time symbol interning | 3.2, 5.1–5.3 | **deltablue 537→399, Cog 1.9×→1.4×** |
| — | `68a7add` | fix `ClearSendCache` namespace (§5.3 trap) | 5.3 | correctness: caches now flush on reload |
| 10 | `d00ed48` | native-send tax: `between:and:` helper + selector-identity cache keys + kNew args | 1.1, 1.3, 0 | **deltablue 399→288 — statistical tie with Cog (278)** |

Three levers proven **dead ends** by measurement, saving the work of building
them: poly-fan devirtualization (§0 forced-inline experiment: ~3 %), raising
inliner budgets (deltablue unchanged), and — at the 399 µs baseline — forcing
MORE inlining, which by then **hurt** (+8%): past a point, splicing everything
costs more in icache/register pressure than the calls it removes. After commit
10 the profile is genuinely flat: the top named C++ frames are single-digit
samples and the time is in generated code — the real boxing floor, reached only
after THREE successive "allocation-bound" diagnoses each turned out to be one
more layer of removable dispatch/marshalling tax. Remaining sketched-not-built
cold-path items: the class-side selector-identity key (STClassSendCommon still
builds its key per call), CHA-guarded inline allocation for inherited factories,
OSR for hosted loops (§2.4), and baking `$c` / `#(…)` literals like symbols.

---

_Last updated: 2026-08-02, after the DeltaBlue dispatch-cache arc. Keep this file
honest — every law here is falsifiable with `xvm-bench` and `sample`, and a law
that stops reproducing should be struck, not defended._
