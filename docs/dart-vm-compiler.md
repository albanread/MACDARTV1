# The Dart 1.24.3 VM Compiler — A Source-Grounded Study

A detailed walk through the compiler of the **Dart 1.24.3** virtual machine — the last
release of the **V1** Dart language, and the VM that [MACDART](../README.md) ports to a
native Apple-Silicon JIT. Every claim here is grounded in a `file.cc:line` citation against
the checked-out reference sources under `runtime/vm/` (version confirmed from `tools/VERSION`:
**MAJOR 1, MINOR 24, PATCH 3, CHANNEL stable**). Nothing here is inferred from modern Dart —
1.24.3 predates the Dart-2 kernel front-end and differs in fundamental ways.

## The shape of the machine

The Dart VM belongs to the **Strongtalk → HotSpot → V8 → Dart** lineage of adaptive object
VMs, and V1 keeps that family's defining engine: a **two-tier speculative JIT** over an
optionally-typed dynamic core. The whole compiler is organised around one loop —
**observe → speculate → guard → deoptimize**:

1. **Observe.** Every function is first compiled *unoptimized*: fast to produce, never
   speculating, but instrumented so each call site records the receiver classes it sees into
   an **inline cache** (`ICData`), and each function/loop counts how hot it is getting. This is
   free, ambient type profiling.
2. **Speculate.** When a function crosses a hotness threshold it is recompiled *optimized*.
   The optimizer treats the observed types as facts and **bets** on them — devirtualizing
   calls, inlining hot callees, unboxing numbers, and deleting checks it can prove redundant.
3. **Guard.** Each bet is backed by a cheap runtime **guard** (`CheckClass`, `CheckSmi`,
   `CheckArrayBound`, an overflow test) or, for class-hierarchy bets, a dependency that will
   retire the code if a violating class is ever loaded.
4. **Deoptimize.** If a guard fails, the VM **reconstructs the exact unoptimized frame** from
   side tables and resumes in unoptimized code — as if the optimization had never happened.
   This safety net is what licenses the aggressive speculation in step 2.

This document follows that arc end to end.

## Naming in the 1.24.3 tree (gotchas)

Several files sit where a modern-Dart reader would not expect — verified against this exact
checkout, not assumed:

| You might look for | In 1.24.3 it is actually | 
|---|---|
| `il.h` / `il.cc` (the IL) | **`intermediate_language.h` / `.cc`** (the `il.*` rename came later). |
| `ic_data.cc` (`ICData`) | **`object.cc`** (`object.cc:13029-14090`); layout in `raw_object.h:1510`. |
| `background_compiler.cc` | inside **`compiler.cc`** (`BackgroundCompiler` has no own file). |
| `reoptimization_counter_threshold` in `flag_list.h` | a `DEFINE_FLAG` in **`runtime_entry.cc:40`** (= 4000). |
| `range_analysis.cc` | **`flow_graph_range_analysis.cc`**. |

## How this study is organised

- **Part I — From source to feedback.** The in-VM recursive-descent parser, the AST, the
  compilation orchestration, the two-tier hotness/background-compilation model, AST→IL
  lowering, the IL/SSA value model, SSA construction, and the *unoptimized* codegen that
  collects type feedback. (Steps 1 of the loop, plus everything shared by both tiers.)
- **Part II — From feedback to machine code and back.** The optimizing pass pipeline, each
  SSA optimization, inline-cache dispatch, class-hierarchy analysis, register allocation, the
  ARM64 backend, and the deoptimization machinery. (Steps 2–4 of the loop.)
- **MACDART port relevance** is flagged inline wherever the code touches the three
  Apple-Silicon corrections (I/D-cache flush, the deopt-stub `SP` push, the `VisitBlocks` NULL
  deref) or the W^X page hand-off.

> Within each Part, a bare section reference (§N) points to a section *of that Part*.

---

# Part I — From Source to Feedback: the Front End and the Two-Tier JIT

---

## 0. Orientation: file map and V1-specific naming

| Concern | File(s) in 1.24.3 | Notes / V1 gotchas |
|---|---|---|
| Tokenizer | `scanner.cc`, `token.h`; `TokenStream` in `object.cc` | Whole script scanned up front into a compact `TokenStream`. |
| Parser | `parser.cc` (15,264 lines) | **In-VM recursive-descent** — V1's defining trait. |
| AST | `ast.h` (2,021), `ast.cc` (794) | 47 node types, visitor pattern. |
| Compile orchestration | `compiler.cc` (2,321) | Includes the `BackgroundCompiler` (no separate `background_compiler.cc` in 1.24.3). |
| AST → IL | `flow_graph_builder.cc` (4,458), `flow_graph_builder.h` | Three-context visitor. |
| IL definitions | **`intermediate_language.h` (8,230), `intermediate_language.cc` (4,336)** | ⚠️ In V1 the IL is *not* `il.h`/`il.cc` — that rename happened in a later Dart. Same content. |
| Representations | `locations.h` (`enum Representation`) | Tagged/unboxed lattice. |
| SSA / flow graph | `flow_graph.cc` (2,319), `flow_graph.h` | `ComputeSSA`, dominators, phis. |
| Baseline codegen (call-site IC emission, prologue) | `flow_graph_compiler.cc`, `flow_graph_compiler_arm64.cc` | The backend proper is Part II; this Part cites only the IC-stub / usage-counter seams. |
| Hotness runtime hooks | `runtime_entry.cc` | `OptimizeInvokedFunction`, OSR. |
| Thresholds | `flag_list.h`, `runtime_entry.cc`, `flow_graph_compiler.cc` | See §4. |

The lower half of `compiler.cc` (from ~line 2191) and `parser.cc` (from ~15211) are
`#else DART_PRECOMPILED_RUNTIME` stub sections — ignore them; the live JIT code is the first
half of each file.

---

## 1. Tokenization — source → `TokenStream`

Before any parsing, a whole compilation unit's source is scanned into a `TokenStream`.

- `Compiler::Compile(library, script)` (`compiler.cc:288`) does `script.Tokenize(library_key)`
  (`compiler.cc:299`) then `Parser::ParseCompilationUnit(library, script)` (`compiler.cc:300`).
- `Script::Tokenize` (`object.cc:9333`) builds a `TokenStream::New(src, private_key, …)`
  (`object.cc:8874`), which internally runs `Scanner scanner(source, private_key)`
  (`object.cc:8901`). The `TokenStream` is a compact byte-encoded stream of tokens + a literal
  table, held on the `Script`.

The parser therefore works over a **pre-scanned token stream**, not raw characters. It can
*seek* within that stream — `Parser::SetPosition(TokenPosition)` (`parser.cc:591`) — which is the
mechanism behind parse-on-demand (§2.2): a function body is parsed by jumping to its
`token_pos()` in the already-tokenized script.

---

## 2. The recursive-descent parser (`parser.cc`)

This ~15k-line hand-written recursive-descent parser is **the single most V1-defining component**:
in 1.24.3 the VM parses *Dart source text* into an AST at runtime. There is no kernel/CFE
front-end feeding the VM (the vestigial kernel path is discussed in §3.1).

### 2.1 Layered structure (grammar → methods)

The parser is organized as a classic layered recursive descent. Key entry points, top-down:

