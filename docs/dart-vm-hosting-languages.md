# Hosting Other Languages on the Dart VM — a Dual-Front-End Architecture and a Feasibility Study

> **Part of a three-document series on the MACDART VM compiler:**
> [`dart-vm-compiler.md`](dart-vm-compiler.md) studies the compiler itself;
> [`dart-vm-frontend-guide.md`](dart-vm-frontend-guide.md) is the how-to for emitting Dart IL;
> **this document** uses both to run a *new* language alongside full Dart in one VM.

Two questions, one answer. **(1)** Can the Dart 1.24.3 VM keep *all* of `dart:core` while
also compiling a different language — i.e. run two front-ends at once? **(2)** Which of the
sister-project languages (Smalltalk, Common Lisp, Forth, BCPL, Modula-2) are worth hosting this
way, and at what cost?

The architectural answer (**Part A**) is that the VM is *already* multi-front-end: the front-end
is chosen **per function**, so adding "Lang X + full Dart" is additive and touches neither the
optimizer, the backend, the GC, nor `dart:core`. The feasibility answer (**Part B**) ranks the
five languages, with **Smalltalk** at the top — not by luck but by lineage. **Part C** turns that
into a concrete recommendation.

All citations are `file:line` into `sdk/runtime/vm/` at the state of this tree (Dart 1.24.3 / V1).

---

# Part A — The dual-front-end architecture: a new language *and* all of Dart

This Part studies (a) how a program's classes/functions are built and **registered** in the VM
object model, and (b) the **per-function front-end selection** mechanism that lets a new language
and full Dart share one VM and one `dart:core`.

The headline finding: **the front-end is chosen per `Function`, not per isolate or per library.** A single opaque `void* kernel_function_` slot on every `Function` (`raw_object.h:853`) is the only thing that routes a function *body* to the parser, the irregexp engine, or the kernel IL builder. Everything downstream of "build a FlowGraph" — SSA, optimizer, register allocator, ARM64 backend, GC, inline caches, deopt — is shared and front-end-agnostic. A third front-end is a fourth arm of one `switch`.

---

## 1. Object construction & registration (what a loader must call)

### 1.1 The four constructors a loader uses

A loader for any language builds the object model out of the same four factory calls the Dart source parser and the kernel reader use:

- **`Library::New(url)`** → `object.cc:11070`, delegating to `Library::NewLibraryHelper(url, import_core_lib)` `object.cc:11010`. This allocates the `RawLibrary`, initializes an empty class dictionary (`InitClassDictionary`, `object.cc:11055`), an import list (`InitImportList`), and a private mangling key (`AllocatePrivateKey`). Critically, when `import_core_lib` is true it constructs a `Namespace` over `Library::CoreLibrary()` and calls `result.AddImport(ns)` (`object.cc:11058-11065`) — **this is exactly how a Lang-X library gets `dart:core` in scope.**

- **`Class::New(lib, name, script, token_pos)`** → `object.cc:3262`. It calls `NewCommon<Instance>(kIllegalCid)` (`object.cc:3266`) to allocate a class whose id is `kIllegalCid`, sets library/name/script/token, then calls `Isolate::Current()->RegisterClass(result)` (`object.cc:3271`). Passing `kIllegalCid` is the signal to the class table to *assign a fresh id* (see §1.3).

- **`Function::New(name, kind, is_static, is_const, is_abstract, is_external, is_native, owner, token_pos, space)`** → `object.cc:6776`. Sets kind/flags/owner and, importantly:
  - `result.set_kernel_function(NULL)` at `object.cc:6817` — **the front-end marker defaults to "use the AST parser."**
  - `result.SetInstructionsSafe(StubCode::LazyCompile_entry()->code())` at `object.cc:6822-6823` — the function's entry point is the **lazy-compile stub**; the *body* is not built at load time. First call traps into `CompileFunction` (`compiler.cc:204`).
  Owner is a `Class` (or PatchClass); `kind` is one of `RawFunction::Kind` (`raw_object.h:781-796`).

- **`Field::New(name, is_static, is_final, is_const, is_reflectable, owner, type, token_pos)`** → `object.cc:7888` (top-level variant `Field::NewTopLevel` at `object.cc:7905`). Just allocates and initializes; the field type is an `AbstractType` resolved later during finalization.

Members are attached to their class with **`Class::SetFunctions(array)`** (`object.cc:2209`) or incremental **`Class::AddFunction(function)`** (`object.cc:2230`), and **`Class::SetFields` / `AddField`** (`object.cc:3162` / `3179`). `SetFunctions` also builds a name→function hash table once the count crosses `kFunctionLookupHashTreshold` (`object.cc:2214-2223`) and asserts every function's `Owner() == raw()` (`object.cc:2220`). The class is put into the library dictionary by **`Library::AddClass(cls)`** (`object.cc:10554`): it calls `AddObject(cls, class_name)`, sets `cls.set_library(*this)`, and invalidates the resolved-name cache.

### 1.2 `Object::RegisterClass` — the two-step "put in library + name it"

`Object::RegisterClass(cls, name, lib)` (`object.cc:1172`) is a thin helper: `cls.set_name(name)` then `lib.AddClass(cls)` (`object.cc:1177-1178`). Its sibling `RegisterPrivateClass` (`object.cc:1182`) mangles the name with the library's private key first. Note: the **class-table** registration (id assignment) already happened inside `Class::New` via `Isolate::RegisterClass`; `Object::RegisterClass` is only the *library-dictionary* half. So a loader that calls `Class::New(lib, ...)` has already registered the class in the class table and merely needs `lib.AddClass` (which `Class::New` does *not* call — see that `Class::New` sets `set_library` implicitly only through the later `AddClass`; in practice the kernel reader calls `library.AddClass` explicitly, `kernel_reader.cc:891`).

### 1.3 Class-table id assignment

`Isolate::RegisterClass(cls)` (`isolate.cc:170`) forwards to `class_table()->Register(cls)` (`isolate.cc:177`). `ClassTable::Register` (`class_table.cc:115`):
- If `cls.id() != kIllegalCid` (a predefined VM class with a fixed id `< kNumPredefinedCids`), it slots the class at that fixed index and records the C++ vtable in `Object::builtin_vtables_` (`class_table.cc:117-131`).
- **Otherwise (the user/loader case) it assigns `top_`**: grows the table if needed, then `cls.set_id(top_); table_[top_] = cls.raw(); top_++;` (`class_table.cc:154-162`). So user classes get **monotonically increasing cids starting after `kNumPredefinedCids`.** `RegisterAt(index, cls)` (`class_table.cc:201`) exists for placing a class at a specific id (used by snapshot/reload).

The cid is the object model's dispatch key (see §4). Assigning it at `Class::New` time — before any body is compiled — is what makes cross-front-end dispatch possible.

### 1.4 Class finalization vs. lazy bodies (`class_finalizer.cc`, 3809 lines)

Loading resolves **signatures only**; **bodies are compiled lazily.** The finalizer's job is to make the *type/shape* of every class consistent, never to compile method bodies.

- **`ClassFinalizer::ProcessPendingClasses(from_kernel)`** (`class_finalizer.cc:124`) is the batch entry point. It first `ResolveSuperTypeAndInterfaces` for every pending class (`:150`), then `FinalizeTypesInClass` for every class (`:155`). Then — the key asymmetry — **only `from_kernel` triggers eager `FinalizeClass` for all of them** (`:161-166`); Dart-**source** classes are "finalized more lazily" (comment `:158-160`).

