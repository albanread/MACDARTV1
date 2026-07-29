# How to Write a Front-End that Emits Dart 1.24.3 IL

> **Part of a three-document series on the MACDART VM compiler:**
> [`dart-vm-compiler.md`](dart-vm-compiler.md) is the study of the compiler itself
> (parser → optimizer → backend → deopt); **this document** is the how-to for
> replacing its front end; and
> [`dart-vm-hosting-languages.md`](dart-vm-hosting-languages.md) applies both to
> host *other* languages (Smalltalk, Lisp, Forth, …) alongside full Dart.

A source-grounded how-to for building a *new* front-end (parser, DSL compiler,
bytecode lifter, whatever) that produces the **same Intermediate Language (IL)
FlowGraph** the stock Dart 1.24.3 (V1) parser produces, so the existing SSA
optimizer and ARM64 back-end will accept and JIT it unchanged.

All line cites are into `sdk/runtime/vm/` of this tree. This is **V1** — the IL
header is `intermediate_language.h` (not `il.h`), there are no type-argument
vectors on most calls, and the kernel reader is an in-VM AST walk, not the
streaming reader modern Dart uses.

The worked reference is the **kernel front-end** — `kernel::FlowGraphBuilder` in
`kernel_to_il.cc` (6839 lines) / `kernel_to_il.h` (1370 lines). It is a complete,
non-parser front-end: it consumes kernel AST nodes and emits exactly the IL the
parser emits. The stock **AST front-end**, `dart::FlowGraphBuilder` in
`flow_graph_builder.cc` (4458 lines), is the simpler parallel; comparing the two
isolates the *invariant contract* both satisfy and that your front-end must also
satisfy. Everything downstream of `FlowGraph*` is shared.

---

## 0. The 30-second mental model

A front-end's only job is to hand the shared compiler **one `FlowGraph*`** for
one function:

```
your front-end  ─┐
kernel front-end ├─►  FlowGraph*  ─►  ComputeSSA ─► optimizer ─► ARM64 codegen
AST parser       ─┘   (graph_entry_ + linked BlockEntry/Instruction list)
```

The `FlowGraph` is a doubly-linked list of `Instruction`s partitioned into basic
blocks, rooted at a `GraphEntryInstr`. The kernel front-end never touches that
linked list by hand; it builds it through one small algebra — the **`Fragment`**
— and a few dozen **emission primitives** (`Constant`, `LoadLocal`, `InstanceCall`
…). Learn those two things and you can emit any function.

The handoff point is fixed by `CompilationPipeline::BuildFlowGraph`
(`compiler.cc:132`), which returns a `FlowGraph*`. Your front-end is a third
implementation of that virtual, or a replacement for the body of the kernel one.

---

## 1. The IL-building API: `Fragment` + `FlowGraphBuilder`

### 1.1 What a `Fragment` is

`class Fragment` (`kernel_to_il.h:168`) is a value type — just two raw pointers:

```cpp
// kernel_to_il.h:170-179
Instruction* entry;    // first instruction of the fragment
Instruction* current;  // last instruction; NULL == control does not fall through
```

A fragment is a **straight-line (or already-terminated) piece of the
instruction list**, tracked only by its two ends. Three constructors
(`kernel_to_il.h:173-179`): empty `Fragment()`, single-instruction
`Fragment(Instruction*)`, and explicit `Fragment(entry, current)` — the last is
how you re-cap a fragment whose real exit is a block you built elsewhere (used
all over the control-flow code).

**Open vs closed** (`kernel_to_il.h:181-182`):

```cpp
bool is_open()   { return entry == NULL || current != NULL; }
bool is_closed() { return !is_open(); }
```

- `entry==NULL, current==NULL` → *empty*, and treated as open (you can still
  append to it; append just adopts the other fragment).
- `entry!=X, current!=NULL` → *open*: control falls through `current`; you may
  append more.
- `entry!=X, current==NULL` → *closed*: the fragment ends in something that does
  not fall through (a `Return`, `Goto`, `Branch`). Appending to a closed
  fragment is a no-op — the new instructions are unreachable and silently
  dropped.

`Fragment::closed()` (`kernel_to_il.h:187`, impl `kernel_to_il.cc:842`) forces
the closed state: `return Fragment(entry, NULL);`.

### 1.2 The two combinators — how instructions enter blocks

**Append a fragment** — `operator+` / `operator+=`
(`kernel_to_il.h:184,190`; impl `kernel_to_il.cc:819`):

```cpp
// kernel_to_il.cc:819
Fragment& Fragment::operator+=(const Fragment& other) {
  if (entry == NULL) {                       // I'm empty: become 'other'
    entry = other.entry; current = other.current;
  } else if (current != NULL && other.entry != NULL) {
    current->LinkTo(other.entry);            // splice the two linked lists
    current = other.current;                 // new tail is other's tail
  }
  return *this;
}
```

**Append one instruction** — `operator<<` / `operator<<=`
(`kernel_to_il.h:185,191`; impl `kernel_to_il.cc:831`):

```cpp
// kernel_to_il.cc:831
Fragment& Fragment::operator<<=(Instruction* next) {
  if (entry == NULL)        { entry = current = next; }
  else if (current != NULL) { current->LinkTo(next); current = next; }
  return *this;
}
```