```
ParseCompilationUnit(library, script)      parser.cc:612    whole library/script (top level)
  └ ParseTopLevel()                        parser.cc:6473
      ├ ParseClassDeclaration/Definition   parser.cc:4724 / 4910
      │   └ ParseClassMemberDefinition     parser.cc:4459
      ├ ParseTopLevelFunction              parser.cc:5833
      ├ ParseTopLevelVariable              parser.cc:5716
      └ ParseTopLevelAccessor              parser.cc:5966
ParseClass(cls)                            parser.cc:954     parse one class' members on demand
ParseFunction(parsed_function)             parser.cc:1078    parse ONE function body on demand
  └ ParseFunc / ParseStatementSequence     parser.cc:8656
      └ ParseStatement                     parser.cc:10574   (if/for/while/switch/try/return/…)
          └ ParseExpr                      parser.cc:11480   expression precedence entry
              └ ParseBinaryExpr(min_prec)  parser.cc:11052   precedence climbing
                  └ ParseUnaryExpr         parser.cc:11582
                      └ ParsePostfixExpr   parser.cc:12373   (calls, indexing, `.`, `++`)
                          └ ParsePrimary   parser.cc:14532   literals, ids, `(`, `new`, `const`
```

Expression parsing uses **precedence climbing**: `ParseBinaryExpr(int min_preced)`
(`parser.cc:11052`) loops consuming operators whose precedence ≥ `min_preced`, recursing for the
right operand — the canonical operator-precedence technique rather than one method per level.

### 2.2 Parse-on-demand of function bodies

`Parser::ParseFunction(ParsedFunction*)` (`parser.cc:1078`) is *the* on-demand entry called by the
compiler for each function it needs to compile. It:

1. Constructs a `Parser parser(script, parsed_function, func.token_pos())` (`parser.cc:1094`),
   seeking to the function's start token in the already-tokenized script.
2. **Dispatches on `func.kind()`** (`parser.cc:1102`) to produce a `SequenceNode*` (the body AST):
   - `kRegularFunction` / `kGetterFunction` / `kSetterFunction` / `kConstructor` →
     `SkipFunctionPreamble()` then `parser.ParseFunc(func, false)` (`parser.cc:1120-1122`) — the
     real source-parsing path.
   - **Synthesized functions with no source** are built directly as AST:
     `kImplicitGetter` → `ParseInstanceGetter` (`:1126`), `kImplicitSetter` → `ParseInstanceSetter`
     (`:1130`), `kImplicitStaticFinalGetter` (`:1133`), `kMethodExtractor` → `ParseMethodExtractor`
     (`:1137`, tear-offs), `kNoSuchMethodDispatcher` (`:1141`), `kInvokeFieldDispatcher` (`:1144`),
     and closure variants `ParseImplicitClosure`/`ParseConstructorClosure` (`:1105/1109`).
3. Finalizes scope bookkeeping: adds the expression-temp, `current_context_var`, and
   finally-return-temp variables to the body scope (`parser.cc:1152-1159`), and records the
   result on `parsed_function->SetNodeSequence(node_sequence)` (`parser.cc:1160`).

So a function is *not* fully parsed when its enclosing library is loaded — only its signature is
resolved during class finalization; the **body is parsed lazily** the first time the function is
compiled. `Compiler::CompileClass` (`compiler.cc:362`) parses the class shell (members, supers,
interfaces via `AddRelatedClassesToList`/`Parser::ParseClass`, `compiler.cc:315/438`) and finalizes
it, but bodies wait.

### 2.3 Scope resolution during parse

Scope handling is interleaved with parsing (not a separate pass). The parser maintains a stack of
`LocalScope`s opened/closed as blocks/functions are entered (e.g. `OpenFunctionBlock`,
`parser.cc:1213`), resolving identifiers against enclosing local scopes, then the class, then the
library. Receiver/`this` and type-argument parameters are looked up via `LookupReceiver` /
`LookupTypeArgumentsParameter` (`parser.cc:1170-1173`), and the parser records whether an
*instantiator* is required for generic type checks/allocation
(`IsInstantiatorRequired`, `parser.cc:1164`). After parsing, `ParsedFunction::AllocateVariables()`
(`compiler.cc:127`) assigns each captured/local variable a frame slot or context index.

### 2.4 Optional types are parsed but (mostly) don't affect runtime semantics

Types are always *parsed* (e.g. `ParseType(...)` in `ParseNewOperator`, `parser.cc:14051`), but
whether they produce **runtime checks** is gated on checked mode. The flow-graph builder only emits
`AssertAssignable` type-check IL when `isolate->type_checks()` (or `asserts()`) is on —
`flow_graph_builder.cc:979, 1116, 1331, 1683`, etc. In production/unchecked mode the same source
parses to the same AST but no `AssertAssignable` is emitted, so optional type annotations are
semantically inert. (This is the classic "optional typing" of Dart 1.x — later reversed by Dart 2's
sound static typing.)

### 2.5 `new` (or `const`) is required for constructor invocation

Constructor calls go through `Parser::ParseNewOperator(Token::Kind)` (`parser.cc:14037`), which
handles both `op_kind == kNEW` and `kCONST` (`parser.cc:14040`). It is reached only from
`ParsePrimary`, which dispatches `ParseNewOperator(Token::kNEW)` (`parser.cc:14677`) and
`ParseNewOperator(Token::kCONST)` (`parser.cc:14686`) when it sees the `new`/`const` keyword.
A bare `Foo()` is therefore parsed as an ordinary call, **not** a constructor — the `new`/`const`
keyword is mandatory in V1. (Dart 2 later made `new` optional.)

---

## 3. The AST (`ast.h`, `ast.cc`)

### 3.1 Node taxonomy

There are **47 AST node types**, enumerated by the X-macro `FOR_EACH_NODE(V)` (`ast.h:19-67`):

- **Control flow:** `Return`, `If`, `Switch`, `Case`, `While`, `DoWhile`, `For`, `Jump`
  (break/continue), `TryCatch`, `CatchClause`, `Throw`, `InlinedFinally`, `Stop`.
- **Calls / dispatch:** `InstanceCall`, `StaticCall`, `ClosureCall`, `ConstructorCall`,
  `InstanceGetter`, `InstanceSetter`, `StaticGetter`, `StaticSetter`.
- **Loads/stores:** `LoadLocal`, `StoreLocal`, `LoadInstanceField`, `StoreInstanceField`,
  `LoadStaticField`, `StoreStaticField`, `LoadIndexed`, `StoreIndexed`, `InitStaticField`.
- **Expressions/values:** `Literal`, `Type`, `Assignable`, `BinaryOp`, `Comparison`, `UnaryOp`,
  `ConditionalExpr`, `ArgumentList`, `Array`, `Closure`, `Primary`, `Let`, `StringInterpolate`.
- **Async:** `Await`, `AwaitMarker`.
- **Sequencing / misc:** `Sequence` (`SequenceNode`, a block with its `LocalScope`),
  `CloneContext`, `NativeBody`.

### 3.2 Base class and visitor pattern

`AstNode` (`ast.h:98`) is `ZoneAllocated`, stores a `token_pos_` (`ast.h:100`), and uses a visitor:
`FOR_EACH_NODE` generates `AstNodeVisitor::Visit<Name>Node` (`ast.h:81-84`) and per-node
`As<Name>Node()` down-casts (`ast.h:108-113`). Notable virtual hooks on `AstNode`:

- `MakeAssignmentNode(AstNode* rhs)` (`ast.h:123`) — **V1 idiom:** during parsing a reference is
  first built as a *load* node (`LoadLocalNode`, `LoadStaticFieldNode`, `InstanceGetterNode`, …);
  when the parser later discovers it's the LHS of `=`, it calls `MakeAssignmentNode` to rewrite the
  load into the corresponding *store* node. Assignment context isn't known at first sight of the id.
- `ApplyUnaryOp` (`ast.h:128`), `IsPotentiallyConst` (`ast.h:138`), `EvalConstExpr` (`ast.h:147`) —
  constant-expression evaluation happens at the AST level (const folding for `const` contexts).

### 3.3 The vestigial kernel path (important context)

`compiler.cc:116` `UseKernelFrontEndFor(parsed_function)` returns true only when
`function.kernel_function() != NULL` or the function is a `kNoSuchMethodDispatcher` /
`kInvokeFieldDispatcher`. For ordinary source-loaded functions `kernel_function()` is NULL, so
`DartCompilationPipeline::ParseFunction` takes the `Parser::ParseFunction` branch
(`compiler.cc:124-128`) and `BuildFlowGraph` takes the AST `FlowGraphBuilder` branch
(`compiler.cc:146-150`). The kernel branch exists but is dormant in normal 1.24.3 JIT operation —
confirming this is genuinely the in-VM-parser world.

---

## 4. Compilation entry & orchestration (`compiler.cc`)

### 4.1 The `CompilationPipeline` abstraction

`CompilationPipeline::New(zone, function)` (`compiler.cc:192`) returns either
`IrregexpCompilationPipeline` (for `IsIrregexpFunction()`) or `DartCompilationPipeline` (`:194-197`).
The pipeline abstracts two steps used by the orchestrator:
- `ParseFunction(parsed_function)` — `DartCompilationPipeline` calls
  `Parser::ParseFunction(parsed_function)` then `parsed_function->AllocateVariables()`
  (`compiler.cc:124-128`).
- `BuildFlowGraph(zone, parsed_function, ic_data_array, osr_id)` — builds the IL via
  `FlowGraphBuilder(...).BuildGraph()` (`compiler.cc:132-151`).

### 4.2 Top-level entry points

- `Compiler::CompileFunction(thread, function)` (`compiler.cc:1442`) — the *runtime* entry hit on a
  cold call (via `DEFINE_RUNTIME_ENTRY(CompileFunction, …)`, `compiler.cc:204`). It **always
  compiles unoptimized first**: `CompileFunctionHelper(pipeline, function, /*optimized=*/false,
  kNoOSRDeoptId)` (`compiler.cc:1467-1468`).
- `Compiler::CompileOptimizedFunction(thread, function, osr_id)` (`compiler.cc:1526`) — compiles
  optimized (`optimized=true`, `compiler.cc:1549`), used when a function is hot or for OSR.
- `Compiler::EnsureUnoptimizedCode(thread, function)` (`compiler.cc:1494`) — forces baseline code to
  exist even if the function currently only has optimized code (needed as a deopt/OSR fallback);
  re-attaches the original code afterwards (`compiler.cc:1511-1516`).

### 4.3 `CompileFunctionHelper` — parse then compile

`CompileFunctionHelper(pipeline, function, optimized, osr_id)` (`compiler.cc:1219`):
1. Wraps everything in a `LongJumpScope`/`setjmp` for bailout/error propagation (`:1225`).
2. Allocates a `ParsedFunction` (`:1236`).
3. `pipeline->ParseFunction(parsed_function)` (`:1258`) — the parse step.
4. Constructs `CompileParsedFunctionHelper helper(parsed_function, optimized, osr_id)` (`:1264`)
   and calls `helper.Compile(pipeline)` (`:1278`).
5. On the unoptimized path, sets `function.set_was_compiled(true)` (`:1281`). On an optimizer
   **bailout**, it does *not* error — it sets `function.SetIsOptimizable(false)` and returns
   `Error::null()` so the function simply keeps running unoptimized (`:1305-1319`). Background
   optimizer bailouts are handled specially (`:1284-1309`).

### 4.4 `CompileParsedFunctionHelper::Compile` — the pass pipeline

`CompileParsedFunctionHelper::Compile(pipeline)` (`compiler.cc:705`) is the core pipeline. It runs
inside a `while (!done)` loop wrapped in `setjmp` so it can **retry with far branches** on ARM/ARM64
if the assembler overflows a branch offset (`:717-725, 1186-1191`). Sequence:

1. **Build flow graph** — `flow_graph = pipeline->BuildFlowGraph(zone, parsed_function,
   *ic_data_array, osr_id())` (`compiler.cc:779`). For *optimized* compiles, type feedback is
   restored first: `function.RestoreICDataMap(ic_data_array, clone_ic_data)` (`:760`) pulls the
   ICData the unoptimized code collected; background compiles *clone* the ICData so it can't mutate
   mid-compile (`:757-760`).
2. **Block scheduling / edge weights** — `BlockScheduler` (`:796`); `AssignEdgeWeights` if reordering
   (`:799-803`).
3. **SSA (optimized only)** — `flow_graph->ComputeSSA(0, NULL)` (`compiler.cc:810`), guarded by
   `if (optimized())` (`:805`). **Unoptimized code is never put into SSA form** — this is a pivotal
   split (see §7, §8).
4. **Optimizer passes (optimized only)** — under `if (optimized())` (`:827`): `JitOptimizer`,
   `ApplyICData` (`:845`), `TryOptimizePatterns` (`:852`), inlining + type propagation
   (`FlowGraphTypePropagator::Propagate`, `ApplyClassIds`, `FlowGraphInliner::Inline`, `:858-889`),
   `Canonicalize` (`:899`), and (further down) range analysis, LICM, CSE, register allocation
   `FlowGraphAllocator::AllocateRegisters` (`:1120-1121`), block reordering (`:1128`). **All of this
   is covered in Part II** — it is listed here only to show where the unoptimized path skips it.
5. **Codegen** — `Assembler assembler; FlowGraphCompiler graph_compiler(...); graph_compiler
   .CompileGraph()` (`compiler.cc:1137-1145`). This one call emits machine code for *both* tiers;
   the difference is entirely in the IL fed to it (naive for unoptimized, optimized+allocated for
   optimized).
6. **Finalize/install** — `FinalizeCompilation(&assembler, &graph_compiler, flow_graph)`
   (`compiler.cc:1153` on the mutator thread; `:1169` under a `SafepointOperationScope` for
   background compiles, `:1162-1171`).

### 4.5 `FinalizeCompilation` — building & installing the `Code`

`CompileParsedFunctionHelper::FinalizeCompilation` (`compiler.cc:526`):
- `Code::FinalizeCode(function, assembler, optimized())` (`:543-544`) materializes the executable
  `Code` object; then finalizes PC descriptors, deopt-info array, stack maps, var descriptors,
  exception handlers, static-call target table, code-source map (`:581-589`).
- **Unoptimized path** (`compiler.cc:671-679`): if the function has no ICData map yet,
  `function.SaveICDataMap(graph_compiler->deopt_id_to_ic_data(),
  edge_counters_array)` (`:672-675`) — this **persists the type-feedback skeleton** (deopt-id →
  ICData, plus edge counters) that the running baseline code will fill in. Then
  `function.set_unoptimized_code(code)` and `function.AttachCode(code)` (`:677-678`).
- **Optimized path** (`compiler.cc:591-670`): installs at a safepoint. Before installing a
  *background-compiled* result it re-validates assumptions — guarded field states
  (`IsConsistentWith`, `:614`), loading-invalidation generation (`:624`), and CHA hierarchy
  consistency (`IsConsistentWithCurrentHierarchy`, `:631`); if stale, the code is thrown away
  (`code = Code::null()`, `:644`). On success it `RegisterDependencies` with CHA and each guarded
  field (`:661-668`) so the code is deoptimized if those assumptions later break.

### 4.6 Error / bailout handling

Three mechanisms: (a) `LongJumpScope`/`setjmp` around parse and compile (`compiler.cc:733, 1225,
1556`) with `thread()->sticky_error()` propagated out; (b) the special
`Object::branch_offset_error()` sentinel that triggers the far-branch retry (`:1186-1191`); and (c)
`Compiler::AbortBackgroundCompilation(deopt_id, msg)` (`compiler.cc:1817`) which long-jumps with
`Object::background_compilation_error()` (`:1833`) whenever the world changed under a background
compile.

### 4.7 OSR (on-stack replacement) entry

OSR reuses the optimized pipeline with a non-`kNoOSRDeoptId` `osr_id`. In `BuildGraph` the graph is
pruned to what's reachable from the OSR entry (`PruneUnreachable`, `flow_graph_builder.cc:4413,
4428`). OSR is triggered from a *loop back-edge* stack-overflow check in unoptimized code (§5.4),
handled by `runtime_entry.cc:1806-1829`: it looks up the OSR deopt-id for the current PC
(`GetDeoptIdForOsr`, `:1807`), calls `Compiler::CompileOptimizedFunction(thread, function, osr_id)`
(`:1817`), and hot-swaps the frame's PC to the optimized entry (`:1825-1828`). OSR is **never**
done in the background (`compiler.cc:641`).

---

## 5. The two-tier JIT / hotness model

Dart 1.24.3 is a **two-tier JIT**: every function is first compiled **unoptimized** (fast to
produce, collects type feedback, never speculates), and only *hot* functions are recompiled
**optimized** (speculative, guarded by deopt). There is no interpreter tier in the arm64 JIT
configuration (the DBC bytecode interpreter is a separate `TARGET_ARCH_DBC` build).

### 5.1 The usage counter and thresholds

Each `Function` has a `usage_counter`. Thresholds:

| Flag | Default | Where | Meaning |
|---|---|---|---|
| `optimization_counter_threshold` | **30000** | `flag_list.h:119` | Ceiling for first-time optimization. |
| `min_optimization_counter_threshold` | 5000 | `flow_graph_compiler.cc:39-41` | Floor of the adaptive threshold. |
| `optimization_counter_scale` | 2000 | `flow_graph_compiler.cc:42-45` | Per-basic-block scaling. |
| `reoptimization_counter_threshold` | **4000** | `runtime_entry.cc:40-42` | Counter (in IC stubs) before an *optimized* fn is reoptimized. |
| `regexp_optimization_counter_threshold` | 1000 | `runtime_entry.cc:37-39` | Regexp functions. |
| `background_compilation` | `USING_MULTICORE` | `flag_list.h:50` | Optimize on a background thread. |
| `polymorphic_with_deopt` | true | `flag_list.h:129` | Deopt-guarded polymorphic dispatch vs. megamorphic. |
| `max_deoptimization_counter_threshold` | 16 | `compiler.cc:63-67` | Give up optimizing after this many deopts. |

The effective first-optimization threshold is **adaptive by function size**
(`FlowGraphCompiler::GetOptimizationThreshold`, `flow_graph_compiler.cc:1694`):

```
if is_optimizing():         threshold = reoptimization_counter_threshold        // 4000
elif IsIrregexpFunction():  threshold = regexp_optimization_counter_threshold   // 1000
else:                       threshold = optimization_counter_scale * basic_blocks
                                        + min_optimization_counter_threshold      // 2000*bb + 5000
                            threshold = min(threshold, optimization_counter_threshold)  // cap 30000
```

So a tiny function optimizes around ~5000–7000 invocations, a large one is capped at 30000.

### 5.2 The prologue counter check (where "hot" is detected)

In *unoptimized* generated code, every function-entry prologue increments and tests the counter.
`FlowGraphCompiler::EmitFrameEntry` (`flow_graph_compiler_arm64.cc:938`) emits an "Invocation Count
Check":

```
LoadField R7 <- function.usage_counter           (:953)
if (!is_optimizing()) { R7++; store back }        (:957-961)   // count at entry for unopt code
CompareImmediate R7, GetOptimizationThreshold()   (:962)
b(dont_optimize, LT)                              (:965)
Branch StubCode::OptimizeFunction_entry()         (:966)       // hot: go optimize
dont_optimize: EnterDartFrame ...                 (:967, 977)
```

Note the asymmetry (`:955-956`): **unoptimized** code counts at *function entry*; **optimized**
code does not — instead its **IC stubs** count call-site executions, so reoptimization is driven by
call frequency inside already-optimized code (threshold 4000).

### 5.3 `OptimizeInvokedFunction` — the promotion runtime entry

The `OptimizeFunction` stub calls `DEFINE_RUNTIME_ENTRY(OptimizeInvokedFunction, 1)`
(`runtime_entry.cc:1851`). It gates on `Compiler::CanOptimizeFunction` (`:1857`) and then either:
- **Background path** (`FLAG_background_compilation`, `:1858-1891`): sets
  `function.set_usage_counter(INT_MIN)` (`:1883`) so it won't re-trigger while queued, calls
  `BackgroundCompiler::EnsureInit` + `isolate->background_compiler()->CompileOptimized(function)`
  (`:1884-1886`), and **returns immediately in the same (unoptimized) code** (`:1888`).
- **Foreground path** (`:1893-1906`): resets `usage_counter` to 0 (`:1895`, prevents recursive
  re-trigger) and calls `Compiler::CompileOptimizedFunction(thread, function)` synchronously (`:1902`).

`Compiler::CanOptimizeFunction` (`compiler.cc:219`) is the gatekeeper: refuses if the debugger is
stepping / has a breakpoint (can't single-step optimized code, `:222-228`), if
`deoptimization_counter() >= max_deoptimization_counter_threshold` (marks non-optimizable, `:230-244`),
if an `--optimization_filter` excludes it (`:246-268`), or if `!function.IsOptimizable()` (`:269-277`).

### 5.4 Installing optimized code / promotion

On the foreground path, `FinalizeCompilation` (§4.5) calls `function.InstallOptimizedCode(code)`
(`compiler.cc:596`) which makes the optimized `Code` the function's current code; subsequent calls
enter the optimized entry. Callers are patched lazily to the new target via `FixCallersTarget`
(`runtime_entry.cc:1917`).

### 5.5 Background compilation (the `BackgroundCompiler`)

Defined entirely in `compiler.cc` (there is no `background_compiler.cc` in 1.24.3):

- **Queue** — `BackgroundCompilationQueue` (`compiler.cc:1870`), a C-heap FIFO of `QueueElement`s
  (`:1839`) each holding a `RawFunction`. `Add`/`Peek`/`Remove`/`ContainsObj` (`:1886-1930`).
- **Producer (mutator side)** — `BackgroundCompiler::CompileOptimized(function)` (`compiler.cc:2041`):
  runs on the mutator thread; de-dups against the queue (`ContainsObj`, `:2051`), enqueues, and
  `Notify()`s the compiler thread (`:2054-2056`).
- **Consumer (helper thread)** — `BackgroundCompiler::Run()` (`compiler.cc:1970`): loops while
  `running_`; `EnterIsolateAsHelper(isolate_, kCompilerTask)` (`:1974`); peeks a function and calls
  `Compiler::CompileOptimizedFunction(thread, function, kNoOSRDeoptId)` (`:1989`); on completion
  removes it and, if it still lacks optimized code and is optimizable, re-queues it (`:2004-2012`);
  blocks on `ml.Wait()` when the queue is empty (`:2025-2028`).
- **Code install** — the helper thread does *not* freely mutate the heap; `Compile` installs the
  finished `Code` inside a `SafepointOperationScope` (`compiler.cc:1162-1171`) that **stops the
  mutator** so that creating the instructions object (which flips code-page W^X permissions) is safe
  (comment at `:1156-1161`). Before install it re-validates guards/CHA/loading-gen (§4.5); if the
  world moved, it discards the code and nudges `usage_counter` so a retry happens soon
  (`compiler.cc:646-653`).
- **Lifecycle** — `EnsureInit` (`:2136`, lazily creates the task + finalizes `NoSuchMethodError`/
  `_Mint`), `Stop` (`:2066`), `Disable`/`Enable`/`IsDisabled` (`:2101/2127/2118`),
  `VisitPointers` for GC of queued functions (`:2061`).

**W^X relevance to the MACDART port:** the safepoint-guarded install (`compiler.cc:1156-1171`) and
`Code::FinalizeCode` are exactly where executable pages are made writable then executable — the
Apple-Silicon `MAP_JIT` + `pthread_jit_write_protect_np` toggle must wrap that instruction
materialization.

---

## 6. AST → Flow Graph (`flow_graph_builder.cc`)

### 6.1 `BuildGraph`

`FlowGraphBuilder::BuildGraph()` (`flow_graph_builder.cc:4385`):
1. Creates a `TargetEntryInstr normal_entry` and a `GraphEntryInstr graph_entry_`
   (`:4399-4402`).
2. Visits the **whole function body** in *effect* context: `EffectGraphVisitor for_effect(this);
   parsed_function().node_sequence()->Visit(&for_effect);` (`:4403-4404`).
3. `AppendFragment(normal_entry, for_effect)` (`:4405`), asserts the graph is closed
   (`!for_effect.is_open()`, `:4407`).
4. For OSR, prunes unreachable blocks (`:4412-4413`).
5. Wraps the result: `new FlowGraph(parsed_function(), graph_entry_, last_used_block_id_)`
   (`:4416`).

### 6.2 The three-context visitor model

The lowering is a classic **destination-driven / three-context** translation
(flow_graph_builder.h):

- `EffectGraphVisitor` (`flow_graph_builder.h:238`) — the base; used when a value is *discarded*
  (statement/effect position).
- `ValueGraphVisitor : EffectGraphVisitor` (`:472`) — used when the value is *needed*; leaves the
  result in `value()`.
- `TestGraphVisitor : ValueGraphVisitor` (`:530`) — used in *boolean-test* position; produces
  true/false successor targets for branches.

Each visitor accumulates a **graph fragment** as an (`entry_`, `exit_`) chain (`:241`), with
`is_open()` meaning "still extendable" (`:254`). Fragment-assembly primitives:

| Primitive | Line | Role |
|---|---|---|
| `Append(other)` | `:260` | Splice another fragment onto the exit. |
| `Bind(Definition*)` → `Value*` | `:262` | Append a value-producing def; get a `Value` use of it. |
| `Do(Definition*)` | `:264` | Append a def whose value is unused (effect only). |
| `AddInstruction(Instruction*)` | `:267` | Append a plain (non-def) instruction. |
| `Goto(JoinEntry*)` | `:270` | Close the fragment with an unconditional jump. |
| `Join(test, true, false)` | `:274` | Build an if/then/else diamond. |
| `TieLoop(...)` | `:281` | Build a loop with a back-edge. |
| `PushArgument(Value*)` | `:288` | Wrap a value in a `PushArgumentInstr` for a call. |

Because `Bind` already returns a `Value*` bound to a `Definition`, the builder produces the
**use-list value model** (§7) from the start — but *not* SSA (no phis, no `ssa_temp_index`); locals
are still real `LoadLocal`/`StoreLocal` against frame slots until SSA renaming (optimized only).

### 6.3 Representative lowering — an instance call

`EffectGraphVisitor::VisitInstanceCallNode` (`flow_graph_builder.cc:2512`) is the canonical example:
```
push type-args (if any)                         (:2523)
evaluate receiver in ValueGraphVisitor context  (:2524-2526)
PushArgument(receiver)                           (:2527-2528)
push each argument                               (:2529)
call = new InstanceCallInstr(token, name, …,
        owner()->ic_data_array())                (:2530-2533)   // <-- threads ICData feedback
ReturnDefinition(call)                           (:2534)
```
The `owner()->ic_data_array()` argument (`:2533`) is the seam that ties each call site to a
deopt-id-indexed `ICData` slot — the thing the baseline code fills with observed receiver classes.
`VisitStaticCallNode` (`:2541`) is analogous with `StaticCallInstr` (`:2547-2549`).

---

## 7. The IL / instruction set (`intermediate_language.h/.cc`)

### 7.1 Instruction / Definition / Value model

- **`Instruction`** (`intermediate_language.h:663`) — base of all IL nodes; `ZoneAllocated`, forms a
  doubly-linked list within a basic block, carries a `deopt_id`, input operands, and an optional
  *environment* (for deopt).
- **`Definition : Instruction`** (`intermediate_language.h:1712`) — any instruction that *produces a
  value*. Key fields:
  - `temp_index_` (`:1722`) — the **unoptimized** stack-machine slot number.
  - `ssa_temp_index_` (`:1727`) — the **SSA virtual register**, assigned during renaming; `-1`
    until then (`HasSSATemp`, `:1732`). *Both indices coexist*; which one is meaningful depends on
    whether SSA ran.
  - `input_use_list_` and `env_use_list_` (`:1792-1796`) — two use lists: normal data-flow uses vs.
    deopt-environment uses. `ReplaceUsesWith`/`ReplaceWith` (`:1804-1810`) rewrite them.
  - `CompileType* type_` (`:1745`) + `range_` (`:1820`) + `constant_value()` (`:1816`) — analysis
    facts attached to the def (populated by the optimizer).
- **`Value`** (`intermediate_language.h:210`) — a single **use edge**: points to its `definition_`
  (`:302`), is a node in that definition's use list (`previous_use_`/`next_use_`, `:303-304`), and
  back-links to the using `instruction_` + `use_index_` (`:305-306`). Carries a `reaching_type_`
  (`:308`) used by type propagation. This is the standard SSA def-use representation.

### 7.2 The instruction set — 140 concrete opcodes

`FOR_EACH_INSTRUCTION(M)` (`intermediate_language.h`) lists **140** concrete instructions
(`FOR_EACH_ABSTRACT_INSTRUCTION` at `:506` lists the abstract bases). Grouped:

- **Block entries:** `GraphEntry`, `JoinEntry`, `TargetEntry`, `IndirectEntry`, `CatchBlockEntry`.
- **SSA machinery:** `Phi`, `Redefinition`, `Parameter`, `ParallelMove`.
- **Control flow:** `Return`, `Throw`, `ReThrow`, `Goto`, `IndirectGoto`, `Branch`, `IfThenElse`,
  `Stop`.
- **Calls:** `ClosureCall`, `InstanceCall`, `PolymorphicInstanceCall`, `StaticCall`, `NativeCall`.
- **Locals / stack:** `LoadLocal`, `StoreLocal`, `DropTemps`, `PushArgument`, `CurrentContext`.
- **Comparisons / tests:** `StrictCompare`, `EqualityCompare`, `RelationalOp`, `TestSmi`, `TestCids`,
  `CheckedSmiComparison`.
- **Loads/stores:** `LoadIndexed`, `LoadCodeUnits`, `StoreIndexed`, `LoadField`, `StoreInstanceField`,
  `LoadStaticField`, `StoreStaticField`, `InitStaticField`, `LoadUntagged`, `LoadClassId`.
- **Arithmetic (representation-specialized):** tagged `BinarySmiOp`/`UnarySmiOp`/`CheckedSmiOp`;
  `BinaryInt32Op`; 64-bit `BinaryMintOp`/`ShiftMintOp`/`UnaryMintOp`; `BinaryUint32Op`/`ShiftUint32Op`;
  floating `BinaryDoubleOp`/`UnaryDoubleOp`/`DoubleTestOp`/`MathUnary`/`MathMinMax`; `TruncDivMod`.
- **Boxing / representation changes:** `Box`, `Unbox`, `BoxInt64`/`UnboxInt64`, `BoxUint32`/
  `UnboxUint32`, `BoxInt32`/`UnboxInt32`, `UnboxedConstant`, `UnboxedIntConverter`; numeric
  conversions `SmiToDouble`, `Int32ToDouble`, `MintToDouble`, `DoubleToSmi`, `DoubleToInteger`, …
- **Speculation guards (deopt points):** `CheckClass`, `CheckClassId`, `CheckSmi`,
  `CheckEitherNonSmi`, `CheckArrayBound`, `GenericCheckBound`, `CheckStackOverflow`,
  `GuardFieldClass`, `GuardFieldLength`, and the explicit `Deoptimize`.
- **Type ops:** `AssertAssignable`, `AssertBoolean`, `InstanceOf`, `InstantiateType`,
  `InstantiateTypeArguments`.
- **Allocation:** `CreateArray`, `AllocateObject`, `AllocateContext`,
  `AllocateUninitializedContext`, `CloneContext`, `MaterializeObject`.
- **Constants:** `Constant`, `UnboxedConstant`.
- **Strings / regexp:** `StringToCharCode`, `OneByteStringFromCharCode`, `StringInterpolate`,
  `CaseInsensitiveCompareUC16`, `GrowRegExpStack`.
- **SIMD:** a large `Float32x4*` / `Int32x4*` / `Float64x2*` family (`Float32x4Constructor`,
  `Simd32x4Shuffle`, `Int32x4Select`, …).

### 7.3 Representations (the tagging lattice)

`enum Representation` (`locations.h:23`): `kTagged` (a Smi or heap-pointer — the default boxed form),
`kUntagged`, `kUnboxedDouble`, `kUnboxedInt32`, `kUnboxedUint32`, `kUnboxedMint` (unboxed 64-bit int),
the SIMD `kUnboxedFloat32x4`/`kUnboxedInt32x4`/`kUnboxedFloat64x2`, and `kPairOfTagged`. In
unoptimized code **everything is `kTagged`** (Smi or boxed) — small ints are Smis, overflow promotes
to boxed Mint, doubles are boxed. The optimizer is what introduces unboxed representations and the
`Box`/`Unbox` conversions guarded by `CheckSmi`/`CheckClass`; Part II covers that.

---

## 8. SSA construction (`flow_graph.cc`)

**Reminder:** SSA runs **only for optimized compiles** (`compiler.cc:805`, `if (optimized())`).
Baseline code is compiled straight from the non-SSA fragment graph.

`FlowGraph::ComputeSSA(next_virtual_register_number, inlining_parameters)`
(`flow_graph.cc:775`) is the textbook Cytron-style construction:

1. `current_ssa_temp_index_ = next_virtual_register_number` (`:779`) — virtual-register numbering
   starts at 0 for a top-level compile, or at the caller's high-water mark when inlining.
2. **Dominators + dominance frontier** — `ComputeDominators(&dominance_frontier)` (`:781`,
   implementation `:809`). Uses **SEMI-NCA** — a two-pass Lengauer–Tarjan variant (comment
   `:811-819`) — with link-eval path compression (`CompressPath`, `:906`). Immediate dominators
   are the NCA of spanning-tree parent and semidominator (`:877-884`); the dominance frontier is
   then computed by the Cooper/Ferrante "simple, fast" walk up to the dominator (`:891-902`).
3. **Variable liveness** — `VariableLivenessAnalysis variable_liveness(this); variable_liveness
   .Analyze()` (`:783-784`), giving per-block assigned-variable sets.
4. **Phi insertion** — `InsertPhis(preorder_, assigned_vars, dominance_frontier, &live_phis)`
   (`:788`, impl `:920`) inserts `PhiInstr`s at the iterated dominance frontier of each assigned
   local, using `has_already`/`work` worklist maps to avoid duplicates (`:928-934`).
5. **Rename** — `Rename(&live_phis, &variable_liveness, inlining_parameters)` (`:794`, impl `:980` /
   `RenameRecursive` `:1063`) walks the dominator tree, replacing `LoadLocal`/`StoreLocal` on locals
   with direct SSA `Value` references to defining instructions/phis and assigning each `Definition`
   its `ssa_temp_index`. This is what turns the frame-slot model into true SSA def-use.
6. **Dead-phi removal** — `RemoveDeadPhis(&live_phis)` (`:798`) prunes phis that reach only other
   dead phis.

After `ComputeSSA`, `DEBUG_ASSERT(flow_graph->VerifyUseLists())` (`compiler.cc:811`) checks the
use-list invariants — the foundation every subsequent optimizer pass relies on.

---

## 9. Unoptimized / baseline codegen — correct-but-slow, feedback-collecting

The baseline compile shares `FlowGraphCompiler::CompileGraph()` with the optimizing compiler
(`compiler.cc:1145`), but the IL it consumes is the naive fragment graph (no SSA, all `kTagged`).
The two hallmarks:

### 9.1 Every dynamic call site is an inline cache (no speculation)

`FlowGraphCompiler::GenerateInstanceCall` (`flow_graph_compiler.cc:1138`) — in the **non-optimizing**
branch (`!is_optimizing()`, `:1182-1193`) — emits an IC-stub call:
```
NumArgsTested == 1 -> EmitInstanceCall(StubCode::OneArgCheckInlineCache_entry(), ic_data, …)  (:1184)
NumArgsTested == 2 -> EmitInstanceCall(StubCode::TwoArgsCheckInlineCache_entry(), ic_data, …)  (:1188)
```
These `…CheckInlineCache` stubs do two jobs at once: **dispatch** to the right target for the
receiver's class *and* **record** the receiver class(es) into the call site's `ICData`. There is no
class assumption, no `CheckClass`, no deopt — baseline code is unconditionally correct for any
receiver. (Contrast: the optimizing branch at `:1151-1180` emits `…OptimizedCheckInlineCache`,
megamorphic, or direct calls, and *counts* for reoptimization.)

The `ICData` objects are pre-created and threaded through the IL as `owner()->ic_data_array()`
(§6.3) and via `GetOrAddInstanceCallICData` (`flow_graph_compiler.cc:1635`), keyed by deopt-id
(`deopt_id_to_ic_data_`, `:1688`).

### 9.2 The collected feedback is persisted for the optimizer

When the baseline `Code` is finalized, `function.SaveICDataMap(deopt_id_to_ic_data(),
edge_counters_array)` (`compiler.cc:672-675`) stores that deopt-id → ICData map (plus edge counters)
on the `Function`. When the function later goes hot and is optimized,
`function.RestoreICDataMap(ic_data_array, clone_ic_data)` (`compiler.cc:760`) reloads it so the
`JitOptimizer` can turn observed monomorphic/polymorphic classes into speculative, `CheckClass`-guarded
fast paths. **This feedback loop — baseline collects, optimized speculates — is the reason for the
two tiers.**

### 9.3 The baseline prologue also drives promotion

As shown in §5.2, the unoptimized prologue (`flow_graph_compiler_arm64.cc:938`) is where the
`usage_counter` is incremented and compared to the (size-adaptive) threshold, branching to the
`OptimizeFunction` stub when hot. So a single body of baseline code simultaneously: runs correctly,
collects type feedback, and self-reports when it deserves optimization.

---

## 10. What the front end hands to the optimizer

The front end's work ends at the *inputs* to optimization and codegen. Concretely it produces three
things:

- **(a) an AST** parsed on demand from source (§2–§3);
- **(b) an IL flow graph** — a non-SSA fragment graph for the baseline tier, or an SSA graph for the
  optimizing tier (§6–§8) — with the deopt-id-indexed **ICData feedback** attached to every call site
  (§6.3, §9);
- **(c) the orchestration / hotness / background-compilation machinery** (§4–§5) that decides *when* a
  function is hot enough to be handed to the optimizer, and installs the result safely.

Everything downstream is **Part II**: the optimizer passes run under `if (optimized())` in
`CompileParsedFunctionHelper::Compile` (`compiler.cc:827-1134`) — `JitOptimizer`/`ApplyICData`,
inlining, type propagation, `Canonicalize`, range analysis, LICM/CSE, and the introduction of unboxed
representations + `Box`/`Unbox`; **register allocation** (`FlowGraphAllocator::AllocateRegisters`,
`compiler.cc:1120`); the **ARM64 backend** (`FlowGraphCompiler::CompileGraph`, the
`intermediate_language_arm64.cc` `EmitNativeCode` methods, `assembler_arm64.*`); and the
**deoptimization** machinery (`CheckClass`→deopt guards, deopt-info encoding, lazy deopt) that keeps
all of that speculation correct. The frame-entry code cited in §5.2/§9.3 is the boundary where the two
tiers meet — the same `CompileGraph` call emits both, differing only in the IL it is fed.

---

## Appendix I — Front-end citation index

- Version: `tools/VERSION` (1.24.3 stable).
- Parser entries: `parser.cc:612` (compilation unit), `:954` (class), `:1078` (function on demand),
  `:6473` (top level), `:10574` (statement), `:11052` (binary-expr precedence climb), `:14037`
  (`new`/`const`), `:14532` (primary; `new` dispatch `:14677`/`:14686`).
- Tokenize: `object.cc:9333` (`Script::Tokenize`), `:8901` (`Scanner`); seek `parser.cc:591`.
- AST: `ast.h:19-67` (`FOR_EACH_NODE`, 47 nodes), `:98` (`AstNode`), `:123` (`MakeAssignmentNode`).
- Orchestration: `compiler.cc:192` (pipeline), `:705` (`Compile` pipeline), `:526` (`FinalizeCompilation`),
  `:1219` (`CompileFunctionHelper`), `:1442`/`:1526`/`:1494` (Compile/Optimized/EnsureUnopt),
  `:219` (`CanOptimizeFunction`).
- Hotness: `flag_list.h:119` (30000), `runtime_entry.cc:40-42` (reopt 4000), `:1851`
  (`OptimizeInvokedFunction`), `flow_graph_compiler.cc:1694` (adaptive threshold),
  `flow_graph_compiler_arm64.cc:938` (prologue check).
- Background: `compiler.cc:1870` (queue), `:1970` (`Run`), `:2041` (`CompileOptimized`),
  `:1162-1171` (safepoint install).
- AST→IL: `flow_graph_builder.cc:4385` (`BuildGraph`), `flow_graph_builder.h:238/472/530`
  (visitors), `flow_graph_builder.cc:2512` (instance-call lowering).
- IL: `intermediate_language.h:210` (`Value`), `:663` (`Instruction`), `:1712` (`Definition`);
  `FOR_EACH_INSTRUCTION` (140 ops); `locations.h:23` (`Representation`).
- SSA: `flow_graph.cc:775` (`ComputeSSA`), `:809` (dominators/SEMI-NCA), `:920` (`InsertPhis`),
  `:980` (`Rename`).
- Baseline codegen: `flow_graph_compiler.cc:1138` (`GenerateInstanceCall`), `:1184/1188`
  (IC stubs), `compiler.cc:672-678` (`SaveICDataMap` + attach).


# Part II — From Feedback to Machine Code and Back

*The optimizer, the ARM64 backend, and the deoptimization safety net.*

> Within Part II, a bare section reference (§N) is internal to Part II. This Part picks up exactly
> where Part I left off — an SSA flow graph carrying the deopt-id-indexed ICData feedback that the
> baseline tier collected — and follows it through optimization, into ARM64 machine code, and back
> out again when a speculation fails.

---

The V1 Dart VM is a **speculative optimizing JIT**. Unoptimized code runs first and *collects type feedback* into Inline Caches (ICData). When a function gets hot, the optimizing compiler re-compiles it, **betting** that the observed types keep holding: it devirtualizes calls, inlines, unboxes, and removes checks — each bet backed by a cheap **guard** (`CheckClass`, `CheckSmi`, `CheckArrayBound`, overflow checks). If a guard fails at runtime, the VM **deoptimizes**: it reconstructs the exact unoptimized frame from side tables and resumes in unoptimized code, as if optimization never happened. This document follows that arc: pipeline → SSA passes → dispatch/IC/CHA → register allocation → ARM64 backend → deoptimization → OSR.

---

## 1. The Optimization Pass Pipeline

The optimized compile is driven by `CompileParsedFunctionHelper::Compile` (`compiler.cc:705`). The whole body runs inside a `setjmp`/`LongJumpScope` (`compiler.cc:733-734`) so that a bailout (e.g. ARM/MIPS far-branch retry, or a speculative-inlining abort) can restart compilation. A `CHA cha(thread())` is constructed for the duration (`compiler.cc:739`) — Class Hierarchy Analysis registers itself with the thread and unregisters on destruction, so any CHA assumption made anywhere in the pipeline is captured.

**Type feedback is extracted *before* the graph is built** (`compiler.cc:747-775`): `function.RestoreICDataMap(ic_data_array, clone_ic_data)` (`compiler.cc:760`) rebuilds a `deopt_id → ICData*` map; in background compilation the ICData is *cloned* ("frozen") so it cannot mutate mid-compile. The graph builder then attaches this feedback to the call nodes it creates (`compiler.cc:779-780`).

The **exact ordered sequence** for an optimized (non-OSR) compile (`compiler.cc:796-1134`):

| # | Pass | Call site | Purpose |
|---|------|-----------|---------|
| 0 | `BlockScheduler::AssignEdgeWeights` | `compiler.cc:802` | Edge frequencies for later block reordering (if `reorder_blocks`). |
| 1 | `ComputeSSA(0, NULL)` | `compiler.cc:810` | Transform to SSA form; renaming, phi insertion. |
| 2 | `JitOptimizer optimizer(flow_graph)` | `compiler.cc:840` | The instance driving IC-based specialization. |
| 3 | `optimizer.ApplyICData()` | `compiler.cc:845` | Convert instance calls to typed IL / specialized calls using IC feedback. |
| 4 | `flow_graph->TryOptimizePatterns()` | `compiler.cc:852` | Merge `(a << b) & c` and similar; run early to widen left-shift opportunities. |
| 5 | **Inlining** (guarded by `FLAG_use_inlining`) | `compiler.cc:858-879` | Runs `FlowGraphTypePropagator::Propagate` → `optimizer.ApplyClassIds` → `FlowGraphInliner::Inline`. |
| 6 | `FlowGraphTypePropagator::Propagate` | `compiler.cc:882` | Re-flow types after inlining; eliminate type tests. |
| 7 | `optimizer.ApplyClassIds()` | `compiler.cc:889` | Use propagated cids to specialize further. |
| 8 | `FlowGraphTypePropagator::Propagate` | `compiler.cc:895` | Types for newly added instructions (before canonicalization). |
| 9 | `flow_graph->Canonicalize()` (twice) | `compiler.cc:899-902` | Local instruction simplification; run twice to fully fold `if (a & const == 0)`. |
| 10 | `BranchSimplifier::Simplify` + `IfConverter::Simplify` | `compiler.cc:909-912` | Branch fusion / if-conversion. |
| 11 | `ConstantPropagator::Optimize` → `Canonicalize` → `ConstantPropagator::Optimize` | `compiler.cc:916-929` | SCCP + canonicalization + a second SCCP. |
| 12 | `LICM::OptimisticallySpecializeSmiPhis` | `compiler.cc:933-936` | Speculatively turn single-non-Smi loop phis into Smi phis. |
| 13 | `FlowGraphTypePropagator::Propagate` | `compiler.cc:942` | Recompute types after CP eliminated phis. |
| 14 | `WidenSmiToInt32` + `SelectRepresentations` | `compiler.cc:950-955` | Choose unboxed representations (unbox doubles, widen Smi→Int32 on 32-bit). |
| 15 | `ComputeBlockEffects` → `DominatorBasedCSE::Optimize` (×2 with `Canonicalize`) | `compiler.cc:964-978` | Load forwarding + CSE; a second round for dependent loads. |
| 16 | `LICM::Optimize` (+ `RenameUsesDominatedByRedefinitions`) | `compiler.cc:984-990` | Loop-invariant code motion (after load numbering). |
| 17 | `flow_graph->TryOptimizePatterns()` | `compiler.cc:998` | Re-run pattern merge after CSE. |
| 18 | `DeadStoreElimination::Optimize` | `compiler.cc:1004` | Remove dead stores. |
| 19 | **Range analysis** (`FLAG_range_analysis`): `Propagate` → `RangeAnalysis::Analyze` | `compiler.cc:1012-1019` | Bounds-check + overflow-check elimination. |
| 20 | `ConstantPropagator::OptimizeBranches` | `compiler.cc:1030` | Prune branches proven dead by range analysis. |
| 21 | `FlowGraphTypePropagator::Propagate` | `compiler.cc:1036` | Reaching types for hoisted values. |
| 22 | `TryCatchAnalyzer::Optimize` | `compiler.cc:1043` | Optimize try-block spill stores. |
| 23 | `flow_graph->EliminateEnvironments()` | `compiler.cc:1049` | Detach deopt environments from instructions that cannot deopt (shrinks materializations). |
| 24 | `DeadCodeElimination::EliminateDeadPhis` | `compiler.cc:1054` | Dead phi removal. |
| 25 | `Canonicalize()` | `compiler.cc:1058-1060` | Clean-up. |
| 26 | **Allocation sinking** (`FLAG_allocation_sinking`, single-entry only) | `compiler.cc:1064-1073` | Sink non-escaping allocations to deopt paths. |
| 27 | `EliminateDeadPhis` → `Propagate` → `SelectRepresentations` → `Canonicalize` (×2) | `compiler.cc:1076-1097` | Fix representations of optimizer-inserted phis; fold residual boxing. |
| 28 | `sinking->DetachMaterializations()` | `compiler.cc:1108` | Float `MaterializeObject` off to the side (env-only refs). |
| 29 | `FlowGraphInliner::CollectGraphInfo(flow_graph, true)` | `compiler.cc:1113` | Store instr/call counts for the inliner's future callers. |
| 30 | `RemoveRedefinitions()` | `compiler.cc:1115` | Strip `Redefinition` nodes used only for flow-sensitive typing. |
| 31 | **Register allocation**: `FlowGraphAllocator::AllocateRegisters` | `compiler.cc:1120-1121` | Linear-scan SSA allocation. |
| 32 | `BlockScheduler::ReorderBlocks` | `compiler.cc:1128` | Lay out hot blocks for fall-through. |
| 33 | `FlowGraphCompiler::CompileGraph` | `compiler.cc:1145` | **Backend / codegen** — emit ARM64. |
| 34 | `FinalizeCompilation` | `compiler.cc:1152` / `1169` | Build the `Code` object, install (at a safepoint if background). |

Two observations worth highlighting:

- **Type propagation is run *seven* times** (`compiler.cc:863, 882, 895, 942, 1012, 1036, 1079`). It is cheap and monotone, and every structural pass (inlining, CP, CSE, LICM, range analysis) opens new typing opportunities. The pipeline interleaves it aggressively.
- The pipeline is a **fixed schedule**, not a fixpoint — passes run a bounded number of times in a hand-tuned order. Only *within* a pass (SCCP, range analysis, type propagation) is there iteration to a fixpoint.

`thread()->CheckForSafepoint()` is sprinkled between heavy passes (`compiler.cc:846, 878, 928, 992, 1072, 1122`) so a long optimize can yield to GC/reload.

---

## 2. Key SSA Optimization Passes

### 2.1 Inlining — `flow_graph_inliner.cc` (3752 lines)

Inlining is the highest-value pass: it exposes the callee's body to all subsequent optimizations (the callee's side effects become visible, its checks fold against the caller's types). It is a **budget-driven, feedback-driven, iterative** inliner.

**Heuristic thresholds** (all `DEFINE_FLAG`, `flow_graph_inliner.cc:28-93`):

- `inlining_depth_threshold = 6` — max nesting depth (`:40-43`).
- `inlining_size_threshold = 25` — always inline callees with ≤25 instructions (`:44-48`).
- `inlining_callee_call_sites_threshold = 1` — always inline callees containing ≤1 call (`:49-52`).
- `inlining_callee_size_threshold = 80` — never inline callees larger than this (`:53-56`).
- `inlining_caller_size_threshold = 50000` — stop inlining once the caller balloons (`:57-60`).
- `inlining_constant_arguments_*` (count=1, min=60, max=200) — inline larger callees when constant args are passed (`:61-75`).
- `inlining_hotness = 10` — only inline calls that are ≥10% of the max call count (`:76-80`).
- `inlining_recursion_depth_threshold = 1` — recursion depth cap (`:81-84`).
- `deoptimization_counter_inlining_threshold = 12` — stop inlining into functions that have deoptimized ≥12 times (`:28-31`).

**The core budget test** `CallSiteInliner::ShouldWeInline` (`flow_graph_inliner.cc:543-573`) is a cascade:
```
if (AlwaysInline(callee)) return true;                         // :547
if (inlined_size_ > FLAG_inlining_caller_size_threshold) ...   // :550  humongous caller → stop
if (const_arg_count > 0) { if (instr_count > 200) return false; }  // :554-557
else if (instr_count > 80) return false;                       // :558  too big, no const args
if (instr_count <= 25) return true;                            // :562  small → always
if (call_site_count <= 1) return true;                         // :565  leaf-ish → always
if (const_arg_count >= 1 && instr_count <= 60) return true;    // :568  const args → larger budget
return false;
```
`AlwaysInline` (`flow_graph_inliner.cc:2063-2091`) forces inlining of dispatchers/implicit accessors, `const` functions, and small getters/setters/operators/constructors (< `inline_getters_setters_smaller_than = 10` instrs), plus anything `MethodRecognizer::AlwaysInline` flags.

**Iterative, breadth-first structure.** `CallSiteInliner::InlineCalls` (`flow_graph_inliner.cc:575-621`) works **depth by depth**. It maintains two `CallSites` collections and swaps between them: at each depth it collects all call sites (`FindCallSites`, respecting `inlining_depth_threshold_`), then inlines instance calls, static calls, and closure calls at that depth (`:607-609`), then increments the depth. It early-outs if the caller has already deoptimized past threshold (`:578-580`) or if a depth has more than `max_inlined_per_depth = 500` calls (`:594`). This is why inlining is preceded by type propagation + `ApplyClassIds`: better cids at depth *n* create more inlinable monomorphic sites at depth *n+1*.

`GraphInfoCollector` (`flow_graph_inliner.cc:150-195`) counts instructions and call sites of a candidate graph; these are cached on the `Function` (`optimized_instruction_count`, `optimized_call_site_count`) via `CollectGraphInfo` (`:2020`) so re-inlining the same callee elsewhere is cheap.

**Polymorphic inlining** — `PolymorphicInliner` (`flow_graph_inliner.cc:458-515`, driver `Inline` at `:1907-1986`). For a `PolymorphicInstanceCall` with several receiver-class variants, it decides *per variant* whether to inline, then **builds a decision tree**:

- Variants beyond `FLAG_max_polymorphic_checks` are dropped to `non_inlined_variants_` (`:1913-1916`).
- Frequency gates: a variant seen in `< total >> 5` (~3%) of dispatches is "way too infrequent" and not inlined (`:1933-1938`); `< total >> 4/3` (6%/12%, small vs large) is "too infrequent" (`:1951-1956`). The last two variants get a `try_harder` bonus because inlining *all* cases lets the compiler see every side effect (`:1924-1925`).
- `CheckInlinedDuplicate` / `CheckNonInlinedDuplicate` (`:1457, 1510`) coalesce variants that share a target.
- If any variant inlined, `BuildDecisionGraph` (`:1660+`) emits a `LoadClassId` on the receiver (`:1669-1672`) and, for each inlined variant, a class-id **branch** (`StrictCompare` for a single cid, or a two-branch range test for a cid range, `:1740-1774`) leading to that variant's body. The **last** variant, *if the call is complete or there are no non-inlined variants*, is guarded by a deopting `CheckClassId` instead of a branch (`:1680-1694`) — i.e. "it must be this class, else deopt." Any non-inlined variants fall through to a residual `PolymorphicInstanceCall`/megamorphic call (`:1853-1866`). Every synthesized branch/check `InheritDeoptTarget(zone(), call_)` so a failure deopts to the original call's deopt id.

**How a call site is inlined** — `CallSiteInliner::InlineCall` (`flow_graph_inliner.cc:1125+`) builds the callee's flow graph, creates `ParameterInstr`/`ConstantInstr` stubs for arguments (`CreateParameterStub`, `:631-642` — a constant argument is materialized as a constant, propagating into the callee), then splices the callee graph in place of the call and wires the callee's return values through an `InlineExitCollector`. `TryInlining` (`:644+`) bails when `!function.CanBeInlined()` (`:654`), when a function has deoptimized too many times (`:700-703`), or when `ShouldWeInline` says no.

### 2.2 Type Propagation — `flow_graph_type_propagator.cc` (1532 lines)

The type propagator flows **CompileTypes** (a `(nullable, cid, AbstractType)` triple) through the SSA graph. It is *flow-sensitive*: a `CheckClass` guard narrows the receiver's type in the region it dominates, which is precisely how speculation feeds the rest of the optimizer.

**Two-phase algorithm** (`Propagate`, `flow_graph_type_propagator.cc:63-114`):

1. **Dominator-tree walk with rollback** — `PropagateRecursive(graph_entry)` (`:117-158`). It visits a block, sets reaching types on each value, then recurses into dominated blocks. Crucially it records every type refinement on a `rollback_` stack (`SetTypeOf`, `:181-185`) and unwinds it when leaving the block (`RollbackTo`, `:161-166`). This makes refinements introduced by a guard **scoped to the dominated subtree**: after a `CheckClass(x, C)`, `x` is known to be class `C` only below the check.
2. **Phi worklist fixpoint** — all phis are collected (`VisitJoinEntry`, `:209-213`), reset to `CompileType::None()` (`:79-82`), then `RecomputeType` is iterated to a fixpoint; whenever a definition's type changes, its users are re-enqueued (`:86-108`). This resolves the cyclic types of loop-carried phis.

**Guard visitors are the speculation hooks.** `SetCid(def, cid)` (`:188-193`) installs a narrowed `CompileType::FromCid(cid)`:
- `VisitCheckSmi` → `SetCid(value, kSmiCid)` (`:216-218`).
- `VisitCheckClass` → `SetCid(value, check->cids().MonomorphicReceiverCid())` (`:228-239`).
- `VisitCheckClassId` → `SetCid(load_cid->object, check->cids().cid_start)` (`:243-253`).
- `VisitCheckArrayBound` → the index is Smi (`:221-224`).
- `VisitInstanceCall` narrows the receiver to the IC's monomorphic receiver cid (`:290-302`) and may insert a `Redefinition` to carry the guarded type past the call.
- `VisitAssertAssignable` narrows to the asserted type (`:329-331`).

**CompileType** (`:491-810`) is the lattice element. `ToCid()` (`:585`) collapses to a concrete cid when decidable; `Union` (`:491`) is the join at merge points; `ComputeType` is defined per instruction (e.g. `PhiInstr::ComputeType` at `:743`, `RedefinitionInstr::ComputeType` at `:770`). `CanComputeIsInstanceOf` (`:680`) and `IsMoreSpecificThan` (`:726`) are what lets `is`/`as` tests fold away once the type is known. In checked mode the propagator also *strengthens* assert-assignable chains (`StrengthenAsserts`, `:422+`).

### 2.3 The JIT Optimizer — `jit_optimizer.cc` (1781 lines)

This is where IC feedback becomes specialized IL. It is a `FlowGraphVisitor`; `ApplyICData()` just calls `VisitBlocks()` (`jit_optimizer.cc:50-52`), and `ApplyClassIds()` (`:61-83`) re-walks after inlining to specialize any remaining calls using propagated cids.

**`VisitInstanceCall`** (`jit_optimizer.cc:1418-1530`) is the heart. In order it tries:
1. `is`/`as` → inlined type test/cast (`:1424-1433`).
2. `TryReplaceWithIndexedOp` for `[]`/`[]=` (`:1438-1443`) — LoadIndexed/StoreIndexed.
3. `TryReplaceWithEqualityOp` / `RelationalOp` / `BinaryOp` / `UnaryOp` (`:1445-1461`) — arithmetic/comparison specialization.
4. `TryInlineInstanceGetter` / `TryInlineInstanceSetter` — direct field load/store (`:1462-1467`).
5. `TryInlineInstanceMethod` (`:1469`) — recognized methods.

**`TryCreateICData`** (`jit_optimizer.cc:92-193`) synthesizes IC feedback from *propagated* cids when the runtime collected none, e.g. guessing that if one operand of a `+` is a number, the other is too (`FLAG_guess_icdata_cid`, `:111-119`), and resolving the target for the guessed receiver class (`ResolveDynamicForReceiverClass`, `:143-145`). This lets code paths that never executed unoptimized still get specialized.

**The `polymorphic_with_deopt` decision** (`jit_optimizer.cc:1475-1529`) — the single most V1-defining choice in the optimizer:

- First, `CallTargets::CreateAndExpand(unary_checks)` builds the receiver-class → target table; `has_one_target` is set if all observed classes share one target and it isn't a polymorphic/`runtimeType` target (`:1475-1489`).
- If one target **and** `InstanceCallNeedsClassCheck` says no check is needed (CHA-devirtualized, see §4), replace with a plain `StaticCall` — no guard at all (`:1491-1499`).
- Otherwise, the key branch (`:1512-1529`):
```
if (has_one_target && FLAG_polymorphic_with_deopt &&
    (!ic_data->HasDeoptReason(kDeoptCheckClass) ||
     unary_checks.NumberOfChecks() <= FLAG_max_polymorphic_checks)) {
  AddReceiverCheck(instr);                         // deopting CheckClass guard
  StaticCallInstr* call = StaticCallInstr::FromCall(Z, instr, target);
  instr->ReplaceWith(call, current_iterator());    // ...then an unchecked direct call
} else {
  PolymorphicInstanceCallInstr* call = new PolymorphicInstanceCallInstr(instr, targets, false);
  instr->ReplaceWith(call, current_iterator());    // non-deopting checked poly call
}
```
The comment (`:1502-1511`) states the trade-off exactly: the deopt-guarded `StaticCall` "enables a lot of optimizations because after the class check we can probably inline the call," but "can fall down if new receiver classes arrive... This causes a deopt, and after a few deopts we won't optimize this function any more." So for **very polymorphic sites, or sites that already deoptimized on a class check** (`HasDeoptReason(kDeoptCheckClass)` with too many checks), it keeps a non-deopting `PolymorphicInstanceCall` that falls back to the megamorphic stub instead.

**`SpecializePolymorphicInstanceCall`** (`jit_optimizer.cc:196-224`) — called from `ApplyClassIds`. When `FLAG_polymorphic_with_deopt` is on and type propagation gave a concrete receiver cid, a `PolymorphicInstanceCall` can be turned into a single `StaticCall` if the cid resolves to a single target (`:220-223`). Guarded by `if (!FLAG_polymorphic_with_deopt) return;` (`:198-201`) — with the flag off, no such specialization (it would add a deopt-capable check).

> **V1 / MACDART note.** `FLAG_polymorphic_with_deopt` defaults **on**. It is force-disabled only in precompiled/AOT mode (`flow_graph_compiler.cc:76`), because AOT has no deopt. In the JIT (the MACDART target) it is on, so DeltaBlue-style polymorphic hot loops take the deopt-guarded `StaticCall` path and lean directly on the deopt machinery of §7. Turning it off trades peak speed for never deopting.

### 2.4 Redundancy Elimination — `redundancy_elimination.cc` (3386 lines)

This one file hosts CSE, load/store forwarding, LICM, allocation sinking, dead-phi elimination, and try-catch analysis. Public entries are declared in `redundancy_elimination.h`.

**CSE** — `DominatorBasedCSE::Optimize` (`redundancy_elimination.cc:2363`). It first runs load forwarding (`LoadOptimizer::OptimizeGraph`, if `FLAG_load_cse`), then a scoped dominator-tree walk `OptimizeRecursive` (`:2376`). Rather than integer value-numbering, it keys instructions on their own structural equality via a `CSEInstructionMap` (`:28`) holding two hash maps — `independent_` (no dependencies) and `dependent_` (side-effect-sensitive) — routed by `instr->Dependencies().IsNone()` (`:48-63`). A replacement is used only if `block_effects()->IsAvailableAt(replacement, block)` (`:2382-2390`); side-effecting instructions clear the dependent map via `RemoveAffected` (`:2400`). The map is copied per dominated child except the last (`:2404-2418`).

**Load forwarding** — `LoadOptimizer` (`redundancy_elimination.cc:1447`, entry `OptimizeGraph` at `:1480`, pipeline in `Optimize` at `:1510`). It is a full available-expression dataflow over *memory places*:
- **`Place`** (`:125`) abstracts a memory location; kinds `kField, kVMField, kIndexed, kConstantIndexed` (`:127-144`). The alias lattice (`*.f`, `X.f`, `*[*]`, `*[C]`, `X[C]`, …) is documented at `:75-123`. `ToAlias` computes the least-generic alias, keeping the instance `X` only for provable allocations (`IsAllocation` recognizes `AllocateObject`/`CreateArray`/context/factory calls, `:442-448`).
- **`AliasedSet`** (`:654`) maps aliases → sets of place ids, with kill sets (`ComputeKillSet`, `:876`) that encode field and TypedData element-size aliasing.
- **Escape analysis** — `ComputeAliasing` (`:1002`) is a worklist fixpoint that optimistically marks allocations `NotAliased` and escalates when a use creates an alias; rolled back in `~LoadOptimizer` (`RollbackAliasedIdentites`, `:711-715`) since later passes may remove the aliasing instruction.
- **Dataflow** — `ComputeInitialSets` (`:1533`, gen/kill per block, store→available-value), `ComputeOutSets` (`:1754`, intersection of predecessor OUTs — available-expression), `ComputeOutValues` (`:1827`, propagates concrete `Definition*` values and inserts **phis for loads** where predecessors disagree, `:1854-1866`), `ForwardLoads` (`:2038`), `EmitPhis` (`:2295`, drops redundant/congruent load-phis).

**Store elimination** — `StoreOptimizer : LivenessAnalysis` (`redundancy_elimination.cc:2423`; entry `DeadStoreElimination::Optimize` at `:2630`). Backward liveness over places: a store to a place that is later overwritten and never loaded is dead and removed (`:2519-2529`). `CanEliminateStore` (`:2473`) refuses to drop field *initializer* stores; immutable fields never participate.

**LICM** — `LICM::Optimize` (`redundancy_elimination.cc:1398`). For each loop header with a pre-header, an instruction is hoistable if `AllowsCSE() && block_effects->CanBeMovedTo(instr, pre_header)` or it is a loop-invariant load (`IsLoopInvariantLoad`, `:1276`), and all its inputs dominate the pre-header (`:1426-1433`). The V1-critical bit is `LICM::Hoist` (`:1290`): before moving a **speculative check** out of the loop it calls `set_licm_hoisted(true)` on `CheckClass`, `CheckSmi`, `CheckEitherNonSmi`, `CheckArrayBound`, `TestCids` (`:1293-1303`). That tag flows to the deopt reason (`ICData::kHoisted`, see `CheckSmiInstr::EmitNativeCode`, `intermediate_language_arm64.cc:5581-5582`) so that if a hoisted check ever deopts, the runtime clears `allows_hoisting_check_class()` and LICM is **permanently disabled for that function** — the whole pass bails at `:1399-1402` if that bit is clear. `OptimisticallySpecializeSmiPhis` (`:1373`, helper `TrySpecializeSmiPhi` at `:1323`) is the same idea for phis: a loop phi with a single non-Smi dynamic input from the pre-header is optimistically retyped Smi, its `CheckSmi` hoisted, backed by deopt.

**Allocation sinking** — `AllocationSinking::Optimize` (`redundancy_elimination.cc:2949`). It finds non-escaping allocations whose only uses are stores (`CollectCandidates`, `:2750`; `IsAllocationSinkingCandidate`, `:2683`), inserts `MaterializeObject` instructions at *every deopt point* describing the object's field state (`InsertMaterializations`, `:3193`), forwards away the now-redundant loads, then removes the real allocation (`EliminateAllocation`, `:2714`). `DetachMaterializations` (`:3004`) floats the materializations off the instruction stream so they are referenced only from deopt environments. This pass exists *entirely* because of deopt: the object is never allocated on the fast path, but if execution deoptimizes the `MaterializeObject` reconstructs it.

### 2.5 Range Analysis — `flow_graph_range_analysis.cc` (~3085 lines)

Range analysis proves integer bounds to remove two kinds of deopt guards: **array bounds checks** and **Smi/int arithmetic overflow checks**.

**`Analyze()`** (`:27-41`) runs, in order: `CollectValues` (`:215`), `InsertConstraints` (`:435`), `DiscoverSimpleInductionVariables` (`:169`), `InferRanges` (`:708`), `EliminateRedundantBoundsChecks` (`:1461`), `MarkUnreachableBlocks` (`:1490`), `NarrowMintToInt32` (`:1575`), integer-instruction selection (`iis.Select()`, `:1595`), `RemoveConstraints` (`:1525`).

**Representation** — `RangeBoundary` (`.h:13-287`) is `{kUnknown, ±Infinity, kSymbol, kConstant}`; a symbolic boundary is `symbol(Definition*) + offset` (`.h:207-213`). `Range` is a `[min, max]` pair (`.h:290-459`) with `Full(size)` for Smi/Int32/Int64. The analysis caches `smi_range_` (full Smi) and `int64_range_` (full Int64) as safe approximations for values only *typed* smi/int by the propagator (`.h:492-494`, `GetSmiRange`/`GetIntRange` at `:446-487`).

**Bounds-check elimination** — `CheckArrayBoundInstr::IsRedundant(length)` (`:3031-3082`) proves `0 <= index < length`: the index range must be provably non-negative (`:3048-3050`), then it compares `index.UpperBound()` against `length.LowerBound()` both as constants (`:3062-3063`) and symbolically by canonicalizing both to the same symbol and comparing offsets (`:3066-3078`). Redundant checks are removed in `EliminateRedundantBoundsChecks` (`:1476-1477`); when not statically provable and `allows_bounds_check_generalization()`, `BoundsCheckGeneralizer::TryGeneralize` (`:928`) hoists a generalized `0 <= lo < hi < length` set of checks out of the loop (LICM-style, backed by deopt) — disabled in AOT (`:1464-1468`).

**Overflow-check removal** — `BinaryIntegerOpInstr::InferRangeHelper` (`:2869-2892`): after computing the result range, if `!is_truncating()` it sets `set_can_overflow(!range->Fits(range_size))` (`:2887-2888`). When the inferred range fits the representation, `can_overflow` becomes false and codegen omits the overflow-deopt branch. `NarrowMintToInt32` (`:1575`) similarly rewrites 64-bit ops to 32-bit with `set_can_overflow(false)` when ranges fit Int32.

**Constraints** — `ConstraintInstr` is an SSA pseudo-copy annotated with a range, inserted on a branch edge where a comparison holds (`ConstrainValueAfterBranch`, `:355-395`; true edge uses `op_kind`, false edge uses the negated comparison). `ConstraintInstr::InferRange` intersects the incoming Smi range with the constraint (`:2741-2759`); an unsatisfiable intersection marks the edge dead, later pruned by `MarkUnreachableBlocks` and finished by `ConstantPropagator::OptimizeBranches`.

**Fixpoint** — `InferRanges` runs three sweeps (`:742-757`): `Iterate(NONE, 2)` (two exact passes), `Iterate(WIDEN, kMaxInt32)` (widening to ±infinity for fast convergence, `WidenMin/WidenMax` at `:508-561`), then `Iterate(NARROW, kMaxInt32)` (recover precision, `NarrowMin/NarrowMax` at `:570-597`). `PhiInstr::InferRange` (`:2709`) joins input ranges and calls `EnsureAcyclicSymbol` (`:2674`) to break self-referential phi cycles by snapping to Smi min/max.

### 2.6 Constant Propagation — `constant_propagator.cc` (1743 lines)

Textbook **Wegman-Zadeck Sparse Conditional Constant Propagation** — folds constants *and* prunes unreachable branches simultaneously, which a separate CP + DCE cannot match. Self-described in `constant_propagator.h:13-14`.

**Lattice** — three levels compared by raw pointer identity against `Object::unknown_constant()` (top) and `Object::non_constant()` (bottom), with any other `Object&` a constant (`constant_propagator.cc:34-35`, predicates in `.h:52-58`). `Join` computes the least-upper-bound (`:88-106`): differing constants meet to non-constant.

**Two worklists + reachability** — `block_worklist_`, `definition_worklist_`, and a `reachable_` BitVector by preorder number (`.h:78-85`). `Analyze()` (`:1490-1509`) seeds the entry, then drains blocks (priority) and definitions to a fixpoint. `SetReachable` (`:59-64`) makes block discovery idempotent.

**Key transfer functions** — `VisitPhi` (`:305-320`) joins **only reachable** predecessor inputs (the SCCP refinement). `VisitBranch` (`:208-231`) marks a successor reachable only if the branch's own block is reachable; a constant condition activates just one successor, a non-constant both, `unknown` neither yet. Integer/comparison/double/load folds are in `VisitBinaryIntegerOp` (`:943`), `VisitEqualityCompare` (`:542`), `VisitStrictCompare` (`:435`), `VisitBinaryDoubleOp` (`:1169`), `VisitLoadField` (`:817`, folds immutable lengths), etc.

**`OptimizeBranches`** (`:50-56`) is the *separate* pipeline entry (step 20) — it runs `Analyze` + `Transform` + `EliminateRedundantBranches` (`:1534`), the last folding a branch whose true/false targets converge on the same phi-less join, and consuming range-analysis' `constant_target()` marks to prune dead edges.

**`Transform`** (`:1590-1741`) writes results back: dead (unreachable) blocks are cleared (`:1603-1611`), phi inputs from dead predecessors pruned (`:1613-1660`), constant Smi/old-space definitions replaced by canonical `ConstantInstr` (`:1664-1683`), dead branches rewritten to `Goto`s (`:1686-1729`), then `DiscoverBlocks`/`MergeBlocks`/`ComputeDominators` rebuild the CFG (`:1732-1735`).

### 2.7 Branch canonicalization

`BranchSimplifier::Simplify` (`branch_optimizer.cc:90`) fuses control flow so the true/false targets become joins, and `IfConverter::Simplify` (`branch_optimizer.cc:244`) converts simple diamonds into `IfThenElse` instructions (avoiding branches). Both run at pipeline step 10.

---

## 3. Inline Caches & Dispatch

The `ICData` class is implemented in **`object.cc`** (there is no `ic_data.cc` in this tree); methods span `object.cc:13029-14090`, declaration `object.h:1883`, raw layout `raw_object.h:1510`.

**What an ICData holds** (`raw_object.h:1510-1541`): `ic_data_` (entries array of `class-ids → target, count`), `target_name_`, `args_descriptor_`, `owner_` (parent function or original for a clone), `deopt_id_`, and `state_bits_` packing `NumArgsTested`, deopt-reason bits, and a static-call bit. Each entry is `num_args + 1 (target) + 1 (count)` slots (`TestEntryLengthFor`, `object.cc:13171`), terminated by an all-`smi_illegal_cid` sentinel (`WriteSentinel`, `:13227`). Deopt reasons live in `state_bits_`; `HasDeoptReason(reason)` is `(DeoptReasons() & (1<<reason)) != 0` (`object.cc:13142`) — this is how the optimizer knows a site previously deoptimized (see the `kDeoptCheckClass` gate in §2.3).

**The monomorphic → polymorphic → megamorphic progression:**

1. **Feedback collection (unoptimized).** IC-miss stubs call `InlineCacheMissHandler` (`runtime_entry.cc:933`): resolve the target, then record the receiver class(es) — `AddReceiverCheck(cid, target)` for 1 arg (`:969`), `AddCheck(class_ids, target)` for N (`:971-976`). One class per miss.
2. **Monomorphic (1 entry) → polymorphic (>1 entry).** `AddReceiverCheck` (`object.cc:13542`) appends an entry, keeping Smi first (`:13557-13565`). `NumberOfChecks` counts to the sentinel (`:13186`); `HasOneTarget` (`:13922`) detects a poly-by-cid but single-target site.
3. **→ megamorphic.** Threshold is `FLAG_max_polymorphic_checks = 4` (`flag_list.h:111`). Two mechanisms: (a) the *optimizer* refuses the deopting single-target form once `NumberOfChecks() > 4` and emits a non-deopting `PolymorphicInstanceCall` (`jit_optimizer.cc:1512-1529`); (b) at runtime the *switchable call* state machine, after adding a check, if `> FLAG_max_polymorphic_checks`, looks up a `MegamorphicCache` (`MegamorphicCacheTable::Lookup`) and `CodePatcher::PatchSwitchableCallAt` installs the megamorphic-call stub (`runtime_entry.cc:1447-1465`); further misses just `cache.Insert(cid, target)` (`:1468-1472`). The switchable states are `UnlinkedCall` (`:1211`), `MonomorphicMiss` (`:1281`), `SingleTargetMiss` (`:1123`).

**Codegen of the dispatch forms** (ARM64, `flow_graph_compiler_arm64.cc`):
- `EmitInstanceCall` / `EmitOptimizedInstanceCall` (`:1186-1219`) — load the ICData into `R5`, call the InlineCache stub; the optimized variant also passes the top function in `R6` for the reoptimization counter.
- `EmitMegamorphicInstanceCall` (`:1222-1267`) — load receiver into `R0`, the `MegamorphicCache` into `R5`, and call `Thread::megamorphic_call_checked_entry`.
- `EmitSwitchableInstanceCall` (`:1270-1297`) — receiver in `R0`, `ICCallThroughFunction` stub in `CODE_REG`, ICData in `R5`; this is the self-modifying monomorphic→polymorphic call chain.

**How feedback reaches the optimizer.** `Function::SaveICDataMap` (`object.cc:7392`) persists per-deopt-id ICData (slot 0 = edge counters); `RestoreICDataMap` (`:7416`) rebuilds the `deopt_id → ICData*` map for the optimizing compiler, optionally deep-cloning each record (`ICData::Clone`, `:14080`) so a background compile sees a stable snapshot. `AsUnaryClassChecks` (`object.h:2073`, impl `object.cc:13775`) reduces a 2-arg IC to receiver-class-only feedback, and `AsUnaryClassChecksSortedByCount` (`:13836`) sorts variants hottest-first — exactly the input the polymorphic inliner and `VisitInstanceCall` consume.

---

## 4. Class Hierarchy Analysis — `cha.cc` (184 lines)

CHA lets the optimizer **devirtualize** a call to a `StaticCall` with *no* class check when a class currently has a single concrete implementation — a speculation validated not by a runtime guard but by a **dependency that deoptimizes the code when a violating class is loaded**.

`CHA` is a `StackResource` (`cha.h:20`) chained on the thread (`cha.h:22-33`) holding `guarded_classes_` — the set of classes an in-progress compile has assumed things about (`cha.h:73-83`).

**Queries** (`cha.cc`): `HasSubclasses` (`:36`, conservatively true for VM/`Object` classes, else checks `direct_subclasses()`), `ConcreteSubclasses` (`:62`), `IsImplemented` (`:87`), `HasOverride` (`:132`, walks finalized subclasses for a name), `IsConsistentWithCurrentHierarchy` (`:120`, recomputes finalized-subclass counts to validate a background compile before install).

**Recording and invalidation** — the safety net:
1. When the optimizer devirtualizes using CHA, it records the class: `thread()->cha()->AddToGuardedClasses(type_class, /*subclass_count=*/0)` (`jit_optimizer.cc:1213-1226`), gated by `FLAG_use_cha_deopt || all_classes_finalized()`.
2. On install, `CHA::RegisterDependencies(code)` (`cha.cc:177`) calls `cls->RegisterCHACode(code)` for each guarded class, appending the `Code` to that class's weak `dependent_code()` list (`Class::RegisterCHACode`, `object.cc:2835`).
3. When a new class is finalized, `ClassFinalizer::FinalizeClass` (under `FLAG_use_cha_deopt`) calls `RemoveCHAOptimizedCode` (`class_finalizer.cc:40`) for the affected super-classes/interfaces → `cls.DisableCHAOptimizedCode` → `CHACodeArray::DisableCode` (`object.cc:2848`), which **deoptimizes** the dependent optimized code.

`FLAG_use_cha_deopt` defaults **true** (`flag_list.h:175`) and is force-off in AOT (`flow_graph_compiler.cc:80`) where deopt is impossible. So in the MACDART JIT, CHA devirtualization is active and self-healing: an assumption of "single implementation" can never be silently violated because loading a subclass eagerly throws away the code that assumed otherwise.

---

## 5. Register Allocation — `flow_graph_allocator.cc` (3098 lines)

A **linear-scan register allocator over SSA** (Wimmer/Mössenböck-style), operating on a linearized instruction numbering with `LiveRange`s built from a backward liveness analysis.

**`AllocateRegisters`** driver (`flow_graph_allocator.cc:2996-3095`):
1. `CollectRepresentations` (`:2997`) — tagged vs unboxed per vreg.
2. `liveness_.Analyze()` (`:2999`) — SSA liveness.
3. `NumberInstructions()` (`:3001`) — assign even/odd linear positions so uses and defs get distinct positions (parallel moves sit at gaps).
4. `DiscoverLoops()` (`:3003`) — loop nesting for spill heuristics.
5. `BuildLiveRanges()` (`:3009`) — construct live intervals + use positions.
6. `PrepareForAllocation` + `AllocateUnallocatedRanges` for **CPU** registers (`:3029-3031`), then again for **FPU** registers (`:3042-3049`) — a two-pass split so integer and float allocation are independent.
7. `ResolveControlFlow()` (`:3055`) — connect split siblings across block boundaries with moves; wire phi inputs.
8. Record `spill_slot_count` on the graph entry (`:3057-3060`).

**The location model.** A `LiveRange` (`:392`) is a chain of `UseInterval`s plus `UsePosition`s, each carrying a `Location*` slot to be filled with the assigned register/stack slot. `AddUse`/`AddHintedUse` (`:271, 326`) record where a value is needed and any register hint (e.g. a fixed-register call argument). `AddSafepoint` (`:307`) records GC-safepoint positions so the allocator can emit stack maps for pointer-holding ranges.

**The allocation decision** — `AllocateUnallocatedRanges` (`:2755`) processes ranges by start position from a priority queue. For each unallocated range:
- `AllocateFreeRegister` (`:2185`) tries to find a register free for the whole range, honoring the register hint first (`:2195`) and otherwise picking the register whose first intersection with the range is farthest away (`FirstIntersectionWithAllocated`, `:2095`). If a free register covers the entire range, assign it.
- Otherwise `AllocateBlockedRegister` must **spill**: it computes, for each register, the next use position of the range currently occupying it, and either spills the current range (`Spill`, `:2082`; `SpillAfter`/`SpillBetween`, `:1944, 1923`) or **evicts** the blocking range by splitting it (`AssignNonFreeRegister` + `EvictIntersection`, `:2483-2499`) and re-queuing the tail. `SplitBetween` (`:686+`) splits a live range at a chosen position, creating a sibling that will be allocated separately (possibly to a stack slot).
- `AllocateSpillSlotFor` (`:1969`) assigns a stack slot when a range is spilled; double/quad slots are tracked separately (`quad_spill_slots_`).

**Connecting the pieces** — after allocation, `ConnectSplitSiblings` (`:2801`) inserts moves where a value moves between a register and a stack slot across a split point, and `ResolveControlFlow` (`:2871`) inserts the parallel moves at block boundaries (including phi resolution). All these moves are emitted later by the `ParallelMoveResolver` in the backend.

Fixed/blocked registers (e.g. `SP`, `THR`, `PP`, `TMP`) are excluded via `blocked_cpu_registers_` passed to `PrepareForAllocation` (`:3030`).

---

## 6. The Backend / Codegen

Two layers: the **architecture-independent driver** `flow_graph_compiler.cc` (2021 lines) and the **ARM64 emitter** `flow_graph_compiler_arm64.cc` (1780 lines), plus the per-instruction `EmitNativeCode` methods in `intermediate_language_arm64.cc` and the `Assembler` in `assembler_arm64.{h,cc}`.

**`CompileGraph`** (ARM64, `flow_graph_compiler_arm64.cc:989-1080`): `InitCompiler` → (AOT-only `MonomorphicCheckedEntry`) → `TryIntrinsify` (fast path for recognized methods, returns early if it fully handles the function) → `EmitFrameEntry` (`:938`, push FP/PP/PC-marker, bump SP for spill slots) → argument-count check / `CopyParameters` for optional params (skipped for OSR, `:1035`) → (unoptimized only) null-initialize spill slots (`:1049-1072`) → **`VisitBlocks()`** → `brk 0` → **`GenerateDeferredCode()`**.

**`VisitBlocks`** (`flow_graph_compiler.cc:515-588`) is the emit loop. For each block in `block_order()` it emits the block entry, sets `pending_deoptimization_env_` from the block/instruction environment (`:545, 568`), and calls `instr->EmitNativeCode(this)` for every instruction (`:569`). `ParallelMove` instructions are handled by `parallel_move_resolver_.EmitNativeCode` (`:562-563`) — this is where the register allocator's inserted moves become real `mov`/`ldr`/`str` (the resolver breaks move cycles with a scratch register, `:1459+`).

> **MACDART patch — the `VisitBlocks` NULL deref.** `loop_headers` is only computed when `Assembler::EmittingComments()` is true (`flow_graph_compiler.cc:517-522`); otherwise it stays `NULL` and is then passed as `*loop_headers` to `LoopInfoComment` (`:540`). Forming a reference from a NULL pointer is undefined; on the MACDART Apple-Silicon port this is one of the two hand-fixed ARM64 corners in Part II (the fix guards the comment path so the NULL is never dereferenced). It is benign only because `LoopInfoComment` itself re-checks `EmittingComments()` before touching the reference — but the port hardened it.

**How an IL instruction becomes machine code.** Each `Instruction` implements `MakeLocationSummary(zone, opt)` (declares input/output/temp `Location` constraints for the allocator) and `EmitNativeCode(compiler)` (emits the actual instructions once the allocator has filled the locations). Example — `CheckClassIdInstr::EmitNativeCode` (`intermediate_language_arm64.cc:5554-5565`): grab the deopt label from `AddDeoptStub(deopt_id(), kDeoptCheckClass)`, compare the value to the expected cid, and `b(deopt, NE)` (single cid) or an unsigned range compare + `b(deopt, HI)` (cid range). `CheckSmiInstr::EmitNativeCode` (`:5579-5583`) tags the deopt with `ICData::kHoisted` when `licm_hoisted_` so a hoisted-check deopt disables further LICM. These are the concrete **speculation guards** — a cheap compare + conditional branch to a deopt stub.

**`EmitPolymorphicInstanceCall`** (`flow_graph_compiler.cc:1791-1824`) is the codegen counterpart of the §2.3 decision:
```
if (FLAG_polymorphic_with_deopt) {
  Label* deopt = AddDeoptStub(deopt_id, kDeoptPolymorphicInstanceCallTestFail);   // :1802
  EmitTestAndCall(targets, ..., deopt /*no cid match → deopt*/, &ok, ...);         // :1804
} else if (complete) {
  EmitTestAndCall(targets, ..., NULL /*no deopt*/, &ok, ...);                       // :1812
} else {
  EmitSwitchableInstanceCall(unary_checks, ...);   // non-deopting fallback         // :1820
}
```
`EmitTestAndCall` (`flow_graph_compiler.cc:1828-1942`) emits the inline class-id decision tree: load receiver (`EmitTestAndCallLoadReceiver`), special-case Smi (`EmitTestAndCallSmiBranch`), load the cid (`EmitTestAndCallLoadCid`), then for each target compare the cid (`EmitTestAndCallCheckCid`) and `GenerateStaticDartCall` to that target. Rare targets (`count < total_ic_calls >> 5`) are not tested inline — control falls to `EmitMegamorphicInstanceCall` instead (`:1911-1940`). The ARM64 primitives are at `flow_graph_compiler_arm64.cc:1463-1539`. With the flag **on**, the "no match" label is the deopt stub (speculation); with it **off** and `complete`, there is no deopt and the last case is unconditional; otherwise it degrades to the switchable/megamorphic call.

**Deferred code / deopt stubs** — `GenerateDeferredCode` (`flow_graph_compiler.cc:643-652`) emits all slow-path code and then, for each `CompilerDeoptInfoWithStub` in `deopt_infos_`, calls `GenerateCode(this, i)` (`:649-651`). On ARM64 that is `CompilerDeoptInfoWithStub::GenerateCode` (`flow_graph_compiler_arm64.cc:166-183`): bind the stub label, optionally `brk 0` (`FLAG_trap_on_deoptimization`), `Push(CODE_REG)`, `BranchLink(StubCode::Deoptimize_entry())`. So every guard's failure edge lands here and funnels into the one Deoptimize stub.

---

## 7. Deoptimization — the Safety Net

Everything speculative above is safe only because the VM can, at any guard failure, **rebuild the exact unoptimized frame and resume**. The machinery is split across the compiler (emit DeoptInfo tables), the stub (`stub_code_arm64.cc`), and the runtime (`deopt_instructions.cc`).

### 7.1 DeoptInfo — the recipe attached to each deopt point

At each potential deopt point, `CompilerDeoptInfo::CreateDeoptInfo` (`deopt_instructions.cc:81-162`) walks the instruction's **deopt environment** (the SSA values live at that point, captured in `pending_deoptimization_env_`) and emits a list of `DeoptInstr`s describing how to fill each slot of the target unoptimized frame — from a CPU register, an FPU register, a stack slot, a constant, or a *deferred materialization*. `DeoptInfoBuilder` (`:1033+`) compresses these into a shared trie (`TrieNode`, `:1001`) so that the many deopt points of a function share suffixes — deopt tables are large, and this keeps them compact. Materializations (`AddMaterialization`, `:1212`; `EmitMaterializationArguments`, `:1241`) come from allocation sinking (§2.4).

The `DeoptInstr` kinds (`deopt_instructions.cc`): `kRetAddress` (`:473`), `kCallerFp` (`:780`), `kMaterializeObject` (`:866`), plus `DeoptWordInstr`/`DeoptMintPairInstr`/`DeoptInt32Instr`/… for copying values from register/stack sources (`CpuRegisterSource`, `:547-651`). `DeoptInstr::Create` (`:913`) reconstructs them from the packed table.

### 7.2 Eager vs lazy deopt

- **Eager deopt** — a guard (`CheckClass`/`CheckSmi`/`CheckArrayBound`/overflow) fails *right now*. It jumps to its deopt stub (`AddDeoptStub`, `flow_graph_compiler.cc:866-890`), which pushes `CODE_REG` and calls `StubCode::Deoptimize` → `GenerateDeoptimizeStub` → `GenerateDeoptimizationSequence(kEagerDeopt)`. The stub reads the DeoptInfo *at the current PC*.
- **Lazy deopt** — the code cannot deopt in place (e.g. a call is in flight, or CHA/field-guard invalidation must retire a function that is currently on the stack). The runtime *patches the return address* of the optimized frame so that when the call returns it lands in `GenerateDeoptimizeLazyFromReturnStub` (`stub_code_arm64.cc:581-590`) or `...FromThrowStub` (`:595-604`). These push a **zap** value instead of `CODE_REG` and a zap return address (`:582-586`) and run `GenerateDeoptimizationSequence(kLazyDeoptFromReturn/Throw)` — the difference being that they preserve the in-flight result (`R0`) or exception/stacktrace (`R0`/`R1`) across the frame rewrite (`:509-516, 527-543, 567-572`).

`AddDeoptIndexAtCall` (`flow_graph_compiler.cc:711`) and the `deopt_id_after`/`ToDeoptAfter` machinery around every Dart call (`GenerateDartCall`, `flow_graph_compiler_arm64.cc:1101-1119`) register the *continuation* deopt point that a lazy deopt after a call will use.

### 7.3 The deopt stub — and the MACDART Apple-Silicon fix

`GenerateDeoptimizationSequence` (`stub_code_arm64.cc:465-577`) is shared by all three deopt kinds. It:
1. `EnterStubFrame` (`:469`).
2. **Saves all CPU registers** in enumeration order (`:483-494`):
   ```cpp
   for (intptr_t i = kNumberOfCpuRegisters - 1; i >= 0; i--) {
     const Register r = static_cast<Register>(i);
     if (r == CODE_REG) { ... ldr R25; str R25, [SP,#-8]! }
     else __ str(r, Address(SP, -1 * kWordSize, Address::PreIndex));   // :492
   }
   ```
   then all V (float) registers (`:496-499`).
3. `CallRuntime(kDeoptimizeCopyFrameRuntimeEntry, 2)` (`:506`) — returns the frame size.
4. Rewinds SP, re-enters a stub frame, `CallRuntime(kDeoptimizeFillFrameRuntimeEntry, 1)` (`:535`).
5. Re-enters again and `CallRuntime(kDeoptimizeMaterializeRuntimeEntry, 0)` (`:562`) to allocate deferred objects, then removes the materialization args (`:575`).

> **MACDART patch — `str SP, [SP,#-8]!`.** In ARM64 the Dart stack pointer is `SP = R15` (`constants_arm64.h:28, 56`). The save loop at `stub_code_arm64.cc:483-494` iterates over **all** `kNumberOfCpuRegisters` (32) registers; when `i == 15`, `r == R15 == SP`, so line `:492` emits `str R15, [SP, #-8]!` — i.e. *store SP using SP as the base with pre-index writeback*. On ARM64 storing `SP` with `SP` as the writeback base is constrained-unpredictable, and **Apple Silicon traps it**. This is the exact instruction the MACDART port fixed in the ARM64 **deopt stub** — one of the two headline ARM64 corrections in Part II. Because *every* eager and lazy deopt runs this sequence, the bug manifested precisely on the deopt-heavy path (see §8 / DeltaBlue).

### 7.4 Reconstructing the frame — `DeoptContext`

The runtime side is `DeoptContext` (`deopt_instructions.cc:28-133`). Its constructor reads the DeoptInfo for the faulting PC (`code.GetDeoptInfoAtPc(frame->pc(), &deopt_reason_, &deopt_flags_)`, `:56-57`), sizes the **source frame** (the optimized frame + saved registers, `:88-92`) and the **destination frame** (the unoptimized frame, `DeoptInfo::FrameSize`, `:108`).

`FillDestFrame` (`:288-345`) does the reconstruction:
1. Unpack the DeoptInstr list (`DeoptInfo::Unpack`, `:295`).
2. `PrepareForDeferredMaterialization` — for each `kMaterializeObject`, create a `DeferredObject` (not yet filled) so objects can reference each other (`:313-324`).
3. Walk the instruction list back-to-front, executing each DeoptInstr to write one destination slot (`instr->Execute(this, to_addr)`, `:327-336`).

`MaterializeDeferredObjects` (`:402-413`) then allocates and fills the sunk objects (`GetDeferredObject(i)->Fill()`), after the frame is fully rebuilt and it is GC-safe. The deopt reason (`deopt_reason_`) and the `deoptimization_counter` on the function are bumped; after enough deopts a function is marked non-optimizable and stops being reoptimized (this is the throttle referenced all over the optimizer — e.g. `HasDeoptReason(kDeoptCheckClass)` in §2.3, `deoptimization_counter_inlining_threshold` in §2.1).

The net effect: a `CheckClass` that fails restores registers, calls into the runtime, rebuilds the unoptimized frame slot-by-slot from the DeoptInfo recipe, materializes any allocation-sunk objects, and returns into unoptimized code at the deopt continuation point — semantically identical to never having optimized.

---

## 8. OSR and Synthesis

### 8.1 On-Stack Replacement

OSR lets a function that is *already running* a hot loop switch to optimized code mid-flight, without waiting for the next call. Back-edges in unoptimized code increment a counter and, on overflow, request OSR via the stack-overflow check.

`DRT_StackOverflow` (`runtime_entry.cc:1775-1830`) handles the `Thread::kOsrRequest` flag: it finds the current unoptimized Dart frame (`:1777-1784`), computes the OSR deopt id for the current PC (`GetDeoptIdForOsr(frame->pc())`, `:1806-1807`), compiles the function optimized *for that OSR id* (`Compiler::CompileOptimizedFunction(thread, function, osr_id)`, `:1817-1818`), and then **rewrites the running frame** to enter the new code: `frame->set_pc(optimized_entry)` and `frame->set_pc_marker(code)` (`:1823-1828`). It refuses OSR on intrinsified functions (`:1798-1801`).

The OSR compile is the same pipeline, but the graph builder specializes for it: `GraphEntryInstr` is built with `osr_id_` (`flow_graph_builder.cc:4402`), and when `osr_id_ != kNoOSRDeoptId`, `PruneUnreachable` (`:4428-4434`) does a DFS from the OSR entry, deleting everything not reachable from it (only the loop and its continuation survive; catch entries are kept). In SSA construction, `IsCompiledForOsr()` makes the *live locals* at the OSR point behave like parameters rather than being initialized (`flow_graph.cc:1004-1017`) — the values are already live on the stack of the running frame.

### 8.2 Synthesis — how it all fits together

The V1 Dart VM's performance model is a tight loop of **observe → speculate → guard → deoptimize**:

1. **Observe.** Unoptimized code runs and records receiver classes and operand types into ICData (§3), and counts calls and loop back-edges. This is free, ambient profiling.
2. **Speculate.** When a function is hot, the optimizing pipeline (§1) runs. Type propagation (§2.2) turns IC cids into `CompileType`s; the JIT optimizer (§2.3) devirtualizes monomorphic calls to `StaticCall`s, either unguarded (CHA proved a single implementation, §4) or behind a `CheckClass` (the `polymorphic_with_deopt` path); the inliner (§2.1) splices hot callees in — including polymorphic decision trees; constant propagation (§2.6), CSE/load-forwarding (§2.4), range analysis (§2.5), and allocation sinking remove work the now-visible types prove redundant. Representation selection unboxes doubles and ints.
3. **Guard.** Every speculative assumption is backed by something cheap: a `CheckClass`/`CheckSmi`/`CheckArrayBound`/overflow compare-and-branch (§6), a switchable-call fallback, or — for CHA — a class-load dependency that will retire the code. Range analysis and LICM even *hoist* guards out of loops, tagging them so a failure disables the optimization.
4. **Deoptimize.** If a guard fails — a new receiver class shows up, an int overflows Smi range, an index goes out of bounds, or a class load violates a CHA assumption — the deopt machinery (§7) reconstructs the unoptimized frame from DeoptInfo side tables and resumes in unoptimized code, correctly and transparently. The deopt counter throttles: after a few deopts a site stops being speculated (the optimizer reads `HasDeoptReason`), so pathological code degrades gracefully to the non-deopting megamorphic/switchable path instead of thrashing.
5. **OSR** closes the loop for long-running loops that never return, letting them jump into optimized code without a re-entry.

**Register allocation** (§5) and the **ARM64 backend** (§6) turn the optimized SSA graph into real machine code, with the deopt stubs (§7.3) as the landing pads for every guard.

**For the MACDART port specifically**, the two hand-fixed ARM64 corners in the optimizer/backend both sit on the *hottest speculative path*:
- the **deopt stub's** `str SP, [SP,#-8]!` register-save (`stub_code_arm64.cc:492`, with `SP == R15`), which Apple Silicon traps — hit by *every* eager and lazy deopt; and
- the **`VisitBlocks` NULL deref** on `loop_headers` (`flow_graph_compiler.cc:517-540`) in the codegen driver.

Because `FLAG_polymorphic_with_deopt` defaults on in the JIT, benchmarks like **DeltaBlue** — heavily polymorphic, with hot receiver classes inlined behind `CheckClass` guards — exercise the deopt path constantly, which is exactly why fixing the deopt-stub trap was load-bearing for the port. Speculation is only as good as the safety net it falls into, and on Apple Silicon that net had to be re-tied.

---

## Appendix II — Optimizer & backend file map

| Concern | File(s) |
|---|---|
| Pipeline driver | `compiler.cc:705-1174` (`CompileParsedFunctionHelper::Compile`) |
| JIT optimizer / IC specialization | `jit_optimizer.cc` (1781 lines) |
| Inlining | `flow_graph_inliner.cc` (3752) |
| Type propagation | `flow_graph_type_propagator.cc` (1532) |
| Redundancy (CSE/LICM/loads/stores/alloc-sinking) | `redundancy_elimination.cc` (3386) |
| Range analysis | `flow_graph_range_analysis.cc` (~3085) + `.h` |
| Constant propagation (SCCP) | `constant_propagator.cc` (1743) |
| Branch canonicalization | `branch_optimizer.cc` (BranchSimplifier/IfConverter) |
| Inline caches | `object.cc:13029-14090` (ICData), `raw_object.h:1510` |
| Class hierarchy analysis | `cha.cc` (184), `cha.h` |
| Register allocation | `flow_graph_allocator.cc` (3098) + `.h` |
| Codegen driver | `flow_graph_compiler.cc` (2021) |
| ARM64 codegen | `flow_graph_compiler_arm64.cc` (1780), `intermediate_language_arm64.cc`, `assembler_arm64.{h,cc}` |
| Deopt tables/context | `deopt_instructions.cc` (1382) + `.h` |
| Deopt stub (ARM64) | `stub_code_arm64.cc:465-610` |
| OSR trigger | `runtime_entry.cc:1775-1830`; OSR graph pruning `flow_graph_builder.cc:4428` |