- **`FinalizeTypesInClass(cls)`** (`class_finalizer.cc:2453`) resolves and finalizes: super class (recursively, `:2469-2472`), type parameters and upper bounds (`:2474`, `:2482`), super type (`:2493`), mixin type (`:2499`), interface types (`:2541-2569`); marks `set_is_type_finalized()` (`:2572`); wires `super_class.AddDirectSubclass(cls)` (`:2577`). Top-level classes are finalized eagerly here (`:2580-2581`); other classes are left for lazy `FinalizeClass`.

- **`FinalizeClass(cls)`** (`class_finalizer.cc:2610`) does the *member* pass: ensures super is finalized (`:2629-2632`), applies mixin members (`:2645`), calls `cls.Finalize()` (`:2648`), and crucially **`ResolveAndFinalizeMemberTypes(cls)`** (`:2669`). It never compiles a body.

- **`ResolveAndFinalizeMemberTypes(cls)`** (`class_finalizer.cc:1509`) finalizes field types (`FinalizeType`, `:1543`) and, for every function in the class, calls **`FinalizeSignature(cls, function)`** (`:1663`). `FinalizeSignature` (`class_finalizer.cc:1375`) resolves parameter and result *types* only — **not the function body.** Override/conflict checks run here too.

- **Lazy trigger:** `Class::EnsureIsFinalized(thread)` (`object.cc:3138`) is called on first use; if not finalized it invokes `Compiler::CompileClass(*this)`. A method body is only turned into IL+machine code when the lazy-compile stub fires `CompileFunction` (`compiler.cc:204`) on first *invocation* of that specific function.

**Why lazy:** because a body is compiled through a front-end-specific pipeline (§2), deferring body compilation is what lets the front-end be chosen per function at *call time*, using the marker stamped at load time.

---

## 2. Per-function front-end selection — THE KEY MECHANISM

### 2.1 The marker: one `void*` per `Function`

`RawFunction` carries `NOT_IN_PRECOMPILED(void* kernel_function_)` at `raw_object.h:853`, exposed via `Function::kernel_function()` / `set_kernel_function()` (`object.h:2630-2642`). It is a **non-GC-scanned opaque pointer** (a `StoreNonPointer`, `object.h:2640`) — the VM never dereferences it as a Dart object; only the owning front-end knows its real type (for kernel it is a `kernel::TreeNode*`). `Function::New` defaults it to `NULL` (`object.cc:6817`).

The other per-function discriminator is the **kind tag** `kind_tag_` (`raw_object.h:850`), decoded to `RawFunction::Kind` (`raw_object.h:781-796`). `IrregexpFunction` is a dedicated kind (`raw_object.h:795`), queried by `Function::IsIrregexpFunction()` (`object.h:2756-2757`).

### 2.2 The routing predicate: `UseKernelFrontEndFor`

```
bool UseKernelFrontEndFor(ParsedFunction* pf) {                 // compiler.cc:116
  const Function& function = pf->function();
  return (function.kernel_function() != NULL) ||                // compiler.cc:118
         (function.kind() == RawFunction::kNoSuchMethodDispatcher) ||
         (function.kind() == RawFunction::kInvokeFieldDispatcher);
}
```

So a function goes to the **kernel** front-end iff its per-function marker is non-NULL (or it is one of two synthesized dispatcher kinds the AST builder cannot express). Otherwise it goes to the **AST parser**. This single test *is* the per-function selector.

### 2.3 The pipeline abstraction

`CompilationPipeline` (`compiler.h:32`) is a 3-method virtual interface:
```
virtual void        ParseFunction(ParsedFunction*)            = 0;  // compiler.h:36
virtual FlowGraph*  BuildFlowGraph(zone, pf, ic_data, osr_id) = 0;  // compiler.h:37
virtual void        FinalizeCompilation(FlowGraph*)           = 0;  // compiler.h:42
static  CompilationPipeline* New(Zone*, const Function&);           // compiler.h:34
```
Two concrete subclasses exist: `DartCompilationPipeline` (`compiler.h:47`) and `IrregexpCompilationPipeline` (`compiler.h:61`).

**`CompilationPipeline::New`** (`compiler.cc:192`) is the *coarse* selector — it branches on the function *kind*:
```
if (function.IsIrregexpFunction())  return new IrregexpCompilationPipeline();  // compiler.cc:194-195
else                                return new DartCompilationPipeline();      // compiler.cc:197
```
The irregexp path is separated at this level because it needs a wholly different `ParseFunction` (it runs `RegExpParser::ParseFunction`, `compiler.cc:159`) and a different `BuildFlowGraph` (it runs `RegExpEngine::CompileIR`, `compiler.cc:170`) and even a `FinalizeCompilation` that patches the backtrack goto table (`compiler.cc:187-188`).

### 2.4 The *fine* selection inside `DartCompilationPipeline` — AST vs kernel

Both plain Dart functions and kernel-loaded functions share **one** pipeline object (`DartCompilationPipeline`) that dispatches internally on the marker:

**Parse** (`compiler.cc:124`):
```
void DartCompilationPipeline::ParseFunction(ParsedFunction* pf) {
  if (!UseKernelFrontEndFor(pf)) {          // compiler.cc:125
    Parser::ParseFunction(pf);              // compiler.cc:126  -> AST
    pf->AllocateVariables();
  }
  // kernel functions skip textual parsing entirely; the kernel tree already exists
}
```

**Build flow graph** (`compiler.cc:132`) — this is the exact fork that routes each function's body to its front-end:
```
FlowGraph* DartCompilationPipeline::BuildFlowGraph(zone, pf, ic_data, osr_id) {
  if (UseKernelFrontEndFor(pf)) {                                     // compiler.cc:137
    kernel::TreeNode* node =
        static_cast<kernel::TreeNode*>(pf->function().kernel_function()); // :138-139  <-- reads the marker
    kernel::FlowGraphBuilder builder(node, pf, ic_data, NULL, osr_id);    // :140  kernel_to_il builder
    return builder.BuildGraph();                                          // :142
  }
  FlowGraphBuilder builder(*pf, ic_data, NULL, osr_id);                   // :146  AST FlowGraphBuilder
  return builder.BuildGraph();                                           // :150
}
```
The marker is cast back to `kernel::TreeNode*` (`compiler.cc:138-139`) — only the kernel front-end knows that is the correct type. If the marker is NULL, the classic AST `FlowGraphBuilder` (declared in `flow_graph_builder.h`, defined in `flow_graph_builder.cc`) consumes the parser's AST instead.

### 2.5 What the kernel builder does with the marker (the template to copy)

`kernel::FlowGraphBuilder::BuildGraph()` (`kernel_to_il.cc:3152`) takes the stored `node_` (the marker) and `switch`es on `function.kind()` (`kernel_to_il.cc:3212`) to pick a body-builder: `BuildGraphOfFunction` for regular/getter/setter/closure (`:3225`), `BuildGraphOfFieldAccessor` for implicit accessors (`:3247`), `BuildGraphOfMethodExtractor` (`:3250`), `BuildGraphOfNoSuchMethodDispatcher` (`:3252`), `BuildGraphOfInvokeFieldDispatcher` (`:3254`). The class is declared at `kernel_to_il.h:784` with ctor `kernel_to_il.h:786`. **A Lang-X `FlowGraphBuilder` mirrors this class: hold the per-function node, emit shared IL.**

