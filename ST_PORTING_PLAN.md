# ST_PORTING_PLAN.md — finishing the Smalltalk world on the bilingual VM

The language core is done and fast (ST_PLAN.md sprints 0–16: closures, NLR,
exceptions, become, metaclasses, inlining, debugging, the equality
representation fix). What remains is the LONG TAIL: a partially-working world
of 280 class declarations / ~3,755 methods / 200 `<primitive:>` sites, where
"broken" hides as *silently wrong* rather than loudly failing. This plan turns
that tail into an enumerable, classified, testable work queue.

**Doctrine.** One image, two languages. Keep the Smalltalk SOURCE verbatim
wherever it runs (the world is MACVM's; drift is a cost). Fix the ENGINE when
the language is broken — never patch the corpus around an engine bug. Use the
Dart library as the world's standard-library substrate (the proven pattern:
Dictionary=Map, WriteStream→StMutableString, gc*/clock stprims). Platform C
(libc syscalls, Accelerate/vDSP) is reached through the corpus's own FFI floor
(§3a) — C++ natives are reserved for VM internals (reflection, become,
instVarAt:) and the FFI core itself. Every fix lands with the probe that
would have caught it.

**Ground truth today** (2026-07-31, primitive_coverage on build-st):

    probed 50   passed 40   FAILED 6   uncovered 68
    uncovered = 2 core (ClassMirror allClasses, LargeInteger byteAt:put:)
              + 66 platform (Accel×27, Posix×31, SystemDictionary×6, Time×2)

---

## 1. The four oracles

Correctness claims must trace to one of these, in precedence order:

1. **MACVM itself** — `~/claudeprojects/MACVM/target/release/macvm run f.mst`.
   The same .mst on both VMs, outputs diffed. THE semantic oracle for anything
   the original implements. (Its `tests/` are bytecode-golden — the *binary*
   is the oracle, not the goldens.)
