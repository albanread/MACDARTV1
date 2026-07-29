# ST_PLAN — MACVM Smalltalk (`.mst`) as a second language in MACDART

Adding **MACVM's `.mst` Smalltalk** to the MACDART VM as a *second, coexisting
front-end*, selected per function, sharing one object model and all of `dart:core`
+ `dart:cocoa` with Dart, and running at full JIT speed on the same ARM64 backend.

This plan is the concrete follow-through on the three study docs — read them first
for the *why*; this doc is the *how* and the *when*:

- [`docs/dart-vm-compiler.md`](docs/dart-vm-compiler.md) — the compiler we build on.
- [`docs/dart-vm-frontend-guide.md`](docs/dart-vm-frontend-guide.md) — how to emit Dart IL (the `Fragment` API, the minimal contract).
- [`docs/dart-vm-hosting-languages.md`](docs/dart-vm-hosting-languages.md) — the dual-front-end architecture (Part A) and why Smalltalk is Tier‑1 (Part B).

---

## 0. TL;DR and the milestone ladder

The Dart VM already selects a front-end **per `Function`** via the opaque
`kernel_function_` marker (`raw_object.h:853`); the kernel path that reads it is
compiled but **dormant** in V1. We reuse that slot for Smalltalk, add a tracked
`macdart/st/` library (mirroring exactly how `dart:cocoa` is built), and hook one
branch into `compiler.cc`. Everything downstream — SSA, optimizer, register
allocator, ARM64 backend, GC, inline caches, deopt, and `dart:core`/`dart:cocoa` —
is reused **unchanged**.

**The milestone that defines success** (Sprint 3): *a Smalltalk method, e.g.
`Foo >> double: n [ ^ n + n ]`, JIT-compiled by the MACDART VM and returning the
right answer when called from Dart.* Everything before it is scaffolding; everything
after it is breadth.

| Sprint | Milestone | VM risk |
|---|---|---|
| **0** | `.mst` reads to an AST (standalone, no VM) | none |
| **1** | the reader parses the real MACVM corpus | none |
| **2** | `.mst` classes/methods **register** in the VM class table | first VM link + rebuild |
| **3** | **a trivial ST method JIT-compiles and runs** ← the headline | `compiler.cc` patch + rebuild |
| **4** | blocks, closures, control flow, cascades | none new |
| **5** | the two desugarings (`^` non-local return, metaclass tower) + `doesNotUnderstand:`→`noSuchMethod` | none new |
| **6** | ST ↔ Dart interop; ST calls `dart:core` and `dart:cocoa` | none new |
| **7** | workspace GUI: load/run/debug `.mst` | none new |
| **8** | corpus bring-up + A/B benchmark vs MACVM | none new |

---

## 1. The input: the MACVM `.mst` dialect

MACVM's `world/*.mst` files (≈90 of them, `01_object.mst` … `75_dns.mst`) are
**GNU-Smalltalk-style bracketed source**, *not* the old bang-chunk fileIn format.
The constructs, verbatim from the repo:

```smalltalk
Object subclass: Posix [
    | fd buffer |                        "instance variables"
    <classVars: Scratch>                 "class-body pragma"

    openForRead: aPath [                 "instance method (keyword selector)"
        | f |                            "temporaries"
        f := self primOpen: aPath flags: 0.
        ^f
    ]

    Posix class >> kqueue [              "class-side method"
        <primitive: FFI function: #kqueue ret: #g args: #()>
    ]

    readInto: buf count: n [
        [ n := self primRead: buf count: 4096. n > 0 ] whileTrue: [ self step ].
        1 to: n do: [ :i | dst at: i put: (buf byteAt: i - 1) ].
        ^self
    ]
]

PosixFile class >> oRdOnly [ ^0 ]        "external top-level method"
```

Salient features: bracket class bodies (`Super subclass: Name [ … ]`), in-body
instance methods (`selector [ body ]`) and class methods (`Name class >> selector
[ body ]`), external `Name >> …` / `Name extend [ … ]`, `< … >` pragmas (notably
`<primitive: …>` and `<primitive: FFI …>`), blocks `[:x | … ]`, cascades `;`,
keyword messages, and literals `#sym` `#(…)` `#[…]` `'str'` `$c` `16rFF`.

### 1.1 The pragma question (the real semantic bridge)

The kernel `.mst` files (`01`–`~32`) are dense with `<primitive: N>` and
`<primitive: FFI …>` — they implement the base classes on MACVM's *own* primitives
and FFI. **We do not port those.** Instead (see §3) Smalltalk base classes are
*bridged* to `dart:core`, so `SmallInteger>>+` is Dart `int`'s `+`, not a ported
primitive. The application-level files (Mandelbrot, benchdash, breakout, the Cocoa
UI) are the interesting targets and mostly sit on the base protocol we bridge.
`<primitive: FFI …>` and `<primitive: N>` pragmas are handled per §3.3.