The actual list surgery is `Instruction::LinkTo` (`intermediate_language.h:747`):
`this->set_next(next); next->set_previous(this);` — a plain doubly-linked-list
insert. **That is the only place raw instructions get linked.** Everything else is
`Fragment` arithmetic, so a front-end never manipulates `next_/previous_` itself.

Idiomatic emission is therefore just `+=`:

```cpp
Fragment body;
body += LoadLocal(x);      // each primitive returns a 1-instr Fragment
body += LoadLocal(y);
body += InstanceCall(pos, Symbols::Plus(), Token::kADD, 2);
body += Return(pos);       // returns a *closed* Fragment → body.is_closed()
```

Because `current==NULL` on a closed fragment stops further appends, straight-line
code, dead-code-after-return, and branch merges all fall out of the same operator
without special-casing.

### 1.3 The builder and its stack machine

`class FlowGraphBuilder` (`kernel_to_il.h:784`) holds the mutable state the
primitives read/write. The important members (`kernel_to_il.h:1056-1073`):

| member | role |
|---|---|
| `next_block_id_` / `AllocateBlockId()` (`:1056`) | monotonic basic-block ids |
| `context_depth_` (`:1062`) | current captured-variable context nesting |
| `loop_depth_` (`:1063`) | for `CheckStackOverflow` / OSR |
| `try_depth_`, `catch_depth_` (`:1064-65`) | exception nesting |
| `stack_` (`:1068`) | the **expression evaluation stack** (a `Value*` list) |
| `pending_argument_count_` (`:1069`) | outgoing args pushed but not consumed |
| `graph_entry_` (`:1071`) | the `GraphEntryInstr` root |
| `scopes_` (`:1073`) | `ScopeBuildingResult*` — the pre-computed locals/scopes |

The front-end is a **stack machine over SSA-candidate `Definition`s**. Primitives
that *produce* a value push it; primitives that *consume* values pop them
(`kernel_to_il.h:1034-1036`, impl `kernel_to_il.cc:3056`):

```cpp
// kernel_to_il.cc:3056
void FlowGraphBuilder::Push(Definition* def) {
  SetTempIndex(def);                          // temp_index = stack height
  Value::AddToList(new (Z) Value(def), &stack_);
}
// kernel_to_il.cc:3062
Value* FlowGraphBuilder::Pop() { /* unlink top of stack_, clear its ssa temp */ }
// kernel_to_il.cc:3075
Fragment FlowGraphBuilder::Drop() { /* pop + emit DropTemps if materialized */ }
```

`SetTempIndex` (`kernel_to_il.cc:3050`) gives each pushed definition a
`temp_index` one above the current top — this is the *virtual expression-stack
slot* the register allocator later understands. So a primitive like `LoadLocal`
doesn't return a value to C++; it **pushes a `Definition` and returns a
`Fragment`** containing that definition. The next primitive that needs the value
calls `Pop()`. This is the exact discipline your front-end must copy: **the order
you emit pushes and pops is the calling convention between primitives.**

### 1.4 `BuildGraphOfFunction` — the whole skeleton

`BuildGraph()` (`kernel_to_il.cc:3152`) is a dispatcher on `function.kind()`
(`:3212`) — regular/closure/getter/setter go to `BuildGraphOfFunction`
(`:3222`), constructors, field accessors, method extractors, noSuchMethod and
invoke-field dispatchers each have their own builder. For a plain function the
entire skeleton is `BuildGraphOfFunction` (`kernel_to_il.cc:3264`). Stripped to
the load-bearing lines:

```cpp
// kernel_to_il.cc:3264
FlowGraph* FlowGraphBuilder::BuildGraphOfFunction(FunctionNode* function, ...) {
  TargetEntryInstr* normal_entry = BuildTargetEntry();                 // :3267
  graph_entry_ = new (Z) GraphEntryInstr(*parsed_function_,
                                         normal_entry, osr_id_);        // :3268

  SetupDefaultParameterValues(function);                               // :3271

  Fragment body;
  if (!dart_function.is_native())
    body += CheckStackOverflowInPrologue();                            // :3274
  // ... allocate context for captured params, run constructor
  //     initializers, checked-mode param checks (all optional) ...

  if (dart_function.is_native())      body += NativeFunctionBody(...);  // :3399
  else if (function->body() != NULL)  body += TranslateStatement(function->body()); // :3402

  if (body.is_open()) {               // implicit `return null;`
    body += NullConstant();                                            // :3405
    body += Return(dart_function.end_token_pos());                     // :3406
  }
  // ... async/yield state-machine rewrite (optional) ...

  normal_entry->LinkTo(body.entry);                                    // :3534
  return new (Z) FlowGraph(*parsed_function_,
                           graph_entry_, next_block_id_ - 1);          // :3545
}
```

Four moves that *every* front-end must make, in this order:

1. Make a `TargetEntryInstr` (`BuildTargetEntry()`, `kernel_to_il.cc:4273`) and
   wrap it in a `GraphEntryInstr` — that pair is the graph root.
2. Build the body as one `Fragment`, prologue-first.
3. Guarantee the body is closed — if `is_open()`, append `NullConstant()+Return`.
   **A front-end must never hand back a fall-off-the-end graph.** The AST side
   asserts exactly this: `ASSERT(!for_effect.is_open())` (`flow_graph_builder.cc:4407`).
4. `normal_entry->LinkTo(body.entry)` then construct the `FlowGraph`.

