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

#include <map>
#include <string>
#include <vector>

#include "st_ast.h"

#include "vm/ast.h"                   // SequenceNode
#include "vm/flow_graph.h"            // FlowGraph
#include "vm/intermediate_language.h" // all the *Instr, Value, Definition
#include "vm/object.h"                // Function, Class, Type, Integer, Bool...
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
        synth_counter_(0) {}

  FlowGraph* Build(MethodNode* method);

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
    LoadLocalInstr* load =
        new (zone_) LoadLocalInstr(*variable, TokenPosition::kNoSource);
    Push(load);
    return Fragment(load);
  }
  Fragment StoreLocal(LocalVariable* variable) {
    Value* value = Pop();
    StoreLocalInstr* store = new (zone_)
        StoreLocalInstr(*variable, value, TokenPosition::kNoSource);
    Push(store);
    return Fragment(store);
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
  void AddLocalName(const std::string& name, LocalScope* scope);
  LocalVariable* AllocSynth(Node* node, const char* prefix, LocalScope* scope);

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
  }
  // One parameter LocalVariable per selector argument.
  for (size_t i = 0; i < method->args.size(); i++) {
    LocalVariable* v = MakeLocal(method->args[i]);
    scope->InsertParameterAt(pos++, v);
    locals_[method->args[i]] = v;
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
    default:
      return Unsupported(node, "literal (string/float/symbol/char/array)");
  }
}

Fragment StGraphBuilder::TranslateVariable(VariableNode* node) {
  if (node->name == "self" || node->name == "super") {
    if (this_var_ != NULL) return LoadLocal(this_var_);
    return Unsupported(node, "self/super in a static method");
  }
  LocalVariable* local = LookupLocal(node->name);
  if (local != NULL) return LoadLocal(local);
  return Unsupported(node, "variable (instance var / global)");
}

Fragment StGraphBuilder::TranslateAssign(AssignNode* node) {
  LocalVariable* local = LookupLocal(node->name);
  if (local == NULL) return Unsupported(node, "assignment to non-local");
  Fragment instructions = TranslateExpression(node->value.get());
  instructions += StoreLocal(local);  // pops value, leaves stored value on stack
  return instructions;
}

Fragment StGraphBuilder::TranslateMessage(MessageNode* node) {
  if (node->receiver == nullptr) {
    return Unsupported(node, "cascade message (no receiver)");
  }
  Fragment instructions = TranslateExpression(node->receiver.get());
  instructions += PushArgument();
  for (size_t i = 0; i < node->args.size(); i++) {
    instructions += TranslateExpression(node->args[i].get());
    instructions += PushArgument();
  }
  const String& selector =
      String::ZoneHandle(zone_, Symbols::New(thread_, node->selector.c_str()));
  const Token::Kind kind = MethodKind(selector);
  const intptr_t argument_count = 1 + static_cast<intptr_t>(node->args.size());
  // Operators type-check every argument (guide §2.4); a plain send checks 1.
  const intptr_t num_args_checked =
      (kind != Token::kILLEGAL) ? argument_count : 1;
  instructions += InstanceCall(selector, kind, argument_count, num_args_checked);
  return instructions;
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
    CollectLocals(m->receiver.get(), scope);
    for (size_t i = 0; i < m->args.size(); i++) {
      CollectLocals(m->args[i].get(), scope);
    }
    if (m->selector == "to:do:" && m->args.size() == 2 &&
        IsBlockNode(m->args[1].get())) {
      AllocSynth(m, "lim", scope);
    }
  } else if (BlockNode* b = dynamic_cast<BlockNode*>(node)) {
    for (size_t i = 0; i < b->args.size(); i++) AddLocalName(b->args[i], scope);
    for (size_t i = 0; i < b->temps.size(); i++) AddLocalName(b->temps[i], scope);
    for (size_t i = 0; i < b->statements.size(); i++) {
      CollectLocals(b->statements[i].get(), scope);
    }
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
  // Recover the ST method node from the marker the loader stamped
  // (ST_PLAN.md §2.2): kernel_function() is reused as the st::MethodNode*.
  MethodNode* method =
      reinterpret_cast<MethodNode*>(pf->function().kernel_function());
  ASSERT(method != NULL);
  StGraphBuilder builder(pf, ic_data_array, osr_id);
  FlowGraph* graph = builder.Build(method);
  ASSERT(graph != NULL);
  return graph;
}

}  // namespace st