---

## 2. Architecture

### 2.1 The integration pattern = the `dart:cocoa` pattern

MACDART's VM tree (`macdart/runtime/`) is **gitignored and regenerated** by
`macdart/port/extract.sh` from a stock Dart 1.24.3 checkout, then the port patch is
applied. So new C++ **cannot** live in `macdart/runtime/`. It follows the exact
shape `dart:cocoa` already uses (`macdart/CMakeLists.txt:244-259`):

- **Tracked source** in its own dir: `macdart/st/` (like `macdart/cocoa/`).
- Compiled as a **static lib** `dart_st` (like `dart_cocoa`), linked into
  `dart_bootstrap`, `gen_snapshot`, `dart`, and `dartui`.
- It `#include`s VM headers (they are on the include path: `include_directories(${RT}
  …)`), so it can call `FlowGraph`, `Instruction`, `Class::New`, etc.
- **VM hook-points** (edits to regenerated files) go in `patches/macdart-port.patch`,
  exactly like the 10-file cocoa/invocation edits already there.

### 2.2 The per-function marker — reuse the dormant `kernel_function_`

Every `Function` carries `NOT_IN_PRECOMPILED(void* kernel_function_)`
(`raw_object.h:853`), read by `UseKernelFrontEndFor` (`compiler.cc:116`) and
`DartCompilationPipeline::BuildFlowGraph` (`compiler.cc:132`) to route a body to the
kernel IL builder. In V1 there is **no kernel input**, so this slot is always `NULL`
and the branch is dead. We **repurpose it for Smalltalk** — a `void*` to an
`st::MethodNode` — with **zero object-layout change** (no new field, so no snapshot
regeneration). The patch changes `BuildFlowGraph`'s kernel branch to call
`st::BuildGraph` instead of the (dormant) kernel builder.

> **Decision D1 (locked for the POC, revisit later):** reuse `kernel_function_`
> rather than add a parallel `st_function_` field. Rationale: adding a `RawFunction`
> field changes heap layout and forces a `gen_snapshot` rebuild and snapshot-version
> bump; reuse costs nothing because the kernel path is dead here. If we ever want the
> kernel front-end back *and* Smalltalk, add the parallel field then (a one-liner in
> `raw_object.h` + accessors mirroring `object.h:2630-2642`).

### 2.3 The pieces (mapped to the hosting-doc blueprint, Part A §5)

```
 .mst source
     │  ┌──────────────────────────────── macdart/st/ (tracked, dart_st lib) ───────────┐
     ▼  │                                                                                │
 st::Lexer ─► st::Parser ─► st::AST ─► st::Loader ─────────────► [ VM object model ]     │
   (Sprint 0/1)             │            creates Library (imports dart:core),            │
                            │            Class::New (×2: instance + metaclass),          │
                            │            Function::New per method  ── set_kernel_function(node)
                            │            Field::New per ivar; RegisterClass;              │
                            │            ClassFinalizer::ProcessPendingClasses            │
                            │                                                             │
                            └─► st::FlowGraphBuilder  ◄── (lazy, on first call, via the   │
                                (ST AST → Dart IL,        compiler.cc patch hook)         │
                                 Fragment combinator)                                     │
     └──────────────────────────────────────────────────────────────────────────────────┘
                                        │  returns FlowGraph*
                                        ▼
        ComputeSSA ─► optimizer ─► register alloc ─► ARM64 codegen ─► deopt   (ALL SHARED, UNCHANGED)
```

Five contributions, one hook — every item has a working template in the tree:

| # | Piece | File(s) | Template to copy |
|---|---|---|---|
| i | Reader (lexer/parser/AST) | `macdart/st/st_{lexer,parser,ast}.*` | — (standalone) |
| ii | Loader (object-model registration) | `macdart/st/st_loader.cc` | `kernel_reader.cc` (`ReadLibrary`, `Class::New`, `Function::New`, `set_kernel_function`) |
| iii | IL builder | `macdart/st/st_flow_graph_builder.cc` | `kernel_to_il.cc` (`Fragment`, `BuildGraphOfFunction`, primitives) — see the front-end guide |
| iv | Pipeline hook | patch to `runtime/vm/compiler.cc` | the existing kernel arm of `BuildFlowGraph`/`ParseFunction` (`compiler.cc:124-151`) |
| v | Dart-facing driver + natives | `macdart/st/st_natives.cc`, a `dart:st`-style entry | `cocoa_natives.mm` / `workspace_natives.cc` |