### 2.6 Where the pipeline is driven

`CompileFunctionHelper` (`compiler.cc:1219`) does: `pipeline->ParseFunction(parsed_function)` (`:1258`) then `helper.Compile(pipeline)` (`:1278`). `CompileParsedFunctionHelper::Compile` (`compiler.cc:705`) calls `pipeline->BuildFlowGraph(...)` (`compiler.cc:779-780`) and **everything after that line is front-end-independent** (block scheduling `:796`, SSA/optimizer, allocation, codegen). `CompilationPipeline::New` is called at each JIT entry point: unoptimized compile (`compiler.cc:1464`), parse (`:1486`), optimized compile (`:1547`).

---

## 3. Bootstrap of `dart:core` (`bootstrap.cc`, 429 lines)

`Bootstrap::DoBootstrapping(kernel_program)` (`bootstrap.cc:402`) is the top. It first **pre-creates a `Library` object for every bootstrap library** (`FOR_EACH_BOOTSTRAP_LIBRARY`, table at `bootstrap.cc:53`), via `Library::NewLibraryHelper(uri, false)` + `lib.Register(thread)` + `object_store()->set_bootstrap_library(id, lib)` (`bootstrap.cc:412-423`). `dart:core` is one of these ids.

Then it forks on source vs kernel (`bootstrap.cc:425-426`):

- **From source** — `BootstrapFromSource(thread)` (`bootstrap.cc:295`): installs a bootstrap tag handler (`:307`), then for each bootstrap library reads its baked-in source and calls `Compile(lib, script)` (`:324`) — `Compile` (`bootstrap.cc:139`) invokes `Compiler::Compile(library, script)`, which runs the **AST parser** to create the classes/functions/fields of `dart:core` (via the same `Class::New`/`Function::New`/`Field::New` from §1, with `kernel_function_ == NULL`). Patch files are layered on with `lib.Patch(script)` (`bootstrap.cc:251`).

- **From kernel** — `BootstrapFromKernel(thread, program)` (`bootstrap.cc:346`): a `kernel::KernelReader reader(program)` (`:348`) walks the program and, for each bootstrap library, `reader.ReadLibrary(kernel_library)` (`:373`) builds the classes/functions (with `kernel_function_` set to the kernel node — see §5.2).

Both paths converge on **`Finish(thread, from_kernel)`** (`bootstrap.cc:260`): it sets up native resolvers, then **`ClassFinalizer::ProcessPendingClasses(from_kernel)`** (`bootstrap.cc:262`) to finalize the type shape of every core class, then eagerly compiles two classes the compiler itself depends on — `_Closure` (`bootstrap.cc:271-272`) and `bool` (`bootstrap.cc:290-291`).

**Adding another library to the isolate** follows the same recipe used everywhere: create it with `Library::New(url)` / `NewLibraryHelper` (`object.cc:11070` / `11010`), which optionally `AddImport`s `dart:core` (`object.cc:11058-11065`); register it with `lib.Register(thread)`; populate it with `Class::New(lib,...)` + `lib.AddClass` + `cls.SetFunctions/SetFields`; then run it through `ClassFinalizer::ProcessPendingClasses`. (The kernel reader does exactly this for non-core libraries via `reader.ReadProgram()`, `bootstrap.cc:385`, e.g. registering `dart:_builtin`, `:387-390`.)

---

## 4. Cross-front-end interop (grounded)

**Claim: a function whose body was built by front-end A can call a function whose body was built by front-end B with no glue.** This holds because every front-end lowers calls into the *same* two shared IL instructions over the *same* object model and class table, and dispatch keys on `cid + selector`, never on the producing front-end.

### 4.1 Static calls — `StaticCallInstr`

`StaticCallInstr` (`intermediate_language.h:3324`) holds `const Function& function_` (`:3339`) — a direct handle to the callee `Function` object. Because both front-ends resolve the same name to the same shared `Function` (via `Resolver::ResolveStatic`, `resolver.cc:146`), a Lang-X caller that references `dart:core`'s `print` gets *the same `Function`* the Dart parser would get. The instruction records only "call this Function"; the callee's own body is compiled by whatever pipeline its own marker selects, lazily, on first entry. Nothing about the caller's front-end is encoded.

### 4.2 Instance calls — `InstanceCallInstr`

`InstanceCallInstr` (`intermediate_language.h:2868`) holds a **selector** `function_name_` (`:2884`), `argument_names` and a `type_args_len` (from `TemplateDartCall`), a `checked_argument_count_`, and an `ICData`. It stores **no callee `Function`** — resolution is deferred to runtime by receiver class-id.

Dispatch at an IC miss: `InlineCacheMissHandler` (`runtime_entry.cc:933`) reads the receiver (`:936`), the `ArgumentsDescriptor` (`:937`), and the `target_name` selector (`:939`), then calls `Resolver::ResolveDynamic(receiver, function_name, args_desc)` (`:943`). `Resolver::ResolveDynamicForReceiverClass` (`resolver.cc:34`) → `ResolveDynamicAnyArgs` (`resolver.cc:65`) walks the receiver's class up the super chain calling `cls.LookupDynamicFunction(function_name)` (`resolver.cc:122`). It keys **purely on `receiver_class` (a cid) + `function_name` (a selector)**. The result is cached as `ic_data.AddReceiverCheck(receiver->GetClassId(), target_function)` (`runtime_entry.cc:969`) — again cid→Function, no front-end field. The same is true for the megamorphic path (`MegamorphicCacheTable::Lookup(isolate, name, arguments_descriptor)`, `flow_graph_compiler_arm64.cc:1234`).

**There is nothing per-front-end in the dispatch/IC path.** `LookupDynamicFunction` returns whatever `Function` lives in the class dictionary under that name; whether its body will be built by parser, irregexp, or kernel is decided *later and independently* when that `Function`'s lazy-compile stub fires.

### 4.3 Real caveats

1. **`ArgumentsDescriptor` shape must match.** The callee is entered through the shared calling convention described by `ArgumentsDescriptor` (positional count, type-argument count, and the *sorted* names of named arguments). Every front-end must emit calls that build an `ArgumentsDescriptor` consistent with how the callee declared its parameters; `AreValidArguments` (`object.cc`, used by `ResolveStatic` at `resolver.cc:159`) rejects mismatches. A Lang-X front-end must produce the identical descriptor layout Dart uses.
2. **Named arguments** are matched by name, so a Lang-X caller invoking a `dart:core` method with optional named parameters must pass the same `argument_names` symbols; positional-only Lang-X semantics are fine but cannot reach named-only parameters.
3. **Checked-mode / assertion type checks** are emitted *in IL by each front-end* (as `AssertAssignable`/`CheckClass` etc.), not by the dispatcher. If Lang-X is untyped it simply omits those instructions; it still interoperates, but it will not enforce Dart's parameter types at the boundary unless it emits the checks itself. (Type *finalization* of the shared `dart:core` signatures still happens in `class_finalizer.cc` regardless.)
4. **Generic type arguments**: passing/receiving type arguments to generic `dart:core` methods requires the Lang-X builder to thread the type-arguments vector through `TemplateDartCall`'s `type_args_len`; ignoring generics is safe for erasure-style semantics but loses reification.

