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
#include <string>
#include <vector>

#include "st_ast.h"

#include "vm/ast.h"                   // SequenceNode
#include "vm/class_finalizer.h"       // FinalizeClass (AllocateObject layout)
#include "vm/flow_graph.h"            // FlowGraph
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
  StGraphBuilder(ParsedFunction* pf,
                 const ZoneGrowableArray<const ICData*>& ic_data_array,
                 intptr_t osr_id)
      : pf_(pf),
        thread_(Thread::Current()),
        zone_(thread_->zone()),
        ic_data_array_(ic_data_array),
        osr_id_(osr_id),
        next_block_id_(1),
        stack_(NULL),
        pending_argument_count_(0),
        graph_entry_(NULL),
        this_var_(NULL),
        value_temp_(NULL),
        synth_counter_(0),
        closure_var_(NULL) {}

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
    return new (zone_)
        TargetEntryInstr(AllocateBlockId(), CatchClauseNode::kInvalidTryIndex);
  }
  JoinEntryInstr* BuildJoinEntry() {
    return new (zone_)
        JoinEntryInstr(AllocateBlockId(), CatchClauseNode::kInvalidTryIndex);
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
        InstanceCallInstr(TokenPosition::kNoSource, name, kind, arguments,
                          kTypeArgsLen, Array::null_array(), num_args_checked,
                          ic_data_array_);
    Push(call);
    return Fragment(call);
  }
  Fragment StaticCall(const Function& target, intptr_t argument_count) {
    ArgumentArray arguments = GetArguments(argument_count);
    StaticCallInstr* call = new (zone_) StaticCallInstr(
        TokenPosition::kNoSource, target, /*type_args_len=*/0,
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
        new (zone_) CheckStackOverflowInstr(TokenPosition::kNoSource, 0));
  }
  Fragment Return() {
    Value* value = Pop();
    ASSERT(stack_ == NULL);
    ReturnInstr* return_instr =
        new (zone_) ReturnInstr(TokenPosition::kNoSource, value);
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
  // Byte offset of an instance variable of the receiver's class, or -1 if
  // `name` is not one. The owner class is member-finalized before compile
  // (st_natives.cc ST_send / ST_new), so Field::Offset() is valid.
  intptr_t IvarOffset(const std::string& name) {
    const Class& owner = Class::Handle(zone_, pf_->function().Owner());
    if (owner.IsNull()) return -1;
    const String& sym =
        String::Handle(zone_, Symbols::New(thread_, name.c_str()));
    const Field& field = Field::Handle(zone_, owner.LookupInstanceField(sym));
    if (field.IsNull()) return -1;
    return field.Offset();
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

  // Sprint 6: class-side sends (Foo new / a class method) + dart:core aliases.
  RawClass* ResolveClassName(const std::string& name);
  Fragment TranslateClassSend(const Class& cls, MessageNode* node);
  Fragment TranslateSuperSend(MessageNode* node);
  std::string DartSelector(const std::string& st_selector);
  std::string DartGetter(const std::string& st_selector);

  Token::Kind MethodKind(const String& name);
  Fragment Unsupported(Node* node, const char* what);

  ParsedFunction* pf_;
  Thread* thread_;
  Zone* zone_;
  const ZoneGrowableArray<const ICData*>& ic_data_array_;
  intptr_t osr_id_;
  intptr_t next_block_id_;
  Value* stack_;
  intptr_t pending_argument_count_;
  GraphEntryInstr* graph_entry_;
  LocalVariable* this_var_;                       // NULL for a static method
  std::map<std::string, LocalVariable*> locals_;  // params + temps by name
  LocalVariable* value_temp_;                     // reusable control-flow value temp
  std::map<Node*, LocalVariable*> synth_;         // per-node synth temps (to:do: limit, cascade rcvr)
  intptr_t synth_counter_;                        // makes synth-temp names unique
  LocalVariable* closure_var_;                    // the :closure param (closure builds)
  std::vector<LocalVariable*> param_vars_;        // params in frame order (capture copy)
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
  // Receiver `self`/`this` for an instance method; a class-side (static) method
  // has none (Sprint 3 acceptance uses only static methods).
  if (!function.is_static()) {
    LocalVariable* this_var = new (zone_)
        LocalVariable(TokenPosition::kNoSource, TokenPosition::kNoSource,
                      Symbols::This(), Object::dynamic_type());
    scope->InsertParameterAt(pos++, this_var);
    this_var_ = this_var;
    param_vars_.push_back(this_var);
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
  // Stage B: mark every method local referenced under a CLOSURE block as
  // captured — BEFORE AllocateVariables, which then assigns those variables
  // context slots instead of frame slots. (value_temp_ is created after this
  // pass so it can never be captured.)
  for (size_t i = 0; i < method->statements.size(); i++) {
    MarkCapturedInClosures(method->statements[i].get());
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
  return Unsupported(node, "expression");
}

Fragment StGraphBuilder::TranslateLiteral(LiteralNode* node) {
  switch (node->kind) {
    case LiteralNode::Kind::kInt:
      return IntConstant(ParseStInt(node->text));
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
    default:
      return Unsupported(node, "literal (symbol/char/array)");
  }
}

Fragment StGraphBuilder::TranslateVariable(VariableNode* node) {
  if (node->name == "self" || node->name == "super") {
    if (this_var_ != NULL) return LoadLocal(this_var_);
    return Unsupported(node, "self/super in a static method");
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
  return Unsupported(node, "variable (global / class name)");
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
  return Unsupported(node, "assignment to non-local");
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
    }
  }

  // `x yourself` -> x (identity): just the receiver's value.
  if (node->selector == "yourself" && node->args.empty()) {
    return TranslateExpression(node->receiver.get());
  }

  // A unary send that bridges to a dart:core GETTER (`x size` -> `x.length`):
  // getters read a value, so they use the mangled name + Token::kGET, not a
  // method call (which would try to invoke the value).
  if (node->args.empty()) {
    const std::string getter = DartGetter(node->selector);
    if (!getter.empty()) {
      Fragment instructions = TranslateExpression(node->receiver.get());
      instructions += PushArgument();
      instructions += Getter(getter);
      return instructions;
    }
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

// A class name resolves to a loaded ST class in the receiver's own library
// (same stLoad). Capitalized identifiers only.
RawClass* StGraphBuilder::ResolveClassName(const std::string& name) {
  if (name.empty() || name[0] < 'A' || name[0] > 'Z') return Class::null();
  const Class& owner = Class::Handle(zone_, pf_->function().Owner());
  if (owner.IsNull()) return Class::null();
  const Library& lib = Library::Handle(zone_, owner.library());
  if (lib.IsNull()) return Class::null();
  const String& sym = String::Handle(zone_, Symbols::New(thread_, name.c_str()));
  return lib.LookupLocalClass(sym);
}

// `Foo <sel>`: a class-side (static) method wins; otherwise `new`/`basicNew`
// allocates a fresh instance. (Class-side method names are NOT aliased —
// aliases are for dart:core sends, not user methods.)
Fragment StGraphBuilder::TranslateClassSend(const Class& cls,
                                            MessageNode* node) {
  // Member-finalize the target class first — LookupStaticFunction would
  // otherwise route through EnsureIsFinalized -> the Dart parser, which crashes
  // on a TokenStream-less ST class (same guard as st_natives.cc).
  if (!cls.is_finalized()) ClassFinalizer::FinalizeClass(cls);
  const String& sel =
      String::Handle(zone_, Symbols::New(thread_, node->selector.c_str()));
  // Zone handle: StaticCallInstr keeps the Function past this HANDLESCOPE (and
  // asserts IsZoneHandle).
  const Function& fn =
      Function::ZoneHandle(zone_, cls.LookupStaticFunction(sel));
  if (!fn.IsNull()) {
    Fragment instructions;  // static call: push args only (no receiver)
    for (size_t i = 0; i < node->args.size(); i++) {
      instructions += TranslateExpression(node->args[i].get());
      instructions += PushArgument();
    }
    instructions += StaticCall(fn, static_cast<intptr_t>(node->args.size()));
    return instructions;
  }
  if ((node->selector == "new" || node->selector == "basicNew") &&
      node->args.empty()) {
    return AllocateObject(cls);
  }
  return Unsupported(node, "class-side send (no matching class method)");
}

// `super sel: ..`: resolve the method starting in the OWNER's superclass and
// emit a StaticCall with self as argument 0 (an instance method's receiver).
// Walks the super chain (LookupDynamicFunction is per class), finalizing each
// visited class on demand.
Fragment StGraphBuilder::TranslateSuperSend(MessageNode* node) {
  const Class& owner = Class::Handle(zone_, pf_->function().Owner());
  const String& sel =
      String::Handle(zone_, Symbols::New(thread_, node->selector.c_str()));
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
  // Closure invocation: the runtime's IC-miss path invokes a closure receiver
  // sent `call` (runtime_entry.cc:1575), so the whole value* family lowers to
  // one selector. KNOWN CONFLICT: an ST class defining its own `value`/`value:`
  // method is unreachable via these selectors (the send becomes `call`); the
  // fix — dual-registering such methods under `call` in the loader — is
  // deferred until corpus code needs it.
  if (s == "value" || s == "value:" || s == "value:value:" ||
      s == "value:value:value:" || s == "value:value:value:value:") {
    return "call";
  }
  if (s == "=") return "==";
  if (s == "printString" || s == "displayString" || s == "asString") {
    return "toString";
  }
  if (s == "at:") return "[]";
  if (s == "at:put:") return "[]=";
  if (s == ",") return "+";
  return s;
}

// ST unary selectors that bridge to a dart:core GETTER (not a method). Empty
// means "not a getter alias" — fall through to a normal send.
std::string StGraphBuilder::DartGetter(const std::string& s) {
  if (s == "size") return "length";
  if (s == "hash") return "hashCode";
  if (s == "isEmpty") return "isEmpty";
  if (s == "isNotEmpty" || s == "notEmpty") return "isNotEmpty";
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
    // A closure: everything referenced beneath it captures.
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

// Under a closure: mark every referenced name that is a method local (or self)
// as captured. Recurses through everything, including nested blocks.
void StGraphBuilder::MarkFreeNames(Node* node) {
  if (node == NULL) return;
  if (VariableNode* v = dynamic_cast<VariableNode*>(node)) {
    if (v->name == "self" || v->name == "super") {
      if (this_var_ != NULL) this_var_->set_is_captured();
    } else {
      std::map<std::string, LocalVariable*>::iterator it =
          locals_.find(v->name);
      if (it != locals_.end()) it->second->set_is_captured();
    }
  } else if (AssignNode* a = dynamic_cast<AssignNode*>(node)) {
    std::map<std::string, LocalVariable*>::iterator it =
        locals_.find(a->name);
    if (it != locals_.end()) it->second->set_is_captured();
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

bool StGraphBuilder::IsInlinableControlFlow(MessageNode* node) {
  const std::string& s = node->selector;
  if (s == "ifTrue:" || s == "ifFalse:" || s == "and:" || s == "or:") {
    return node->args.size() == 1 && IsBlockNode(node->args[0].get());
  }
  if (s == "ifTrue:ifFalse:" || s == "ifFalse:ifTrue:") {
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

  return Unsupported(node, "control-flow selector");
}

// recv m1; m2; m3  ->  eval recv once into a temp, send each message to it; the
// cascade's value is the last message's result.
Fragment StGraphBuilder::TranslateCascade(CascadeNode* node) {
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
    instructions += LoadLocal(recv);
    instructions += PushArgument();
    for (size_t a = 0; a < m->args.size(); a++) {
      instructions += TranslateExpression(m->args[a].get());
      instructions += PushArgument();
    }
    const String& sel =
        String::ZoneHandle(zone_, Symbols::New(thread_, m->selector.c_str()));
    const Token::Kind kind = MethodKind(sel);
    const intptr_t argc = 1 + static_cast<intptr_t>(m->args.size());
    const intptr_t nchecked = (kind != Token::kILLEGAL) ? argc : 1;
    instructions += InstanceCall(sel, kind, argc, nchecked);  // pushes result
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
    fn.set_is_inlinable(false);  // same inliner-misroute guard as ST methods
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

  intptr_t pos = 0;
  LocalVariable* closure_var = MakeLocal(":closure");
  scope->InsertParameterAt(pos++, closure_var);
  closure_var_ = closure_var;
  for (size_t i = 0; i < block->args.size(); i++) {
    LocalVariable* v = MakeLocal(block->args[i]);
    scope->InsertParameterAt(pos++, v);
    locals_[block->args[i]] = v;
  }
  for (size_t i = 0; i < block->temps.size(); i++) {
    LocalVariable* v = MakeLocal(block->temps[i]);
    scope->AddVariable(v);
    locals_[block->temps[i]] = v;
  }
  for (size_t i = 0; i < block->statements.size(); i++) {
    CollectLocals(block->statements[i].get(), scope);
  }
  value_temp_ = MakeLocal(":cfval");
  scope->AddVariable(value_temp_);

  pf_->AllocateVariables();
}

FlowGraph* StGraphBuilder::BuildClosure(BlockNode* block) {
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

  if (HasReturn(block)) {
    // `^` inside a first-class closure is a NON-LOCAL return (Stage C); until
    // then the closure conservatively evaluates to nil, loudly.
    OS::PrintErr(
        "st::BuildClosure: non-local ^ in a closure at %d:%d (Stage C) — "
        "closure yields nil\n",
        block->pos.line, block->pos.col);
    body += NullConstant();
  } else {
    body += InlineBlockValue(block);  // the last statement's value (or nil)
  }
  if (body.is_open()) body += Return();

  normal_entry->LinkTo(body.entry);
  return new (zone_) FlowGraph(*pf_, graph_entry_, next_block_id_ - 1);
}

Fragment StGraphBuilder::TranslateStatement(Node* node) {
  if (ReturnNode* r = dynamic_cast<ReturnNode*>(node)) {
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

FlowGraph* StGraphBuilder::Build(MethodNode* method) {
  PrepareScope(method);

  // Graph root: normal_entry (block id 1) wrapped in the GraphEntry (block 0).
  TargetEntryInstr* normal_entry = BuildTargetEntry();
  graph_entry_ =
      new (zone_) GraphEntryInstr(*pf_, normal_entry, osr_id_);

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

  body += TranslateStatements(method->statements);

  // Guarantee the body is closed on every path (invariant #1): a method with no
  // explicit `^` returns null (self-return desugaring is Sprint 5).
  if (body.is_open()) {
    body += NullConstant();
    body += Return();
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

}  // namespace st