---

## 3. Reuse `dart:core` — the base-class bridging strategy

This is the crux of Tier‑1 (cheap) hosting: **do not reimplement the Smalltalk
number tower / collections**. Map Smalltalk base classes onto Dart's.

### 3.1 Base-class identity

The loader recognizes a fixed set of **bridged** class names and maps sends to the
corresponding Dart class instead of creating a new one:

| Smalltalk | Dart (`dart:core`) |
|---|---|
| `Object` | `Object` |
| `SmallInteger` / `LargeInteger` / `Integer` | `int` (`Smi`→`Mint`→`Bigint`) |
| `Float` / `FloatD` | `double` |
| `Boolean` / `True` / `False` | `bool` |
| `UndefinedObject` (`nil`) | `Null` |
| `String` / `Symbol` | `String` |
| `Array` / `OrderedCollection` | `List` |
| `BlockClosure` | `Function` (closure) |
| `Character` | (library `Character` over `int` code units) |

### 3.2 Selector aliasing

Where Smalltalk and Dart spell the same operation differently, the IL builder emits
the **Dart** selector: `printString`→`toString`, `size`→`length`, `do:`→`forEach`,
`at:`/`at:put:`→`[]`/`[]=`, `,` (concat) stays `+` for strings, `=`→`==`, `hash`→
`hashCode`, `isNil`→(`== null`). A small alias table lives in the builder; the long
tail is filled as the corpus demands. Selectors that already match (`+ - * < >
ifTrue:ifFalse: whileTrue: value value:`) pass through unchanged.

### 3.3 `<primitive:>` pragmas

- `<primitive: N>` on a *bridged* base method → the method never runs; the send was
  already routed to Dart (§3.2), so the pragma is ignored.
- `<primitive: FFI function: #f ret: … args: …>` → map to the MACDART equivalent:
  POSIX/`libc` FFI becomes a `dart:cocoa`/native call; Cocoa FFI becomes a
  `dart:cocoa` send. A `st:prim` compatibility shim (a handful of natives in
  `st_natives.cc`, plus a `.dart`/`.mst` prelude) covers the primitives the target
  files actually use. **Scoped per target file, not exhaustively.**
- `<primitive: N>` on an *application* class → treat as `self primitiveFailed` /
  a `noSuchMethod`-style error until implemented.

### 3.4 The two desugarings (from feasibility Part B)

1. **Non-local return `^expr` from inside a block.** The home method wraps its body:
   `try { … } catch (_STReturn r) { if (r.home == thisToken) return r.value; rethrow; }`;
   a `^` inside a block throws `_STReturn(homeToken, value)`. If the home frame is
   already dead → no catch → "block cannot return" — which is the correct semantics.
   Uses `ThrowInstr`/`CatchBlockEntry`; cost only on the `^`-in-block slow path.
2. **Class-side / metaclasses.** Each ST class becomes **two** Dart classes: instance
   `Foo` and metaclass-instance `Foo_class` with a singleton; `Foo new` is an
   `InstanceCall` on that singleton, class variables are its fields. Faithful metaclass
   tower using single dispatch throughout.

---

## 4. Semantic mapping (quick reference)

| Smalltalk | Dart IL / runtime | Sprint |
|---|---|---|
| unary/binary/keyword send | `InstanceCallInstr` (verbatim selector or §3.2 alias) | 3 |
| `self` / args / temps | `LoadLocal` / `StoreLocal` (params + temps via scope prep) | 3 |
| `^expr` (method) | `Return` | 3 |
| literals `1 1.5 'x' #s $c` | `Constant` | 3 |
| resolvable static/`super` send | `StaticCallInstr` | 3 |
| `[:x | … ]` block | `Closure` + `Context`; `value`/`value:` → `ClosureCallInstr` | 4 |
| `ifTrue:ifFalse:`, `and:`, `or:` | inlined branch (or send to `bool`) | 4 |
| `whileTrue:`, `to:do:`, `timesRepeat:` | inlined loop (or send) | 4 |
| cascade `;` | shared-receiver `InstanceCall` sequence | 4 |
| `^` from block | `_STReturn` throw/catch (§3.4.1) | 5 |
| `Foo new`, class vars | metaclass singleton (§3.4.2) | 5 |
| `doesNotUnderstand:` | dispatch-miss → `noSuchMethod` (`InvokeNoSuchMethod`) | 5 |
| `#perform:` / `respondsTo:` | reflective `InstanceCall` / dynamic lookup | 6 |

---

## 5. The sprints