None of these are glue between front-ends; they are just "speak the shared ABI of the object model." The dispatcher itself is oblivious.

---

## 5. The dual-front-end blueprint

From §1–§4, adding a coexisting **Lang X** front-end while keeping **all of `dart:core` importable and callable** requires exactly four new pieces and touches one selection point. The existing kernel front-end is the working template for every item.

### (i) A loader that builds & registers the object model
Mirror `KernelReader`. Create the Lang-X library with `Library::New(url)` (`object.cc:11070`) — pass through `NewLibraryHelper` with `import_core_lib=true` (`object.cc:11010`, `AddImport(dart:core)` at `:11058-11065`) so `dart:core` names resolve. For each Lang-X type: `Class::New(lib, name, script, token_pos)` (`object.cc:3262`) which auto-assigns a cid via `Isolate::RegisterClass`→`ClassTable::Register` (`isolate.cc:170`, `class_table.cc:115`), then `library.AddClass(cls)` (`object.cc:10554`). For each routine: `Function::New(...)` (`object.cc:6776`), attach with `Class::SetFunctions`/`AddFunction` (`object.cc:2209`/`2230`); for state: `Field::New` (`object.cc:7888`) + `Class::SetFields`/`AddField`. Run the batch through `ClassFinalizer::ProcessPendingClasses` (`class_finalizer.cc:124`) so signatures/types finalize. Template: `kernel_reader.cc` — `ReadLibrary` (`:236`), toplevel `Class::New` (`:253`), `LookupClass` creating+`AddClass` (`:882-891`), `ReadProcedure` building `Function::New` (`:531`), `SetFunctions` (`:471`).

### (ii) A per-`Function` marker that routes bodies to Lang X
Reuse the existing opaque slot `kernel_function_` (`raw_object.h:853`) via `set_kernel_function(langx_node)` — it is just a `void*` the VM never scans. The kernel loader does precisely this at `kernel_reader.cc:540` (`function.set_kernel_function(kernel_procedure)`). Cleaner long-term is a parallel slot (e.g. `langx_function_`) + accessor mirroring `object.h:2630-2642`, so kernel and Lang X can coexist unambiguously; but for a VM that hosts *only* Dart-source + Lang X, overloading the existing slot works because the source path leaves it NULL (`object.cc:6817`).

### (iii) A Lang-X `FlowGraphBuilder` (the R1 topic)
A builder class shaped like `kernel::FlowGraphBuilder` (`kernel_to_il.h:784`, `BuildGraph` at `kernel_to_il.cc:3152`): it takes the per-function node, walks the Lang-X representation, and **emits the shared IL** — `StaticCallInstr` (`intermediate_language.h:3324`) for static calls into `dart:core`, `InstanceCallInstr` (`intermediate_language.h:2868`) with a selector for dynamic calls, plus the shared value/branch/allocation instructions — producing a `FlowGraph`. It must emit `ArgumentsDescriptor`-consistent calls (§4.3).

### (iv) Selection wired into the pipeline
Two edits:
- **`DartCompilationPipeline::BuildFlowGraph`** (`compiler.cc:132`): add a branch — if the Lang-X marker is set, `static_cast` it to the Lang-X node type and run the Lang-X builder, exactly like the kernel branch at `compiler.cc:137-144`. (Correspondingly teach `ParseFunction`, `compiler.cc:124`, to skip textual parsing for Lang-X functions, like it already does for kernel via `UseKernelFrontEndFor`, `compiler.cc:116`.)
- Optionally, if Lang X needs a distinct *parse* or *finalize* step, give it its own `CompilationPipeline` subclass (like `IrregexpCompilationPipeline`, `compiler.h:61`) and add a branch in `CompilationPipeline::New` (`compiler.cc:192`) — but if it only needs a different flow-graph builder, extending `DartCompilationPipeline` internally (as kernel does) is sufficient and lighter.

### Reused entirely unchanged
Everything downstream of `BuildFlowGraph` is front-end-agnostic and needs **zero** changes:
- **Optimizer / SSA / CSE / inliner / range analysis / constant propagation** — driven in `CompileParsedFunctionHelper::Compile` after `BuildFlowGraph` (`compiler.cc:779`+), operate on the shared `FlowGraph`/IL.
- **Register allocator, block scheduler** (`compiler.cc:796`), **ARM64 backend** (`flow_graph_compiler_arm64.cc`, `assembler_arm64.cc`).
- **GC** — Lang-X objects are ordinary heap objects with a cid; the class table (`class_table.cc`) and object layout are shared.
- **Inline caches & megamorphic dispatch** (`runtime_entry.cc:933`, `resolver.cc:34`, `megamorphic_cache_table.cc`) — key on cid+selector, oblivious to front-end.
- **Deoptimization** (`deopt_instructions.*`), **lazy compilation stub** (`StubCode::LazyCompile`, wired at `object.cc:6822`).
- **All of `dart:core`** — imported by (i), resolved by name to shared `Function`s (§4), called via the shared IL. No re-implementation, no bridging layer.

**Net:** the third front-end is additive. It contributes a loader, a per-function marker, and an IL builder, and hooks a single `if` into `BuildFlowGraph`/`New`. The object model, class table, dispatch, optimizer, backend, GC, and `dart:core` are all shared verbatim — which is the whole reason a new language can run *inside* the Dart VM and freely call Dart, and vice versa.

---

## Part A citation index

| Topic | Location |
|---|---|
| `UseKernelFrontEndFor` (marker test) | `compiler.cc:116-121` |
| `DartCompilationPipeline::BuildFlowGraph` AST vs kernel fork | `compiler.cc:132-151` |
| `CompilationPipeline::New` (irregexp vs dart) | `compiler.cc:192-199` |
| Pipeline interface & subclasses | `compiler.h:32-73` |
| `kernel_function()` / `set_kernel_function()` | `object.h:2630-2642` |
| `RawFunction` struct; `kernel_function_`; `kind_tag_` | `raw_object.h:779-858` (853, 850) |
| `Function::Kind` enum incl. `kIrregexpFunction` | `raw_object.h:781-796` |
| `Object::RegisterClass` / `RegisterPrivateClass` | `object.cc:1172-1191` |
| `Isolate::RegisterClass` | `isolate.cc:170-178` |
| `ClassTable::Register` (cid assignment `top_++`) | `class_table.cc:115-163` |
| `Class::New(lib,...)` / `NewCommon` | `object.cc:3228-3273` |
| `Function::New` (marker NULL, lazy stub) | `object.cc:6776-6838` (6817, 6822) |
| `Field::New` / `NewTopLevel` | `object.cc:7888-7916` |
| `Library::NewLibraryHelper` (imports dart:core) | `object.cc:11010-11067` |
| `Library::AddClass` | `object.cc:10554-10561` |
| `Class::SetFunctions` / `AddFunction` | `object.cc:2209-2247` |
| `Class::EnsureIsFinalized` (lazy) | `object.cc:3138` |
| `ProcessPendingClasses` | `class_finalizer.cc:124-185` |
| `FinalizeTypesInClass` | `class_finalizer.cc:2453-2582` |
| `FinalizeClass` / `ResolveAndFinalizeMemberTypes` / `FinalizeSignature` | `class_finalizer.cc:2610`, `1509`, `1375` |
| Bootstrap entry / source / kernel / finish | `bootstrap.cc:402`, `295`, `346`, `260` |
| Kernel loader builds+marks functions/classes | `kernel_reader.cc:531-540`, `882-891`, `236-301`, `378-471` |
| Kernel `FlowGraphBuilder::BuildGraph` dispatch | `kernel_to_il.cc:3152-3261`; class `kernel_to_il.h:784` |
| `InstanceCallInstr` (selector) / `StaticCallInstr` (Function) | `intermediate_language.h:2868`, `3324` |
| IC miss handler (cid+selector) | `runtime_entry.cc:933-1001` |
| `Resolver::ResolveDynamic*` | `resolver.cc:34`, `65-143` |


