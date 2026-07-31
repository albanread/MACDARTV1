// MACVM Smalltalk (.mst) IL builder — Sprint 3 of ST_PLAN.md. See the header.
//
// Structure mirrors runtime/vm/kernel_to_il.cc, reduced to the minimal contract
// from docs/dart-vm-frontend-guide.md §5:
//   A. the Fragment algebra (operator+= / operator<<= over Instruction::LinkTo),
//   B. the expression-stack discipline (Push/Pop/Drop over `stack_`),
//   C. the block factory + graph root (BuildTargetEntry + GraphEntryInstr +
//      normal_entry->LinkTo(body.entry) + new FlowGraph),
//   D. a handful of primitives (Constant/IntConstant/NullConstant, LoadLocal/
//      StoreLocal, PushArgument+GetArguments, InstanceCall, Return),
//   F. scope prep (LocalVariables + ParsedFunction::AllocateVariables).
//
// The five hard invariants (guide §5) are honored: the body Fragment is closed
// on every path; the expression stack is empty at every Return; GetArguments(n)
// finds exactly n PushArgumentInstrs; construction order is deterministic (deopt
// ids are pulled from the instruction ctors); block ids are unique.
//
// Supported expression subset (Sprint 3 milestone): integer / nil / true / false
// literals; variable refs (self, params, temps); assignment `id := expr`;
// unary/binary/keyword message sends -> InstanceCall; `^expr` -> Return; an
// implicit `^null` if the body falls off the end. Everything else routes to
// Unsupported() which reports and emits a null so the graph stays valid — blocks,
// cascades, control-flow messages, non-local return and instance allocation are
// Sprint 4/5.

#include "st_flow_graph_builder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "st_ast.h"
#include "st_loader.h"                // FindStClassByName (cross-load resolve)

#include "vm/ast.h"                   // SequenceNode
#include "vm/class_finalizer.h"       // FinalizeClass (AllocateObject layout)
#include "vm/flow_graph.h"            // FlowGraph
#include "vm/compiler.h"              // Compiler::kNoOSRDeoptId
#include "vm/flow_graph_builder.h"    // InlineExitCollector (ST inlining)
#include "vm/intermediate_language.h" // all the *Instr, Value, Definition
#include "vm/isolate.h"               // Isolate (closure-function table)
#include "vm/object.h"                // Function, Class, Type, Integer, Bool...
#include "vm/object_store.h"          // object_store()->closure_class()
#include "vm/os.h"                    // OS::PrintErr
#include "vm/parser.h"                // ParsedFunction
#include "vm/scopes.h"                // LocalScope, LocalVariable
#include "vm/symbols.h"               // Symbols
#include "vm/thread.h"                // Thread, Zone
#include "vm/token.h"                 // Token::Kind

namespace st {

using namespace dart;  // NOLINT — this TU is VM-internal, like st_loader.cc.

namespace {

// Universal-helper rewrites (one canonical list — used by BOTH the normal
// send path and cascades): Dart-receiver fast paths with ST-dispatch
// fallback inside each helper.
struct HelperRewrite { const char* sel; const char* helper; size_t argc; };
static const HelperRewrite kHelperRewrites[] = {
    {"at:", "stAt1", 1},        {"at:put:", "stAtPut1", 2},
    {"size", "stSizeOf", 0},    {"isEmpty", "stIsEmptyU", 0},
    {"not", "stNot", 0},        {"error:", "stError", 1},
    {"&", "stBoolAnd", 1},      {"|", "stBoolOr", 1},
    {"add:", "stAddU", 1},      {"do:", "stDo", 1},
    {"value", "stValue0", 0},   {"value:", "stValue1", 1},
    {"value:value:", "stValue2", 2},
    {"value:value:value:", "stValue3", 3},
    {"value:value:value:value:", "stValue4", 4},
    {"max:", "stMax", 1},       {"min:", "stMin", 1},
    {"asSymbol", "stAsSymbol", 0},
    {"printString", "stPrintOf", 0},
    {"displayString", "stDisplayOf", 0},
    {"asString", "stDisplayOf", 0},
    {"printOn:", "stPrintOn", 1},
    {"class", "stClassOf", 0},
    {"/", "stDivide", 1},
    // Smalltalk `//` and `\\` are FLOORED (toward -inf), and `\\` takes the
    // sign of the DIVISOR — Dart's `~/` (truncating) and `%` (Euclidean) are
    // both wrong for negatives, and Fraction had neither. Route through the
    // floored helpers; the corpus's dead <primitive:4/5> bodies never run.
    {"//", "stFloorDiv", 1},    {"\\\\", "stFloorMod", 1},
    // `shallowCopy` — the world's <primitive: 247> body fell through to
    // `^self`, so every `copy` (= shallowCopy postCopy) aliased its receiver.
    // Route to a real clone; the immutable overrides (Symbol/Boolean/nil/
    // Character = ^self) are honoured inside the helper.
    {"shallowCopy", "stShallowCopy", 0},
    {"asDouble", "stAsDouble", 0}, {"asFloat", "stAsDouble", 0},
    {"asInteger", "stTruncated", 0}, {"truncated", "stTruncated", 0},
    {"rounded", "stRounded", 0},   {"floor", "stFloorU", 0},
    {"ceiling", "stCeilingU", 0},  {"negated", "stNegated", 0},
    {"sqrt", "stSqrt", 0},
    // Without these the send falls through to the world's bare <primitive: N>
    // body, which compiles to nothing and returns SELF — `2 sin` answered 2.
    // st/test/primitive_coverage.dart pins all eight.
    {"ln", "stLn", 0},          {"exp", "stExp", 0},
    {"sin", "stSin", 0},        {"cos", "stCos", 0},
    {"tan", "stTan", 0},        {"atan", "stAtan", 0},
    // Smalltalk spellings of the arc functions (the corpus never declared
    // them, so `1.5 arcTan` was a raw DNU on a native double).
    {"arcTan", "stAtan", 0},    {"arcSin", "stArcSin", 0},
    {"arcCos", "stArcCos", 0},
    {"bitShift:", "stBitShift", 1},
    {"compare:", "stCompare", 1},
    // `k -> v` builds the Association here so a Symbol key stays a Symbol (the
    // Object>>-> method forwarded on a Symbol receiver, demoting #a to 'a').
    {"->", "stArrow", 1},
    // Round two of the same audit: each of these was a bare <primitive: N>
    // with no fast path, so it answered its receiver.
    {"instVarAt:", "stInstVarAt", 1},
    {"basicByteAt:", "stBasicByteAt", 1},
    {"valueWithArguments:", "stValueWithArgs", 1},
    {"printDigits", "stPrintDigits", 0},
    {"basicByteAt:put:", "stBasicBytePut", 2},
    {"halt", "stHalt", 0},
    {"perform:", "stPerform1", 1},
    {"perform:withArguments:", "stPerform2", 2},
    {"<", "stLess", 1},   {"<=", "stLessEq", 1},
    {">", "stGreater", 1}, {">=", "stGreaterEq", 1},
    {"copyFrom:to:", "stCopyFromTo", 2},
};
static const HelperRewrite* FindHelperRewrite(const std::string& sel,
                                              size_t argc) {
  for (size_t i = 0; i < sizeof(kHelperRewrites) / sizeof(kHelperRewrites[0]);
       i++) {
    if (sel == kHelperRewrites[i].sel && argc == kHelperRewrites[i].argc) {
      return &kHelperRewrites[i];
    }
  }
  return NULL;
}

// Parse an ST integer literal (`42`, `-7`, radix `16rFF`) to int64. Sprint 3
// small-integer scope; big-int promotion is left to Dart's own tower later.
int64_t ParseStInt(const std::string& text) {
  const size_t rpos = text.find('r');
  if (rpos != std::string::npos && rpos > 0 && rpos + 1 < text.size()) {
    // <radix>r<digits>, e.g. 16rFF. Reject a leading '-' inside the radix.
    bool radix_all_digits = true;
    for (size_t i = 0; i < rpos; i++) {
      if (text[i] < '0' || text[i] > '9') {
        radix_all_digits = false;
        break;
      }
    }
    if (radix_all_digits) {
      const int base = static_cast<int>(strtol(text.substr(0, rpos).c_str(),
                                               NULL, 10));
      if (base >= 2 && base <= 36) {
        return strtoll(text.c_str() + rpos + 1, NULL, base);
      }
    }
  }
  return strtoll(text.c_str(), NULL, 10);
}

// ---------------------------------------------------------------------------
// A. The Fragment algebra (guide §1.1-1.2) — a value type tracking the two ends
// of a straight-line (or terminated) piece of the instruction list. Identical
// semantics to dart::Fragment in kernel_to_il.h, kept in namespace st so this
// TU need not pull in the whole kernel builder.
// ---------------------------------------------------------------------------
class Fragment {
 public:
  Instruction* entry;
  Instruction* current;

  Fragment() : entry(NULL), current(NULL) {}
  explicit Fragment(Instruction* instruction)
      : entry(instruction), current(instruction) {}
  Fragment(Instruction* entry, Instruction* current)
      : entry(entry), current(current) {}

  bool is_open() { return entry == NULL || current != NULL; }
  bool is_closed() { return !is_open(); }

  Fragment& operator+=(const Fragment& other) {
    if (entry == NULL) {
      entry = other.entry;
      current = other.current;
    } else if (current != NULL && other.entry != NULL) {
      current->LinkTo(other.entry);
      current = other.current;
    }
    return *this;
  }

  Fragment& operator<<=(Instruction* next) {
    if (entry == NULL) {
      entry = current = next;
    } else if (current != NULL) {
      current->LinkTo(next);
      current = next;
    }
    return *this;
  }

  Fragment closed() {
    ASSERT(entry != NULL);
    return Fragment(entry, NULL);
  }
};

Fragment operator+(const Fragment& first, const Fragment& second) {
  Fragment result = first;
  result += second;
  return result;
}

typedef ZoneGrowableArray<PushArgumentInstr*>* ArgumentArray;

// ---------------------------------------------------------------------------
// The builder proper.
// ---------------------------------------------------------------------------
class StGraphBuilder {
 public:
  // Scope-only entry (var-descriptor path): recover the marker and populate
  // pf's node_sequence scope + AllocateVariables — the front of Build(), with
  // no graph. The stack-walker/GC/debugger recompute an unoptimized ST
  // method's LocalVarDescriptors through here, NOT the kernel ScopeBuilder.
  void PrepareScopesOnly() {
    Node* node = reinterpret_cast<Node*>(pf_->function().kernel_function());
    ASSERT(node != NULL);
    if (MethodNode* method = dynamic_cast<MethodNode*>(node)) {
      PrepareScope(method);
    } else if (BlockNode* block = dynamic_cast<BlockNode*>(node)) {
      PrepareClosureScope(block);
    }
  }

  StGraphBuilder(ParsedFunction* pf,
                 const ZoneGrowableArray<const ICData*>& ic_data_array,
                 intptr_t osr_id,
                 InlineExitCollector* exit_collector = NULL,
                 intptr_t first_block_id = 1)
      : pf_(pf),
        thread_(Thread::Current()),
        zone_(thread_->zone()),
        ic_data_array_(ic_data_array),
        osr_id_(osr_id),
        exit_collector_(exit_collector),
        next_block_id_(first_block_id),
        stack_(NULL),
        pending_argument_count_(0),
        graph_entry_(NULL),
        this_var_(NULL),
        value_temp_(NULL),
        synth_counter_(0),
        closure_var_(NULL),
        in_closure_(false),
        needs_nlr_(false),
        try_index_(CatchClauseNode::kInvalidTryIndex),
        exc_var_(NULL),
        stk_var_(NULL),
        saved_ctx_var_(NULL) {}

  FlowGraph* Build(MethodNode* method);
  FlowGraph* BuildClosure(BlockNode* block);  // Stage A: a closure body

 private:
  // --- expression stack (guide §1.3, §5.B) ---
  void SetTempIndex(Definition* definition) {
    definition->set_temp_index(
        stack_ == NULL ? 0 : stack_->definition()->temp_index() + 1);
  }
  void Push(Definition* definition) {
    SetTempIndex(definition);
    Value::AddToList(new (zone_) Value(definition), &stack_);
  }
  Value* Pop() {
    ASSERT(stack_ != NULL);
    Value* value = stack_;
    stack_ = value->next_use();
    if (stack_ != NULL) stack_->set_previous_use(NULL);
    value->set_next_use(NULL);
    value->set_previous_use(NULL);
    value->definition()->ClearSSATempIndex();
    return value;
  }
  Fragment Drop() {
    ASSERT(stack_ != NULL);
    Fragment instructions;
    Definition* definition = stack_->definition();
    if (definition->HasSSATemp() || definition->IsLoadLocal()) {
      instructions <<= new (zone_) DropTempsInstr(1, NULL);
    } else {
      definition->ClearTempIndex();
    }
    Pop();
    return instructions;
  }

  // --- block factory + ids (guide §5.C) ---
  intptr_t AllocateBlockId() { return next_block_id_++; }
  TargetEntryInstr* BuildTargetEntry() {
    return new (zone_) TargetEntryInstr(AllocateBlockId(), try_index_);
  }
  JoinEntryInstr* BuildJoinEntry() {
    return new (zone_) JoinEntryInstr(AllocateBlockId(), try_index_);
  }
  Fragment Goto(JoinEntryInstr* destination) {
    return Fragment(new (zone_) GotoInstr(destination)).closed();
  }
  // Branch on the boolean currently on top of the expression stack, comparing
  // it === Bool::True() (guide §2.5 / kernel BranchIfTrue).
  Fragment BranchIfTrue(TargetEntryInstr** then_entry,
                        TargetEntryInstr** otherwise_entry) {
    Fragment instructions = Constant(Bool::True());
    Value* right = Pop();  // the true constant
    Value* left = Pop();   // the condition value
    StrictCompareInstr* compare = new (zone_) StrictCompareInstr(
        TokenPosition::kNoSource, Token::kEQ_STRICT, left, right, false);
    BranchInstr* branch = new (zone_) BranchInstr(compare);
    *then_entry = *branch->true_successor_address() = BuildTargetEntry();
    *otherwise_entry = *branch->false_successor_address() = BuildTargetEntry();
    return instructions + Fragment(branch).closed();
  }
  // Branch on identity of the top two stack values (Stage C: the NLR home
  // test — carrier.home === my context).
  Fragment BranchIfStrictEqual(TargetEntryInstr** then_entry,
                               TargetEntryInstr** otherwise_entry) {
    Value* right = Pop();
    Value* left = Pop();
    StrictCompareInstr* compare = new (zone_) StrictCompareInstr(
        TokenPosition::kNoSource, Token::kEQ_STRICT, left, right, false);
    BranchInstr* branch = new (zone_) BranchInstr(compare);
    *then_entry = *branch->true_successor_address() = BuildTargetEntry();
    *otherwise_entry = *branch->false_successor_address() = BuildTargetEntry();
    return Fragment(branch).closed();
  }