Each sprint lists **goal · deliverables · acceptance · risk**. Sprints 0–1 touch no
VM code and cannot destabilize the working GUI; the VM work is quarantined to 2–3.

### Sprint 0 — the reader (standalone, no VM) · *in progress*
- **Goal.** Lex + parse the `.mst` dialect (§1) to an AST, standalone C++17.
- **Deliverables.** `macdart/st/st_{ast.h,lexer.*,parser.*}`, a `st_dump` tool,
  `build.sh`, `examples/*.mst`, `README.md`.
- **Acceptance.** `st_dump` parses the §1 constructs and the examples, prints a clean AST.
- **Risk.** None — nothing links against the VM, nothing in CMake changes.

### Sprint 1 — grammar hardening against the corpus
- **Goal.** Parse the real MACVM `world/*.mst` (≈90 files), or a defined subset.
- **Deliverables.** A grammar note; a corpus runner reporting per-file parse pass/fail;
  fixes for the long tail (radix/scaled numbers, `extend`, dynamic arrays, nested pragmas).
- **Setup.** Clone the corpus (read-only reference; run yourself):
  ```bash
  git clone --depth 1 https://github.com/albanread/MACVM.git /tmp/MACVM
  for f in /tmp/MACVM/world/*.mst; do macdart/st/st_dump "$f" >/dev/null || echo "FAIL $f"; done
  ```
- **Acceptance.** ≥ the core files (`01`–`13`) plus a chosen app file parse clean;
  coverage reported.
- **Risk.** None.

### Sprint 2 — the loader: classes/methods register in the VM
- **Goal.** Turn an ST AST into registered VM entities (bodies still stubbed).
- **Deliverables.** `macdart/st/st_loader.cc` (mirrors `kernel_reader.cc`):
  `Library::NewLibraryHelper(url, import_core=true)`; per class `Class::New(lib,…)` +
  `Library::AddClass` (two classes per ST class, §3.4.2); per method `Function::New`
  stamped `set_kernel_function(stNode)`; per ivar `Field::New`;
  `ClassFinalizer::ProcessPendingClasses`. Wire `dart_st` into `CMakeLists.txt` and link it.
- **Acceptance.** After loading a `.mst`, the classes exist in the class table and a
  selector lookup (`Class::LookupDynamicFunction`) finds the methods; verified from a
  tiny Dart harness calling an `st_natives` entry (`stLoad(source)`).
- **Risk.** First VM link + `dartui` rebuild. Isolated: no method bodies compile yet, so
  no codegen path is exercised.

### Sprint 3 — the IL builder: **a Smalltalk method runs** ← headline
- **Goal.** Compile a trivial ST method body to Dart IL and run it.
- **Deliverables.** `macdart/st/st_flow_graph_builder.cc` — a `Fragment` combinator
  copy (~40 lines, front-end guide §1) + the minimal primitives (`Constant`,
  `LoadLocal`/`StoreLocal`, `PushArgument`, `InstanceCall`, `StaticCall`, `Return`) and
  the scope prep (`LocalVariable`s + `AllocateVariables`). The `compiler.cc` **patch**:
  route ST-marked functions (`kernel_function() != NULL`) to `st::BuildGraph` in
  `BuildFlowGraph`, and skip textual parse in `ParseFunction`.
- **Acceptance.** `Foo >> double: n [ ^ n + n ]` (or `>> answer [ ^40 + 2 ]`)
  JIT-compiles and returns `84`/`42` when invoked from Dart.
- **Risk.** The `compiler.cc` patch + rebuild. This is the one genuinely delicate step;
  the deopt-id-order and stack-balance invariants (front-end guide §4.1, §5) must hold.

### Sprint 4 — blocks, control flow, cascades
- **Goal.** Closures and the common control messages.
- **Deliverables.** `[:x | …]` → `Closure`+`Context`; `value`/`value:` → `ClosureCall`;
  `ifTrue:ifFalse:`/`and:`/`or:` inlined to branches; `whileTrue:`/`to:do:`/
  `timesRepeat:` inlined to loops; cascades.
- **Acceptance.** A method using a block, a loop, and a conditional computes correctly
  (e.g. a factorial or a sum-to-N).
- **Risk.** None new (all in `dart_st`).

### Sprint 5 — the two desugarings + `doesNotUnderstand:`
- **Goal.** Non-local return, the metaclass tower, and DNU.
- **Deliverables.** `^`-in-block → `_STReturn` throw/catch (§3.4.1); `Foo new` + class
  vars via the metaclass singleton (§3.4.2); unknown selector → `noSuchMethod`.
- **Acceptance.** Class-side construction, a non-local return from a block, and a
  `doesNotUnderstand:` handler all work.