# Part B — Feasibility: hosting the sister languages

**Question.** How easily can each albanread sister-language be re-hosted on the MACDART VM (Dart 1.24.3, the last V1) via the dual-front-end path of Part A — a new language reaching the VM by emitting Dart IL (FlowGraph) over the shared object model and reusing `dart:core`?

**The target VM's model** is the one established in [`dart-vm-compiler.md`](dart-vm-compiler.md) and Part A: class-based **single** dispatch keyed by `(receiver class-id + selector String + ArgumentsDescriptor)`; tagged `Smi` + boxed `double` + arbitrary-precision int (`Mint`/`Bigint`); first-class closures with captured `Context`s; optional typing (types parse but are semantically inert in unchecked/production mode); `noSuchMethod`; a generational **moving/compacting** GC; a rich `dart:core`; polymorphic inline caches + deoptimization + hot reload. The mapping claims below are grounded against this checkout's VM source: `flow_graph_builder.cc` (`InstanceCallInstr`, `PolymorphicInstanceCall`), `dart_entry.h`/`stub_code_arm64.cc` (`InvokeNoSuchMethod`), `deopt_instructions.cc`, `isolate_reload.cc`, `become.cc` (`Become::`, `ElementsForwardIdentity`, `ForwardObjectTo`), `clustered_snapshot.cc` (full heap snapshot), `mirrors_impl.dart`/`mirrors_patch.dart` (reflection), and `Float32x4` NEON support in the compiler backends.

**Tier scale used.**
- **Tier 1** = different surface syntax, *same* semantics: parser → Dart AST/IL, reuse `dart:core`. Cheapest, full JIT speed.
- **Tier 2** = different-but-compatible semantics, *desugared* to Dart constructs (the JVM/CLR-guest pattern). Uses the object model + GC + closures; adds runtime-library machinery.
- **Tier 3** = fundamentally different object model: you reuse the **JIT + GC as a backend**, not "the Dart VM." `dart:core` and single-dispatch are largely bypassed.

---

## Sources consulted

READMEs fetched live (2026-07-29): `albanread/MACVM`, `albanread/MacModula2`, `albanread/MacBCPL`, `albanread/MF67`, `albanread/NewCL`. An earlier survey referred to one repo as "MacNCL"; it **does not exist under that name** — the actual repo is **`NewCL` (NCL)**, a **Common Lisp / Corman-Lisp reimplementation** in Rust with an LLVM JIT, Cocoa not exposed to the language (matching the "outlier" characterization; identity confirmed, only the repo name corrected). All five READMEs were reachable, so nothing here is characterized from language-family alone; every Dart-VM claim is grounded against this checkout's source.

---

## The standout: Smalltalk (MACVM) — Tier 1

**Why it is not just "a good fit" but a genealogical one.** Dart's VM is a direct descendant of MACVM's stated ancestor. The line is **Strongtalk → HotSpot → V8 → Dart VM**: the same people (Bak, Hölzle, and the Self/Strongtalk group) carried the same playbook — *optional* types layered on a dynamic core, polymorphic inline caches driven by type feedback, deoptimization, a generational **moving** collector, mixed-mode tiered execution — from Strongtalk into every VM that followed. MACVM's own README describes itself as "**Strongtalk-inspired**," "a **class-based object model** with an **adaptive optimizing compiler** driven by type feedback," with "**polymorphic inline caches (PICs)**," "**deoptimization** with recompile-on-trap," and a "**generational scavenge plus full compacting collector**." That is a line-for-line description of the Dart VM. MACVM and the MACDART VM are **siblings built from the same book** — which is exactly why Smalltalk is the cheapest guest.

## Smalltalk feature → concrete Dart IL / runtime primitive

| Smalltalk construct | Dart VM mechanism it lands on | Verdict |
|---|---|---|
| Message send `recv sel: a` (unary/binary/keyword) | `InstanceCallInstr` (name = selector String, `ArgumentsDescriptor`); backed by ICData **polymorphic inline caches**; optimizer devirtualizes via CHA + type feedback → `PolymorphicInstanceCallInstr` | **Native.** Same PIC architecture MACVM uses. |
| Binary selectors `+ - < =` | operator methods → `InstanceCall`, specialized after feedback to `BinarySmiOp`/`BinaryDoubleOp`/`CheckedSmiOp` | **Native.** SmallInteger fast path ↔ Dart `Smi` fast path is *identical*. |
| Keyword selector name `at:put:` | kept **verbatim** as the VM `Function` name String — colons/binary chars are legal in VM-level names when you emit IL directly (no source-identifier constraint) | **Native, zero mangling.** `#perform:` with `Symbol('at:put:')` resolves to the same Function. |
| Block `[:x \| ... ]` | `Closure` object + captured `Context` (`AllocateContext`/allocate-closure); `value`/`value:`/`value:value:` = `ClosureCallInstr` | **Native.** Blocks *are* closures; block-arity ↔ closure-arity. |
| Cascade `recv m1; m2; m3` | Dart cascade `recv..m1()..m2()..m3()`: `LoadLocal(temp)` + a sequence of `InstanceCall`s sharing the receiver | **Native — Dart has cascades.** 1:1. |
| `doesNotUnderstand: aMessage` | the VM's dispatch-miss path `InvokeNoSuchMethod` builds an `InvocationMirror` (memberName `Symbol` = selector, positional + named args) → user `noSuchMethod` | **Native — the single strongest match.** Smalltalk `Message` ≡ Dart `Invocation`. `@proxy` silences static warnings. |
| `#perform:withArguments:` (computed selector) | reflective dynamic send: `Resolver::ResolveDynamic(cid, selector, argsdesc)` / `DartEntry::InvokeFunction` — what `InstanceMirror.invoke` compiles to; constant selector → plain `InstanceCall` | **Native** (via the same path `dart:mirrors` uses). |
| `respondsTo:` | `class.lookupDynamicFunction(sel) != null`, or `ClassMirror.instanceMembers` | **Native.** |
| everything-is-an-object; `nil`/`true`/`false` | Dart `int`/`double`/`bool`/`Null` are all objects; `Smi` is a tagged **int object**; `nil` ↔ `null` (the `Null` instance), `true`/`false` ↔ `bool` | **Native.** `Object` protocol overlaps: `=`/`hash`/`printString`/`doesNotUnderstand:` ↔ `==`/`hashCode`/`toString`/`noSuchMethod`. |
| Number tower `SmallInteger`/`LargeInteger`/`Float` | `Smi` → `Mint` → `Bigint` **auto-promoting**; `Float` ↔ `double` | **Native.** (`Fraction`/`ScaledDecimal` = a library class, no VM work.) |
| SIMD value classes `Float64x2`/`Float32x4`/`Int32x4` fused to NEON | `dart:typed_data` `Float64x2`/`Float32x4`/`Int32x4` with the VM's NEON codegen | **Native, 1:1** — an unusually exact match; MACVM and Dart independently expose the *same three* SIMD value types. |
| Live class redefinition + deopt | `isolate_reload.cc`: recompile, **deopt** live frames, migrate instances | **Native** — the same capability MACVM ships. |
| `become:` (incl. **across structure change**) | the VM's internal `Become` (`become.cc`: `ForwardObjectTo`, `ElementsForwardIdentity`), used by isolate reload to migrate instances when field layout changes | **Primitive exists in the VM** (not language-exposed today; can be surfaced). Note MACVM itself **dropped** `become:` for JIT reasons — so here **Dart can offer *more* than MACVM**. |
| Multi-VM workers + Erlang-style messaging + OTP supervision | Dart **isolates** + `SendPort`/`ReceivePort`; isolate groups | **Native architectural match** — MACVM's worker fleet ↔ Dart isolate model. |
| `ensure:` / `ifCurtailed:` | `try`/`finally` | **Native.** |