`BuildTargetEntry`/`BuildJoinEntry` (`kernel_to_il.cc:4273-4285`) are the only
two block-entry factories:

```cpp
TargetEntryInstr* BuildTargetEntry() {              // single-predecessor block
  return new (Z) TargetEntryInstr(AllocateBlockId(), CurrentTryIndex());
}
JoinEntryInstr* BuildJoinEntry() {                  // merge point, >1 predecessor
  return new (Z) JoinEntryInstr(AllocateBlockId(), CurrentTryIndex());
}
```

### 1.5 Control flow assembled from fragments

This is the part with no analogue in a tree-walker; study it. Blocks are created
lazily (a `TargetEntryInstr` per branch arm, a `JoinEntryInstr` per merge) and
stitched with `Goto` and `BranchIf*`. The pattern is always: *build a closed
branch fragment, seed new fragments from the branch's target entries, then merge
with a join.*

**`if / else`** (`VisitIfStatement`, `kernel_to_il.cc:5819`):

```cpp
Fragment instructions = TranslateCondition(node->condition(), &negate); // :5823
TargetEntryInstr *then_entry, *otherwise_entry;
instructions += BranchIfTrue(&then_entry, &otherwise_entry, negate);    // :5826  (closes 'instructions')

Fragment then_fragment(then_entry);                                     // :5828  seed from the entry block
then_fragment += TranslateStatement(node->then());

Fragment otherwise_fragment(otherwise_entry);                           // :5831
otherwise_fragment += TranslateStatement(node->otherwise());

if (then_fragment.is_open() && otherwise_fragment.is_open()) {          // :5834
  JoinEntryInstr* join = BuildJoinEntry();
  then_fragment      += Goto(join);
  otherwise_fragment += Goto(join);
  fragment_ = Fragment(instructions.entry, join);   // re-cap: entry is the branch, exit is the join
}                                                     // (the open-count decides which of 4 merge shapes)
```

Note the re-capping trick `Fragment(instructions.entry, join)`: the visible
fragment keeps the *original* entry but its fall-through is now the join block —
`entry` and `current` need not be adjacent in the list.

**`while`** (`VisitWhileStatement`, `kernel_to_il.cc:5851`) — a back-edge is just
a `Goto` to a join placed *before* the condition, plus a `CheckStackOverflow` at
the loop header:

```cpp
++loop_depth_;                                                          // :5854
Fragment condition = TranslateCondition(...); 
condition += BranchIfTrue(&body_entry, &loop_exit, negate);            // :5859
Fragment body(body_entry);
body += TranslateStatement(node->body());
if (body.is_open()) {
  JoinEntryInstr* join = BuildJoinEntry();                            // :5866
  body += Goto(join);                                                 // back-edge
  Fragment loop(join);
  loop += CheckStackOverflow();                                       // :5870
  loop += condition;
  entry = new (Z) GotoInstr(join);      // fall-in to the loop header // :5872
}
fragment_ = Fragment(entry, loop_exit);                               // :5878
--loop_depth_;
```

`for` (`:5913`) is the same shape plus `EnterScope`/`CloneContext` for captured
loop variables and an update list; `do/while` (`:5883`) puts the condition after
the body.