- **Risk.** None new.

### Sprint 6 — interop with `dart:core` and `dart:cocoa`
- **Goal.** Prove the free interop the architecture promises.
- **Deliverables.** The §3 bridge (base-class identity + selector aliases + the
  `<primitive:>` shim) fleshed out for the demo targets; ST → Dart and Dart → ST calls.
- **Acceptance.** An ST method calls `print`, builds an `NSString`, and pokes the game
  pane; a Dart do-it calls an ST method and gets the result.
- **Risk.** None new.

### Sprint 7 — workspace GUI integration
- **Goal.** Smalltalk in the IDE.
- **Deliverables.** Load `.mst` into the image (a Smalltalk source column beside the
  Dart one, or an `.mst` import); a "run ST method" path; confirm the debugger and
  profiler work on ST frames (they should — the IL carries `TokenPosition`s).
- **Acceptance.** Load a `.mst`, run a method from the workspace, step it in the debugger.
- **Risk.** None new (workspace/`language.dart` are runtime scripts, no rebuild).

### Sprint 8 — corpus bring-up + benchmark
- **Goal.** Run real MACVM code; measure against MACVM.
- **Deliverables.** Bring up a growing subset of `world/` on the bridge; port a shared
  benchmark (benchdash/Mandelbrot already exist on both sides); A/B vs MACVM's JIT.
- **Acceptance.** A nontrivial MACVM program runs on MACDART; a benchmark number lands.
- **Risk.** None new.

---

## 6. File / build / patch layout

```
macdart/st/                         # tracked (NOT gitignored, like macdart/cocoa/)
  st_ast.h  st_lexer.{h,cc}  st_parser.{h,cc}      # reader           (Sprint 0/1)
  st_dump.cc  build.sh  examples/*.mst  README.md  # standalone tool  (Sprint 0)
  st_loader.{h,cc}                                 # object-model reg  (Sprint 2)
  st_flow_graph_builder.{h,cc}  st_fragment.h      # ST AST → IL       (Sprint 3+)
  st_natives.cc  st.dart                           # Dart-facing driver(Sprint 2/6)
macdart/CMakeLists.txt              # add_library(dart_st …) + link into the 4 exes
macdart/patches/macdart-port.patch  # + runtime/vm/compiler.cc hook (Sprint 3)
ST_PLAN.md                          # this file
```

CMake change mirrors `dart_cocoa` (`CMakeLists.txt:245-259`, `315/327/356/372`):
`add_library(dart_st STATIC macdart/st/st_loader.cc st_flow_graph_builder.cc
st_lexer.cc st_parser.cc st_natives.cc)` then add `dart_st` to each
`target_link_libraries`. The standalone `st_dump` stays a separate, VM-free target.

---

## 7. Risks & open decisions

- **D1 (locked):** reuse `kernel_function_` as the ST marker — zero layout change (§2.2).
- **D2:** base classes bridge to `dart:core` rather than being reimplemented (§3) — the
  whole Tier‑1 bet. Revisit only if a target needs true Smalltalk metaobject semantics
  the bridge can't express.
- **R1 (Sprint 3):** the `compiler.cc` patch is the one delicate VM edit. Mitigation: it
  mirrors the existing kernel arm almost line-for-line; keep it tiny; the deopt-id and
  stack-balance invariants are asserted by the VM (front-end guide §5), so mistakes
  crash loudly rather than miscompile silently.
- **R2:** `<primitive: FFI …>` breadth — MACVM's kernel files are FFI-heavy. Mitigation:
  we don't port kernel files (§3.3); the shim covers only what the demo targets use.
- **R3:** number semantics — ST `SmallInteger` overflow promotes exactly like Dart
  `Smi`→`Mint`→`Bigint`, so arithmetic is a direct match; no masking needed (unlike a
  fixed-width language).
- **R4:** rebuild cost — Sprints 2–3 rebuild `dartui`; keep the working release binary
  aside so the GUI stays usable during bring-up.

---

## 9. Closures — implementation blueprint (the next build)

Full first-class closures with capture are the largest remaining piece. The blueprint
below was **stress-tested against the VM source**; two risks collapsed into verified
simpler paths, and two hidden requirements surfaced. Land it in three stages, each
verifiable alone. Everything is in `st_flow_graph_builder.cc` (+ the loader pre-pass);
**no new VM patch**.

**Two verified simplifications:**
- **`value:` needs NO `ClosureCallInstr`.** The IC-miss path special-cases selector
  `call` on a closure receiver → `DartEntry::InvokeClosure`
  (`runtime_entry.cc:1575-1580`). So `value`/`value:`/`value:value:` lower to a plain
  `InstanceCall("call", …)` — correct for any receiver (a non-closure DNUs, which is
  right), no static receiver knowledge, reuses the existing send machinery. A direct
  `ClosureCallInstr` is a later optimization, not a requirement.