2. **The world's own docstrings** — each class documents its contract
   (09_character's flyweight promise found the `$a == $a` bug; trust these).
3. **The battery** — conformance (38), primitive coverage, richards/deltablue
   exact checksums, library_bench 11/11, 86/86 load. Green is the gate.
4. **The GUI** — the browser/demos/workspace exercise paths headless never
   reaches (the `classNamed: #Symbol` regression shipped through a fully green
   battery and died on tab-open). GUI smoke is load-bearing, not optional.

A deliberate difference from MACVM goes in **DEVIATIONS.md** with a test
asserting the *deviation* (the `ok(dart)` pattern conformance already uses) —
so an accidental drift back toward MACVM is also caught.

## 2. Discovery — make every gap enumerable

**D1. Static inventory (`st_dump --audit`).** Extend the standalone dumper
(no VM deps) to emit machine-readable TSV/JSON per world file: classes,
supers, ivars, methods (side, selector, argc), `<primitive: N>` sites (bare
vs. guarded-with-fallback), and every selector SENT in method bodies. One
cross-ref pass then yields the two lists that drive everything:

- **sent-but-undefined**: selectors the corpus sends that no ST class,
  extension holder, universal helper, or bridge defines → *will dNU at
  runtime*, sorted by static send count = the missing-feature list, priced.
- **defined-but-untested**: selectors no probe exercises = the coverage debt.

**D2. Primitive census.** `primitive_coverage.dart` already inventories and
probes bare primitives ("silence is the failure mode"). Grow it until every
bare primitive on a core class is probed; platform primitives graduate to
their porting bucket (§3) rather than probes-forever.

**D3. Loud engine (the force multiplier).** Today an unwired bare
`<primitive: N>` compiles to an empty body and *answers self* (`2 sin` → 2).
Change the builder: a bare `<primitive: N>` with NO fallback statements
compiles to a catchable `STThrow("unimplemented primitive N: Cls>>sel")`;
a guarded one keeps running its fallback (ANSI semantics, unchanged).
This converts the whole class of silent-wrong bugs into loud, greppable,
enumerable errors — discovery by running the corpus, not by suspicion.
(Boot-critical stubs that trip get wired or given real fallbacks, which is
exactly the work surfacing itself.)

**D4. A/B differential runner (`st/test/ab/`).** Self-checking probe files
runnable on BOTH VMs (the bench harness already proves the dual-run pattern);
`ab.sh` runs each on macvm + macdart and diffs. Divergence = engine bug,
missing port, or a deviation to document — never ignorable.

**D5. Protocol matrix probes (`st/test/probes/`).** One probe file per class
family exercising every public selector on canonical receivers, printing
`sel expected actual` self-checking lines. This is the per-class
definition-of-done instrument (§5).

**D6. GUI smoke script (`st/test/gui_smoke.sh`).** Scripted control-plane
pass: launch, ping, `stbrowser` build, browse a class + method source, three
doits (a Fraction, a WriteStream, an equality matrix), launch one ST demo,
then grep the log for `ERR|NoSuchMethod|StSymbol`. Red on any hit. This
script, run before the last two pushes, would have caught the browser
regression automatically.

## 3. Classification — every gap gets exactly one bucket

| Bucket | Meaning | Examples (live ones) |
|---|---|---|
| **ENGINE** | builder/helper/native mislowers or misdispatches | the `=` leak (fixed); `,` on Arrays (fixed); `copy` → immutable buffer hang |
| **WIRE** | capability already exists, primitive/selector just not connected | SystemDictionary gc*/clock → existing stGc*/stMillisecondClock stprims |
| **PORT-ST** | pure Smalltalk can express it; write/keep .mst | most collection/stream/printing methods; Set `with:` |
| **FFI-VERBATIM** | corpus C bindings run unmodified on the FFI floor (§3a) | Posix syscalls, sockets/DNS/ping (61c/61d/75), **Accelerate vDSP/BLAS (61a — wanted)**, mmap clock |
| **BRIDGE-DART** | ST facade keeps the MACVM API; `<stprim:>` body → dart:cocoa helper → Dart library | Date/Time conveniences → DateTime; Random → dart:math; Files where dart:io is simply better |
| **NATIVE-C** | VM internals only | allClasses (prim 98) class-table walk; LargeInteger byteAt:put:; the FFI core natives themselves |
| **DEVIATE** | deliberate difference, documented + tested | resumable `resume:` (deferred by choice); ByteArray is a List |

Decision tree, applied per selector: *does pure ST express it against
already-working protocol?* → PORT-ST. *Is it a corpus C binding?* →
FFI-VERBATIM (the pragma + Alien floor — never one-off natives). *Is it
platform/library state where Dart's library is genuinely better?* →
BRIDGE-DART. *VM guts?* → NATIVE-C. *Wrong answers from working machinery?*
→ ENGINE. Never fix the corpus to dodge an engine bug.

### 3a. The FFI floor — MACVM's Alien, ported not redesigned

Decided 2026-07-31 (discussion): the world already contains a Strongtalk-style
Alien FFI — `Alien forAddress:size:` + 1-based `byteAt:[put:]` accessors,
`NativeBuffer` (one mmap'd page, GC-stable by construction), and the
declarative pragma `<primitive: FFI function: #name ret: #g args: #(g g ...)>`
with word-level type codes (`#g` GPR word, `#v` void, doubles for BLAS). All
marshalling intelligence (sockaddr packing, endianness, errno-as-value) is
Smalltalk library code in the corpus. We port THAT floor, not a new design:

- **Builder**: `<primitive: FFI function:ret:args:>` compiles like the
  `<stprim:>` hook — a parameterized call into the core.
- **Core natives (~4)**: `dlsym` (RTLD_DEFAULT + dlopen fallback), one
  generic word/double C-call reusing the existing AAPCS64 marshaller in
  cocoa_natives.mm (on arm64 objc_msgSend IS a C call — this is its easy
  subset), and bounds-checked peek/poke against the alien's
  [address, address+size) span.
- **Verbatim on top**: Alien / NativeBuffer / NativeFloatArray / Posix /
  Accel classes as written.
- **Explicitly NOT built**: callbacks/thunks (no corpus form; poll-model
  kqueue), struct-by-value (corpus packs bytes itself), Smalltalk-heap
  aliens (mmap pages only — the corpus's own GC-stability premise).
- **Known dependency**: blocking IO (62_ioworker) wants `Worker` (prim 220,
  unported) — scope to the kqueue/non-blocking subset first.
- **Accelerate is a first-class target, not demand-gated**: link (or dlopen)
  Accelerate.framework; vDSP FFT + BLAS dgemm probed and A/B'd; NativeFloatArray
  needs the double-width peek/poke pair. Visible payoff: an FFT/spectrogram
  demo in the demos pane and an Accel-vs-pure-ST bench row.

**Priority score** = static send count (D1) × surface weight (browser/
workspace/demos first — the user-visible image) × unblocking value (Magnitude
before everything comparable; streams before printing; the FFI floor before
the whole 61/62/75 tier). The sockets/DNS/ping/Accel tier is REAL library
surface (workspace-callable), not dead weight — it lands as FFI-VERBATIM in
M4, behind kernel truth.

## 4. Porting workflow — the per-class assembly line

1. **Inventory** the class from D1 (selectors, primitives, senders).
2. **Probe first**: write/extend its protocol-matrix file; run RED.
3. **Classify** each gap into §3 buckets (recorded in the ledger, §6).
4. **Implement** per bucket (engine fix / .mst port / cocoa.dart helper /
   native). ST source stays MACVM-shaped; facades keep MACVM selectors.
5. **A/B** the probe on MACVM where it runs there; else oracle = docstring;
   divergence → fix or DEVIATIONS.md entry.
6. **Battery + GUI smoke** green on debug AND release.
7. **Ledger update**; commit with the probe in the same commit.

**Definition of done (per class):** every public selector probed; A/B clean
or deviation documented; survives `stimport` + reboot (SQLite image); visible
and editable in the Browser tab; no bare-primitive throw reachable from it.

## 5. Testing architecture — one battery, seven tiers, one exit code

| Tier | What | Runs against |
|---|---|---|
| 0 | 86/86 parse+load, world boots, zero load errors | debug + release |
| 1 | `type_conformance` (38) — language semantics, NO world | both |
| 2 | `primitive_coverage` — bare-primitive census, world loaded | both |
| 3 | protocol matrix probes — per-class, world loaded | both |
| 4 | A/B differential vs MACVM | release |
| 5 | apps exact: richards, deltablue 224874, library_bench 11/11 | release |
| 6 | GUI smoke (control plane + log grep) | release dartui |

`st/test/run_all.sh` runs 0–5 (6 where a display exists), exits nonzero on
any red. That script IS the pre-push gate. Laws already learned, now binding:
warm numbers are best-of; ApiError is not catchable (natives answer
`[result]`-or-null); cocoa.dart changes need a snapshot rebuild; workspace.dart
changes need a full GUI restart; vendored world edits need `--reimport`.

## 6. The ledger — visible progress, no vibes

`st/PORTING_LEDGER.md`: one row per class — bucket counts, probe file,
A/B status, done-mark. Regenerated header numbers from D1 + tier results
(classes done / selectors probed / bare primitives remaining / deviations).
The plan is finished when the ledger says: every class done-marked, tier
matrix green, bare-primitive count 0, and the browser can open, edit, and
re-Accept any class in the image.

## 7. Milestones

- **M0 — Tooling (first, small, unblocks everything).** `st_dump --audit` +
  cross-ref report; loud bare primitives (D3); `ab.sh`; `run_all.sh`;
  ledger generator; gui_smoke.sh. Exit: the sent-but-undefined list exists
  and the 6 failing probes are triaged into buckets.
  **STATUS (2026-07-31): substantially DONE.** `st/st_audit` + `st/audit/`
  (run_audit.sh, builtins.txt, AUDIT_SUMMARY.md) ship the static cross-ref —
  headline finding: the language selector graph is CLOSED (≈0 genuine
  sent-but-undefined pure-ST selectors; the whole surface is 144 bare
  primitives = 84 num-bare + 60 ffi-bare[Posix 31/Accel 27/Time 2]). The
  battery is unified behind `st/test/run_all.sh` (7 tiers, one exit code,
  verified ALL GREEN) with `gui_smoke.sh` (the browser-regression catcher) and
  `ab.sh` (MACVM oracle diff). The 6 failing probes are already fixed by the
  parallel primitive-audit session (tier2 = failed 0). REMAINING: loud bare
  primitives (D3 — the parallel session's active lane) and a per-class
  PORTING_LEDGER.md generator (AUDIT_SUMMARY.md is the interim snapshot;
  methods.tsv is its join source).
- **M1 — Kernel truth.** The 6 probe failures; `copy`/at:put: hang (ENGINE —
  copy must answer a mutable buffer); instVar family; LargeInteger
  byteAt:put:; comparison/hashing coherence across the new
  Symbol/Character/MutableString trio everywhere (Dict/Set keys, sort).
- **M2 — Collections & streams.** Protocol matrix green for Ordered/Sorted/
  Dictionary/Set/Bag/Interval + Read/Write/ReadWrite streams; `Set with:`;
  the copy family (copy/copyFrom:to:/copyWith:/reversed) on every collection.
- **M3 — Strings & text.** Full String/Symbol/Character matrix (case, trim,
  tokenize, format, replaceAll), printString/displayString/storeString
  everywhere; text goes through the mutable-string machinery only.
- **M4 — The C door: MACVM's FFI floor (§3a), then the platform tier
  verbatim.** Stage a **DONE (2026-07-31, 4038ac7)**: builder lowers
  `<primitive: FFI function:ret:args:>` → stFfiCall([params], "name|ret|codes");
  ST_ffiCall dlsym's + calls the arm64 word path (fail-safe STThrow on an
  unresolved symbol). Word args/return only. VERIFIED on libc (abs/getpid) and
  the corpus's own `Posix socketDomain:type:protocol:` → real fd, `close:` → 0.
  Stage b **DONE (2026-07-31, 27f9d2b)**: the Alien class (MACVM built-in the
  corpus assumes but never defines) provided in the prelude — 1-based byteAt:/
  doubleAt:/signedLongAt: (+put:), ST bounds/base checks → catchable, backed by
  6 peek/poke natives (byte/f64/i64, reject addr<=0). VERIFIED end-to-end on the
  corpus's `Time>>millisecondClockValue` (clock_gettime → mmap timespec →
  signedLongAt:) → real epoch ms. Stage c **DONE (2026-07-31, 2824f0b)**: an arm64 AAPCS64 asm trampoline
  (ffi_call_aapcs) — GPR x0-x7 + FPR d0-d7 + >8-arg stack spill — so fp-register
  scalars and argument spill work. Accelerate is fully live: it dlopens via FFI,
  vDSP (reductions/scale/FFT) runs on a+b (its doubles pass by pointer through
  the mmap'd NativeFloatArray), and **cblas_dgemm** (2 fp scalars + 4 spilled
  words) computes a correct 2x2 product via NativeMatrix. Also fixed a stEquals
  nil bug (`nil = x`) it surfaced. Then the **FFT demo landed in the demos pane**
  (9413984) and the **sockets/DNS/ping tier went live** (f55e4d3): Dns
  blockingResolve: → real IPs, Ping → ICMP 4/4, TCP connect+send+recv → live
  HTTP/1.1 200 — needing a SIGPROF mask around the FFI call (the profiler was
  EINTR-ing blocking syscalls), asInteger-parses-a-String, and native
  Symbol/mutable-String getting the full String-ext protocol. **M4 CORE +
  SHOWCASE COMPLETE.** WIRE/BRIDGE-DART keep the few
  spots where Dart's library is simply better (SystemDictionary stprims,
  DateTime conveniences, Random). Blocking IO / Worker (62/62a, prim 220)
  deferred.
- **M5 — Reflection & tools.** **allClasses + the mirror family DONE
  (2026-07-31, 586aed8)**: 6 reflection natives over the VM's real Class API
  (allClasses walks the st: libraries → 190 class Types; name/superclass/
  selectorsOf:/instanceVariablesOf:/classVariablesOf:), overlay
  76_reflection.mst reopens Behavior/ClassMirror onto them. browseSnapshot walks
  Object's whole tree (114 children); Fraction ivars → [numerator, denominator].
  Remaining M5 (optional): primitiveOf:/methodSends:, browser deep features
  (senders/implementors via D1's send index, in-image).
- **M6 — Numerics tail.** LargeInteger byte protocol **DONE (2026-07-31,
  827e7c9)**: size (magnitude byte count) + byteAt: (1-based little-endian byte)
  read the real Dart int; hash (self) and byteAt:put: (immutable int) are
  documented deviations, not gaps. Remaining M6 (optional): NativeFloatArray
  perf pass (bulk copy without per-element sends).

Sequencing note: M1–M3 are dependency-ordered (everything sits on kernel +
collections + strings); M4/M5 parallelize after M2; M6 floats. M4's stages
land independently — Accel (4c) does not wait on sockets (4b).

## 8. Seed backlog (known reds, day one of M0/M1)

1. The 6 failing primitive probes (triage first — each is a wrong answer
   shipping today).
2. `'x' copy at: 1 put:` hangs the isolate (task already spawned; ENGINE).
3. `Set with:` answers nil (PORT-ST, 26_set class side).
4. OrderedCollection `collect:` partial-dispatch miss (verify, then ENGINE
   or WIRE).
5. ClassMirror `allClasses` prim 98 unwired → UiBrowserService browseSnapshot
   dies (NATIVE-C; unblocks M5).
6. Multi-statement workspace do-its answer `STDoItN` instead of the value
   (control-plane wrapper; user-facing daily).
7. NSException from a Cocoa send is not `on:do:`-catchable (BRIDGE seam).
8. Symbol-vs-String at native boundaries: audit remaining `String`-typed
   natives a symbol can reach (`classNamed:` pattern; getClass/classExists/
   selectorInfo).