## Where Smalltalk-on-Dart needs desugaring (the honest gaps)

1. **Non-local return `^expr` from inside a block.** Dart closures `return` from the *closure only*; Smalltalk `^` returns from the *home method*. Desugar: the home method wraps its body in `try { … } catch (NonLocalReturn r) { if (r.token == homeToken) return r.value; rethrow; }`; a `^` inside a block does `throw NonLocalReturn(homeToken, value)`. If the home activation is already dead (escaped block) there is no matching catch → `BlockContext cannot return` error — which is *exactly* the correct Smalltalk semantics. Uses the VM's `ThrowInstr`/`CatchBlockEntry`; cost is paid only on the `^` slow path. **Light Tier-2 desugaring, no VM change.**
2. **Class-side methods / metaclasses.** Dart classes are not full first-class objects, so `Foo new` (a message to the class) has no native home. Model each Smalltalk class as **two** Dart entities: an instance class `Foo`, plus a **singleton metaclass-instance object** whose Dart class is `Foo_class`; `Foo new` becomes an ordinary `InstanceCall` on that singleton, class variables become fields on it, and the metaclass tower closes with a shared `Metaclass` fixpoint. Faithful reproduction of the metaclass hierarchy **using single dispatch throughout** — a compilation strategy, not a runtime change. **Light Tier-2 desugaring.**
3. **`thisContext` / reified activations / continuations.** Not language-exposed (the VM has `StackFrameIterator` only internally, for the debugger/GC). Practical impact is low: most Smalltalk code touches `thisContext` only in the debugger and a few control constructs, and the debugger is better built on the vm-service anyway. **Residual gap, low impact.**
4. **Resumable exceptions** (`Exception>>resume:` returning to the signal point). Dart exceptions are non-resumable. **But MACVM has no exception system at all** ("`self error:` stops computation; scoped `catch` was deliberately rejected"), so MACVM parity does not need this. Full ANSI Smalltalk would.
5. **Persistent image.** Classic Smalltalk saves a live world. Dart's nearest is a full **isolate snapshot** (`clustered_snapshot.cc`), which approximates it — but **MACVM explicitly rejects images** ("rather **throw a VM away and rebuild it from source than mutate one in place**"), so there is *no image to port*.

**The decisive observation:** every Smalltalk feature that is classically *hard* to host — persistent image, general `become:`, resumable exceptions, `thisContext`-based control — is a feature **MACVM deliberately omits**. The intersection of "what MACVM actually uses" and "what the Dart VM natively provides" is almost total. What remains (`^` non-local return, the metaclass tower) are two well-understood desugarings that do not touch the object model.

**Tier: 1** (with two light Tier-2 desugarings). **Effort: Low–Medium** — the work is a Smalltalk-syntax front-end emitting FlowGraph plus a kernel-class library bootstrapped on `dart:core`; almost no VM surgery. As the tier definition promises, this is the cheapest guest and runs at full JIT speed.

---

## Common Lisp / CLOS (NewCL) — Tier 2

**Identity confirmed:** `NewCL` is "a from-scratch reimplementation of the Common Lisp / Corman Lisp language," Rust core, LLVM JIT, numeric tower, CLOS ("`defclass, defmethod, generic dispatch; closette-derived`"), the full condition system and macro system. Cocoa is **not** exposed.

**Object model.** Everything is a first-class object with a generational GC — this half maps *cleanly* onto Dart (closures, `Bignum`, everything-is-an-object, moving GC are all present). The friction is concentrated in a few specific subsystems:

- **CLOS multiple dispatch vs. the VM's single dispatch — the headline friction.** CLOS methods specialize on the classes of *all* required arguments; the Dart VM dispatches on the *receiver* class only. This does **not** force Tier 3 (the object model is compatible) but it does force a **generic-function dispatcher built in the runtime library**: each generic function becomes a Dart object that reads the argument class-ids (`obj.runtimeType`/`ClassMirror`), computes the applicable-methods list + `call-next-method` chain, and invokes. It is a library over the VM's class-ids, not a VM change — but it is real work and it is *slower* than a monomorphic `InstanceCall` unless you cache per argument-class-tuple (a multi-key PIC you implement yourself).
- **Numeric tower gaps.** `fixnum`/`bignum`/`double-float` ↔ `Smi`/`Bigint`/`double` are native; but CL's **`ratio`** and **`complex`** have no `dart:core` equivalent → library classes (`Ratio`, `Complex`), correct but unoptimized.
- **Condition system with restarts.** `unwind-protect` ↔ `finally`; `handler-case` ↔ `try/catch`. **Restarts are the hard part** — `invoke-restart` *resumes* computation at a chosen frame, which Dart's non-resumable exceptions cannot do. Desugar via a restart-registry + captured closures (each restart's continuation is a closure invoked from the handler), or a full CPS transform for the hairy cases.
- **Runtime `eval`/`compile`.** CL can compile new forms at runtime. On Dart V1 you must embed the NCL→FlowGraph front-end *in-process* and drive the VM's JIT from it (the classic Lisp requirement). Doable — the JIT is there — but it is the deepest single piece.
- **Dynamic (special) variables**, **multiple values**, **guaranteed tail calls.** Dynamic vars → a dynamic-binding stack restored via `finally`; multiple values → a record/list return + `multiple-value-bind` destructure; TCO → **Dart's VM does not guarantee tail-call elimination**, so deep CPS/loop-as-recursion must be **trampolined**.
- **Macros / reader macros** are compile-time (front-end) and do **not** affect VM fit at all.

**Tier: 2. Effort: High** — the largest of the five by surface area (reader, macroexpander, CLOS dispatcher, conditions/restarts, tower extensions, runtime eval bridge, dynamic vars, MV, trampolining) — but **no VM surgery**; it is all front-end + runtime library over a compatible object model. **Biggest friction: CLOS multiple dispatch on a single-dispatch VM, plus resumable restarts and runtime eval/compile.**