- **Closure-side capture scope is a VM primitive.** When the closure body compiles, its
  scope is built as a child of `LocalScope::RestoreOuterScope(function.context_scope())`
  (`parser.cc:6596`) — the captured variables come back with correct context
  levels/indices for free; no hand-reconstruction.

**Two hidden requirements (missed by a first draft):**
- **A closure function's argument 0 is the closure object itself**, and its prologue
  must load the saved context: `closure_param → LoadField(Closure::context_offset()) →
  StoreLocal(current_context_var)` (kernel does this for `IsClosureFunction()`).
  `num_fixed_parameters` = 1 (closure) + block args.
- **Unique synthetic TokenPositions per block.** `NewClosureFunction` /
  `LookupClosureFunction` dedup by (parent, token-pos); all our positions are
  `kNoSource` and would collide. Synthesize from the parser's `SrcPos` (line/col),
  `TokenPosition(...).ToSynthetic()`. Also: store the marker as `static_cast<Node*>`
  consistently (loader stores `MethodNode*`, closures store `BlockNode*`) and
  `dynamic_cast` on recovery to dispatch method-vs-closure builds.

**Stage A — non-capturing closures** (`[:x | x * x] value: 5` → 25):
`BlockNode` in value position → `TranslateClosure`: mirror `kernel_to_il.cc:6604` —
`Function::NewClosureFunction(name, pf_->function(), synthPos)`; empty
`ContextScope::New(0,false)`; `set_kernel_function(static_cast<Node*>(block))`;
dynamic params; finalize `SignatureType`; `isolate()->AddClosureFunction`. Emit
`AllocateObject(closure_class)` + `set_closure_function`, store the Function into
`Closure::function_offset()` and null into `Closure::context_offset()` (via a synth
temp). `st::BuildGraph` dispatches on the recovered node type; `BuildClosureGraph`
takes params = closure + block args and compiles the block body (last-expression
value). Sends `value*` become `InstanceCall("call")`. The loader pre-pass must stop
hoisting closure-block locals (only *inlined* control-flow blocks hoist).

**Stage B — variable capture** (`| n | n := 10. ^ [:x | n + x] value: 5` → 15):
mark method locals referenced inside closure blocks `set_is_captured()` *before*
`AllocateVariables`; method prologue allocates the context (`AllocateContext(n)` +
chain to `current_context_var`, copying captured params in — kernel
`BuildGraphOfFunction:3277-3311`); `LoadLocal`/`StoreLocal` route captured vars via
`LoadContextAt(level)` + `Context::variable_offset(index)` (kernel `:2646/:2857`);
closure creation stores the real `current_context_var` into `context_offset` and sets
`context_scope = blockScope->PreserveOuterScope(context_depth_)` — which requires the
block's `LocalScope` to be a real child of the method scope (restructure `PrepareScope`
away from the flat hoist for closure blocks). Closure-body compile uses
`RestoreOuterScope` (above). Single-level capture first; nested block-in-block later.

**Stage C — non-local `^` from a real closure**: the try/catch home-token desugaring
(`ThrowInstr`/`CatchBlockEntry` + try-index machinery). Until then, `^` inside a
*closure* block is `Unsupported` — note that `^` inside *inlined* control-flow blocks
(the overwhelmingly common case in the corpus) already works as a plain `Return`.

Risk concentrates in Stage B's context indices/levels (Debug asserts catch mismatches
loudly). Stages A and C are modest; A is independently shippable.

## 8. Status

- **Sprint 0 ✓** — the standalone `.mst` reader (`macdart/st/`), builds clean.
- **Sprint 1 ✓** — parses all 86 MACVM `world/*.mst` (inline `<Type>` annotations handled).
- **Sprint 2 ✓** — the loader registers `.mst` classes/methods/fields into the VM
  class table; all 86 files register (258 classes) via `stLoad`.
- **Sprint 3 ✓ — the headline milestone reached.** A Smalltalk method body is
  JIT-compiled by the Dart VM and returns the right value. `st_flow_graph_builder`
  turns the ST AST into Dart IL (the `Fragment` API); a guarded `compiler.cc` hook
  (in `patches/macdart-port.patch`) routes `kernel_function_`-marked ST functions to
  it; `stInvokeStatic` calls one. `Calc class >> answer [ ^40 + 2 ]` → **42**, and
  `double: n [ ^ n + n ]` → correct through the *optimizing* compiler (40k calls, no
  Debug-assert failures). Ordinary Dart and the 86-file corpus load are unaffected.
  Finalization is lazy at load + on-demand (`FinalizeClass`) per invoked class, so a
  method-less base class never trips the "class needs ≥1 function" assert.