**Short-circuit `&&` / `||`** (`VisitLogicalExpression`, `kernel_to_il.cc:5456`)
is control flow producing a *value*: branch on the left; the taken side evaluates
the right and stores the boolean into `expression_temp_var`; the constant side
stores `true`/`false`; both `Goto` a join; after the join a single `LoadLocal`
re-reads the temp so the whole thing leaves exactly one value on the stack
(`:5488-5493`). This "materialize through a temp, merge, reload" idiom is how any
value-producing diamond is kept SSA-friendly without the front-end doing phi
insertion (`ComputeSSA` inserts the phis later from the join's predecessors).

**`switch`** uses helper `SwitchBlock` (`kernel_to_il.h:1127`) that lazily
`BuildJoinEntry`s one destination per case (`EnsureDestination`, `:1186`) so
`continue`-to-case and fallthrough resolve to the right join. `break`/`continue`
walk chained `BreakableBlock`/`SwitchBlock`/`TryFinallyBlock` records
(`kernel_to_il.h:1268`, `:1127`, `:1231`) to find their destination join and
unwind context depth. A minimal front-end can ignore all of these until it needs
labeled break/continue.

---

## 2. Core emission primitives (`kernel_to_il.h:912-994`)

These are the vocabulary. Each is a `FlowGraphBuilder` method returning a
`Fragment`; almost all follow the same three-line body: *pop inputs → `new (Z)`
the instruction → `Push` if it produces a value → return `Fragment(instr)`*.

### 2.1 Constants and literals

```cpp
// kernel_to_il.cc:2492
Fragment Constant(const Object& value) {
  ConstantInstr* c = new (Z) ConstantInstr(value);
  Push(c);                       // pushes, consumes nothing
  return Fragment(c);
}
```

`IntConstant(int64)` (`:2515`) wraps `Integer::New`; `NullConstant()` (`:2674`) is
`Constant(Instance::null())`. Constants must be zone-handles, asserted at
`:2493` (`value.IsNotTemporaryScopedHandle()`).

### 2.2 Locals

```cpp
// kernel_to_il.cc:2644
Fragment LoadLocal(LocalVariable* variable) {
  if (variable->is_captured()) {                       // lives in a Context object
    ... LoadContextAt(owner->context_level())
      + LoadField(Context::variable_offset(index)) ...
  } else {
    LoadLocalInstr* load = new (Z) LoadLocalInstr(*variable, kNoSource);
    Push(load);                                        // pushes the loaded value
  }
}
// kernel_to_il.cc:2854
Fragment StoreLocal(TokenPosition pos, LocalVariable* variable) {
  if (variable->is_captured()) { ... StoreInstanceField into the context ... }
  else {
    Value* value = Pop();                              // consumes top of stack
    StoreLocalInstr* store = new (Z) StoreLocalInstr(*variable, value, pos);
    Push(store);                                       // store *also* yields the value
  }
}
```

Note the captured-variable branch: a captured local is *not* a stack slot, it is a
field of a heap `Context`, so load/store transparently redirect through
`LoadField`/`StoreInstanceField` (see §3). This is invisible to callers — you emit
`LoadLocal(v)` and the primitive picks the representation from
`v->is_captured()`.

### 2.3 Object allocation and fields

```cpp
// kernel_to_il.cc:2323
Fragment AllocateObject(const dart::Class& klass, intptr_t argument_count) {
  ArgumentArray args = GetArguments(argument_count);   // pops N PushArguments
  AllocateObjectInstr* a = new (Z) AllocateObjectInstr(kNoSource, klass, args);
  Push(a);
}
// kernel_to_il.cc:2610 / 2620 — field load
Fragment LoadField(const dart::Field& field);          // typed, by Field object
Fragment LoadField(intptr_t offset, intptr_t class_id); // raw, by byte offset
// kernel_to_il.cc:2798 / 2840 — field store
Fragment StoreInstanceField(const dart::Field&, bool is_init, StoreBarrierType);
Fragment StoreInstanceField(TokenPosition, intptr_t offset, StoreBarrierType);
```

`LoadField(offset)` pops the receiver and pushes the loaded slot;
`StoreInstanceField(offset)` pops value then receiver. The store-barrier is
auto-elided for constant values (`value->BindsToConstant()` → `kNoStoreBarrier`,
`:2809`, `:2845`) — a GC-correctness detail your front-end gets for free by
calling the primitive rather than building the instr yourself.

### 2.4 Calls — the two primitives that carry Dart semantics

Everything above is plumbing. **`InstanceCall` and `StaticCall` are where Dart
dynamic-dispatch and static-binding semantics live**, so they are the primitives a
new front-end must get exactly right.

Both consume their arguments the same way: arguments are first pushed as ordinary
values, then reified into `PushArgumentInstr`s (§2.5), then collected by
`GetArguments(count)` (`kernel_to_il.cc:4452`) which pops `count`
`PushArgumentInstr`s off the stack in reverse into a `ZoneGrowableArray`.

```cpp
// kernel_to_il.cc:2531  — dynamic dispatch by selector
Fragment InstanceCall(TokenPosition pos, const String& name, Token::Kind kind,
                      intptr_t argument_count, const Array& argument_names,
                      intptr_t num_args_checked) {
  ArgumentArray arguments = GetArguments(argument_count);   // receiver + args
  const intptr_t kTypeArgsLen = 0;   // V1: no generic instance calls
  InstanceCallInstr* call = new (Z) InstanceCallInstr(
      pos, name, kind, arguments, kTypeArgsLen,
      argument_names, num_args_checked, ic_data_array_);
  Push(call);                        // the call result is pushed
  return Fragment(call);
}
```

The **selector `String` + argument shape** *is* the call: dispatch is resolved at
run time from the receiver class against `name`/`argument_names`, seeded by the
inline-cache array `ic_data_array_` (see §4). `num_args_checked` (1 for a normal
call, = arg count for operators) tells the IC how many leading args to type-check.
`kind` is a `Token::Kind` marking recognized operators (`kADD`, `kEQ`, `kGET`,
`kSET`, `kILLEGAL` for a plain method) — the constructor asserts `kind` is one of
the operator/getter/setter/illegal kinds (`intermediate_language.h:2891-2898`).

```cpp
// kernel_to_il.cc:2762  — statically-bound target
Fragment StaticCall(TokenPosition pos, const Function& target,
                    intptr_t argument_count, const Array& argument_names) {
  ArgumentArray arguments = GetArguments(argument_count);
  const intptr_t kTypeArgsLen = 0;
  StaticCallInstr* call = new (Z) StaticCallInstr(
      pos, target, kTypeArgsLen, argument_names, arguments, ic_data_array_);
  // recognized list-factories / intrinsics get a result cid for the optimizer:
  const intptr_t list_cid = GetResultCidOfListFactory(Z, target, argument_count);
  if (list_cid != kDynamicCid) { call->set_result_cid(list_cid); ... }
  else if (target.recognized_kind() != MethodRecognizer::kUnknown)
    call->set_result_cid(MethodRecognizer::ResultCid(target));
  Push(call);
}
```

`StaticCall` differs from `InstanceCall` only in that dispatch is already resolved
to a concrete `Function&` (top-level function, constructor, or a
direct/super call the front-end resolved itself — see `VisitDirectMethodInvocation`
`kernel_to_il.cc:5194`, which resolves the member then emits `StaticCall`).

### 2.5 `PushArgument`, `Return`, branches

```cpp
// kernel_to_il.cc:2689
Fragment PushArgument() {
  PushArgumentInstr* argument = new (Z) PushArgumentInstr(Pop());  // pops a value
  Push(argument);                                                  // pushes the arg marker
  argument->set_temp_index(argument->temp_index() - 1);
  ++pending_argument_count_;                                       // tracked for GetArguments
}
// kernel_to_il.cc:2700
Fragment Return(TokenPosition pos) {
  ... CheckReturnTypeInCheckedMode();
  Value* value = Pop();  ASSERT(stack_ == NULL);   // stack must be empty at return
  ReturnInstr* r = new (Z) ReturnInstr(pos, value);
  instructions <<= r;
  return instructions.closed();                    // Return always closes
}
```

`Return`'s `ASSERT(stack_ == NULL)` (`:2706`) is a hard front-end invariant:
**the expression stack must be balanced to empty at every return.** Push/pop
discipline errors surface here.

Branches don't consume through the stack normally — they pop their two comparands
and **write their successor blocks by address**
(`BranchIfEqual`, `kernel_to_il.cc:2377`):

```cpp
Value* right = Pop(); Value* left = Pop();
StrictCompareInstr* cmp = new (Z) StrictCompareInstr(kNoSource,
    negate ? Token::kNE_STRICT : Token::kEQ_STRICT, left, right, false);
BranchInstr* branch = new (Z) BranchInstr(cmp);
*then_entry      = *branch->true_successor_address()  = BuildTargetEntry();
*otherwise_entry = *branch->false_successor_address() = BuildTargetEntry();
return Fragment(branch).closed();     // a branch always closes its fragment
```

`Goto(join)` (`kernel_to_il.cc:2510`) is `Fragment(new GotoInstr(join)).closed()`.

### 2.6 Worked example: a method call becomes an `InstanceCallInstr`

Source `a.foo(b, c)` — trace `VisitMethodInvocation` (`kernel_to_il.cc:5139`):

```cpp
const String& name = H.DartMethodName(node->name());          // "foo"        :5142
const intptr_t argument_count = node->arguments()->count()+1; // +1 = receiver :5143
const Token::Kind token_kind = MethodKind(name);              // kILLEGAL      :5144

Fragment instructions = TranslateExpression(node->receiver()); // eval 'a', push :5165
instructions += PushArgument();                                // reify receiver :5166
Array& argument_names = Array::ZoneHandle(Z);
instructions += TranslateArguments(node->arguments(), &argument_names); // b,c   :5170
                     // each arg: TranslateExpression + PushArgument

fragment_ = instructions + InstanceCall(node->position(), name, token_kind,
                                        argument_count, argument_names,
                                        num_args_checked);      //               :5180
```

The emitted linear IL (each line a `Definition` on the expression stack, then
reified to an argument):

```
v0 = <eval a>            ; TranslateExpression(receiver) → Push
     PushArgument(v0)    ; PushArgument            (pending_argument_count_=1)
v1 = <eval b>
     PushArgument(v1)                              (=2)
v2 = <eval c>
     PushArgument(v2)                              (=3)
v3 = InstanceCall:foo( v0, v1, v2 )   ; GetArguments(3) pops the 3 PushArguments
```

`InstanceCall` calls `GetArguments(3)` (`:2537` → `:4452`), which pops the three
`PushArgumentInstr`s (asserting each `stack_->definition()->IsPushArgument()`,
`:4457`) and hands them to the `InstanceCallInstr` constructor. The call result
`v3` is pushed, ready to be the receiver/argument of the next primitive. No
`EmitNativeCode` anywhere — the front-end only ever *constructs and links*
instructions; native code generation is the shared back-end's job.

---

## 3. Locals, scopes, temporaries, captured variables, closures

### 3.1 `LocalVariable` and the pre-computed scope

The front-end does **not** invent locals on the fly for source variables; a
separate scope-building pass produces every `LocalVariable` and its frame index
first, and the IL builder only *looks them up*. The result object is
`ScopeBuildingResult` (`kernel_to_il.h:615`):

```cpp
IntMap<LocalVariable*> locals;   // keyed by kernel_offset of the declaration  :626
IntMap<LocalScope*>    scopes;   // keyed by kernel_offset of the scope node    :627
LocalVariable* this_variable;    // non-NULL for instance methods              :631
LocalVariable* type_arguments_variable;   // factories                          :634
LocalVariable* switch_variable, *finally_return_variable, *setter_value; ...
GrowableArray<LocalVariable*> exception_variables / stack_trace_variables / ... ;
```

`ScopeBuilder::BuildScopes()` (`kernel_to_il.cc:286`) walks the function once and:

- creates the receiver `this` param for non-static functions
  (`kernel_to_il.cc:353-362`), the closure param for closures (`:347-352`), or
  the type-args param for factories (`:378-383`), each via
  `scope_->InsertParameterAt(pos++, variable)`;
- adds the declared parameters (`AddParameters` `:101` → `AddParameter` `:113`),
  inserting each into `result_->locals` keyed by kernel offset (`:125`);
- registers the forced-stack `current_context_var` (`:323-325`).

`MakeVariable` (`kernel_to_il.cc:93`) is a thin `new (Z) LocalVariable(...)`. The
builder later resolves declarations with `LookupVariable`
(`kernel_to_il.cc:3036/3043`) — an assert-backed `scopes_->locals.Lookup(offset)`.
So a source `x` becomes an IL `LocalVariable*` by kernel-offset lookup, and the
`VisitVariableGet`/`VisitVariableSet` visitors (`kernel_to_il.cc:4849/4855`) just
`LoadLocal(LookupVariable(...))` / `StoreLocal(...)`.

**Frame slots** are assigned last, by `ParsedFunction::AllocateVariables`
(`parser.cc:308`): it sets `first_parameter_index_`, `first_stack_local_index_`,
`num_stack_locals_` (`parser.cc:319-339`) which `MakeTemporary` and the register
allocator read. A new front-end reuses this machinery unchanged — build scopes,
then `AllocateVariables`.

### 3.2 Temporaries

`MakeTemporary()` (`kernel_to_il.cc:3005`) turns *the definition currently on top
of the stack* into a named `:tempN` `LocalVariable` so it can be re-loaded later:

```cpp
intptr_t index = stack_->definition()->temp_index();
LocalVariable* variable = new (Z) LocalVariable(..., H.DartSymbol(":tempN"), dynamic);
variable->set_index(first_stack_local_index - num_stack_locals
                    - pending_argument_count_ - index);   // frame slot
stack_->definition()->set_ssa_temp_index(0);              // mark used → materialized
```

Pattern: emit something that pushes (e.g. `CreateArray`), `LocalVariable* t =
MakeTemporary()`, then `LoadLocal(t)` as many times as needed. Used pervasively —
string interpolation (`:5528`), closure creation (`:6689`), context push
(`:2195`).

### 3.3 Captured variables and the `Context` object

A variable referenced by a nested function is *captured*: it can't live in the
stack frame because the closure outlives the frame, so it lives in a heap-allocated
`Context`. The builder tracks nesting with `context_depth_` and manipulates
contexts through five primitives:

- `AllocateContext(size)` (`kernel_to_il.cc:2315`) — `new AllocateContextInstr`.
- `PushContext(size)` (`kernel_to_il.cc:2192`) — allocate a context, chain its
  `Context::parent_offset()` to the current context, store it back into
  `current_context_var`, `++context_depth_`.
- `PopContext()` (`:2207`) → `AdjustContextTo(context_depth_-1)` (`:2178`) —
  reload the parent context and `--context_depth_`.
- `LoadContextAt(depth)` (`:2167`) — load `current_context_var` then walk
  `Context::parent_offset()` links `(context_depth_ - depth)` times.
- `EnterScope`/`ExitScope` (`:2130`/`:2151`) — look up the scope's
  `num_context_variables()`; if > 0, push/pop a context around the block.

`LoadLocal`/`StoreLocal` (§2.2) already route captured vars here: a captured
`LoadLocal(v)` becomes `LoadContextAt(v->owner()->context_level()) +
LoadField(Context::variable_offset(v->index()))` (`kernel_to_il.cc:2646-2648`).
The prologue of `BuildGraphOfFunction` copies captured *parameters* from their
incoming stack slots into the freshly allocated context
(`kernel_to_il.cc:3277-3311`).

### 3.4 Lowering a closure / function expression

`TranslateFunctionNode` (`kernel_to_il.cc:6604`) lowers a nested function literal:

1. Find (or lazily create) the `Function` object for the closure, keyed by
   enclosing function + a synthetic `TokenPosition`
   (`I->LookupClosureFunction(...)`, `:6626`; `Function::NewClosureFunction`,
   `:6637`). Its `context_scope` is preserved from the current context depth
   (`scope->PreserveOuterScope(context_depth_)`, `:6667`) so captures resolve at
   run time.
2. Allocate a `Closure` instance: `AllocateObject(closure_class, function)`
   (`:6688`) — the two-arg overload (`kernel_to_il.cc:2333`) that stamps
   `set_closure_function` onto the `AllocateObjectInstr`.
3. `MakeTemporary()` the closure (`:6689`), then store two fields into it:
   the function (`Closure::function_offset()`, `:6695-6697`) and the *current
   context* (`Closure::context_offset()`, `:6699-6702`) — the captured
   environment.

The closure's own body is compiled *separately* later, as its own function of
kind `kClosureFunction`, going through the same `BuildGraphOfFunction`. Implicit
closures (tear-offs) use `BuildImplicitClosureCreation` (`kernel_to_il.cc:3786`).
A block/scope with its own locals is just `EnterScope + statements + ExitScope`
(`VisitBlock`, `kernel_to_il.cc:5719`).

---

## 4. Bookkeeping the shared back-end requires

The optimizer and codegen read four things the front-end must set correctly.

### 4.1 Deopt ids — assigned at instruction construction, order-sensitive

A deopt id ties an optimized instruction to the point in the *unoptimized* code
where execution resumes after deoptimization. **The front-end does not manage a
counter or call a "next deopt id" function per emission.** Instead every
deoptimizing/target instruction pulls its id from the thread *inside its
constructor*:

```cpp
// intermediate_language.h:669  — base default
explicit Instruction(intptr_t deopt_id = Thread::kNoDeoptId) : deopt_id_(deopt_id) ...
// intermediate_language.h:2878  — InstanceCallInstr
: TemplateDartCall(Thread::Current()->GetNextDeoptId(), ...)
// also :2112, :2142, :3332 (StaticCall), :3249, :4053 ... — same idiom
```

Consequence for a new front-end: the *only* requirement is that you **construct
instructions in a deterministic order**, because the deopt-id sequence must be
identical between the unoptimized and optimized builds of the same function
(otherwise a deopt lands at the wrong resume point). You get this for free by
building the graph the same way each time. A handful of primitives allocate ids
explicitly via `H.thread()->GetNextDeoptId()` — the field guards
(`kernel_to_il.cc:2831/2833`) and `CatchBlockEntry` (`:2418`) — but these are the
exception; call the primitive and the id is handled.

`CheckStackOverflowInPrologue` (`kernel_to_il.cc:2459`) is instructive: even when
inlining suppresses the actual check, it still *constructs* a
`CheckStackOverflowInstr` "in order to allocate a deopt id" (`:2462`) so the id
stream stays aligned. Preserving id-stream alignment is a real invariant, not an
optimization.

### 4.2 `TokenPosition`

Every value-producing/side-effecting instruction carries a `TokenPosition` for
debugging, breakpoints, and stack traces. The front-end threads the source
position through each primitive (`InstanceCall(node->position(), ...)`,
`Return(node->position())`). When there is no meaningful source location — synthetic
prologue code, compiler temporaries — use `TokenPosition::kNoSource` (seen in
nearly every primitive, e.g. `kernel_to_il.cc:2317, 2327, 2651`). Positions must
be *unique per parent* in a couple of places (closure lookup synthesizes a fake
one, `kernel_to_il.cc:2622`), but for ordinary code any position, including
`kNoSource`, is accepted.

### 4.3 Block ids and try indices

`AllocateBlockId()` (`kernel_to_il.h:1057`) hands each `BlockEntryInstr` a unique
id; `CurrentTryIndex()` (`kernel_to_il.cc:3027`) supplies the enclosing catch's
index (or `kInvalidTryIndex`). The final `max_block_id` passed to the `FlowGraph`
ctor is `next_block_id_ - 1` (`kernel_to_il.cc:3545`). `DiscoverBlocks` (called
from the ctor, below) recomputes pre/post orders from these.

### 4.4 Returning the `FlowGraph*` to the shared optimizer

The finished graph is one object:

```cpp
// kernel_to_il.cc:3545
return new (Z) FlowGraph(*parsed_function_, graph_entry_, next_block_id_ - 1);
```

`FlowGraph::FlowGraph` (`flow_graph.cc:26`) stores the parsed function, the
graph entry, `max_block_id`, and immediately calls `DiscoverBlocks()` (`:52`) to
build the block orderings the optimizer needs. Nothing else is required of the
front-end — no SSA, no phis, no register info.

The handoff is via the pipeline virtual `CompilationPipeline::BuildFlowGraph`
(`compiler.cc:132`, `DartCompilationPipeline::BuildFlowGraph`), which for a kernel
function does exactly:

```cpp
// compiler.cc:137-144
kernel::FlowGraphBuilder builder(node, parsed_function, ic_data_array, NULL, osr_id);
FlowGraph* graph = builder.BuildGraph();
ASSERT(graph != NULL);
return graph;
```

and the caller `CompileParsedFunctionHelper` then drives the shared pipeline
(`compiler.cc:779` builds it, `:810` `flow_graph->ComputeSSA(0, NULL)`, then the
optimization passes and ARM64 codegen). **A new front-end is a fourth arm of that
`if` in `BuildFlowGraph`** (alongside kernel / AST-parser / irregexp), or a
replacement body for the kernel arm, returning a `FlowGraph*` built exactly as
above. Everything after the `return` is untouched.

The AST parser proves the contract is front-end-agnostic: its
`FlowGraphBuilder::BuildGraph` (`flow_graph_builder.cc:4385`) makes the *same*
`normal_entry`/`GraphEntryInstr` pair (`:4399-4402`), appends the body
(`AppendFragment`, `:4405`), asserts closed (`:4407`), and returns
`new FlowGraph(parsed_function, graph_entry_, last_used_block_id_)` (`:4416`). Its
combinator is `EffectGraphVisitor` with `Append`/`Bind`/`Do`/`AddInstruction`
(`flow_graph_builder.cc:645/657/672/685`) instead of `Fragment`, but the produced
object is identical in shape.

---

## 5. The minimal contract — the API surface you reimplement

To get **one function JIT-compiled**, a new front-end must produce a `FlowGraph*`
that is (a) rooted at a `GraphEntryInstr` with a normal `TargetEntryInstr`,
(b) a correctly linked block/instruction list, (c) closed on every path, and
(d) stack-balanced. That is achievable with a surprisingly small kernel of the
API. Reimplement (or reuse) exactly this much:

**A. The fragment algebra (or an equivalent).**
`Fragment` with `entry`/`current`, `operator+=` splicing via `Instruction::LinkTo`,
`operator<<=` for single instructions, `is_open/is_closed`, and `closed()`
(`kernel_to_il.h:168-191`; `kernel_to_il.cc:819-859`). This is ~40 lines and is
the whole list-building mechanism.

**B. The expression-stack discipline.**
`Push`/`Pop`/`Drop`/`SetTempIndex`/`MakeTemporary`
(`kernel_to_il.cc:3005,3050,3056,3062,3075`) and the field `stack_`. Every
value-producing primitive `Push`es; every consumer `Pop`s; stack must be empty at
`Return`.

**C. Block factories + graph root.**
`BuildTargetEntry`/`BuildJoinEntry` (`kernel_to_il.cc:4273-4285`),
`AllocateBlockId` (`kernel_to_il.h:1057`), and the
`GraphEntryInstr(parsed_function, normal_entry, osr_id)` +
`normal_entry->LinkTo(body.entry)` + `new FlowGraph(...)` sequence
(`kernel_to_il.cc:3267-3269, 3534, 3545`).

**D. The smallest useful primitive set** (all in `kernel_to_il.h:912-994`):

| need | primitive(s) | impl |
|---|---|---|
| constants / null | `Constant`, `IntConstant`, `NullConstant` | `.cc:2492, 2515, 2674` |
| read/write a local | `LoadLocal`, `StoreLocal` | `.cc:2644, 2854` |
| read/write a field | `LoadField`, `StoreInstanceField` | `.cc:2610/2620, 2798/2840` |
| allocate an object | `AllocateObject` | `.cc:2323` |
| reify a call arg | `PushArgument` (+ `GetArguments`) | `.cc:2689, 4452` |
| dynamic dispatch | **`InstanceCall`** (selector + arg-descriptor) | `.cc:2531` |
| static call | **`StaticCall`** (resolved `Function&`) | `.cc:2762` |
| compare | `StrictCompare` | `.cc:2351` |
| conditional branch | `BranchIfTrue`/`BranchIfEqual`/`BranchIfStrictEqual` | `.cc:2362/2377/2392` |
| unconditional jump | `Goto` | `.cc:2510` |
| stack-overflow/OSR check | `CheckStackOverflow(InPrologue)` | `.cc:2459/2470` |
| return | `Return` | `.cc:2700` |

**E. Control-flow shapes.** `if` (`.cc:5819`), `while`/`for`/`do` (`.cc:5851/5913/5883`),
short-circuit `&&`/`||` (`.cc:5456`) — each is the "closed branch fragment + seed
from target entries + merge at a join" pattern from §1.5. `switch`, `break`,
`continue`, try/catch/finally are additive; skip until needed.

**F. Scope prep, once per function.** Produce the `LocalVariable`s and scopes
(your analogue of `ScopeBuilder::BuildScopes`, `kernel_to_il.cc:286`) and call
`ParsedFunction::AllocateVariables` (`parser.cc:308`) so frame slots exist before
you emit `LoadLocal`. Provide `this`/params via `InsertParameterAt`, and a
`current_context_var` even if you never capture anything (the prologue and
`LoadContextAt` assume it exists — `kernel_to_il.cc:323`).

**What you get for free** by using the primitives instead of hand-building
instructions: deopt-id allocation (constructor-time, §4.1), store-barrier
elision (§2.3), SSA construction and phi insertion (`ComputeSSA`, `compiler.cc:810`),
block ordering (`DiscoverBlocks` in the `FlowGraph` ctor), all optimization passes,
and ARM64 code generation. **You never write `EmitNativeCode`, never insert phis,
never allocate registers.**

**Hard invariants the shared code will assert on** — get these wrong and it
crashes, not miscompiles:

1. The body `Fragment` is **closed** on every path (append `NullConstant()+Return`
   if `is_open()`) — cf. `flow_graph_builder.cc:4407`.
2. The expression **stack is empty at every `Return`** — `kernel_to_il.cc:2706`.
3. `GetArguments(n)` finds exactly `n` `PushArgumentInstr`s on top of the stack —
   `kernel_to_il.cc:4457`.
4. Instructions are constructed in a **deterministic order** so the deopt-id
   stream matches between unoptimized and optimized builds — §4.1.
5. Every `BlockEntryInstr` has a unique id from `AllocateBlockId`, and the
   `FlowGraph` is given `next_block_id_ - 1` as `max_block_id` —
   `kernel_to_il.cc:3545`.

Satisfy those and the graph is SSA-able and the stock 1.24.3 optimizer + ARM64
backend will compile it exactly as if the parser had produced it.

---

## Appendix — file map

| file | role | key entry points |
|---|---|---|
| `kernel_to_il.h` | builder + fragment + scope decls | `Fragment` :168, `FlowGraphBuilder` :784, primitives :912-994, `ScopeBuildingResult` :615 |
| `kernel_to_il.cc` | kernel front-end impl | `Fragment` ops :819-859; `BuildGraph` :3152; `BuildGraphOfFunction` :3264; primitives :2315-2871; control flow :5819-5968; closures :6604 |
| `flow_graph_builder.cc` | AST parser front-end (parallel) | `BuildGraph` :4385; `EffectGraphVisitor::Append/Bind/Do` :645-682 |
| `intermediate_language.h` | the IL instructions | `Instruction` :663, `LinkTo` :747, `InstanceCallInstr` :2868, `StaticCallInstr` :3324 |
| `flow_graph.cc` | the `FlowGraph` container | ctor :26 (calls `DiscoverBlocks`) |
| `compiler.cc` | pipeline / handoff | `DartCompilationPipeline::BuildFlowGraph` :132; drive `ComputeSSA` etc. :779-810 |
| `parser.cc` | frame-slot allocation | `AllocateVariables` :308; `EnsureKernelScopes` :236 |

---

## See also

- [`dart-vm-compiler.md`](dart-vm-compiler.md) — what happens *after* you return the `FlowGraph`: SSA, the optimizer, register allocation, the ARM64 backend, and deopt.
- [`dart-vm-hosting-languages.md`](dart-vm-hosting-languages.md) — how to *register* a new language's classes/functions so the front-end you build here has something to compile, and which languages are worth it.