---

## Forth (MF67, "Objective Forth") — Tier 3, but cheap

**Identity confirmed:** an optimizing Forth for Apple Silicon with its own **LLVM-free AArch64 JIT** (`wfasm::a64` + `native_macos::MacJit`, JASM backend), subroutine-threaded, **typeless cell-based** stack machine, separate FP stack, `CREATE`/`DOES>`, immediate words, `catch`/`throw`, terminal tail-call optimization.

**Why Tier 3.** Forth's model is a **word/cell stack machine**, not an object graph. On Dart you represent it as: data stack + return stack = `Int64List` + SP/RP; the "memory" (`HERE`/`ALLOT`/`,`/`@`/`!`) = a flat `typed_data` buffer with integer addresses; the dictionary = a name→xt map; execution tokens = first-class Dart functions (or indices). **This bypasses the tagged-object model and `dart:core` almost entirely** — you are running a word machine on the JIT, not hosting Forth on the Dart object model. Hence Tier 3 by definition, regardless of how easy it is.

**Why it is nonetheless low-effort.** The surface to emulate is tiny and maps to things the VM optimizes well: colon words compose to Dart functions/closures; `if/then`, `begin/until`, `do/loop` map straight to Dart control flow inside the compiled word; STC ("each word is a function that calls other word-functions") is the natural Dart shape; `catch`/`throw` ↔ non-resumable `try/catch` (a perfect match — Forth's is non-resumable too); the FP stack ↔ `double` + a second buffer; `CREATE`/`DOES>`/immediate words are compile-time front-end metaprogramming that never touch the VM.

**Frictions.** (1) **No VM tail-call elimination** — Forth's terminal-TCO loops must be emitted as Dart loops or trampolined. (2) You get **little speed benefit**: MF67 already has a hand-tuned register-pinned STC JIT; Dart's general JIT is likely comparable-to-slower on tight 64-bit loops, so re-hosting is an exercise in GC-managed data / portability rather than performance.

**Tier: 3 (JIT-as-backend). Effort: Low. Biggest friction: it is a word machine that ignores the object model and `dart:core`; no VM TCO; negligible gain over its own JASM JIT.**

---

## BCPL (MacBCPL) — Tier 3, mechanically simple

**Identity confirmed:** a modern BCPL for macOS arm64 (Rust + LLVM 22), JIT + AOT. **Typeless** — "register-class type inference" that "**never errors on type grounds**"; word-based heritage; `GETVEC`/`FREEVEC` manual heap; `VALOF`/`RESULTIS`, `SWITCHON`, `FOREACH`, PAIR-as-`<2 x i64>` SIMD.

**Why Tier 3.** BCPL's entire universe is *a flat array of machine words + integer addresses + the global vector*, with words used interchangeably as ints, pointers, and function addresses. That is the polar opposite of a tagged-object heap. On Dart you model "the store" as one big `Int64List` (BCPL addresses = indices), the global vector as a slice, label-values as indices into a function table (or first-class Dart functions), and `GETVEC` as an arena inside the buffer. **Zero reuse of the tagged-object model, single dispatch, or `dart:core`** — again the VM is a byte-machine backend. Manual `FREEVEC` sits *beside* the GC (the store is one pre-allocated buffer the VM never scans), which is actually clean and predictable.

**Why effort is Low–Medium.** BCPL is *tiny* and typeless, so what you must emit is small: integer arithmetic (fast `Smi`), load/store on the buffer, indirect calls, `SWITCHON`, `VALOF`/`RESULTIS`. All map to `typed_data` + `Smi` ops the JIT handles well. The conceptual overlap with Dart is the *least* of any of the five, but the mechanical translation is among the simplest.

**Tier: 3. Effort: Low–Medium. Biggest friction: a typeless word machine + global vector emulated on a `typed_data` store; you gain the JIT and nothing from the object model; manual memory lives outside the GC.**

---

## Modula-2 (MacModula2) — Tier 3, worst effort-to-fit

**Identity confirmed:** a from-scratch Modula-2 (PIM 4 + ISO 10514-1), Rust + LLVM, AOT (Mach-O) + JIT (ORC), with a **Cocoa-native object model** — "a Modula-2 `CLASS` *is* an Objective-C object" (`objc_allocateClassPair`/`objc_registerClassPair`), `NEW(obj)` → `[[Class alloc] init]`, `DISPOSE` → `[release]`, `malloc`/`free` heap, UTF-16 strings ↔ `NSString`, blocks wrapping M2 procedures.

**Why Tier 3 *and* high effort — it actively fights the VM on several axes at once:**

- **Raw pointers + pointer arithmetic + `ADR`/address-of + variant records.** Dart has *no* raw pointers, no address-of, no pointer arithmetic; the **moving GC forbids stable addresses**. You must emulate memory as a `typed_data` buffer with integer "addresses" — discarding the Dart object model exactly as with BCPL/Forth, *but* Modula-2 also wants...
- **Flat / value record layout.** M2 records are flat value structs, often embedded in arrays and passed by value, and (in this fork) their layout must interoperate with **Cocoa structs**. Dart objects are heap-boxed with headers and are reference types — boxing every record destroys the flat layout and the by-value semantics, so records too must live in the `typed_data` store, not as Dart classes.
- **Coroutines / processes (`TRANSFER`, `NEWPROCESS`).** Dart has **no coroutines and no user-switchable stacks**; `async`/`await` is not a general stack switch and isolates are separate heaps (too heavy, no shared memory). True Modula-2 coroutines need a stack-switch primitive the VM does not expose → either a whole-program CPS transform or the feature is effectively **blocked**.
- **`DISPOSE` / manual free** beside a moving GC; **unsigned `CARDINAL` and defined `INTEGER` wraparound** vs. Dart's arbitrary-precision `int` (needs masking on every op); module initialization order.
- The Cocoa-object identity model ("a `CLASS` *is* an ObjC object") is orthogonal to Dart's object model and would have to be rebuilt via MACDART's own `dart:cocoa` bridge (which exists) rather than reused.

Static typing itself is *not* a friction — M2's type checks run in the front-end and the Dart VM's inert types are irrelevant.

**Tier: 3. Effort: High. Biggest friction: raw pointers/pointer-arithmetic, flat/variant records, `DISPOSE`, and coroutines have no counterpart in a moving tagged-object VM — you must emulate raw memory in `typed_data` *and* there is no stack-switch/coroutine primitive; the systems-language identity is what makes it the worst effort-to-fit of the five.**

---

## Feasibility ranking

Ranked by **fit** (tier) first, then effort within tier. Smalltalk at the top, as the lineage predicts.

| Rank | Language (repo) | Tier | Effort | Biggest friction |
|---|---|---|---|---|
| **1** | **Smalltalk (MACVM)** | **Tier 1** (+2 light desugars) | **Low–Med** | Non-local return `^` and the metaclass/class-side tower — both light desugarings that don't touch the object model. The classically hard bits (image, `become:`, resumable exceptions, `thisContext`) are ones **MACVM deliberately omits**, and the VM even has an internal `become` (`become.cc`) if you want it. |
| **2** | **Common Lisp / CLOS (NewCL)** | **Tier 2** | **High** | CLOS **multiple dispatch** on a single-dispatch VM (build a generic-function dispatcher over class-ids); plus resumable **restarts**, runtime **`eval`/`compile`**, `ratio`/`complex`, dynamic vars, and no guaranteed TCO. No VM surgery — all front-end + runtime library. |
| **3** | **Forth (MF67)** | **Tier 3** (JIT-as-backend) | **Low** | A word/cell stack machine that bypasses the object model & `dart:core`; no VM tail-call elimination; little speed gain over its own JASM JIT. |
| **4** | **BCPL (MacBCPL)** | **Tier 3** | **Low–Med** | Typeless word machine + global vector emulated on a `typed_data` store; zero reuse of the tagged-object model; manual memory sits beside the GC. Least conceptual overlap, but mechanically simple. |
| **5** | **Modula-2 (MacModula2)** | **Tier 3** | **High** | Raw pointers/pointer-arithmetic, flat/variant records, `DISPOSE`, and coroutines (`TRANSFER`) have no counterpart in a moving tagged-object VM — emulate raw memory in `typed_data`, and there is **no** coroutine/stack-switch primitive. Worst effort-to-fit. |

### One-line takeaways

- **Smalltalk is not merely feasible — it is the case the VM was born for.** doesNotUnderstand ≡ noSuchMethod, blocks ≡ closures, cascades are native, selectors dispatch by class-id + name through the same PIC + deopt machinery, the number tower and even the *three* SIMD value types line up, and hot reload gives live class redefinition. The only work is a front-end + kernel library and two desugarings.
- **Common Lisp is a big but honest Tier-2 guest** — the object model is compatible; the cost is rebuilding CLOS multi-dispatch, restarts, and runtime eval as libraries.
- **Forth and BCPL are Tier 3 but cheap** — they are small word machines that use the JIT as a fast backend and ignore the object model; re-hosting buys portability/GC-managed data, not speed.
- **Modula-2 is Tier 3 and expensive** — a systems language whose pointers, flat records, and coroutines fight a moving, tagged, GC'd object model at every turn.

---

# Part C — Recommendation

## Do Smalltalk first, and do it as a *coexisting* front-end

Part A shows the dual-front-end path is additive and cheap; Part B shows Smalltalk is the one
guest that lands at Tier 1. The two conclusions point the same way: **the highest-value first
alternative language for the MACDART VM is a Smalltalk front-end, built with the per-function
selection mechanism so that Smalltalk and full Dart run in one VM and call each other freely.**

Why Smalltalk before the others:

- **It is the cheapest** (Tier 1 + two light desugarings), because Dart *is* its lineage
  descendant — `doesNotUnderstand` ≡ `noSuchMethod`, blocks ≡ closures, selector dispatch runs
  through the same PIC + deopt machinery, and even the number tower and the three SIMD value
  types line up (Part B).
- **It has the highest payoff for this project specifically**: the sibling **MACVM** *is* a
  Smalltalk. Hosting Smalltalk on the Dart VM gives a direct, same-language A/B against MACVM's
  own JIT — the natural continuation of the benchmark work already in this repo.
- **The interop is free** (Part A §4): a Smalltalk method is an ordinary Dart `Function` reached
  by `cid + selector`, so Smalltalk code calls `dart:core`, `dart:cocoa`, and the game pane, and
  Dart code calls Smalltalk, with no bridge layer. The workspace, debugger, and profiler all work
  on the new language for free.

## The concrete build, mapped to the other two docs

Each step is the corresponding item from Part A's blueprint (§5), using the emission API of
[`dart-vm-frontend-guide.md`](dart-vm-frontend-guide.md):

1. **A per-`Function` marker.** Add a parallel opaque slot (e.g. `langx_function_`) mirroring
   `kernel_function_` (`object.h:2630-2642`), or reuse `kernel_function_` since the Dart-source
   path leaves it `NULL` (`object.cc:6817`). Extend `UseKernelFrontEndFor` / add a sibling
   predicate (`compiler.cc:116`).
2. **A loader.** Mirror `kernel_reader.cc`: for each Smalltalk class emit **two** Dart classes
   (an instance class `Foo` and a metaclass-instance class `Foo_class`, per Part B), via
   `Class::New(lib, …)` + `Library::AddClass` over a library that imports `dart:core`
   (`Library::NewLibraryHelper(url, /*import_core=*/true)`, `object.cc:11010`); register each
   method as a `Function::New` stamped with the Lang-X marker; run the batch through
   `ClassFinalizer::ProcessPendingClasses`.
3. **A Smalltalk→FlowGraph builder.** A `FlowGraphBuilder`-shaped class (front-end guide §1) that
   emits the *verbatim* selector as the `InstanceCallInstr` name (keyword selectors like `at:put:`
   are legal VM function names — no mangling), `ClosureCall` for `value`/`value:`, the
   `noSuchMethod` path for `doesNotUnderstand:`, cascades as a shared-receiver `InstanceCall`
   sequence, and the two desugarings: `^` non-local return (throw/catch a home token) and the
   metaclass tower.
4. **One hook.** A branch in `DartCompilationPipeline::BuildFlowGraph` (`compiler.cc:132`) — the
   fourth arm of the same `if` the kernel front-end already uses.

Everything else — SSA, the optimizer, register allocation, the ARM64 backend, the GC, inline
caches, deopt, and all of `dart:core` — is reused verbatim (Part A §5).

## A minimal proof of concept first

Before the full language, prove the plumbing end to end with a **Smalltalk-subset** front-end:
parse a handful of methods (unary/binary/keyword sends, blocks, `ifTrue:ifFalse:`, a literal or
two), register them as Dart classes, JIT them, and call one from the Dart workspace. That
exercises every seam — marker, loader, IL builder, pipeline hook, cross-language call — in a few
hundred lines, and de-risks the two desugarings before they matter. It is also the smallest thing
that yields a headline: *"a Smalltalk method, JIT-compiled by the Dart VM, calling `dart:cocoa`."*

## On the other four

- **Common Lisp (NewCL)** is a worthwhile but *large* Tier-2 project (a CLOS multi-dispatch
  library over class-ids, restarts, runtime `eval`) — take it on only if the goal is Lisp itself,
  not a quick win.
- **Forth (MF67)** and **BCPL (MacBCPL)** are Tier-3 "word machines": re-hosting them buys
  GC-managed data and portability, **not** speed (each already has a tuned native JIT), so it is
  only worth it as a curiosity or for uniform tooling.
- **Modula-2 (MacModula2)** is the one to *not* port: raw pointers, flat/variant records, and
  coroutines fight a moving tagged-object VM at every turn, and its "a `CLASS` is an ObjC object"
  model is orthogonal to Dart's — it is better served by its own LLVM backend.

The through-line: the Dart VM is a superb host for **class-based, single-dispatch, GC'd,
closure-having** languages (Smalltalk natively, Lisp with work) and a merely adequate *backend*
for word/pointer machines. Host the languages that share its object model; leave the systems
languages to their own compilers.

---

## See also

- [`dart-vm-compiler.md`](dart-vm-compiler.md) — the compiler this all sits on: parser → optimizer → ARM64 backend → deopt.
- [`dart-vm-frontend-guide.md`](dart-vm-frontend-guide.md) — the how-to for emitting Dart IL that Part C's step 3 builds on.