- **Sprint 4 ✓** — inlined control flow + cascades, no new VM patch (all in
  `st_flow_graph_builder.cc`). `ifTrue:`/`ifFalse:`/`ifTrue:ifFalse:`, `and:`/`or:`,
  `whileTrue:`/`whileFalse:`, and `to:do:` inline their block operands (so `[^x]`
  inside a conditional is a plain `Return`), and cascades work. Verified:
  `sumWhile:100`→5050, `sumDo:100`→5050 (a `to:do:` loop), `classify:`→0/1/2,
  `and:` short-circuits, a cascade `5 +1;+2;+3`→8 — all correct through the
  *optimizing* compiler (40k calls, no Debug-assert failures); ordinary Dart and the
  86-file corpus load unaffected. A scope pre-pass hoists inlined-block locals + per-
  loop/cascade synth temps before `AllocateVariables`; control-flow values materialize
  through one reusable temp. Deferred: **real first-class closures** (`value:`/
  `ClosureCall`), `timesRepeat:`, instance-var access, `super`/class-name sends.
- **Sprint 5 ✓** — instance methods + ivar state, no new VM patch. Instance methods
  read/write instance variables via `LoadField`/`StoreInstanceField` at
  `Field::Offset()` on `self` (an assignment carries its value through `value_temp_`);
  the owner class is member-finalized on demand. Two natives — `stNew(class)`
  (`Instance::New` on a finalized class) and `stSend(recv, sel, args)`
  (`LookupDynamicFunction` + `DartEntry::InvokeFunction` with the receiver as arg 0) —
  allocate objects and send instance messages from Dart. Verified: a `Counter`
  (init/bump/bumpBy:/count) → 12; a `Point` with x/y, `sum`→7, `manhattanTo:`→10
  (dispatches `x`/`y` to *another* Point and calls `int.abs` from `dart:core`); two
  instances keep isolated state; an ivar-mutating loop is correct through the
  *optimizing* compiler (`add=40000 sumTo=5050`, no assert failures);
  statics/control-flow/Dart/corpus unaffected. **Deferred**: `Foo new` from ST *source*
  (class-name globals + metaclass tower), real first-class closures (`value:`/
  `ClosureCall`), `super` sends, the closure `^` desugaring.
- **Sprint 6 ✓** — interop breadth, no new VM patch. `Foo new`/`basicNew` and
  class-side factory sends from ST *source* (class-name resolution + `AllocateObject` /
  `StaticCall`, target on-demand finalized); string + double literals; a `dart:core`
  selector-alias bridge — methods (`printString`→`toString`, `=`→`==`, `,`→`+`,
  `at:`/`at:put:`→`[]`/`[]=`) and getters (`size`→`length`, `hash`→`hashCode`, via the
  mangled name + `Token::kGET`); `yourself`. ST methods are marked **non-inlinable** in
  the loader — the optimizer's inliner builds callee graphs itself and would misroute an
  ST callee to the kernel builder; they still optimize top-level. Verified: a
  self-contained `Point`/`Demo` program allocates and uses its own instances (`run`→7,
  `viaFactory`→11), `42 printString`→"42", `'ab','cd'`→"abcd", `'hello world' size`→11,
  `3=3`→true, `3.5+1.5`→5.0; an ST-calls-ST method is correct through the optimizing
  compiler (sum 1..40000 = 800020000); all earlier sprints + Dart + the 86-file corpus
  unaffected. (Two handle-lifetime bugs fixed along the way: `AllocateObject`/`StaticCall`
  need **zone** handles, not temporary-scoped ones.) **Deferred**: the metaclass tower
  with class variables + class-side `self`, real first-class closures, `super`.
- **Sprint 7 — `super` ✓** — `super sel: ..` resolves the method starting in the owner's
  superclass (walking the chain, finalizing each visited class on demand) and emits a
  StaticCall with self as argument 0. Verified across a 3-level hierarchy
  (Puppy→Dog→Animal, `super speak` chaining two levels → 111). No new VM patch.