  // --- primitives (guide §2, §5.D) ---
  Fragment Constant(const Object& value) {
    ASSERT(value.IsNotTemporaryScopedHandle());
    ConstantInstr* constant = new (zone_) ConstantInstr(value);
    Push(constant);
    return Fragment(constant);
  }
  Fragment IntConstant(int64_t value) {
    return Constant(Integer::ZoneHandle(zone_, Integer::New(value, Heap::kOld)));
  }
  Fragment NullConstant() {
    return Constant(Instance::ZoneHandle(zone_, Instance::null()));
  }
  Fragment LoadLocal(LocalVariable* variable) {
    if (variable->is_captured()) {
      // Stage B: a captured variable lives in the heap Context, not the frame.
      // Single-level capture: the context is current_context_var directly
      // (which is never itself captured, so the recursion terminates).
      Fragment instructions = LoadLocal(pf_->current_context_var());
      instructions += LoadField(Context::variable_offset(variable->index()));
      return instructions;
    }
    LoadLocalInstr* load =
        new (zone_) LoadLocalInstr(*variable, TokenPosition::kNoSource);
    Push(load);
    return Fragment(load);
  }
  Fragment StoreLocal(LocalVariable* variable) {
    if (variable->is_captured()) {
      // stack: [value] -> spill to value_temp_ (never captured), store into
      // the context, re-push the value (a store is an expression).
      Fragment instructions;
      instructions += StoreLocal(value_temp_);
      instructions += Drop();
      instructions += LoadLocal(pf_->current_context_var());
      instructions += LoadLocal(value_temp_);
      instructions +=
          StoreInstanceField(Context::variable_offset(variable->index()));
      instructions += LoadLocal(value_temp_);
      return instructions;
    }
    Value* value = Pop();
    StoreLocalInstr* store = new (zone_)
        StoreLocalInstr(*variable, value, TokenPosition::kNoSource);
    Push(store);
    return Fragment(store);
  }
  Fragment AllocateContext(intptr_t size) {
    AllocateContextInstr* allocate =
        new (zone_) AllocateContextInstr(TokenPosition::kNoSource, size);
    Push(allocate);
    return Fragment(allocate);
  }
  Fragment LoadField(intptr_t offset) {
    LoadFieldInstr* load = new (zone_) LoadFieldInstr(
        Pop(), offset, AbstractType::ZoneHandle(zone_),
        TokenPosition::kNoSource);
    Push(load);
    return Fragment(load);
  }
  Fragment StoreInstanceField(intptr_t offset) {
    Value* value = Pop();
    const StoreBarrierType barrier =
        value->BindsToConstant() ? kNoStoreBarrier : kEmitStoreBarrier;
    StoreInstanceFieldInstr* store = new (zone_) StoreInstanceFieldInstr(
        offset, Pop(), value, barrier, TokenPosition::kNoSource);
    return Fragment(store);  // a store produces no value (no Push)
  }
  // Sprint 11b: class variables. LoadStaticField consumes a pushed Field
  // CONSTANT (kernel_to_il.cc:2666 shape); StoreStaticField takes the Field
  // directly and pops the value (produces none). Fields are zone handles —
  // the instructions outlive this HANDLESCOPE.
  Fragment LoadStaticField(const Field& field) {
    Fragment instructions = Constant(field);
    LoadStaticFieldInstr* load =
        new (zone_) LoadStaticFieldInstr(Pop(), TokenPosition::kNoSource);
    Push(load);
    instructions += Fragment(load);
    return instructions;
  }
  Fragment StoreStaticField(const Field& field) {
    StoreStaticFieldInstr* store = new (zone_)
        StoreStaticFieldInstr(field, Pop(), TokenPosition::kNoSource);
    return Fragment(store);  // a store produces no value (no Push)
  }
  Fragment PushArgument() {
    PushArgumentInstr* argument = new (zone_) PushArgumentInstr(Pop());
    Push(argument);
    argument->set_temp_index(argument->temp_index() - 1);
    ++pending_argument_count_;
    return Fragment(argument);
  }
  ArgumentArray GetArguments(intptr_t count) {
    ArgumentArray arguments =
        new (zone_) ZoneGrowableArray<PushArgumentInstr*>(zone_, count);
    arguments->SetLength(count);
    for (intptr_t i = count - 1; i >= 0; --i) {
      ASSERT(stack_->definition()->IsPushArgument());
      ASSERT(!stack_->definition()->HasSSATemp());
      arguments->data()[i] = stack_->definition()->AsPushArgument();
      Drop();
    }
    pending_argument_count_ -= count;
    ASSERT(pending_argument_count_ >= 0);
    return arguments;
  }
  Fragment InstanceCall(const String& name,
                        Token::Kind kind,
                        intptr_t argument_count,
                        intptr_t num_args_checked) {
    ArgumentArray arguments = GetArguments(argument_count);
    const intptr_t kTypeArgsLen = 0;
    InstanceCallInstr* call = new (zone_)
        InstanceCallInstr(cur_pos_, name, kind, arguments,
                          kTypeArgsLen, Array::null_array(), num_args_checked,
                          ic_data_array_);
    Push(call);
    return Fragment(call);
  }
  Fragment StaticCall(const Function& target, intptr_t argument_count) {
    ArgumentArray arguments = GetArguments(argument_count);
    StaticCallInstr* call = new (zone_) StaticCallInstr(
        cur_pos_, target, /*type_args_len=*/0,
        Array::null_array(), arguments, ic_data_array_);
    Push(call);
    return Fragment(call);
  }
  Fragment AllocateObject(const Class& cls) {
    // The class needs an instance layout (member-finalized) before we allocate;
    // the on-demand finalize mirrors st_natives.cc.
    if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
    // The instruction outlives this HANDLESCOPE (it is read at codegen), so the
    // class must be a zone handle, not a temporary-scoped one.
    const Class& zcls = Class::ZoneHandle(zone_, cls.raw());
    ArgumentArray no_args = new (zone_) ZoneGrowableArray<PushArgumentInstr*>();
    AllocateObjectInstr* alloc = new (zone_)
        AllocateObjectInstr(TokenPosition::kNoSource, zcls, no_args);
    Push(alloc);
    return Fragment(alloc);
  }
  // A Dart getter access `x.name` (receiver already pushed as an argument):
  // the mangled getter name + Token::kGET, so we read the value rather than
  // call it. Used for ST unary sends that bridge to a dart:core getter.
  Fragment Getter(const std::string& dart_name) {
    ArgumentArray arguments = GetArguments(1);  // the receiver
    const String& gname = String::ZoneHandle(
        zone_, Field::GetterSymbol(
                   String::Handle(zone_, Symbols::New(thread_,
                                                      dart_name.c_str()))));
    InstanceCallInstr* call = new (zone_) InstanceCallInstr(
        TokenPosition::kNoSource, gname, Token::kGET, arguments,
        /*type_args_len=*/0, Array::null_array(), /*num_args_checked=*/1,
        ic_data_array_);
    Push(call);
    return Fragment(call);
  }
  Fragment CheckStackOverflow() {
    return Fragment(
        new (zone_) CheckStackOverflowInstr(cur_pos_, 0));
  }
  Fragment Return() {
    Value* value = Pop();
    ASSERT(stack_ == NULL);
    ReturnInstr* return_instr =
        new (zone_) ReturnInstr(cur_pos_, value);
    // Inlining: register every return with the exit collector so the inliner
    // can rewrite it into a goto to the continuation (identical to
    // kernel_to_il.cc's Return). NULL when compiling normally.
    if (exit_collector_ != NULL) exit_collector_->AddExit(return_instr);
    Fragment instructions;
    instructions <<= return_instr;
    return instructions.closed();
  }

  // --- scope prep (guide §3, §5.F) ---
  void PrepareScope(MethodNode* method);
  LocalVariable* LookupLocal(const std::string& name) {
    std::map<std::string, LocalVariable*>::iterator it = locals_.find(name);
    return (it == locals_.end()) ? NULL : it->second;
  }
  LocalVariable* MakeLocal(const std::string& name) {
    const String& sym =
        String::ZoneHandle(zone_, Symbols::New(thread_, name.c_str()));
    return new (zone_) LocalVariable(TokenPosition::kNoSource,
                                     TokenPosition::kNoSource, sym,
                                     Object::dynamic_type());
  }
  // Sprint 11b: resolve `name` as a CLASS VARIABLE — a static Field on the
  // owner's metaclass shadow (or an ancestor's; class vars are inherited).
  // Works from both metalevels: an instance method's owner is Foo (find its
  // shadow), a class-side method's owner IS the shadow.
  RawField* ClassVarField(const std::string& name) {
    const Class& owner = Class::Handle(zone_, pf_->function().Owner());
    if (owner.IsNull()) return Field::null();
    Class& inst = Class::Handle(zone_);
    Class& shadow = Class::Handle(zone_);
    MetaSplit(owner, inst, shadow);
    if (shadow.IsNull()) return Field::null();
    const String& sym =
        String::Handle(zone_, Symbols::New(thread_, name.c_str()));
    Field& field = Field::Handle(zone_);
    Class& c = Class::Handle(zone_, shadow.raw());
    while (!c.IsNull()) {
      field = c.LookupStaticField(sym);
      if (!field.IsNull()) return field.raw();
      c = c.SuperClass();
    }
    return Field::null();
  }

  // Sprint 11c: a GLOBAL — a static Field on the prelude's STGlobals holder,
  // CREATED on first compile-time reference (reads of an unassigned global
  // answer nil, the ST convention). Only capitalized names reach here.
  RawField* GlobalField(const std::string& name) {
    const Class& holder =
        Class::Handle(zone_, FindStClassByName(thread_, "STGlobals"));
    if (holder.IsNull()) return Field::null();
    // Member-finalize the holder (ClassFinalizer::FinalizeClass, NOT
    // EnsureIsFinalized — the latter routes to the Dart parser, which
    // crashes on a TokenStream-less ST class).
    if (!holder.is_finalized()) ClassFinalizer::FinalizeClass(holder);
    const String& sym =
        String::Handle(zone_, Symbols::New(thread_, name.c_str()));
    Field& field = Field::Handle(zone_, holder.LookupStaticField(sym));
    if (!field.IsNull()) return field.raw();
    // Append a fresh nil-valued static Field to the holder.
    const GrowableObjectArray& grow = GrowableObjectArray::Handle(
        zone_, GrowableObjectArray::New(Heap::kOld));
    const Array& old_fields = Array::Handle(zone_, holder.fields());
    Field& f = Field::Handle(zone_);
    for (intptr_t j = 0; j < old_fields.Length(); j++) {
      f ^= old_fields.At(j);
      grow.Add(f, Heap::kOld);
    }
    field = Field::New(sym, /*is_static=*/true, /*is_final=*/false,
                       /*is_const=*/false, /*is_reflectable=*/true, holder,
                       Object::dynamic_type(), TokenPosition::kNoSource);
    field.SetStaticValue(Object::null_instance(), /*save_initial=*/true);
    grow.Add(field, Heap::kOld);
    holder.SetFields(Array::Handle(zone_, Array::MakeArray(grow)));
    return field.raw();
  }

  // Byte offset of an instance variable of the receiver's class — INCLUDING
  // inherited ivars (Sprint 11: walk the super chain; finalization has laid
  // fields out hierarchy-wide, so each Field's Offset() is absolute). -1 if
  // `name` is not an ivar. The owner class is member-finalized before compile
  // (st_natives.cc ST_send / ST_new), so Field::Offset() is valid.
  intptr_t IvarOffset(const std::string& name) {
    const String& sym =
        String::Handle(zone_, Symbols::New(thread_, name.c_str()));
    Field& field = Field::Handle(zone_);
    Class& c = Class::Handle(zone_, pf_->function().Owner());
    while (!c.IsNull()) {
      field = c.LookupInstanceField(sym);
      if (!field.IsNull()) return field.Offset();
      c = c.SuperClass();
    }
    return -1;
  }

  // --- translation ---
  Fragment TranslateStatements(const std::vector<NodePtr>& statements);
  Fragment TranslateStatement(Node* node);
  Fragment TranslateExpression(Node* node);
  Fragment TranslateLiteral(LiteralNode* node);
  Fragment TranslateVariable(VariableNode* node);
  Fragment TranslateAssign(AssignNode* node);
  Fragment TranslateMessage(MessageNode* node);

  // Sprint 4: inlined control flow + cascades.
  bool IsInlinableControlFlow(MessageNode* node);
  Fragment TranslateControlFlow(MessageNode* node, bool value_context);
  Fragment TranslateCascade(CascadeNode* node);
  Fragment InlineBlockStmts(BlockNode* block);
  Fragment InlineBlockValue(BlockNode* block);
  Fragment ArmValue(BlockNode* block);
  Fragment StoreToValueTemp();
  void CollectLocals(Node* node, LocalScope* scope);
  void CollectLocalsInBlock(BlockNode* block, LocalScope* scope);
  void AddLocalName(const std::string& name, LocalScope* scope);
  LocalVariable* AllocSynth(Node* node, const char* prefix, LocalScope* scope);

  // Closures Stage A (non-capturing): a BlockNode in value position becomes a
  // first-class Closure; `value*` sends become InstanceCall("call").
  Fragment TranslateClosure(BlockNode* block);
  void PrepareClosureScope(BlockNode* block);
  static bool HasReturn(Node* node);

  // Closures Stage B (capture): method locals referenced under a closure are
  // marked captured (before AllocateVariables assigns their context slots).
  // (AllocateContext is defined inline with the other primitives above.)
  void MarkCapturedInClosures(Node* node);
  void MarkFreeNames(Node* node);

  // A block's own parameter/temp captured by a NESTED closure must live in the
  // shared method context, not the block's frame — else the inner closure
  // reads it as a "global" (null). This pass finds those names: `ancestor` =
  // names bound by enclosing value-position blocks (crossing one is a closure
  // boundary), `current` = names bound in the block frame being scanned;
  // a reference whose name is in `ancestor` is captured-across and hoisted.
  void CollectHoistedBlockParams(Node* node,
                                 const std::set<std::string>& ancestor,
                                 std::set<std::string> current,
                                 std::set<std::string>* out);
  // Copies (raw incoming block param -> its shared-context slot) done in the
  // closure prologue, for hoisted params. Filled by PrepareClosureScope.
  std::vector<std::pair<LocalVariable*, LocalVariable*> > block_param_copies_;

  // Stage C: resolve a dart:cocoa top-level helper (stNlrThrow/Home/Value).
  RawFunction* LookupCocoaFunction(const char* name);

  // Sprint 6: class-side sends (Foo new / a class method) + dart:core aliases.
  RawClass* ResolveClassName(const std::string& name);
  Fragment TranslateClassSend(const Class& cls, MessageNode* node);
  Fragment TranslateSuperSend(MessageNode* node);
  void MetaSplit(const Class& cls, Class& inst, Class& shadow);
  std::string DartSelector(const std::string& st_selector);
  std::string DartGetter(const std::string& st_selector);

  Token::Kind MethodKind(const String& name);
  Fragment Unsupported(Node* node, const char* what);