- **Closures Stage A ✓** — non-capturing first-class closures (§9 blueprint). A
  `BlockNode` in value position creates a real `Closure` (a dedup'd closure `Function`
  per block via unique synthetic TokenPositions, `empty_context_scope`, the block
  stamped as its marker; `AllocateObject(closure_class)` + `set_closure_function` +
  function/context fields), and `value`/`value:`/… lower to `InstanceCall("call")`,
  which the runtime invokes on a closure receiver. `st::BuildGraph` dispatches
  method-vs-closure on the marker's dynamic type; `BuildClosure` compiles the block
  body (arg 0 = the closure itself). The pre-pass hoists only *inlined* blocks —
  closure blocks are self-contained. Verified: `[:x|x*x] value: 5`→25, `[42] value`→42,
  `value:value:`→7, a closure **passed across methods** →11, one closure invoked twice
  →50; correct through the *optimizing* compiler (40k calls); `^`-in-closure fails soft
  (stderr note + nil, per Stage C); all sprints + Dart + the 86-file corpus unaffected.
  Known conflict (documented in `DartSelector`): an ST class's own `value` method is
  shadowed by the `call` alias until dual-registration lands.
- **Closures Stage B ✓ — variable capture.** A capture-analysis pre-pass marks every
  method local (and `self`) referenced under a closure block `set_is_captured()` before
  `AllocateVariables` (which then assigns context slots); the method prologue allocates
  the heap `Context` into `current_context_var` and copies captured *parameters* in from
  their raw frame slots (`Symbols::TempParam()` synthetic, kernel `:3277` pattern);
  captured `LoadLocal`/`StoreLocal` route through the context (single level — the one
  shared method context, level 0 everywhere, so nested closures re-export for free);
  closure creation hand-builds the `ContextScope` (name/type/index/level per captured
  var) and stores the real `current_context_var`; the closure body restores the outer
  scope via `LocalScope::RestoreOuterScope` (a restored `this` becomes `self`, so
  closures reach ivars) and its prologue loads the saved context out of the closure.
  Verified: capture-and-read →15; **mutation through the context** (method observes
  closure writes) →9; **captured parameter** →42; **a closure escaping its frame**
  (heap context outlives the method) →8; a counter closure invoked 3× →3; **self-capture
  mutating an ivar** →3; correct through the *optimizing* compiler; all sprints + Dart +
  the 86-file corpus unaffected. Deferred: capture of a *closure's own* locals by a
  nested closure (needs context chaining — fails soft as unsupported-variable).
- **Sprint 8 (A/B benchmark) ✓ — the payoff measured.** The same `stbench.mst`, byte
  for byte, three ways (`macdart/st/bench/`, results in its README): **MACDART‑ST beats
  MACVM 52×–230×** (fib30 5 ms vs 262 ms; a 50M-iteration loop 22 ms vs 5,066 ms; 2M
  block calls 4 ms vs 331 ms; 2M allocations 5 ms vs 358 ms), and the ST-front-end tax
  vs native Dart on the same VM is **1.00× on loops** (same IL → same machine code),
  2.5× on send-heavy fib (ST methods are non-inlinable for now), ~1.7× on allocation.
  Bonus finding: `value:`→`call` is IC-fast (~2 ns/call) — the VM installs a lazy
  invoke-field dispatcher on `_Closure` after the first miss — and provably correct for
  distinct closures through one send site.
- **Closures Stage C ✓ — non-local `^`.** A `^` under a first-class closure throws an
  `_STNlr` carrier (`stNlrThrow(home, value)`, helpers in `cocoa.dart`) whose home token
  is the method's per-activation **Context** (a synthetic captured `:home` guarantees one
  exists and exports into every closure's ContextScope, so each closure restores the home
  context); a `^`-carrying method wraps its body in a real IL try/catch — try index 0 on
  the body's blocks, `:saved_try_context_var` stored *after* the context prologue,
  `CatchBlockEntryInstr` + `graph_entry->AddCatchEntry`, catch-all handler that compares
  `stNlrHome(e) === current_context_var` and either returns `stNlrValue(e)` or
  `ReThrow`s (kernel `RethrowException` bookkeeping). Verified: `^` unwinds **through**
  an intermediate ST frame (99), falls through when untaken (1), homes to the correct
  activation in a nested chain (199), and an **escaped** block's `^` raises the classic
  `BlockContext>>cannotReturn` error; correct through the optimizing compiler (60k calls
  — after fixing a background-compiler new-space allocation: `String::New` needs
  `Heap::kOld` on the compile path). Bonus: an ST closure is callable directly as a Dart
  closure (`b()`).
- **The core language is semantically complete.** Methods, objects+ivars, control flow,
  cascades, `super`, class-side + `Foo new`, capturing closures, and non-local `^` all
  run — Smalltalk's block-based idioms (`detect:`-style early exit through a passed
  block) now work. **Next:** the workspace GUI, corpus/base-library breadth on the
  bridge, nested-closure-own-local capture, the metaclass tower.