  ParsedFunction* pf_;
  Thread* thread_;
  Zone* zone_;
  const ZoneGrowableArray<const ICData*>& ic_data_array_;
  intptr_t osr_id_;
  InlineExitCollector* exit_collector_;  // non-NULL when inlining this callee
  TokenPosition cur_pos_ = TokenPosition::kNoSource;  // current stmt's source pos
  intptr_t next_block_id_;
  Value* stack_;
  intptr_t pending_argument_count_;
  GraphEntryInstr* graph_entry_;
  LocalVariable* this_var_;                       // NULL for a static method
  std::map<std::string, LocalVariable*> locals_;  // params + temps by name
  LocalVariable* value_temp_;                     // reusable control-flow value temp
  std::map<Node*, LocalVariable*> synth_;         // per-node synth temps (to:do: limit, cascade rcvr)
  std::map<Node*, LocalVariable*> synth2_;        // second per-node temp (timesRepeat: counter)
  intptr_t synth_counter_;                        // makes synth-temp names unique
  LocalVariable* closure_var_;                    // the :closure param (closure builds)
  std::vector<LocalVariable*> param_vars_;        // params in frame order (capture copy)
  // Stage C (non-local ^): a `^` under a first-class closure throws an _STNlr
  // carrier; the home method wraps its body in a catch keyed on its Context.
  bool in_closure_;                               // building a closure body?
  bool needs_nlr_;                                // method has a ^-carrying closure
  intptr_t try_index_;                            // try index for new blocks
  LocalVariable* exc_var_;                        // :exception (catch-defined)
  LocalVariable* stk_var_;                        // :stack_trace (catch-defined)
  LocalVariable* saved_ctx_var_;                  // :saved_try_context_var
};

void StGraphBuilder::PrepareScope(MethodNode* method) {
  const Function& function = pf_->function();

  LocalScope* scope = new (zone_) LocalScope(NULL, 0, 0);
  scope->set_begin_token_pos(function.token_pos());
  scope->set_end_token_pos(function.end_token_pos());

  // Every function has a current-context slot; force it to the stack (we never
  // capture in this subset) and add it before the parameters, mirroring
  // ScopeBuilder::BuildScopes (kernel_to_il.cc:323-325).
  LocalVariable* context_var = pf_->current_context_var();
  context_var->set_is_forced_stack();
  scope->AddVariable(context_var);

  // AllocateVariables reads node_sequence()->scope(); a SequenceNode wrapper is
  // all it needs.
  pf_->SetNodeSequence(new (zone_)
                           SequenceNode(TokenPosition::kNoSource, scope));

  intptr_t pos = 0;
  // Implicit parameter 0: the receiver for an instance method; the RECEIVING
  // CLASS for a class-side method (Sprint 11 — bound as an ordinary local
  // named `self`, so it is loadable, capturable, and dispatchable like any
  // other; this_var_ stays NULL to mark the class side).
  if (!function.is_static()) {
    LocalVariable* this_var = new (zone_)
        LocalVariable(TokenPosition::kNoSource, TokenPosition::kNoSource,
                      Symbols::This(), Object::dynamic_type());
    scope->InsertParameterAt(pos++, this_var);
    this_var_ = this_var;
    param_vars_.push_back(this_var);
  } else {
    LocalVariable* cls_var = MakeLocal("self");
    scope->InsertParameterAt(pos++, cls_var);
    locals_["self"] = cls_var;
    param_vars_.push_back(cls_var);
  }
  // One parameter LocalVariable per selector argument.
  for (size_t i = 0; i < method->args.size(); i++) {
    LocalVariable* v = MakeLocal(method->args[i]);
    scope->InsertParameterAt(pos++, v);
    locals_[method->args[i]] = v;
    param_vars_.push_back(v);
  }
  // One local LocalVariable per method temporary.
  for (size_t i = 0; i < method->temps.size(); i++) {
    LocalVariable* v = MakeLocal(method->temps[i]);
    scope->AddVariable(v);
    locals_[method->temps[i]] = v;
  }

  // Sprint 4: every INLINED block contributes its args/temps to the method
  // frame, and to:do:/cascades need synthetic temps. Hoist them all into the
  // scope BEFORE AllocateVariables (which assigns frame slots once).
  for (size_t i = 0; i < method->statements.size(); i++) {
    CollectLocals(method->statements[i].get(), scope);
  }
  // A block param/temp captured by a NESTED closure has to live in the shared
  // method context (a `[:s | coll do: [:e | s ...]]` — streamContents: — read
  // `s` as null otherwise). Give each such name a captured method-context slot
  // here; the owning block's prologue copies its incoming arg into it. (Skip a
  // name that is already a method local — a block param shadowing one is a rare
  // case left on the frame.)
  {
    std::set<std::string> hoist;
    for (size_t i = 0; i < method->statements.size(); i++) {
      CollectHoistedBlockParams(method->statements[i].get(),
                                std::set<std::string>(),
                                std::set<std::string>(), &hoist);
    }
    for (std::set<std::string>::iterator it = hoist.begin(); it != hoist.end();
         ++it) {
      if (locals_.count(*it)) continue;
      LocalVariable* v = MakeLocal(*it);
      v->set_is_captured();
      scope->AddVariable(v);
      locals_[*it] = v;
    }
  }
  // Stage B: mark every method local referenced under a CLOSURE block as
  // captured — BEFORE AllocateVariables, which then assigns those variables
  // context slots instead of frame slots. (value_temp_ is created after this
  // pass so it can never be captured.)
  for (size_t i = 0; i < method->statements.size(); i++) {
    MarkCapturedInClosures(method->statements[i].get());
  }
  // Stage C: a method containing a ^-carrying closure needs (a) a NON-NULL,
  // per-activation Context to serve as the NLR home token — the synthetic
  // captured ":home" guarantees one, and, living in locals_, it exports into
  // every closure's ContextScope so each closure restores the home context —
  // and (b) the three try/catch frame variables the catch machinery uses.
  if (needs_nlr_) {
    LocalVariable* home = MakeLocal(":home");
    home->set_is_captured();
    scope->AddVariable(home);
    locals_[":home"] = home;

    exc_var_ = MakeLocal(":exception");
    exc_var_->set_is_forced_stack();
    scope->AddVariable(exc_var_);
    stk_var_ = MakeLocal(":stack_trace");
    stk_var_->set_is_forced_stack();
    scope->AddVariable(stk_var_);
    saved_ctx_var_ = MakeLocal(":saved_try_context_var");
    saved_ctx_var_->set_is_forced_stack();
    scope->AddVariable(saved_ctx_var_);
  }
  // A single reusable temp to materialize control-flow expression values.
  value_temp_ = MakeLocal(":cfval");
  scope->AddVariable(value_temp_);

  // Assign frame slots (first_parameter_index_, first_stack_local_index_,
  // num_stack_locals_) — must happen before any LoadLocal.
  pf_->AllocateVariables();
}

Token::Kind StGraphBuilder::MethodKind(const String& name) {
  // Mirror FlowGraphBuilder::MethodKind (kernel_to_il.cc:3094) for the operators
  // the milestone needs; anything else is a plain (kILLEGAL) send.
  if (name.raw() == Symbols::Plus().raw()) return Token::kADD;
  if (name.raw() == Symbols::Minus().raw()) return Token::kSUB;
  if (name.raw() == Symbols::Star().raw()) return Token::kMUL;
  if (name.raw() == Symbols::Slash().raw()) return Token::kDIV;
  if (name.raw() == Symbols::Percent().raw()) return Token::kMOD;
  if (name.raw() == Symbols::BitOr().raw()) return Token::kBIT_OR;
  if (name.raw() == Symbols::Ampersand().raw()) return Token::kBIT_AND;
  if (name.raw() == Symbols::Caret().raw()) return Token::kBIT_XOR;
  if (name.raw() == Symbols::EqualOperator().raw()) return Token::kEQ;
  if (name.raw() == Symbols::LAngleBracket().raw()) return Token::kLT;
  if (name.raw() == Symbols::RAngleBracket().raw()) return Token::kGT;
  if (name.raw() == Symbols::LessEqualOperator().raw()) return Token::kLTE;
  if (name.raw() == Symbols::GreaterEqualOperator().raw()) return Token::kGTE;
  return Token::kILLEGAL;
}

Fragment StGraphBuilder::Unsupported(Node* node, const char* what) {
  OS::PrintErr("st::BuildGraph: unsupported %s at %d:%d (Sprint 4/5)\n", what,
               node->pos.line, node->pos.col);
  // Keep the graph valid + the stack balanced: an unsupported expression yields
  // null. (The Sprint 3 acceptance never reaches this path.)
  return NullConstant();
}

Fragment StGraphBuilder::TranslateExpression(Node* node) {
  if (LiteralNode* n = dynamic_cast<LiteralNode*>(node)) {
    return TranslateLiteral(n);
  }
  if (VariableNode* n = dynamic_cast<VariableNode*>(node)) {
    return TranslateVariable(n);
  }
  if (AssignNode* n = dynamic_cast<AssignNode*>(node)) {
    return TranslateAssign(n);
  }
  if (CascadeNode* n = dynamic_cast<CascadeNode*>(node)) {
    return TranslateCascade(n);
  }
  if (BlockNode* n = dynamic_cast<BlockNode*>(node)) {
    return TranslateClosure(n);  // a block in value position = a closure
  }
  if (MessageNode* n = dynamic_cast<MessageNode*>(node)) {
    if (IsInlinableControlFlow(n)) {
      return TranslateControlFlow(n, /*value_context=*/true);
    }
    return TranslateMessage(n);
  }
  if (DynArrayNode* n = dynamic_cast<DynArrayNode*>(node)) {
    // `{ e. e. e }` — same stack chain as a literal array, elements are
    // full expressions (Sprint 11c).
    const Function& new_list =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stNewList"));
    const Function& append =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stListAppend"));
    Fragment instructions = StaticCall(new_list, 0);
    for (size_t i = 0; i < n->elements.size(); i++) {
      instructions += PushArgument();
      instructions += TranslateExpression(n->elements[i].get());
      instructions += PushArgument();
      instructions += StaticCall(append, 2);
    }
    return instructions;
  }
  return Unsupported(node, "expression");
}

Fragment StGraphBuilder::TranslateLiteral(LiteralNode* node) {
  switch (node->kind) {
    case LiteralNode::Kind::kInt: {
      // Radix literals (`16rFF`) aren't decimal — parse straight to int64
      // (the corpus's radix literals are masks/colors, always < 2^32). Plain
      // decimals go through the VM's own Integer::New(String), which promotes
      // past int64 to Bigint instead of clamping — so `30 factorial`'s value
      // can be written as a literal (guide §5.D: honour Dart's integer tower).
      if (node->text.find('r') != std::string::npos) {
        return IntConstant(ParseStInt(node->text));
      }
      const String& s =
          String::Handle(zone_, String::New(node->text.c_str(), Heap::kOld));
      return Constant(Integer::ZoneHandle(zone_, Integer::New(s, Heap::kOld)));
    }
    case LiteralNode::Kind::kNil:
      return NullConstant();
    case LiteralNode::Kind::kTrue:
      return Constant(Bool::True());
    case LiteralNode::Kind::kFalse:
      return Constant(Bool::False());
    case LiteralNode::Kind::kString:
      return Constant(String::ZoneHandle(
          zone_, String::New(node->text.c_str(), Heap::kOld)));
    case LiteralNode::Kind::kFloat:
      return Constant(Double::ZoneHandle(
          zone_, Double::New(strtod(node->text.c_str(), NULL), Heap::kOld)));
    case LiteralNode::Kind::kSymbol: {
      // A Symbol is a DISTINCT interned class (StSymbol) — `String subclass:
      // Symbol` in the world, but Dart's String can't be subclassed, so it is
      // its own class that forwards String protocol and whose `=` is identity.
      // stSymbol(name) interns, so `#foo == #foo` holds by identity, and the
      // distinct class is what lets `=` tell a Symbol from a String.
      Fragment f = Constant(String::ZoneHandle(
          zone_, String::New(node->text.c_str(), Heap::kOld)));
      f += PushArgument();
      f += StaticCall(
          Function::ZoneHandle(zone_, LookupCocoaFunction("stSymbol")), 1);
      return f;
    }
    case LiteralNode::Kind::kChar: {
      // A Character is a DISTINCT flyweight class (not a 1-char string) — so
      // `$a == $a` holds (shared Latin-1 instance) and `$a = 'a'` is false.
      // stCharLit(glyph) answers the flyweight for the glyph's code point.
      Fragment f = Constant(String::ZoneHandle(
          zone_, String::New(node->text.c_str(), Heap::kOld)));
      f += PushArgument();
      f += StaticCall(
          Function::ZoneHandle(zone_, LookupCocoaFunction("stCharLit")), 1);
      return f;
    }
    case LiteralNode::Kind::kArray:
    case LiteralNode::Kind::kByteArray: {
      // Sprint 11c: `#(...)` / `#[...]` build a Dart List by a pure stack
      // chain — stNewList() then stListAppend(list, elem) per element (the
      // helper returns the list, so no temp is needed).
      const Function& new_list =
          Function::ZoneHandle(zone_, LookupCocoaFunction("stNewList"));
      const Function& append =
          Function::ZoneHandle(zone_, LookupCocoaFunction("stListAppend"));
      Fragment instructions = StaticCall(new_list, 0);
      for (size_t i = 0; i < node->elements.size(); i++) {
        instructions += PushArgument();  // the list so far
        LiteralNode* elem = dynamic_cast<LiteralNode*>(node->elements[i].get());
        if (elem != NULL) {
          instructions += TranslateLiteral(elem);
        } else {
          instructions += TranslateExpression(node->elements[i].get());
        }
        instructions += PushArgument();
        instructions += StaticCall(append, 2);
      }
      return instructions;
    }
    default:
      return Unsupported(node, "literal");
  }
}

Fragment StGraphBuilder::TranslateVariable(VariableNode* node) {
  if (node->name == "self" || node->name == "super") {
    if (this_var_ != NULL) return LoadLocal(this_var_);
    // Class-side (Sprint 11): `self` is the implicit thisCls parameter — an
    // ordinary local (capturable). Fall through to standard local resolution.
    if (node->name != "self" || locals_.count("self") == 0) {
      return Unsupported(node, "self/super here");
    }
  }
  LocalVariable* local = LookupLocal(node->name);
  if (local != NULL) return LoadLocal(local);
  // An instance variable of the receiver's class: self.<field>.
  if (this_var_ != NULL) {
    const intptr_t offset = IvarOffset(node->name);
    if (offset >= 0) {
      Fragment instructions = LoadLocal(this_var_);  // push self
      instructions += LoadField(offset);             // pop self, push the field
      return instructions;
    }
  }
  // Sprint 11b: a class variable (a static Field on the metaclass shadow),
  // visible from both metalevels. Checked BEFORE class-name resolution so a
  // classVar shadowing a class name follows Smalltalk scoping.
  {
    const Field& field = Field::ZoneHandle(zone_, ClassVarField(node->name));
    if (!field.IsNull()) return LoadStaticField(field);
  }
  // Sprint 9: a capitalized name resolving to an ST class is a CLASS VALUE —
  // its Type object — so classes flow as arguments (`[..] on: Error do: ..`).
  {
    const Class& cls = Class::Handle(zone_, ResolveClassName(node->name));
    if (!cls.IsNull()) {
      return Constant(
          Type::ZoneHandle(zone_, Type::NewNonParameterizedType(cls)));
    }
  }
  // Sprint 11c: a bridged core name in value position is its HOLDER's class
  // value (`aClass == Character`, `x isKindOf: Integer`).
  if (!node->name.empty() && node->name[0] >= 'A' && node->name[0] <= 'Z') {
    const Class& holder = Class::Handle(
        zone_, FindStClassByName(thread_, (node->name + " ext").c_str()));
    if (!holder.IsNull()) {
      return Constant(
          Type::ZoneHandle(zone_, Type::NewNonParameterizedType(holder)));
    }
  }
  // Sprint 11c: a capitalized non-class name is a GLOBAL (created nil).
  if (!node->name.empty() && node->name[0] >= 'A' && node->name[0] <= 'Z') {
    const Field& field = Field::ZoneHandle(zone_, GlobalField(node->name));
    if (!field.IsNull()) return LoadStaticField(field);
  }
  return Unsupported(node, "variable (global)");
}

Fragment StGraphBuilder::TranslateAssign(AssignNode* node) {
  LocalVariable* local = LookupLocal(node->name);
  if (local != NULL) {
    Fragment instructions = TranslateExpression(node->value.get());
    instructions += StoreLocal(local);  // pops value, leaves stored value
    return instructions;
  }
  // An instance variable: self.<field> := value, leaving the value on the stack
  // (an assignment is an expression). value_temp_ carries the value across the
  // StoreInstanceField (which pushes nothing).
  if (this_var_ != NULL) {
    const intptr_t offset = IvarOffset(node->name);
    if (offset >= 0) {
      Fragment instructions = TranslateExpression(node->value.get());  // value
      instructions += StoreLocal(value_temp_);   // value -> value_temp_
      instructions += Drop();
      instructions += LoadLocal(this_var_);      // push self
      instructions += LoadLocal(value_temp_);    // push value
      instructions += StoreInstanceField(offset);  // pop value, pop self
      instructions += LoadLocal(value_temp_);    // the assignment's value
      return instructions;
    }
  }
  // Sprint 11b: a class variable — store to the shadow's static Field,
  // leaving the value on the stack (assignment is an expression).
  {
    const Field& field = Field::ZoneHandle(zone_, ClassVarField(node->name));
    if (!field.IsNull()) {
      Fragment instructions = TranslateExpression(node->value.get());
      instructions += StoreLocal(value_temp_);
      instructions += Drop();
      instructions += LoadLocal(value_temp_);
      instructions += StoreStaticField(field);   // pops the value
      instructions += LoadLocal(value_temp_);    // the assignment's value
      return instructions;
    }
  }
  // Sprint 11c: a capitalized name is a GLOBAL (created on first store —
  // `Transcript := TranscriptStream new`, CharacterTable, ...).
  if (!node->name.empty() && node->name[0] >= 'A' && node->name[0] <= 'Z') {
    const Field& field = Field::ZoneHandle(zone_, GlobalField(node->name));
    if (!field.IsNull()) {
      Fragment instructions = TranslateExpression(node->value.get());
      instructions += StoreLocal(value_temp_);
      instructions += Drop();
      instructions += LoadLocal(value_temp_);
      instructions += StoreStaticField(field);
      instructions += LoadLocal(value_temp_);
      return instructions;
    }
  }
  return Unsupported(node, "assignment to non-local");
}

// Dart's native number types expose these as GETTERS (0-arg properties), not
// methods. An ST unary send of the same name to a NATIVE receiver (7 sign,
// 3.0 isNaN) would otherwise compile to a plain InstanceCall and be hijacked by
// Dart's getter-CALL semantics — `o.name()` resolves the getter then invokes
// the result, i.e. `(7.sign).call()`, which crashes ("int has no method call")
// and never reaches the ST method that should run (Number>>sign). The builder
// forces these through stSend, which does real ST dispatch for both native and
// ST receivers and never consults a Dart getter. Only names that are BOTH a
// dart:core getter AND a plausible ST selector need listing: `sign` is the one
// the corpus actually sends (14 sites), the rest are defensive against the same
// trap. (Found by the self-validating feature-test suite: `7 sign`.)
static bool IsCoreGetterCollision(const std::string& sel) {
  // num/double getters:
  if (sel == "sign" || sel == "isNaN" || sel == "isInfinite" ||
      sel == "isFinite" || sel == "isNegative" || sel == "bitLength") {
    return true;
  }
  // List / Iterable getters (a literal #(...) array is a Dart _List, so
  // `#(1 2 3) first` and the corpus's `SequenceableCollection>>reverse` — which
  // sends `reversed` — hit the same trap). size/isEmpty are NOT here: they are
  // already handled by the universal stSizeOf/stIsEmptyU helper rewrites.
  return sel == "first" || sel == "last" || sel == "single" ||
         sel == "reversed";
}

Fragment StGraphBuilder::TranslateMessage(MessageNode* node) {
  if (node->receiver == nullptr) {
    return Unsupported(node, "cascade message (no receiver)");
  }

  // `super sel: ..` — dispatch starts in the superclass, resolved now.
  if (VariableNode* sv = dynamic_cast<VariableNode*>(node->receiver.get())) {
    if (sv->name == "super" && this_var_ != NULL) {
      return TranslateSuperSend(node);
    }
  }

  // A send to a class NAME: `Foo new` allocates, `Foo x: .. y: ..` calls a
  // class-side (static) method. Only for an identifier that is not a local /
  // self and resolves to a loaded ST class.
  if (VariableNode* rv = dynamic_cast<VariableNode*>(node->receiver.get())) {
    if (rv->name != "self" && rv->name != "super" &&
        LookupLocal(rv->name) == NULL) {
      const Class& cls = Class::Handle(zone_, ResolveClassName(rv->name));
      if (!cls.IsNull()) return TranslateClassSend(cls, node);
      // Sprint 11b: BRIDGED class-name sends — sealed core classes that can't
      // be ST-registered. `String new: n` answers a mutable char buffer (a
      // Dart List — Dart strings are immutable; at:put:/size work through the
      // universal helpers); `Character value: c` answers a 1-char string.
      if (!rv->name.empty() && rv->name[0] >= 'A' && rv->name[0] <= 'Z' &&
          ClassVarField(rv->name) == Field::null()) {
        static const struct {
          const char* cls; const char* sel; const char* helper; size_t argc;
        } kBridgedClassSends[] = {
            {"String", "new:", "stStringNew", 1},
            {"String", "new", "stStringNew0", 0},
            {"String", "new:withAll:", "stStringNewWithAll", 2},
            {"ByteArray", "new:", "stNewByteArray", 1},
            {"Character", "value:", "stCharValue", 1},
            {"String", "with:", "stStringWith", 1},
            {"String", "lf", "stStrLf", 0},
            {"Character", "lf", "stStrLf", 0},
            {"Character", "tab", "stStrTab", 0},
            {"Character", "cr", "stStrCr", 0},
            {"Character", "space", "stStrSpace", 0},
        };
        for (size_t i = 0;
             i < sizeof(kBridgedClassSends) / sizeof(kBridgedClassSends[0]);
             i++) {
          if (rv->name != kBridgedClassSends[i].cls) continue;
          if (node->selector != kBridgedClassSends[i].sel) continue;
          if (node->args.size() != kBridgedClassSends[i].argc) continue;
          Fragment instructions;
          for (size_t a = 0; a < node->args.size(); a++) {
            instructions += TranslateExpression(node->args[a].get());
            instructions += PushArgument();
          }
          instructions += StaticCall(
              Function::ZoneHandle(
                  zone_, LookupCocoaFunction(kBridgedClassSends[i].helper)),
              static_cast<intptr_t>(node->args.size()));
          return instructions;
        }
        // Sprint 11c: the world kernel's class-side methods for a bridged
        // name live on its extension holder ("Character ext class" — e.g.
        // `Character initTable`). The bridge table above wins first, so the
        // prelude's working constructors are never shadowed by a holder's
        // <primitive:> stub.
        {
          const Class& holder = Class::Handle(
              zone_,
              FindStClassByName(thread_, (rv->name + " ext").c_str()));
          if (!holder.IsNull()) return TranslateClassSend(holder, node);
        }
      }
    }
  }

  // `x yourself` -> x (identity): just the receiver's value.
  if (node->selector == "yourself" && node->args.empty()) {
    return TranslateExpression(node->receiver.get());
  }

  // Sprint 9: the exception protocol lowers to dart:cocoa helpers over
  // closure calls (ST closures are Dart-callable): `[..] on: Cls do: [:e|..]`
  // -> stOnDo(protected, type, handler); ensure:/ifCurtailed: likewise. Since
  // stEnsure is a Dart try/finally, an ensure: block runs during NLR
  // unwinding — exact Smalltalk semantics.
  if ((node->selector == "on:do:" && node->args.size() == 2) ||
      ((node->selector == "ensure:" || node->selector == "ifCurtailed:") &&
       node->args.size() == 1)) {
    const char* helper = (node->selector == "on:do:")
                             ? "stOnDo"
                             : (node->selector == "ensure:") ? "stEnsure"
                                                             : "stIfCurtailed";
    const Function& fn =
        Function::ZoneHandle(zone_, LookupCocoaFunction(helper));
    Fragment instructions = TranslateExpression(node->receiver.get());
    instructions += PushArgument();
    for (size_t i = 0; i < node->args.size(); i++) {
      instructions += TranslateExpression(node->args[i].get());
      instructions += PushArgument();
    }
    instructions +=
        StaticCall(fn, 1 + static_cast<intptr_t>(node->args.size()));
    return instructions;
  }

  // Sprint 11 (corpus breadth): identity, logic, and universal-helper
  // rewrites. `==`/`~~` are Smalltalk IDENTITY — a StrictCompare, not a send.
  if ((node->selector == "==" || node->selector == "~~") &&
      node->args.size() == 1) {
    Fragment instructions = TranslateExpression(node->receiver.get());
    instructions += TranslateExpression(node->args[0].get());
    Value* right = Pop();
    Value* left = Pop();
    StrictCompareInstr* compare = new (zone_) StrictCompareInstr(
        TokenPosition::kNoSource,
        (node->selector == "==") ? Token::kEQ_STRICT : Token::kNE_STRICT,
        left, right, false);
    Push(compare);
    instructions += Fragment(compare);
    return instructions;
  }
  if (node->args.empty() &&
      (node->selector == "isNil" || node->selector == "notNil")) {
    Fragment instructions = TranslateExpression(node->receiver.get());
    instructions += NullConstant();
    Value* right = Pop();
    Value* left = Pop();
    StrictCompareInstr* compare = new (zone_) StrictCompareInstr(
        TokenPosition::kNoSource,
        (node->selector == "isNil") ? Token::kEQ_STRICT : Token::kNE_STRICT,
        left, right, false);
    Push(compare);
    instructions += Fragment(compare);
    return instructions;
  }
  // `=` value equality — the representation fix. Routes to stEquals, which
  // recovers class identity: numbers numeric, Symbol identity, String element,
  // real ST objects to their OWN `=` method (Fraction, user classes). `==`
  // stays a StrictCompare (identity) above; this is the value side.
  if (node->selector == "=" && node->args.size() == 1) {
    Fragment instructions = TranslateExpression(node->receiver.get());
    instructions += PushArgument();
    instructions += TranslateExpression(node->args[0].get());
    instructions += PushArgument();
    instructions += StaticCall(
        Function::ZoneHandle(zone_, LookupCocoaFunction("stEquals")), 2);
    return instructions;
  }
  if (node->selector == "~=" && node->args.size() == 1) {
    // a ~= b  ==  (a = b) not  — value inequality (was identity; now stEquals)
    Fragment instructions = TranslateExpression(node->receiver.get());
    instructions += PushArgument();
    instructions += TranslateExpression(node->args[0].get());
    instructions += PushArgument();
    instructions += StaticCall(
        Function::ZoneHandle(zone_, LookupCocoaFunction("stEquals")), 2);
    instructions += PushArgument();
    instructions += StaticCall(
        Function::ZoneHandle(zone_, LookupCocoaFunction("stNot")), 1);
    return instructions;
  }
  // `,` concatenation — routed through stConcat so a native mutable String
  // (or Symbol/Character) concatenates with a literal String without tripping
  // Dart's String.+ type check, and so Array,Array works too. String+String
  // stays the fast Dart `+` inside the helper.
  if (node->selector == "," && node->args.size() == 1) {
    Fragment instructions = TranslateExpression(node->receiver.get());
    instructions += PushArgument();
    instructions += TranslateExpression(node->args[0].get());
    instructions += PushArgument();
    instructions += StaticCall(
        Function::ZoneHandle(zone_, LookupCocoaFunction("stConcat")), 2);
    return instructions;
  }
  {
    const HelperRewrite* hr =
        FindHelperRewrite(node->selector, node->args.size());
    if (hr != NULL) {
      Fragment instructions = TranslateExpression(node->receiver.get());
      instructions += PushArgument();
      for (size_t a = 0; a < node->args.size(); a++) {
        instructions += TranslateExpression(node->args[a].get());
        instructions += PushArgument();
      }
      instructions += StaticCall(
          Function::ZoneHandle(zone_, LookupCocoaFunction(hr->helper)),
          1 + static_cast<intptr_t>(node->args.size()));
      return instructions;
    }
  }

  // Class-side `self <sel>` (Sprint 11): dispatch on the RECEIVING class held
  // in the implicit thisCls parameter — a runtime class-send (stClassSendN),
  // because the target depends on which class the original message named
  // (`IdleTask link:..` running TaskControlBlock's inherited constructor must
  // see self = IdleTask). Covers class-side closures too (this_var_ is NULL
  // there as well; `self` is the captured thisCls).
  if (VariableNode* sv = dynamic_cast<VariableNode*>(node->receiver.get())) {
    if (sv->name == "self" && this_var_ == NULL && locals_.count("self") &&
        node->args.size() <= 5) {
      // FAST PATH (perf): resolve the class-side method in the owner's
      // metaclass-shadow chain at compile time and emit a DIRECT StaticCall
      // (thisCls as arg 0) instead of the runtime stClassSend helper — a
      // native transition + shadow-chain walk + InvokeFunction per call.
      // Recursive class-side `self fib:` was ~480x MACVM before this. Correct
      // for inherited `self new` too: the resolved `new`'s body sees
      // self = thisCls (arg 0) and allocates the RECEIVING class. The one
      // divergence — a subclass overriding a class-side method that a
      // superclass self-sends still reaches the compile-time-resolved
      // (superclass) method — is a rare pattern, absent from the corpus.
      const String& msel = String::ZoneHandle(
          zone_,
          Symbols::New(thread_, ::st::MangleSelector(node->selector).c_str()));
      Function& fn = Function::ZoneHandle(zone_);
      {
        Class& c = Class::Handle(zone_, pf_->function().Owner());
        while (!c.IsNull()) {
          if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
          fn ^= c.LookupStaticFunction(msel);
          if (!fn.IsNull()) break;
          c ^= c.SuperClass();
        }
      }
      if (!fn.IsNull()) {
        Fragment instructions = LoadLocal(locals_["self"]);  // thisCls arg 0
        instructions += PushArgument();
        for (size_t i = 0; i < node->args.size(); i++) {
          instructions += TranslateExpression(node->args[i].get());
          instructions += PushArgument();
        }
        instructions +=
            StaticCall(fn, 1 + static_cast<intptr_t>(node->args.size()));
        return instructions;
      }
      // Unresolved `self new`/`self basicNew` (no user class-side override):
      // GUARDED INLINE ALLOCATION. The runtime thisCls is compared (one
      // StrictCompare — Types are canonical) against the compile-time owner's
      // instance class: equal — every call that NAMES the class, i.e. the hot
      // 99% — allocates inline with AllocateObject, no native transition;
      // different (an INHERITED factory: thisCls = a subclass) takes the
      // stBasicNew native, which allocates the receiving subclass correctly.
      if ((node->selector == "new" || node->selector == "basicNew") &&
          node->args.empty()) {
        const Class& shadow = Class::Handle(zone_, pf_->function().Owner());
        Class& inst_cls = Class::Handle(zone_);
        {
          const String& sn = String::Handle(zone_, shadow.Name());
          const char* sc = sn.ToCString();   // "Foo class" -> "Foo"
          size_t len = strlen(sc);
          if (len > 6 && strcmp(sc + len - 6, " class") == 0) {
            std::string base(sc, len - 6);
            inst_cls = FindStClassByName(thread_, base.c_str());
          }
        }
        if (!inst_cls.IsNull()) {
          if (!inst_cls.is_finalized()) {
            ClassFinalizer::FinalizeClass(inst_cls);
          }
          const Type& owner_type = Type::ZoneHandle(
              zone_, Type::NewNonParameterizedType(inst_cls));
          Fragment instructions = LoadLocal(locals_["self"]);  // thisCls
          instructions += Constant(owner_type);
          TargetEntryInstr* fast = NULL;
          TargetEntryInstr* slow = NULL;
          instructions += BranchIfStrictEqual(&fast, &slow);
          Fragment fast_f(fast);
          fast_f += AllocateObject(inst_cls);
          fast_f += StoreLocal(value_temp_);
          fast_f += Drop();
          Fragment slow_f(slow);
          // thisCls is a SUBCLASS (an inherited factory): dispatch the actual
          // `new`/`basicNew` so the subclass's override (with its init) runs —
          // stBasicNew here skipped it and left growable collections nil.
          slow_f += LoadLocal(locals_["self"]);
          slow_f += PushArgument();
          slow_f += Constant(String::ZoneHandle(
              zone_, Symbols::New(thread_, node->selector.c_str())));
          slow_f += PushArgument();
          slow_f += StaticCall(
              Function::ZoneHandle(zone_,
                                   LookupCocoaFunction("stClassNewDispatch")),
              2);
          slow_f += StoreLocal(value_temp_);
          slow_f += Drop();
          JoinEntryInstr* join = BuildJoinEntry();
          fast_f += Goto(join);
          slow_f += Goto(join);
          Fragment result(instructions.entry, join);
          result += LoadLocal(value_temp_);
          return result;
        }
        Fragment instructions = LoadLocal(locals_["self"]);  // thisCls
        instructions += PushArgument();
        instructions += Constant(String::ZoneHandle(
            zone_, Symbols::New(thread_, node->selector.c_str())));
        instructions += PushArgument();
        instructions += StaticCall(
            Function::ZoneHandle(zone_,
                                 LookupCocoaFunction("stClassNewDispatch")),
            2);
        return instructions;
      }
      // Other unresolved (signal desugars, class-side closures whose owner
      // isn't the shadow): the general runtime class-send handles it.
      char helper[16];
      snprintf(helper, sizeof(helper), "stClassSend%d",
               static_cast<int>(node->args.size()));
      Fragment instructions = TranslateExpression(node->receiver.get());
      instructions += PushArgument();
      instructions += Constant(String::ZoneHandle(
          zone_, Symbols::New(thread_, node->selector.c_str())));
      instructions += PushArgument();
      for (size_t i = 0; i < node->args.size(); i++) {
        instructions += TranslateExpression(node->args[i].get());
        instructions += PushArgument();
      }
      instructions += StaticCall(
          Function::ZoneHandle(zone_, LookupCocoaFunction(helper)),
          2 + static_cast<intptr_t>(node->args.size()));
      return instructions;
    }
  }

  // A unary send that bridges to a dart:core GETTER (`x hash` ->
  // `x.hashCode`): getters read a value, so they use the mangled name +
  // Token::kGET, not a method call (which would try to invoke the value).
  if (node->args.empty()) {
    const std::string getter = DartGetter(node->selector);
    if (!getter.empty()) {
      Fragment instructions = TranslateExpression(node->receiver.get());
      instructions += PushArgument();
      instructions += Getter(getter);
      return instructions;
    }
  }

  // A unary selector that collides with a dart:core GETTER (7 sign) must NOT
  // become a plain InstanceCall — on a native receiver Dart would resolve the
  // getter and getter-CALL its result. Route it through stSend(recv, sel, [])
  // so ST dispatch runs (Number>>sign) for native AND ST receivers alike.
  if (node->args.empty() && IsCoreGetterCollision(node->selector)) {
    Fragment instructions = TranslateExpression(node->receiver.get());
    instructions += PushArgument();
    instructions += Constant(String::ZoneHandle(
        zone_, Symbols::New(thread_, node->selector.c_str())));
    instructions += PushArgument();
    instructions += StaticCall(
        Function::ZoneHandle(zone_, LookupCocoaFunction("stNewList")), 0);
    instructions += PushArgument();
    instructions += StaticCall(
        Function::ZoneHandle(zone_, LookupCocoaFunction("stSendExt")), 3);
    return instructions;
  }

  Fragment instructions = TranslateExpression(node->receiver.get());
  instructions += PushArgument();
  for (size_t i = 0; i < node->args.size(); i++) {
    instructions += TranslateExpression(node->args[i].get());
    instructions += PushArgument();
  }
  // Translate the ST selector to its dart:core equivalent (printString ->
  // toString, = -> ==, ...) so a send reaches the bridged core method.
  const std::string dart_sel = DartSelector(node->selector);
  const String& selector =
      String::ZoneHandle(zone_, Symbols::New(thread_, dart_sel.c_str()));
  const Token::Kind kind = MethodKind(selector);
  const intptr_t argument_count = 1 + static_cast<intptr_t>(node->args.size());
  // Operators type-check every argument (guide §2.4); a plain send checks 1.
  const intptr_t num_args_checked =
      (kind != Token::kILLEGAL) ? argument_count : 1;
  instructions += InstanceCall(selector, kind, argument_count, num_args_checked);
  return instructions;
}

// A class name resolves to a loaded ST class in ANY st: library (the user's
// loads and the prelude — newest first). Capitalized identifiers only.
RawClass* StGraphBuilder::ResolveClassName(const std::string& name) {
  if (name.empty() || name[0] < 'A' || name[0] > 'Z') return Class::null();
  return FindStClassByName(thread_, name.c_str());
}

// Sprint 11: from either metalevel, find both sides — the instance class and
// its `Foo class` metaclass shadow. Either out-param may stay null (non-ST or
// pre-metaclass classes); callers fall back to the class they were handed.
void StGraphBuilder::MetaSplit(const Class& cls, Class& inst, Class& shadow) {
  const String& nm = String::Handle(zone_, cls.Name());
  const std::string n(nm.ToCString());
  static const char kSuffix[] = " class";
  const size_t klen = sizeof(kSuffix) - 1;
  if (n.size() > klen && n.compare(n.size() - klen, klen, kSuffix) == 0) {
    shadow = cls.raw();
    inst = FindStClassByName(thread_, n.substr(0, n.size() - klen).c_str());
  } else {
    inst = cls.raw();
    shadow = FindStClassByName(thread_, (n + kSuffix).c_str());
  }
}

// `Foo <sel>`: a class-side (static) method wins; otherwise `new`/`basicNew`
// allocates a fresh instance. (Class-side method names are NOT aliased —
// aliases are for dart:core sends, not user methods.)
Fragment StGraphBuilder::TranslateClassSend(const Class& cls,
                                            MessageNode* node) {
  const String& sel = String::Handle(
      zone_,
      Symbols::New(thread_, ::st::MangleSelector(node->selector).c_str()));
  // The metaclass split (Sprint 11): class-side methods live on the `Foo
  // class` shadow, whose super chain mirrors the instance chain (inherited
  // class-side conveniences work); instances allocate from Foo itself. We may
  // be handed either side — a source send hands us Foo, class-side `self`
  // hands us the shadow that owns the running static method.
  Class& inst_cls = Class::Handle(zone_);
  Class& shadow = Class::Handle(zone_);
  MetaSplit(cls, inst_cls, shadow);
  if (inst_cls.IsNull()) inst_cls = cls.raw();

  // Walk the metaclass chain for the method, member-finalizing each visited
  // class — a bare LookupStaticFunction would route through EnsureIsFinalized
  // -> the Dart parser, which crashes on a TokenStream-less ST class. Zone
  // handle: StaticCallInstr keeps the Function past this HANDLESCOPE.
  Function& fn = Function::ZoneHandle(zone_);
  {
    Class& c = Class::Handle(zone_, shadow.IsNull() ? cls.raw() : shadow.raw());
    while (!c.IsNull()) {
      if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
      fn ^= c.LookupStaticFunction(sel);
      if (!fn.IsNull()) break;
      c ^= c.SuperClass();
    }
  }
  if (!fn.IsNull()) {
    // Implicit arg 0 = the RECEIVING class (class-side `self` dispatches on
    // it — an inherited constructor must allocate the subclass it was sent
    // to, not its defining class).
    Fragment instructions = Constant(
        Type::ZoneHandle(zone_, Type::NewNonParameterizedType(inst_cls)));
    instructions += PushArgument();
    for (size_t i = 0; i < node->args.size(); i++) {
      instructions += TranslateExpression(node->args[i].get());
      instructions += PushArgument();
    }
    instructions +=
        StaticCall(fn, 1 + static_cast<intptr_t>(node->args.size()));
    return instructions;
  }
  if ((node->selector == "new" || node->selector == "basicNew") &&
      node->args.empty()) {
    return AllocateObject(inst_cls);
  }
  // Sprint 9: ANSI `Exception class >> signal[:]` — a class-side signal send
  // creates and signals: `Error signal: 'x'` == `Error new signal: 'x'`.
  // (Kept even with the metaclass tower: it works for every user-defined
  // exception subclass without each writing a class-side method.)
  if ((node->selector == "signal" && node->args.empty()) ||
      (node->selector == "signal:" && node->args.size() == 1)) {
    Fragment instructions = AllocateObject(inst_cls);
    instructions += PushArgument();
    for (size_t i = 0; i < node->args.size(); i++) {
      instructions += TranslateExpression(node->args[i].get());
      instructions += PushArgument();
    }
    const String& sel = String::ZoneHandle(
        zone_,
        Symbols::New(thread_, ::st::MangleSelector(node->selector).c_str()));
    const intptr_t argc = 1 + static_cast<intptr_t>(node->args.size());
    instructions += InstanceCall(sel, Token::kILLEGAL, argc, 1);
    return instructions;
  }
  // A universal-helper selector (printString -> stPrintOf, size -> stSizeOf,
  // ...) applies to a class VALUE too. The class-name routing reached here
  // BEFORE the instance-send HelperRewrite ran, so re-apply it now — otherwise
  // `Integer printString` misses stPrintOf and prints the holder name.
  if (const HelperRewrite* hr =
          FindHelperRewrite(node->selector, node->args.size())) {
    Fragment instructions = Constant(
        Type::ZoneHandle(zone_, Type::NewNonParameterizedType(inst_cls)));
    instructions += PushArgument();  // receiver = the class value
    for (size_t i = 0; i < node->args.size(); i++) {
      instructions += TranslateExpression(node->args[i].get());
      instructions += PushArgument();
    }
    instructions += StaticCall(
        Function::ZoneHandle(zone_, LookupCocoaFunction(hr->helper)),
        1 + static_cast<intptr_t>(node->args.size()));
    return instructions;
  }

  // No class-side (static) method, and not new/signal: the selector may be a
  // Behavior/Class INSTANCE method that a class object answers — `Integer name`,
  // `Integer superclass`. Fall back to a runtime send to the class VALUE (its
  // Type), which reaches those through the Type ext-holders (Behavior ext ->
  // ClassDescription ext -> ...) exactly as a runtime reflective send does. A
  // genuine miss now becomes an honest doesNotUnderstand instead of a silent nil.
  {
    const Function& send =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stSendExtOrNil"));
    const Function& new_list =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stNewList"));
    const Function& append =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stListAppend"));
    Fragment b;
    // Push the fixed args first (arg 0 = receiver, arg 1 = selector), THEN build
    // the list on top — GetArguments wants the call's args contiguous on the
    // stack, and each append consumes only its own last two.
    b += Constant(
        Type::ZoneHandle(zone_, Type::NewNonParameterizedType(inst_cls)));
    b += PushArgument();  // receiver = the class value    -> arg 0
    b += Constant(String::ZoneHandle(
        zone_, Symbols::New(thread_, node->selector.c_str())));
    b += PushArgument();  // selector (stSendExt mangles)  -> arg 1
    b += StaticCall(new_list, 0);  // the args list
    for (size_t i = 0; i < node->args.size(); i++) {
      b += PushArgument();  // list so far
      b += TranslateExpression(node->args[i].get());
      b += PushArgument();
      b += StaticCall(append, 2);  // -> list (grown)
    }
    b += PushArgument();  // the args list                 -> arg 2
    b += StaticCall(send, 3);
    return b;
  }
}

// `super sel: ..`: resolve the method starting in the OWNER's superclass and
// emit a StaticCall with self as argument 0 (an instance method's receiver).
// Walks the super chain (LookupDynamicFunction is per class), finalizing each
// visited class on demand.
Fragment StGraphBuilder::TranslateSuperSend(MessageNode* node) {
  const Class& owner = Class::Handle(zone_, pf_->function().Owner());
  const String& sel = String::Handle(
      zone_,
      Symbols::New(thread_, ::st::MangleSelector(node->selector).c_str()));
  Function& fn = Function::ZoneHandle(zone_);
  Class& c = Class::Handle(zone_, owner.SuperClass());
  while (!c.IsNull()) {
    if (!c.is_finalized()) ClassFinalizer::FinalizeClass(c);
    fn ^= c.LookupDynamicFunction(sel);
    if (!fn.IsNull()) break;
    c ^= c.SuperClass();
  }
  if (fn.IsNull()) return Unsupported(node, "super send (not found in supers)");
  Fragment instructions = LoadLocal(this_var_);  // receiver = self
  instructions += PushArgument();
  for (size_t i = 0; i < node->args.size(); i++) {
    instructions += TranslateExpression(node->args[i].get());
    instructions += PushArgument();
  }
  instructions += StaticCall(fn, 1 + static_cast<intptr_t>(node->args.size()));
  return instructions;
}

// ST selector -> dart:core selector, where they differ. Selectors that already
// match (+, -, <, abs, ...) pass through. The long tail is filled as needed.
std::string StGraphBuilder::DartSelector(const std::string& s) {
  // (Sprint 11b: the value* family no longer aliases to `call` here — it goes
  // through the stValueN universal helpers in the rewrite table, so an ST
  // class defining its own `value`/`value:` — DeltaBlue's Variable — works,
  // and closures still invoke on the inlined fast path.)
  if (s == "=") return "==";
  // (printString/displayString/asString route through stPrintOf/stDisplayOf
  // helpers — Sprint 11b — so ST-defined printOn: drives them.)
  if (s == ",") return "+";
  if (s == "bitAnd:") return "&";   // Dart int operator methods
  if (s == "bitOr:") return "|";
  if (s == "bitXor:") return "^";
  // (// and \\ route through the stFloorDiv/stFloorMod helper rewrites above —
  // they are FLOORED; the old ~/ and % mappings truncated and were wrong for
  // negatives. Left unmapped here so any stray path is a visible miss, not a
  // silently-wrong operator.)
  // Any remaining keyword selector targets an ST-defined method: use the
  // canonical mangled name the loader registered (':' -> '_').
  if (s.find(':') != std::string::npos) return ::st::MangleSelector(s);
  return s;
}

// ST unary selectors that bridge to a dart:core GETTER (not a method). Empty
// means "not a getter alias" — fall through to a normal send. (size/isEmpty
// moved to the UNIVERSAL helpers above so ST-defined receivers keep working.)
std::string StGraphBuilder::DartGetter(const std::string& s) {
  if (s == "hash") return "hashCode";
  return "";
}

// ---------------------------------------------------------------------------
// Sprint 4: inlined control flow + cascades. Blocks passed to the control-flow
// selectors are INLINED (their statements compiled in place), so `^` inside a
// conditional is a plain Return and no first-class closure is created. Real
// closures (value:/ClosureCall) remain a later sprint.
// ---------------------------------------------------------------------------

static bool IsBlockNode(Node* n) { return dynamic_cast<BlockNode*>(n) != NULL; }

void StGraphBuilder::AddLocalName(const std::string& name, LocalScope* scope) {
  if (name == "self" || name == "super") return;
  if (locals_.find(name) != locals_.end()) return;  // dedup: a shadow shares it
  LocalVariable* v = MakeLocal(name);
  scope->AddVariable(v);
  locals_[name] = v;
}

LocalVariable* StGraphBuilder::AllocSynth(Node* node, const char* prefix,
                                          LocalScope* scope) {
  char buf[32];
  snprintf(buf, sizeof(buf), ":%s%ld", prefix,
           static_cast<long>(synth_counter_++));
  LocalVariable* v = MakeLocal(buf);
  scope->AddVariable(v);
  synth_[node] = v;
  return v;
}

// Pre-pass: hoist every inlined-block local + allocate per-node synth temps so
// AllocateVariables (which runs once) gives them frame slots.
void StGraphBuilder::CollectLocals(Node* node, LocalScope* scope) {
  if (node == NULL) return;
  if (AssignNode* a = dynamic_cast<AssignNode*>(node)) {
    CollectLocals(a->value.get(), scope);
  } else if (ReturnNode* r = dynamic_cast<ReturnNode*>(node)) {
    CollectLocals(r->value.get(), scope);
  } else if (MessageNode* m = dynamic_cast<MessageNode*>(node)) {
    if (IsInlinableControlFlow(m)) {
      // Inlined control flow: its block operands compile IN this frame, so
      // their args/temps hoist here. Non-block operands recurse normally.
      if (m->receiver != nullptr) {
        if (BlockNode* rb = dynamic_cast<BlockNode*>(m->receiver.get())) {
          CollectLocalsInBlock(rb, scope);
        } else {
          CollectLocals(m->receiver.get(), scope);
        }
      }
      for (size_t i = 0; i < m->args.size(); i++) {
        if (BlockNode* ab = dynamic_cast<BlockNode*>(m->args[i].get())) {
          CollectLocalsInBlock(ab, scope);
        } else {
          CollectLocals(m->args[i].get(), scope);
        }
      }
      if (m->selector == "to:do:" && m->args.size() == 2 &&
          IsBlockNode(m->args[1].get())) {
        AllocSynth(m, "lim", scope);
      }
      if (m->selector == "timesRepeat:" && m->args.size() == 1 &&
          IsBlockNode(m->args[0].get())) {
        AllocSynth(m, "lim", scope);            // the count      -> synth_
        char buf[32];
        snprintf(buf, sizeof(buf), ":i%ld", static_cast<long>(synth_counter_++));
        LocalVariable* i = MakeLocal(buf);      // the counter    -> synth2_
        scope->AddVariable(i);
        synth2_[m] = i;
      }
      if (m->selector == "ifNil:" || m->selector == "ifNotNil:" ||
          m->selector == "ifNil:ifNotNil:" || m->selector == "ifNotNil:ifNil:") {
        AllocSynth(m, "rcv", scope);            // receiver, once -> synth_
      }
    } else {
      CollectLocals(m->receiver.get(), scope);
      for (size_t i = 0; i < m->args.size(); i++) {
        CollectLocals(m->args[i].get(), scope);
      }
    }
  } else if (BlockNode* b = dynamic_cast<BlockNode*>(node)) {
    // A block in VALUE position (not a control-flow operand) is a first-class
    // CLOSURE: its args/temps belong to the closure function's own frame, not
    // this one. All this frame needs is a temp to hold the allocated closure
    // while its fields are stored (TranslateClosure).
    if (!synth_.count(b)) AllocSynth(b, "clos", scope);
  } else if (CascadeNode* c = dynamic_cast<CascadeNode*>(node)) {
    CollectLocals(c->receiver.get(), scope);
    for (size_t i = 0; i < c->messages.size(); i++) {
      CollectLocals(c->messages[i].get(), scope);
    }
    AllocSynth(c, "casc", scope);
  } else if (DynArrayNode* d = dynamic_cast<DynArrayNode*>(node)) {
    for (size_t i = 0; i < d->elements.size(); i++) {
      CollectLocals(d->elements[i].get(), scope);
    }
  }
}

// An INLINED block's args/temps hoist into the enclosing frame; recurse into
// its statements (where nested closures/synths may appear).
void StGraphBuilder::CollectLocalsInBlock(BlockNode* block, LocalScope* scope) {
  for (size_t i = 0; i < block->args.size(); i++) {
    AddLocalName(block->args[i], scope);
  }
  for (size_t i = 0; i < block->temps.size(); i++) {
    AddLocalName(block->temps[i], scope);
  }
  for (size_t i = 0; i < block->statements.size(); i++) {
    CollectLocals(block->statements[i].get(), scope);
  }
}

// Does this subtree contain a `^` return? Used to reject non-local `^` inside
// a first-class closure (Stage C) — over-approximating into nested blocks is
// deliberate: any `^` under a closure is a non-local return from the home.
bool StGraphBuilder::HasReturn(Node* node) {
  if (node == NULL) return false;
  if (dynamic_cast<ReturnNode*>(node) != NULL) return true;
  if (AssignNode* a = dynamic_cast<AssignNode*>(node)) {
    return HasReturn(a->value.get());
  }
  if (MessageNode* m = dynamic_cast<MessageNode*>(node)) {
    if (HasReturn(m->receiver.get())) return true;
    for (size_t i = 0; i < m->args.size(); i++) {
      if (HasReturn(m->args[i].get())) return true;
    }
    return false;
  }
  if (BlockNode* b = dynamic_cast<BlockNode*>(node)) {
    for (size_t i = 0; i < b->statements.size(); i++) {
      if (HasReturn(b->statements[i].get())) return true;
    }
    return false;
  }
  if (CascadeNode* c = dynamic_cast<CascadeNode*>(node)) {
    if (HasReturn(c->receiver.get())) return true;
    for (size_t i = 0; i < c->messages.size(); i++) {
      if (HasReturn(c->messages[i].get())) return true;
    }
    return false;
  }
  if (DynArrayNode* d = dynamic_cast<DynArrayNode*>(node)) {
    for (size_t i = 0; i < d->elements.size(); i++) {
      if (HasReturn(d->elements[i].get())) return true;
    }
    return false;
  }
  return false;
}

// Stage B capture analysis: walk the method body; INLINED control-flow blocks
// are part of this frame (recurse through them), while any other BlockNode is
// a closure — every name referenced under it captures the matching method
// local. Over-approximation (shadowed names, nested blocks) is deliberate: a
// needlessly-captured variable still behaves correctly, just via the context.
void StGraphBuilder::MarkCapturedInClosures(Node* node) {
  if (node == NULL) return;
  if (AssignNode* a = dynamic_cast<AssignNode*>(node)) {
    MarkCapturedInClosures(a->value.get());
  } else if (ReturnNode* r = dynamic_cast<ReturnNode*>(node)) {
    MarkCapturedInClosures(r->value.get());
  } else if (MessageNode* m = dynamic_cast<MessageNode*>(node)) {
    if (IsInlinableControlFlow(m)) {
      if (m->receiver != nullptr) {
        if (BlockNode* rb = dynamic_cast<BlockNode*>(m->receiver.get())) {
          for (size_t i = 0; i < rb->statements.size(); i++) {
            MarkCapturedInClosures(rb->statements[i].get());
          }
        } else {
          MarkCapturedInClosures(m->receiver.get());
        }
      }
      for (size_t i = 0; i < m->args.size(); i++) {
        if (BlockNode* ab = dynamic_cast<BlockNode*>(m->args[i].get())) {
          for (size_t j = 0; j < ab->statements.size(); j++) {
            MarkCapturedInClosures(ab->statements[j].get());
          }
        } else {
          MarkCapturedInClosures(m->args[i].get());
        }
      }
    } else {
      MarkCapturedInClosures(m->receiver.get());
      for (size_t i = 0; i < m->args.size(); i++) {
        MarkCapturedInClosures(m->args[i].get());
      }
    }
  } else if (BlockNode* b = dynamic_cast<BlockNode*>(node)) {
    // A closure: everything referenced beneath it captures; a `^` beneath it
    // (any depth) is a non-local return, so the method needs the NLR catch.
    if (HasReturn(b)) needs_nlr_ = true;
    for (size_t i = 0; i < b->statements.size(); i++) {
      MarkFreeNames(b->statements[i].get());
    }
  } else if (CascadeNode* c = dynamic_cast<CascadeNode*>(node)) {
    MarkCapturedInClosures(c->receiver.get());
    for (size_t i = 0; i < c->messages.size(); i++) {
      MarkCapturedInClosures(c->messages[i].get());
    }
  } else if (DynArrayNode* d = dynamic_cast<DynArrayNode*>(node)) {
    for (size_t i = 0; i < d->elements.size(); i++) {
      MarkCapturedInClosures(d->elements[i].get());
    }
  }
}

// Stage C: resolve a top-level dart:cocoa helper by name (the NLR carrier
// functions live there — ordinary Dart, so the optimizer may even inline them
// into the ST caller).
RawFunction* StGraphBuilder::LookupCocoaFunction(const char* name) {
  // kOld: this can run on the BACKGROUND compiler thread (an optimized
  // recompile), which must not allocate in new space.
  const Library& lib = Library::Handle(
      zone_, Library::LookupLibrary(
                 thread_,
                 String::Handle(zone_, String::New("dart:cocoa", Heap::kOld))));
  if (lib.IsNull()) return Function::null();
  return lib.LookupFunctionAllowPrivate(
      String::Handle(zone_, Symbols::New(thread_, name)));
}

// Under a closure: mark every referenced name that is a method local (or self)
// as captured. Recurses through everything, including nested blocks.
void StGraphBuilder::MarkFreeNames(Node* node) {
  if (node == NULL) return;
  if (VariableNode* v = dynamic_cast<VariableNode*>(node)) {
    if (v->name == "self" || v->name == "super") {
      if (this_var_ != NULL) {
        this_var_->set_is_captured();
      } else {
        // Class-side (Sprint 11b): `self` is the thisCls LOCAL — capture it
        // like any other local so class-side closures can send to self.
        std::map<std::string, LocalVariable*>::iterator it =
            locals_.find("self");
        if (it != locals_.end()) it->second->set_is_captured();
      }
    } else {
      std::map<std::string, LocalVariable*>::iterator it =
          locals_.find(v->name);
      if (it != locals_.end()) {
        it->second->set_is_captured();
      } else if (this_var_ != NULL && IvarOffset(v->name) >= 0) {
        // Referencing an INSTANCE VARIABLE under a closure captures self.
        this_var_->set_is_captured();
      }
    }
  } else if (AssignNode* a = dynamic_cast<AssignNode*>(node)) {
    std::map<std::string, LocalVariable*>::iterator it =
        locals_.find(a->name);
    if (it != locals_.end()) {
      it->second->set_is_captured();
    } else if (this_var_ != NULL && IvarOffset(a->name) >= 0) {
      this_var_->set_is_captured();  // ivar write under a closure needs self
    }
    MarkFreeNames(a->value.get());
  } else if (ReturnNode* r = dynamic_cast<ReturnNode*>(node)) {
    MarkFreeNames(r->value.get());
  } else if (MessageNode* m = dynamic_cast<MessageNode*>(node)) {
    MarkFreeNames(m->receiver.get());
    for (size_t i = 0; i < m->args.size(); i++) {
      MarkFreeNames(m->args[i].get());
    }
  } else if (BlockNode* b = dynamic_cast<BlockNode*>(node)) {
    for (size_t i = 0; i < b->statements.size(); i++) {
      MarkFreeNames(b->statements[i].get());
    }
  } else if (CascadeNode* c = dynamic_cast<CascadeNode*>(node)) {
    MarkFreeNames(c->receiver.get());
    for (size_t i = 0; i < c->messages.size(); i++) {
      MarkFreeNames(c->messages[i].get());
    }
  } else if (DynArrayNode* d = dynamic_cast<DynArrayNode*>(node)) {
    for (size_t i = 0; i < d->elements.size(); i++) {
      MarkFreeNames(d->elements[i].get());
    }
  }
}

// Find block params/temps captured across a closure boundary (see the header
// note). An INLINED control-flow block shares the current frame, so its
// params add to `current`; a VALUE-position block is a real closure, so
// entering it makes today's `current` part of the next frame's `ancestor`.
void StGraphBuilder::CollectHoistedBlockParams(
    Node* node, const std::set<std::string>& ancestor,
    std::set<std::string> current, std::set<std::string>* out) {
  if (node == NULL) return;
  if (VariableNode* v = dynamic_cast<VariableNode*>(node)) {
    if (ancestor.count(v->name)) out->insert(v->name);
  } else if (AssignNode* a = dynamic_cast<AssignNode*>(node)) {
    if (ancestor.count(a->name)) out->insert(a->name);
    CollectHoistedBlockParams(a->value.get(), ancestor, current, out);
  } else if (ReturnNode* r = dynamic_cast<ReturnNode*>(node)) {
    CollectHoistedBlockParams(r->value.get(), ancestor, current, out);
  } else if (MessageNode* m = dynamic_cast<MessageNode*>(node)) {
    if (IsInlinableControlFlow(m)) {
      // Operand blocks share THIS frame — their params extend `current`.
      Node* parts[1 + 8];
      size_t np = 0;
      parts[np++] = m->receiver.get();
      for (size_t i = 0; i < m->args.size() && np < 9; i++)
        parts[np++] = m->args[i].get();
      for (size_t i = 0; i < np; i++) {
        if (BlockNode* b = dynamic_cast<BlockNode*>(parts[i])) {
          std::set<std::string> cur2 = current;
          for (size_t k = 0; k < b->args.size(); k++) cur2.insert(b->args[k]);
          for (size_t k = 0; k < b->temps.size(); k++) cur2.insert(b->temps[k]);
          for (size_t s = 0; s < b->statements.size(); s++)
            CollectHoistedBlockParams(b->statements[s].get(), ancestor, cur2,
                                      out);
        } else {
          CollectHoistedBlockParams(parts[i], ancestor, current, out);
        }
      }
    } else {
      CollectHoistedBlockParams(m->receiver.get(), ancestor, current, out);
      for (size_t i = 0; i < m->args.size(); i++)
        CollectHoistedBlockParams(m->args[i].get(), ancestor, current, out);
    }
  } else if (BlockNode* b = dynamic_cast<BlockNode*>(node)) {
    // A real closure: everything `current` holds is now an ancestor for it.
    std::set<std::string> anc2 = ancestor;
    anc2.insert(current.begin(), current.end());
    std::set<std::string> cur2;
    for (size_t k = 0; k < b->args.size(); k++) cur2.insert(b->args[k]);
    for (size_t k = 0; k < b->temps.size(); k++) cur2.insert(b->temps[k]);
    for (size_t s = 0; s < b->statements.size(); s++)
      CollectHoistedBlockParams(b->statements[s].get(), anc2, cur2, out);
  } else if (CascadeNode* c = dynamic_cast<CascadeNode*>(node)) {
    CollectHoistedBlockParams(c->receiver.get(), ancestor, current, out);
    for (size_t i = 0; i < c->messages.size(); i++)
      CollectHoistedBlockParams(c->messages[i].get(), ancestor, current, out);
  } else if (DynArrayNode* d = dynamic_cast<DynArrayNode*>(node)) {
    for (size_t i = 0; i < d->elements.size(); i++)
      CollectHoistedBlockParams(d->elements[i].get(), ancestor, current, out);
  }
}

bool StGraphBuilder::IsInlinableControlFlow(MessageNode* node) {
  const std::string& s = node->selector;
  if (s == "ifTrue:" || s == "ifFalse:" || s == "and:" || s == "or:") {
    return node->args.size() == 1 && IsBlockNode(node->args[0].get());
  }
  if (s == "ifTrue:ifFalse:" || s == "ifFalse:ifTrue:") {
    return node->args.size() == 2 && IsBlockNode(node->args[0].get()) &&
           IsBlockNode(node->args[1].get());
  }
  // The nil-test family is inlined like ifTrue: — a `receiver === nil` branch —
  // so a LITERAL nil receiver works (a message to Dart null otherwise throws a
  // raw NoSuchMethod that bypasses the ST NSM hook). Block-literal args only.
  if (s == "ifNil:" || s == "ifNotNil:") {
    return node->args.size() == 1 && IsBlockNode(node->args[0].get());
  }
  if (s == "ifNil:ifNotNil:" || s == "ifNotNil:ifNil:") {
    return node->args.size() == 2 && IsBlockNode(node->args[0].get()) &&
           IsBlockNode(node->args[1].get());
  }
  if (s == "whileTrue:" || s == "whileFalse:") {
    return IsBlockNode(node->receiver.get()) && node->args.size() == 1 &&
           IsBlockNode(node->args[0].get());
  }
  if (s == "to:do:") {
    return node->args.size() == 2 && IsBlockNode(node->args[1].get());
  }
  if (s == "timesRepeat:") {
    return node->args.size() == 1 && IsBlockNode(node->args[0].get());
  }
  return false;
}

// Inline a block as a statement sequence (its value discarded).
Fragment StGraphBuilder::InlineBlockStmts(BlockNode* block) {
  return TranslateStatements(block->statements);
}

// Inline a block so its LAST statement's value is left on the stack.
Fragment StGraphBuilder::InlineBlockValue(BlockNode* block) {
  if (block->statements.empty()) return NullConstant();
  Fragment instructions;
  for (size_t i = 0; i < block->statements.size(); i++) {
    if (instructions.is_closed()) return instructions;  // dead code after ^
    Node* stmt = block->statements[i].get();
    const bool last = (i + 1 == block->statements.size());
    if (last && dynamic_cast<ReturnNode*>(stmt) == NULL) {
      instructions += TranslateExpression(stmt);  // leave the value
    } else {
      instructions += TranslateStatement(stmt);   // effect, or a closing ^
      if (last && instructions.is_open()) {
        // Stage C: a last-position `^` inside a closure THROWS (open, dead
        // fall-through) rather than closing — supply the dead value.
        instructions += NullConstant();
      }
    }
  }
  return instructions;
}

// Pop the value on top and stash it in value_temp_ (leaving the stack empty).
Fragment StGraphBuilder::StoreToValueTemp() {
  Fragment instructions;
  instructions += StoreLocal(value_temp_);  // pops value, pushes stored value...
  instructions += Drop();                   // ...which we discard
  return instructions;
}

// An if/and/or arm producing a value: the block's value (or nil for a missing
// arm) materialized into value_temp_. A block that closed with `^` stores
// nothing (that path returned from the method).
Fragment StGraphBuilder::ArmValue(BlockNode* block) {
  Fragment instructions =
      (block != NULL) ? InlineBlockValue(block) : NullConstant();
  if (instructions.is_open()) instructions += StoreToValueTemp();
  return instructions;
}

Fragment StGraphBuilder::TranslateControlFlow(MessageNode* node,
                                              bool value_context) {
  const std::string& s = node->selector;

  // --- if variants ------------------------------------------------------
  if (s == "ifTrue:" || s == "ifFalse:" || s == "ifTrue:ifFalse:" ||
      s == "ifFalse:ifTrue:") {
    BlockNode* then_block = NULL;
    BlockNode* else_block = NULL;
    if (s == "ifTrue:") {
      then_block = dynamic_cast<BlockNode*>(node->args[0].get());
    } else if (s == "ifFalse:") {
      else_block = dynamic_cast<BlockNode*>(node->args[0].get());
    } else if (s == "ifTrue:ifFalse:") {
      then_block = dynamic_cast<BlockNode*>(node->args[0].get());
      else_block = dynamic_cast<BlockNode*>(node->args[1].get());
    } else {  // ifFalse:ifTrue:
      else_block = dynamic_cast<BlockNode*>(node->args[0].get());
      then_block = dynamic_cast<BlockNode*>(node->args[1].get());
    }

    Fragment instructions = TranslateExpression(node->receiver.get());
    TargetEntryInstr* then_entry;
    TargetEntryInstr* otherwise_entry;
    instructions += BranchIfTrue(&then_entry, &otherwise_entry);

    Fragment then_fragment(then_entry);
    Fragment otherwise_fragment(otherwise_entry);
    if (value_context) {
      then_fragment += ArmValue(then_block);
      otherwise_fragment += ArmValue(else_block);
    } else {
      if (then_block != NULL) then_fragment += InlineBlockStmts(then_block);
      if (else_block != NULL) otherwise_fragment += InlineBlockStmts(else_block);
    }

    Fragment result;
    if (then_fragment.is_open() && otherwise_fragment.is_open()) {
      JoinEntryInstr* join = BuildJoinEntry();
      then_fragment += Goto(join);
      otherwise_fragment += Goto(join);
      result = Fragment(instructions.entry, join);
    } else if (then_fragment.is_open()) {
      result = Fragment(instructions.entry, then_fragment.current);
    } else if (otherwise_fragment.is_open()) {
      result = Fragment(instructions.entry, otherwise_fragment.current);
    } else {
      result = instructions.closed();
    }
    if (value_context && result.is_open()) result += LoadLocal(value_temp_);
    return result;
  }

  // --- ifNil: family (a `receiver === nil` branch, inlined) -------------
  // Real Smalltalks compile these; we must too, because a message sent to Dart
  // `null` throws a raw NoSuchMethod that never reaches the ST NSM hook. The
  // receiver is evaluated ONCE into a temp (side effects; reused as the value
  // and as a 1-arg ifNotNil: block's argument). Value rules: nil receiver ->
  // the nil-block's value (or nil); non-nil receiver -> the notNil-block's
  // value with its param bound to the receiver (or the receiver itself).
  if (s == "ifNil:" || s == "ifNotNil:" || s == "ifNil:ifNotNil:" ||
      s == "ifNotNil:ifNil:") {
    BlockNode* nil_block = NULL;
    BlockNode* notnil_block = NULL;
    if (s == "ifNil:") {
      nil_block = dynamic_cast<BlockNode*>(node->args[0].get());
    } else if (s == "ifNotNil:") {
      notnil_block = dynamic_cast<BlockNode*>(node->args[0].get());
    } else if (s == "ifNil:ifNotNil:") {
      nil_block = dynamic_cast<BlockNode*>(node->args[0].get());
      notnil_block = dynamic_cast<BlockNode*>(node->args[1].get());
    } else {  // ifNotNil:ifNil:
      notnil_block = dynamic_cast<BlockNode*>(node->args[0].get());
      nil_block = dynamic_cast<BlockNode*>(node->args[1].get());
    }
    LocalVariable* recv = synth_.count(node) ? synth_[node] : NULL;
    if (recv == NULL) return Unsupported(node, "ifNil: without a receiver temp");

    Fragment instructions = TranslateExpression(node->receiver.get());
    instructions += StoreLocal(recv);
    instructions += Drop();
    instructions += LoadLocal(recv);
    instructions += NullConstant();
    TargetEntryInstr* nil_entry;
    TargetEntryInstr* notnil_entry;
    instructions += BranchIfStrictEqual(&nil_entry, &notnil_entry);

    // The non-nil arm binds a 1-arg block's parameter to the receiver.
    Fragment bind;
    if (notnil_block != NULL && notnil_block->args.size() >= 1) {
      LocalVariable* p = LookupLocal(notnil_block->args[0]);
      if (p != NULL) {
        bind += LoadLocal(recv);
        bind += StoreLocal(p);
        bind += Drop();
      }
    }

    Fragment nil_frag(nil_entry);
    Fragment notnil_frag(notnil_entry);
    if (value_context) {
      nil_frag += ArmValue(nil_block);  // nil-block value, or nil
      notnil_frag += bind;
      if (notnil_block != NULL) {
        Fragment v = InlineBlockValue(notnil_block);
        if (v.is_open()) v += StoreToValueTemp();
        notnil_frag += v;
      } else {                          // ifNil: with no notNil arm -> receiver
        notnil_frag += LoadLocal(recv);
        notnil_frag += StoreToValueTemp();
      }
    } else {
      if (nil_block != NULL) nil_frag += InlineBlockStmts(nil_block);
      if (notnil_block != NULL) {
        notnil_frag += bind;
        notnil_frag += InlineBlockStmts(notnil_block);
      }
    }

    Fragment result;
    if (nil_frag.is_open() && notnil_frag.is_open()) {
      JoinEntryInstr* join = BuildJoinEntry();
      nil_frag += Goto(join);
      notnil_frag += Goto(join);
      result = Fragment(instructions.entry, join);
    } else if (nil_frag.is_open()) {
      result = Fragment(instructions.entry, nil_frag.current);
    } else if (notnil_frag.is_open()) {
      result = Fragment(instructions.entry, notnil_frag.current);
    } else {
      result = instructions.closed();
    }
    if (value_context && result.is_open()) result += LoadLocal(value_temp_);
    return result;
  }

  // --- and: / or: (short-circuit; always yields a bool) -----------------
  if (s == "and:" || s == "or:") {
    BlockNode* block = dynamic_cast<BlockNode*>(node->args[0].get());
    Fragment instructions = TranslateExpression(node->receiver.get());
    TargetEntryInstr* then_entry;
    TargetEntryInstr* otherwise_entry;
    instructions += BranchIfTrue(&then_entry, &otherwise_entry);

    Fragment then_fragment(then_entry);
    Fragment otherwise_fragment(otherwise_entry);
    if (s == "and:") {
      then_fragment += ArmValue(block);
      otherwise_fragment += Constant(Bool::False());
      otherwise_fragment += StoreToValueTemp();
    } else {  // or:
      then_fragment += Constant(Bool::True());
      then_fragment += StoreToValueTemp();
      otherwise_fragment += ArmValue(block);
    }

    Fragment result;
    if (then_fragment.is_open() && otherwise_fragment.is_open()) {
      JoinEntryInstr* join = BuildJoinEntry();
      then_fragment += Goto(join);
      otherwise_fragment += Goto(join);
      result = Fragment(instructions.entry, join);
    } else if (then_fragment.is_open()) {
      result = Fragment(instructions.entry, then_fragment.current);
    } else if (otherwise_fragment.is_open()) {
      result = Fragment(instructions.entry, otherwise_fragment.current);
    } else {
      result = instructions.closed();
    }
    if (result.is_open()) result += LoadLocal(value_temp_);
    return result;  // a value; the caller Drops it in statement position
  }

  // --- whileTrue: / whileFalse: -----------------------------------------
  if (s == "whileTrue:" || s == "whileFalse:") {
    BlockNode* cond_block = dynamic_cast<BlockNode*>(node->receiver.get());
    BlockNode* body_block = dynamic_cast<BlockNode*>(node->args[0].get());
    Fragment condition = InlineBlockValue(cond_block);  // pushes the bool
    TargetEntryInstr* body_entry;
    TargetEntryInstr* loop_exit;
    if (s == "whileTrue:") {
      condition += BranchIfTrue(&body_entry, &loop_exit);
    } else {  // whileFalse: — loop while the condition is false
      condition += BranchIfTrue(&loop_exit, &body_entry);
    }
    Fragment body(body_entry);
    body += InlineBlockStmts(body_block);
    Instruction* entry;
    if (body.is_open()) {
      JoinEntryInstr* join = BuildJoinEntry();
      body += Goto(join);
      Fragment loop(join);
      loop += CheckStackOverflow();
      loop += condition;
      entry = new (zone_) GotoInstr(join);
    } else {
      entry = condition.entry;
    }
    Fragment result(entry, loop_exit);
    if (value_context) result += NullConstant();  // a loop's value is nil
    return result;
  }

  // --- to:do: (a counting loop) -----------------------------------------
  if (s == "to:do:") {
    BlockNode* block = dynamic_cast<BlockNode*>(node->args[1].get());
    LocalVariable* i =
        (block->args.size() >= 1) ? LookupLocal(block->args[0]) : NULL;
    LocalVariable* limit = synth_.count(node) ? synth_[node] : NULL;
    if (i == NULL || limit == NULL) {
      return Unsupported(node, "to:do: without a bound loop variable");
    }
    const String& le = String::ZoneHandle(zone_, Symbols::New(thread_, "<="));
    const String& plus = String::ZoneHandle(zone_, Symbols::New(thread_, "+"));

    Fragment instructions;
    instructions += TranslateExpression(node->receiver.get());  // start
    instructions += StoreLocal(i);
    instructions += Drop();
    instructions += TranslateExpression(node->args[0].get());  // stop
    instructions += StoreLocal(limit);
    instructions += Drop();

    Fragment condition;
    condition += LoadLocal(i);
    condition += PushArgument();
    condition += LoadLocal(limit);
    condition += PushArgument();
    condition += InstanceCall(le, Token::kLTE, 2, 2);
    TargetEntryInstr* body_entry;
    TargetEntryInstr* loop_exit;
    condition += BranchIfTrue(&body_entry, &loop_exit);

    Fragment body(body_entry);
    body += InlineBlockStmts(block);
    body += LoadLocal(i);
    body += PushArgument();
    body += IntConstant(1);
    body += PushArgument();
    body += InstanceCall(plus, Token::kADD, 2, 2);
    body += StoreLocal(i);
    body += Drop();

    Instruction* entry;
    if (body.is_open()) {
      JoinEntryInstr* join = BuildJoinEntry();
      body += Goto(join);
      Fragment loop(join);
      loop += CheckStackOverflow();
      loop += condition;
      entry = new (zone_) GotoInstr(join);
    } else {
      entry = condition.entry;
    }
    instructions += Fragment(entry, loop_exit);
    if (value_context) instructions += NullConstant();
    return instructions;
  }

  // --- timesRepeat: (a counting loop, no loop variable exposed) ----------
  if (s == "timesRepeat:") {
    BlockNode* block = dynamic_cast<BlockNode*>(node->args[0].get());
    LocalVariable* limit = synth_.count(node) ? synth_[node] : NULL;
    LocalVariable* i = synth2_.count(node) ? synth2_[node] : NULL;
    if (limit == NULL || i == NULL) {
      return Unsupported(node, "timesRepeat: without temps");
    }
    const String& le = String::ZoneHandle(zone_, Symbols::New(thread_, "<="));
    const String& plus = String::ZoneHandle(zone_, Symbols::New(thread_, "+"));

    Fragment instructions;
    instructions += TranslateExpression(node->receiver.get());  // the count
    instructions += StoreLocal(limit);
    instructions += Drop();
    instructions += IntConstant(1);
    instructions += StoreLocal(i);
    instructions += Drop();

    Fragment condition;
    condition += LoadLocal(i);
    condition += PushArgument();
    condition += LoadLocal(limit);
    condition += PushArgument();
    condition += InstanceCall(le, Token::kLTE, 2, 2);
    TargetEntryInstr* body_entry;
    TargetEntryInstr* loop_exit;
    condition += BranchIfTrue(&body_entry, &loop_exit);

    Fragment body(body_entry);
    body += InlineBlockStmts(block);
    body += LoadLocal(i);
    body += PushArgument();
    body += IntConstant(1);
    body += PushArgument();
    body += InstanceCall(plus, Token::kADD, 2, 2);
    body += StoreLocal(i);
    body += Drop();

    Instruction* entry;
    if (body.is_open()) {
      JoinEntryInstr* join = BuildJoinEntry();
      body += Goto(join);
      Fragment loop(join);
      loop += CheckStackOverflow();
      loop += condition;
      entry = new (zone_) GotoInstr(join);
    } else {
      entry = condition.entry;
    }
    instructions += Fragment(entry, loop_exit);
    if (value_context) instructions += NullConstant();
    return instructions;
  }

  return Unsupported(node, "control-flow selector");
}

// recv m1; m2; m3  ->  eval recv once into a temp, send each message to it; the
// cascade's value is the last message's result.
Fragment StGraphBuilder::TranslateCascade(CascadeNode* node) {
  // Sprint 10: a cascade whose receiver is a CLASS NAME sends class-side
  // messages (`Transcript show: 'x'; cr`) — each message goes through the
  // class-send path (static lookup / new / signal desugars).
  if (VariableNode* rv = dynamic_cast<VariableNode*>(node->receiver.get())) {
    if (rv->name != "self" && rv->name != "super" &&
        LookupLocal(rv->name) == NULL) {
      const Class& cls = Class::Handle(zone_, ResolveClassName(rv->name));
      if (!cls.IsNull()) {
        Fragment instructions;
        for (size_t k = 0; k < node->messages.size(); k++) {
          MessageNode* m = dynamic_cast<MessageNode*>(node->messages[k].get());
          if (m == NULL) {
            instructions +=
                Unsupported(node->messages[k].get(), "cascade message");
          } else {
            instructions += TranslateClassSend(cls, m);
          }
          if (k + 1 < node->messages.size()) instructions += Drop();
        }
        return instructions;  // value = the last message's result
      }
    }
  }
  LocalVariable* recv = synth_.count(node) ? synth_[node] : NULL;
  if (recv == NULL) return Unsupported(node, "cascade (no receiver temp)");
  Fragment instructions = TranslateExpression(node->receiver.get());
  instructions += StoreLocal(recv);
  instructions += Drop();
  for (size_t k = 0; k < node->messages.size(); k++) {
    MessageNode* m = dynamic_cast<MessageNode*>(node->messages[k].get());
    if (m == NULL) {
      instructions += Unsupported(node->messages[k].get(), "cascade message");
      instructions += Drop();
      continue;
    }
    // `; yourself` — the receiver itself (the idiom that makes a cascade
    // answer the object being configured).
    if (m->selector == "yourself" && m->args.empty()) {
      instructions += LoadLocal(recv);
      if (k + 1 < node->messages.size()) instructions += Drop();
      continue;
    }
    instructions += LoadLocal(recv);
    instructions += PushArgument();
    for (size_t a = 0; a < m->args.size(); a++) {
      instructions += TranslateExpression(m->args[a].get());
      instructions += PushArgument();
    }
    const intptr_t argc = 1 + static_cast<intptr_t>(m->args.size());
    // Same routing as a normal send (Sprint 12): universal helpers first,
    // else the aliased/mangled selector — a cascaded `add:`/`at:put:` must
    // behave exactly like its non-cascaded form.
    const HelperRewrite* hr =
        FindHelperRewrite(m->selector, m->args.size());
    if (hr != NULL) {
      instructions += StaticCall(
          Function::ZoneHandle(zone_, LookupCocoaFunction(hr->helper)), argc);
    } else {
      const std::string dsel = DartSelector(m->selector);
      const String& sel =
          String::ZoneHandle(zone_, Symbols::New(thread_, dsel.c_str()));
      const Token::Kind kind = MethodKind(sel);
      const intptr_t nchecked = (kind != Token::kILLEGAL) ? argc : 1;
      instructions += InstanceCall(sel, kind, argc, nchecked);  // pushes result
    }
    if (k + 1 < node->messages.size()) instructions += Drop();  // keep only last
  }
  return instructions;
}

// ---------------------------------------------------------------------------
// Closures Stage A (non-capturing). A BlockNode in value position becomes a
// first-class Closure object; `value*` sends lower to InstanceCall("call"),
// which the runtime's IC-miss path invokes on a closure receiver
// (runtime_entry.cc:1575 -> DartEntry::InvokeClosure). References from the
// closure body to enclosing method locals / self are Unsupported until the
// Stage-B capture layer; `^` inside a closure is Stage C.
// ---------------------------------------------------------------------------

// Mirror of kernel_to_il.cc TranslateFunctionNode (:6604): get-or-create the
// closure Function (dedup'd per (parent, synthetic position)), then allocate a
// Closure object and store the function + a null context into it.
Fragment StGraphBuilder::TranslateClosure(BlockNode* block) {
  LocalVariable* tmp = synth_.count(block) ? synth_[block] : NULL;
  if (tmp == NULL) return Unsupported(block, "closure (no creation temp)");

  Isolate* isolate = thread_->isolate();
  // A unique synthetic position per block: NewClosureFunction /
  // LookupClosureFunction dedup by (parent, position), so kNoSource would
  // alias every block in a method. Line/col are unique per block start.
  const TokenPosition pos =
      TokenPosition(block->pos.line * 1000 + block->pos.col).ToSynthetic();
  Function& fn = Function::ZoneHandle(
      zone_, isolate->LookupClosureFunction(pf_->function(), pos));
  if (fn.IsNull()) {
    fn = Function::NewClosureFunction(Symbols::AnonymousClosure(),
                                      pf_->function(), pos);
    fn.set_result_type(Object::dynamic_type());
    // The VM closure calling convention: argument 0 is the closure object
    // itself; the block's own args follow.
    const intptr_t num_params = 1 + static_cast<intptr_t>(block->args.size());
    fn.set_num_fixed_parameters(num_params);
    fn.SetNumOptionalParameters(0, /*are_positional=*/true);
    fn.set_parameter_types(
        Array::Handle(zone_, Array::New(num_params, Heap::kOld)));
    fn.set_parameter_names(
        Array::Handle(zone_, Array::New(num_params, Heap::kOld)));
    fn.SetParameterTypeAt(0, Object::dynamic_type());
    fn.SetParameterNameAt(
        0, String::Handle(zone_, Symbols::New(thread_, ":closure")));
    for (size_t a = 0; a < block->args.size(); a++) {
      fn.SetParameterTypeAt(1 + a, Object::dynamic_type());
      fn.SetParameterNameAt(
          1 + a,
          String::Handle(zone_, Symbols::New(thread_, block->args[a].c_str())));
    }
    // Finalize the signature type NOW (the parser does the same for its
    // closures, parser.cc ~6963). Left unfinalized, the closure's function
    // type reaches CompileType::Union once the INLINER starts splicing ST
    // graphs (a phi unioning closure values) and TypeTest asserts
    // IsFinalized() — the deltablue inlining crash.
    Type& sig = Type::ZoneHandle(zone_, fn.SignatureType());
    sig ^= ClassFinalizer::FinalizeType(
        Class::Handle(zone_, pf_->function().Owner()), sig,
        ClassFinalizer::kCanonicalize);
    fn.SetSignatureType(sig);
    // Stage B: export every captured variable visible here (the method's
    // captured locals — or, inside a closure body, the restored outer vars,
    // which re-export to nested closures for free since the context is the
    // single shared method context at level 0).
    std::vector<LocalVariable*> captured;
    if (this_var_ != NULL && this_var_->is_captured()) {
      captured.push_back(this_var_);
    }
    for (std::map<std::string, LocalVariable*>::iterator it = locals_.begin();
         it != locals_.end(); ++it) {
      if (it->second->is_captured()) captured.push_back(it->second);
    }
    if (captured.empty()) {
      fn.set_context_scope(Object::empty_context_scope());
    } else {
      const ContextScope& context_scope = ContextScope::Handle(
          zone_, ContextScope::New(static_cast<intptr_t>(captured.size()),
                                   /*is_implicit=*/false));
      for (size_t ci = 0; ci < captured.size(); ci++) {
        LocalVariable* v = captured[ci];
        const intptr_t idx = static_cast<intptr_t>(ci);
        context_scope.SetTokenIndexAt(idx, TokenPosition::kNoSource);
        context_scope.SetDeclarationTokenIndexAt(idx, TokenPosition::kNoSource);
        context_scope.SetNameAt(idx, v->name());
        context_scope.SetIsFinalAt(idx, false);
        context_scope.SetIsConstAt(idx, false);
        context_scope.SetTypeAt(idx, Object::dynamic_type());
        context_scope.SetContextIndexAt(idx, v->index());
        context_scope.SetContextLevelAt(idx, 0);  // single shared context
      }
      fn.set_context_scope(context_scope);
    }
    // The marker, stored as Node* like the loader's methods; st::BuildGraph
    // dispatches on the dynamic type.
    fn.set_kernel_function(reinterpret_cast<void*>(static_cast<Node*>(block)));
    // (Closures are inlinable — the inliner routes the marker to
    // st::BuildGraph now. InlineClosureCalls resolves the target from the
    // creation's AllocateObjectInstr::closure_function and splices the body.)
    isolate->AddClosureFunction(fn);
  }

  // Allocate the Closure and fill its two fields (function, context).
  const Class& closure_class =
      Class::ZoneHandle(zone_, isolate->object_store()->closure_class());
  ArgumentArray no_args =
      new (zone_) ZoneGrowableArray<PushArgumentInstr*>(zone_, 0);
  AllocateObjectInstr* alloc = new (zone_)
      AllocateObjectInstr(TokenPosition::kNoSource, closure_class, no_args);
  alloc->set_closure_function(fn);
  Push(alloc);
  Fragment instructions(alloc);
  instructions += StoreLocal(tmp);
  instructions += Drop();
  instructions += LoadLocal(tmp);
  instructions += Constant(fn);
  instructions += StoreInstanceField(Closure::function_offset());
  instructions += LoadLocal(tmp);
  // The current context (null when this frame captured nothing) — the closure
  // body's prologue restores it into its own current_context_var.
  instructions += LoadLocal(pf_->current_context_var());
  instructions += StoreInstanceField(Closure::context_offset());
  instructions += LoadLocal(tmp);  // the closure is the expression's value
  return instructions;
}

// Scope prep for a CLOSURE body compile: argument 0 is the closure object,
// then the block args; block temps are stack locals. No `self` (this_var_
// stays NULL — self/ivars inside a closure are Stage B).
void StGraphBuilder::PrepareClosureScope(BlockNode* block) {
  const Function& function = pf_->function();

  // Stage B: if this closure captured outer variables, rebuild them from the
  // ContextScope the creation site preserved — the VM primitive
  // LocalScope::RestoreOuterScope (parser.cc:6596) returns an outer scope
  // whose variables are already marked captured with the right context
  // levels/indices. The closure's own scope is its child.
  const ContextScope& context_scope =
      ContextScope::Handle(zone_, function.context_scope());
  LocalScope* outer = NULL;
  if (!context_scope.IsNull() && context_scope.num_variables() > 0) {
    outer = LocalScope::RestoreOuterScope(context_scope);
  }
  LocalScope* scope = new (zone_) LocalScope(outer, 0, 0);
  scope->set_begin_token_pos(function.token_pos());
  scope->set_end_token_pos(function.end_token_pos());

  LocalVariable* context_var = pf_->current_context_var();
  context_var->set_is_forced_stack();
  scope->AddVariable(context_var);

  pf_->SetNodeSequence(new (zone_)
                           SequenceNode(TokenPosition::kNoSource, scope));

  // Register the restored captured variables by name (before the block's own
  // args/temps, so a shadowing block arg correctly wins the map). A restored
  // `this` becomes self.
  if (outer != NULL) {
    for (intptr_t i = 0; i < outer->num_variables(); i++) {
      LocalVariable* v = outer->VariableAt(i);
      const char* name = v->name().ToCString();
      if (strcmp(name, "this") == 0) {
        this_var_ = v;
      } else {
        locals_[std::string(name)] = v;
      }
    }
  }

  // Which of THIS block's params/temps are captured by a nested closure? Those
  // names were restored above as shared-context vars (the method allocated the
  // slot); keep those bindings and route the incoming value through them,
  // rather than shadowing with a fresh frame local the inner closure can't see.
  std::set<std::string> hoisted;
  for (size_t i = 0; i < block->statements.size(); i++) {
    std::set<std::string> anc;
    for (size_t k = 0; k < block->args.size(); k++) anc.insert(block->args[k]);
    for (size_t k = 0; k < block->temps.size(); k++) anc.insert(block->temps[k]);
    CollectHoistedBlockParams(block->statements[i].get(), anc,
                              std::set<std::string>(), &hoisted);
  }
  block_param_copies_.clear();

  intptr_t pos = 0;
  LocalVariable* closure_var = MakeLocal(":closure");
  scope->InsertParameterAt(pos++, closure_var);
  closure_var_ = closure_var;
  for (size_t i = 0; i < block->args.size(); i++) {
    const std::string& nm = block->args[i];
    // A hoisted param the enclosing frame exported: the incoming arg needs a
    // raw frame slot (`:cp<i>`) to be read from, then copied into its context
    // slot by the prologue; references to `nm` keep the restored context var.
    if (hoisted.count(nm) && locals_.count(nm) &&
        locals_[nm]->is_captured()) {
      char buf[32];
      snprintf(buf, sizeof(buf), ":cp%ld", static_cast<long>(i));
      LocalVariable* raw = MakeLocal(buf);
      scope->InsertParameterAt(pos++, raw);
      block_param_copies_.push_back(std::make_pair(raw, locals_[nm]));
      continue;
    }
    LocalVariable* v = MakeLocal(nm);
    scope->InsertParameterAt(pos++, v);
    locals_[nm] = v;
  }
  for (size_t i = 0; i < block->temps.size(); i++) {
    const std::string& nm = block->temps[i];
    // A hoisted temp already lives in the shared context (restored above); a
    // fresh frame local would shadow it and hide writes from nested closures.
    if (hoisted.count(nm) && locals_.count(nm) &&
        locals_[nm]->is_captured()) {
      continue;
    }
    LocalVariable* v = MakeLocal(nm);
    scope->AddVariable(v);
    locals_[nm] = v;
  }
  for (size_t i = 0; i < block->statements.size(); i++) {
    CollectLocals(block->statements[i].get(), scope);
  }
  value_temp_ = MakeLocal(":cfval");
  scope->AddVariable(value_temp_);

  pf_->AllocateVariables();
}

FlowGraph* StGraphBuilder::BuildClosure(BlockNode* block) {
  in_closure_ = true;  // `^` in this body = non-local return (Stage C)
  // CLOSURES INLINE (the deltablue gap): the graph is ordinary IL — the
  // prologue's LoadField(closure.context) forwards to the caller's
  // AllocateObject stores once inlined, and SSA renames the locals. The chain
  // that gets here: a stValueN helper inlines into the ST caller, its `r(a)`
  // is a ClosureCallInstr, and InlineClosureCalls resolves the target from
  // AllocateObjectInstr::closure_function. A `^` inside the closure is a
  // stNlrThrow StaticCall — plain IL, unchanged semantics inlined (it still
  // unwinds to the home method's catch, which never inlines).
  PrepareClosureScope(block);

  TargetEntryInstr* normal_entry = BuildTargetEntry();
  graph_entry_ = new (zone_) GraphEntryInstr(*pf_, normal_entry, osr_id_);

  Fragment body;
  body += CheckStackOverflow();

  // Stage B prologue: restore the captured context. The closure object is
  // argument 0; its saved context (stored at creation) becomes this frame's
  // current_context_var, through which every captured load/store routes.
  const ContextScope& context_scope =
      ContextScope::Handle(zone_, pf_->function().context_scope());
  if (!context_scope.IsNull() && context_scope.num_variables() > 0) {
    body += LoadLocal(closure_var_);
    body += LoadField(Closure::context_offset());
    body += StoreLocal(pf_->current_context_var());
    body += Drop();
  }

  // Copy each hoisted param's incoming value (a raw frame slot) into its shared
  // context slot, so a nested closure that captures the param sees the argument
  // this activation was called with (the streamContents: `[:s | ... s ...]`
  // fix). Mirrors the method prologue's captured-parameter copy.
  for (size_t i = 0; i < block_param_copies_.size(); i++) {
    LocalVariable* raw = block_param_copies_[i].first;
    LocalVariable* ctx = block_param_copies_[i].second;
    body += LoadLocal(pf_->current_context_var());
    body += LoadLocal(raw);
    body += StoreInstanceField(Context::variable_offset(ctx->index()));
  }

  body += InlineBlockValue(block);  // the last statement's value (or nil);
                                    // a `^` inside throws the NLR carrier
  if (body.is_open()) body += Return();

  normal_entry->LinkTo(body.entry);
  return new (zone_) FlowGraph(*pf_, graph_entry_, next_block_id_ - 1);
}

Fragment StGraphBuilder::TranslateStatement(Node* node) {
  // Sprint 16: this statement's source offset becomes the token position of the
  // instructions it emits (calls, checks, returns) — the debugger's breakpoint
  // map. A `0` offset (synthesized node) leaves the prior position in place.
  if (node != nullptr && node->pos.offset > 0) {
    cur_pos_ = TokenPosition(node->pos.offset);
  }
  if (ReturnNode* r = dynamic_cast<ReturnNode*>(node)) {
    if (in_closure_) {
      // Stage C: `^` under a first-class closure is a NON-LOCAL return from
      // the home method — throw the carrier {home: my restored context,
      // value}. stNlrThrow never returns; its (dead) result is dropped so the
      // stack stays balanced, and the fragment stays open as dead code.
      const Function& throw_fn =
          Function::ZoneHandle(zone_, LookupCocoaFunction("stNlrThrow"));
      Fragment instructions;
      instructions += LoadLocal(pf_->current_context_var());  // home token
      instructions += PushArgument();
      if (r->value != nullptr) {
        instructions += TranslateExpression(r->value.get());
      } else {
        instructions += NullConstant();
      }
      instructions += PushArgument();
      instructions += StaticCall(throw_fn, 2);
      instructions += Drop();
      return instructions;
    }
    Fragment instructions = (r->value != nullptr)
                                ? TranslateExpression(r->value.get())
                                : NullConstant();
    instructions += Return();
    return instructions;
  }
  // Control-flow messages in statement position (if/while/to:do:) leave NO value
  // — translate them directly, no trailing Drop. and:/or: are value operators,
  // so they fall through to the generic expression+Drop path below.
  if (MessageNode* m = dynamic_cast<MessageNode*>(node)) {
    if (IsInlinableControlFlow(m) && m->selector != "and:" &&
        m->selector != "or:") {
      return TranslateControlFlow(m, /*value_context=*/false);
    }
  }
  // An expression statement: evaluate for its effect, discard the value.
  Fragment instructions = TranslateExpression(node);
  instructions += Drop();
  return instructions;
}

Fragment StGraphBuilder::TranslateStatements(
    const std::vector<NodePtr>& statements) {
  Fragment instructions;
  for (size_t i = 0; i < statements.size(); i++) {
    if (instructions.is_closed()) break;  // dead code after a `^return`
    instructions += TranslateStatement(statements[i].get());
  }
  return instructions;
}

// Parse a `<primitive: FFI function: #name ret: #r args: #( c c )>` pragma's
// captured text into name / ret-code / concatenated arg-codes (e.g. "gg").
// Returns false (leaving the method to compile normally) on anything malformed.
static bool ParseFfiPragma(const std::string& t, std::string* name,
                           std::string* ret, std::string* codes) {
  const size_t fp = t.find("function: #");
  const size_t rp = t.find("ret: #");
  if (fp == std::string::npos || rp == std::string::npos) return false;
  const size_t fs = fp + 11;  // strlen("function: #")
  const size_t fe = t.find(' ', fs);
  *name = t.substr(fs, fe == std::string::npos ? std::string::npos : fe - fs);
  *ret = t.substr(rp + 6, 1);  // strlen("ret: #") == 6
  codes->clear();
  const size_t ap = t.find("args: #(");
  if (ap != std::string::npos) {
    const size_t as = ap + 8;  // strlen("args: #(")
    const size_t ae = t.find(')', as);
    for (size_t i = as; i < ae && i < t.size(); i++) {
      if (t[i] != ' ' && t[i] != '\t') codes->push_back(t[i]);
    }
  }
  return !name->empty() && !ret->empty();
}

FlowGraph* StGraphBuilder::Build(MethodNode* method) {
  PrepareScope(method);

  // INLINING BAILOUT: a method with the non-local-return try/catch wrapper (a
  // ^-carrying closure) is not inlined in v1 — the exit collector expects
  // plain ReturnInstrs, not the NLR CatchBlockEntry/ReThrow machinery. Mark it
  // non-inlinable permanently (so future attempts skip it at CanBeInlined) and
  // bail this attempt via the inliner's LongJumpScope. Simple methods — the
  // hot getters/setters/dispatchers — inline. (Only reached when inlining;
  // needs_nlr_ is set by PrepareScope's capture pass.)
  if (exit_collector_ != NULL && needs_nlr_) {
    pf_->function().set_is_inlinable(false);
    pf_->Bailout("st::BuildGraph", "non-local return not inlinable");
    UNREACHABLE();
  }

  // Graph root: normal_entry (block id 1) wrapped in the GraphEntry (block 0).
  TargetEntryInstr* normal_entry = BuildTargetEntry();
  graph_entry_ =
      new (zone_) GraphEntryInstr(*pf_, normal_entry, osr_id_);

  // Sprint 9: a `<stprim: name>` pragma body IS a call to the named
  // dart:cocoa helper with (self +) the parameters as arguments — the
  // prelude's primitive mechanism (signal, becomeForward:, ...), the same
  // shape MACVM's own kernel uses for its primitives.
  for (size_t i = 0; i < method->pragmas.size(); i++) {
    const std::string& text = method->pragmas[i].text;
    if (text.compare(0, 8, "stprim: ") != 0) continue;
    std::string prim = text.substr(8);
    while (!prim.empty() && prim[prim.size() - 1] == ' ') {
      prim.erase(prim.size() - 1);
    }
    const Function& fn =
        Function::ZoneHandle(zone_, LookupCocoaFunction(prim.c_str()));
    Fragment prim_body;
    prim_body += CheckStackOverflow();
    intptr_t argc = 0;
    if (this_var_ != NULL) {
      prim_body += LoadLocal(this_var_);
      prim_body += PushArgument();
      argc++;
    }
    for (size_t a = 0; a < method->args.size(); a++) {
      prim_body += LoadLocal(locals_[method->args[a]]);
      prim_body += PushArgument();
      argc++;
    }
    prim_body += StaticCall(fn, argc);
    prim_body += Return();
    normal_entry->LinkTo(prim_body.entry);
    return new (zone_) FlowGraph(*pf_, graph_entry_, next_block_id_ - 1);
  }

  // A `<primitive: FFI function: #name ret: #r args: #( c c )>` — the FFI floor
  // (ST_PORTING_PLAN §3a). The whole body IS the call (a bare primitive): build
  // [params] as a Dart List and hand it to stFfiCall(args, "name|ret|codes"),
  // which dlsym's the C function and marshals per the codes. Malformed pragma
  // falls through to normal compilation (answers self, as today).
  for (size_t i = 0; i < method->pragmas.size(); i++) {
    const std::string& text = method->pragmas[i].text;
    if (text.compare(0, 15, "primitive: FFI ") != 0) continue;
    std::string fname, fret, fcodes;
    if (!ParseFfiPragma(text, &fname, &fret, &fcodes)) break;
    const std::string desc = fname + "|" + fret + "|" + fcodes;
    const Function& call =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stFfiCall"));
    const Function& new_list =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stNewList"));
    const Function& append =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stListAppend"));
    Fragment b;
    b += CheckStackOverflow();
    b += StaticCall(new_list, 0);                    // the args list
    for (size_t a = 0; a < method->args.size(); a++) {
      b += PushArgument();                           // list so far
      b += LoadLocal(locals_[method->args[a]]);
      b += PushArgument();
      b += StaticCall(append, 2);                    // -> list (grown)
    }
    b += PushArgument();                             // args list  -> arg 0
    b += Constant(String::ZoneHandle(
             zone_, String::New(desc.c_str(), Heap::kOld)));
    b += PushArgument();                             // descriptor -> arg 1
    b += StaticCall(call, 2);
    b += Return();
    normal_entry->LinkTo(b.entry);
    return new (zone_) FlowGraph(*pf_, graph_entry_, next_block_id_ - 1);
  }

  // Sprint 16: the entry stack-check carries the method's opening position, so
  // a breakpoint on the method's signature line (or "pause on entry") lands
  // before the first statement runs.
  if (method->pos.offset > 0) cur_pos_ = TokenPosition(method->pos.offset);
  Fragment body;
  body += CheckStackOverflow();

  // Stage B: if any locals were captured, allocate the heap Context and chain
  // it into current_context_var, then copy captured PARAMETERS from their
  // incoming frame slots into it (mirrors kernel BuildGraphOfFunction:3277 —
  // the captured variable's LocalVariable now holds a CONTEXT index, so the
  // raw frame slot needs a synthetic forced-stack variable to read it).
  const intptr_t context_size =
      pf_->node_sequence()->scope()->num_context_variables();
  if (context_size > 0) {
    body += AllocateContext(context_size);
    body += StoreLocal(pf_->current_context_var());  // never captured: plain
    body += Drop();
    intptr_t frame_index = pf_->first_parameter_index();
    for (size_t i = 0; i < param_vars_.size(); i++, frame_index--) {
      LocalVariable* variable = param_vars_[i];
      if (!variable->is_captured()) continue;
      LocalVariable* raw_parameter = new (zone_)
          LocalVariable(TokenPosition::kNoSource, TokenPosition::kNoSource,
                        Symbols::TempParam(), Object::dynamic_type());
      raw_parameter->set_index(frame_index);
      raw_parameter->set_is_captured_parameter(true);
      body += LoadLocal(pf_->current_context_var());
      body += LoadLocal(raw_parameter);
      body += StoreInstanceField(Context::variable_offset(variable->index()));
    }
  }

  // Stage C: enter the NLR try region. The context prologue above stays
  // OUTSIDE it so :saved_try_context_var (stored here, restored by the catch)
  // holds the real context. The body's blocks inherit try index 0.
  if (needs_nlr_) {
    body += LoadLocal(pf_->current_context_var());
    body += StoreLocal(saved_ctx_var_);
    body += Drop();
    try_index_ = 0;
    JoinEntryInstr* try_entry = BuildJoinEntry();  // carries try index 0
    body += Goto(try_entry);
    body = Fragment(body.entry, try_entry);  // continue appending after it
  }

  body += TranslateStatements(method->statements);

  // Guarantee the body is closed on every path (invariant #1): a method that
  // falls off the end returns SELF (Smalltalk's implicit return — the corpus
  // constructor idiom `^self basicNew init...` depends on it). Instance side:
  // the receiver; class side: thisCls. LoadLocal routes captured self via the
  // context automatically.
  if (body.is_open()) {
    if (this_var_ != NULL) {
      body += LoadLocal(this_var_);
    } else if (locals_.count("self") != 0) {
      body += LoadLocal(locals_["self"]);
    } else {
      body += NullConstant();
    }
    body += Return();
  }

  // Stage C: the NLR catch handler. Catch-all; if the carrier's home is THIS
  // activation's context, return its value — otherwise rethrow (an outer ST
  // frame may be the home; an escaped-home carrier reaches the top as the
  // classic cannotReturn error).
  if (needs_nlr_) {
    try_index_ = CatchClauseNode::kInvalidTryIndex;  // handler is outside
    const Array& handler_types =
        Array::ZoneHandle(zone_, Array::New(1, Heap::kOld));
    handler_types.SetAt(0, Object::dynamic_type());
    CatchBlockEntryInstr* catch_entry = new (zone_) CatchBlockEntryInstr(
        TokenPosition::kNoSource, /*is_generated=*/false, AllocateBlockId(),
        try_index_, graph_entry_, handler_types, /*handler_index=*/0,
        *exc_var_, *stk_var_, /*needs_stacktrace=*/true,
        thread_->GetNextDeoptId(), /*should_restore_closure_context=*/false);
    graph_entry_->AddCatchEntry(catch_entry);
    Fragment handler(catch_entry);
    // Restore the context (kernel CatchBlockEntry does the same).
    handler += LoadLocal(saved_ctx_var_);
    handler += StoreLocal(pf_->current_context_var());
    handler += Drop();
    // stNlrHome(e) === my context ?
    const Function& home_fn =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stNlrHome"));
    const Function& value_fn =
        Function::ZoneHandle(zone_, LookupCocoaFunction("stNlrValue"));
    handler += LoadLocal(exc_var_);
    handler += PushArgument();
    handler += StaticCall(home_fn, 1);
    handler += LoadLocal(pf_->current_context_var());
    TargetEntryInstr* match_entry;
    TargetEntryInstr* nomatch_entry;
    handler += BranchIfStrictEqual(&match_entry, &nomatch_entry);
    // match: return the carrier's value from this method.
    Fragment match_fragment(match_entry);
    match_fragment += LoadLocal(exc_var_);
    match_fragment += PushArgument();
    match_fragment += StaticCall(value_fn, 1);
    match_fragment += Return();
    // no match: rethrow (kernel RethrowException bookkeeping: the two
    // PushArguments are consumed by the ReThrow at run time; drop them from
    // the model stack and fix the pending count).
    Fragment nomatch_fragment(nomatch_entry);
    nomatch_fragment += LoadLocal(exc_var_);
    nomatch_fragment += PushArgument();
    nomatch_fragment += LoadLocal(stk_var_);
    nomatch_fragment += PushArgument();
    nomatch_fragment += Drop();
    nomatch_fragment += Drop();
    nomatch_fragment +=
        Fragment(new (zone_) ReThrowInstr(TokenPosition::kNoSource,
                                          /*catch_try_index=*/0)).closed();
    pending_argument_count_ -= 2;
  }

  normal_entry->LinkTo(body.entry);
  return new (zone_) FlowGraph(*pf_, graph_entry_, next_block_id_ - 1);
}

}  // namespace

FlowGraph* BuildGraph(ParsedFunction* pf,
                      const ZoneGrowableArray<const ICData*>& ic_data_array,
                      intptr_t osr_id) {
  // Recover the marker (ST_PLAN.md §2.2). It is stored as a Node*: the loader
  // stamps methods with a MethodNode*, and TranslateClosure stamps closure
  // functions with their BlockNode* — dispatch on the dynamic type.
  Node* node = reinterpret_cast<Node*>(pf->function().kernel_function());
  ASSERT(node != NULL);
  StGraphBuilder builder(pf, ic_data_array, osr_id);
  FlowGraph* graph = NULL;
  if (MethodNode* method = dynamic_cast<MethodNode*>(node)) {
    graph = builder.Build(method);
  } else if (BlockNode* block = dynamic_cast<BlockNode*>(node)) {
    graph = builder.BuildClosure(block);
  }
  ASSERT(graph != NULL);
  return graph;
}

// Inlining overload: build an ST callee graph for the inliner (returns route
// through `exit_collector`; block ids start at `first_block_id` so they don't
// collide with the caller's). The graph is otherwise identical — the inliner
// runs SSA on it (adding ParameterInstr per num_direct_parameters, which our
// param LoadLocals wire to) and substitutes the caller's actuals. NLR methods
// and closures self-bail (see Build/BuildClosure) via the inliner's
// LongJumpScope. This is what makes ST methods inlinable — the whole point of
// closing the call-heavy gap with native Dart.
FlowGraph* BuildGraph(ParsedFunction* pf,
                      const ZoneGrowableArray<const ICData*>& ic_data_array,
                      ::dart::InlineExitCollector* exit_collector,
                      intptr_t first_block_id) {
  // The inliner CACHES ParsedFunctions across call sites, but our scope prep
  // (SetNodeSequence + AllocateVariables) runs once and is not idempotent — a
  // second inline of the same method would re-set the cached scope and assert.
  // Build with a FRESH ParsedFunction each time (the Function is shared, so
  // set_is_inlinable on a bail still sticks; InlinedCallData keeps no
  // ParsedFunction, only the callee_graph which references this fresh one).
  Thread* thread = Thread::Current();
  ParsedFunction* fresh = new (thread->zone()) ParsedFunction(
      thread, Function::ZoneHandle(thread->zone(), pf->function().raw()));
  Node* node = reinterpret_cast<Node*>(fresh->function().kernel_function());
  ASSERT(node != NULL);
  StGraphBuilder builder(fresh, ic_data_array, Compiler::kNoOSRDeoptId,
                         exit_collector, first_block_id);
  FlowGraph* graph = NULL;
  if (MethodNode* method = dynamic_cast<MethodNode*>(node)) {
    graph = builder.Build(method);
  } else if (BlockNode* block = dynamic_cast<BlockNode*>(node)) {
    graph = builder.BuildClosure(block);
  }
  ASSERT(graph != NULL);
  return graph;
}

// Populate `pf`'s scope for an ST function WITHOUT building a graph — the
// var-descriptor recompute path (compiler.cc ComputeLocalVarDescriptors).
// Without this, that path routes an ST method's marker into the kernel
// ScopeBuilder and segvs (the profiler/GC/debugger walking an unoptimized ST
// frame). An empty ic_data array suffices; scope prep never reads it.
void PrepareScopes(ParsedFunction* pf) {
  ZoneGrowableArray<const ICData*>* ic = new ZoneGrowableArray<const ICData*>();
  StGraphBuilder builder(pf, *ic, /*osr_id=*/-1 /*Compiler::kNoOSRDeoptId*/);
  builder.PrepareScopesOnly();
}

}  // namespace st
