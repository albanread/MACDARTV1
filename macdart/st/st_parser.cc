// MACVM Smalltalk (.mst) reader — recursive-descent parser implementation.

#include "st_parser.h"

#include <utility>

namespace st {

namespace {

// SrcPos from a token, carrying its absolute byte offset (Sprint 16 debug).
static inline SrcPos PosOf(const Token& t) { return {t.line, t.col, t.offset}; }

// Renders a token back to an approximate source form, used only for
// reconstructing raw pragma text (Sprint 0 does not interpret pragmas).
std::string TokenToSource(const Token& t) {
  switch (t.kind) {
    case Tok::kSymbol:
      return "#" + t.text;
    case Tok::kChar:
      return "$" + t.text;
    case Tok::kString:
      return "'" + t.text + "'";
    default:
      return t.text;
  }
}

bool IsPseudoLiteral(const std::string& s) {
  return s == "nil" || s == "true" || s == "false";
}

}  // namespace

Parser::Parser(std::vector<Token> tokens) : toks_(std::move(tokens)) {}

const Token& Parser::Cur() const { return toks_[pos_]; }

const Token& Parser::PeekTok(int ahead) const {
  size_t p = pos_ + static_cast<size_t>(ahead);
  if (p >= toks_.size()) return toks_.back();  // EOF
  return toks_[p];
}

bool Parser::Is(Tok k) const { return Cur().kind == k; }

bool Parser::IsKeyword(const std::string& kw) const {
  return Cur().kind == Tok::kIdent && Cur().text == kw;
}

Token Parser::Take() {
  Token t = toks_[pos_];
  if (pos_ + 1 < toks_.size()) pos_++;
  return t;
}

bool Parser::Accept(Tok k) {
  if (Is(k)) {
    Take();
    return true;
  }
  return false;
}

bool Parser::Expect(Tok k, const char* what) {
  if (Is(k)) {
    Take();
    return true;
  }
  Fail(Cur(), std::string("expected ") + what);
  return false;
}

void Parser::Fail(const Token& at, const std::string& msg) {
  if (!err_.ok) return;  // keep the first error
  err_.ok = false;
  err_.line = at.line;
  err_.col = at.col;
  err_.message = msg;
}

// ---------------------------------------------------------------------------
// Program / top level
// ---------------------------------------------------------------------------

std::unique_ptr<ProgramNode> Parser::ParseProgram(ParseError* err) {
  auto prog = std::make_unique<ProgramNode>();
  prog->pos = PosOf(Cur());
  while (!Is(Tok::kEof) && !failed()) {
    NodePtr item = ParseTopLevelItem();
    if (failed()) break;
    if (item) prog->items.push_back(std::move(item));
    // Optional statement separators between top-level items / do-its.
    while (Accept(Tok::kDot)) {
    }
  }
  if (failed()) {
    *err = err_;
    return nullptr;
  }
  err->ok = true;
  return prog;
}

NodePtr Parser::ParseTopLevelItem() {
  // Sprint 11c: top-level `| a b |` — temporaries for the file's do-it
  // statements (the loader folds them into STMain>>main's temps).
  if (Is(Tok::kBar)) {
    auto d = std::make_unique<VarDeclNode>();
    d->pos = PosOf(Cur());
    ParseTempsOpt(&d->names);
    return d;
  }
  // External / extend forms are introduced by a class name identifier.
  if (Is(Tok::kIdent)) {
    const Token& n1 = PeekTok(1);
    // Foo >> pattern [ ... ]
    if (n1.kind == Tok::kBinary && n1.text == ">>") {
      Token cls = Take();  // class name
      Take();              // >>
      auto m = ParseMethod(/*is_class_side=*/false);
      if (failed()) return nullptr;
      auto e = std::make_unique<ExtMethodNode>();
      e->pos = PosOf(cls);
      e->class_name = cls.text;
      e->method = std::move(m);
      return e;
    }
    // Foo class >> pattern [ ... ]   or   Foo class extend [ ... ]
    if (n1.kind == Tok::kIdent && n1.text == "class") {
      const Token& n2 = PeekTok(2);
      if (n2.kind == Tok::kBinary && n2.text == ">>") {
        Token cls = Take();  // class name
        Take();              // class
        Take();              // >>
        auto m = ParseMethod(/*is_class_side=*/true);
        if (failed()) return nullptr;
        auto e = std::make_unique<ExtMethodNode>();
        e->pos = PosOf(cls);
        e->class_name = cls.text;
        e->method = std::move(m);
        return e;
      }
      if (n2.kind == Tok::kIdent && n2.text == "extend") {
        Token cls = Take();  // class name
        Take();              // class
        Take();              // extend
        auto e = std::make_unique<ExtendNode>();
        e->pos = PosOf(cls);
        e->class_name = cls.text;
        e->is_class_side = true;
        Expect(Tok::kLBracket, "'[' to open extend body");
        ParseClassBody(&e->pragmas, &e->ivars, &e->methods);
        Expect(Tok::kRBracket, "']' to close extend body");
        return e;
      }
    }
    // Foo extend [ ... ]
    if (n1.kind == Tok::kIdent && n1.text == "extend") {
      Token cls = Take();  // class name
      Take();              // extend
      auto e = std::make_unique<ExtendNode>();
      e->pos = PosOf(cls);
      e->class_name = cls.text;
      e->is_class_side = false;
      Expect(Tok::kLBracket, "'[' to open extend body");
      ParseClassBody(&e->pragmas, &e->ivars, &e->methods);
      Expect(Tok::kRBracket, "']' to close extend body");
      return e;
    }
  }

  // Otherwise: a do-it statement, which may actually be a class definition
  // (`Super subclass: Name [ ... ]` — an ordinary keyword send special-cased).
  Token start = Cur();
  NodePtr node = ParseStatement();
  if (failed()) return nullptr;

  auto* msg = dynamic_cast<MessageNode*>(node.get());
  if (msg && msg->kind == MessageNode::Kind::kKeyword &&
      msg->selector == "subclass:" && Is(Tok::kLBracket)) {
    std::string super_name = "?";
    if (auto* v = dynamic_cast<VariableNode*>(msg->receiver.get())) {
      super_name = v->name;
    }
    std::string class_name;
    if (!msg->args.empty()) {
      if (auto* a = dynamic_cast<VariableNode*>(msg->args[0].get())) {
        class_name = a->name;
      }
    }
    if (class_name.empty()) {
      Fail(start, "subclass: expects an identifier class name");
      return nullptr;
    }
    auto cd = ParseClassDef(super_name, start);
    if (failed()) return nullptr;
    cd->name = class_name;
    return cd;
  }
  return node;
}

std::unique_ptr<ClassDefNode> Parser::ParseClassDef(
    const std::string& super_name, const Token& start) {
  auto cd = std::make_unique<ClassDefNode>();
  cd->pos = PosOf(start);
  cd->superclass = super_name;
  Expect(Tok::kLBracket, "'[' to open class body");
  ParseClassBody(&cd->pragmas, &cd->ivars, &cd->methods);
  Expect(Tok::kRBracket, "']' to close class body");
  return cd;
}

void Parser::ParseClassBody(
    std::vector<Pragma>* pragmas,
    std::vector<std::unique_ptr<VarDeclNode>>* ivars,
    std::vector<std::unique_ptr<MethodNode>>* methods) {
  while (!Is(Tok::kRBracket) && !Is(Tok::kEof) && !failed()) {
    // Binary method named `|` (the union / or operator): `| arg [ ... ]` or
    // `| arg ^ <Type> [ ... ]`. Distinguished from an instance-variable list
    // (`| a b |`) by an argument name followed immediately by the method body
    // `[` or a return-type `^` — neither of which can appear in an ivar list.
    // (An *annotated* `| arg <Type> [ … ]` form stays ambiguous with a typed
    // ivar list; MACVM's own sources omit the annotation here to avoid it.)
    if (Is(Tok::kBar) && PeekTok(1).kind == Tok::kIdent &&
        (PeekTok(2).kind == Tok::kLBracket || PeekTok(2).kind == Tok::kCaret)) {
      auto m = ParseMethod(/*is_class_side=*/false);
      if (failed()) return;
      methods->push_back(std::move(m));
      continue;
    }
    // Instance-variable declaration: | a b |
    if (Is(Tok::kBar)) {
      Token bar = Take();
      auto vd = std::make_unique<VarDeclNode>();
      vd->pos = PosOf(bar);
      while (Is(Tok::kIdent)) {
        vd->names.push_back(Take().text);
        SkipTypeAnnotationOpt();  // optional `<Type>` after an ivar name
      }
      Expect(Tok::kBar, "'|' to close instance-variable list");
      ivars->push_back(std::move(vd));
      continue;
    }
    // Class-body pragma: < keyword: ... >
    if (Is(Tok::kBinary) && Cur().text == "<" &&
        PeekTok(1).kind == Tok::kKeyword) {
      pragmas->push_back(ParsePragma());
      continue;
    }
    // Class-side method: Foo class >> pattern [ ... ]
    if (Is(Tok::kIdent) && PeekTok(1).kind == Tok::kIdent &&
        PeekTok(1).text == "class" && PeekTok(2).kind == Tok::kBinary &&
        PeekTok(2).text == ">>") {
      Take();  // receiver name
      Take();  // class
      Take();  // >>
      auto m = ParseMethod(/*is_class_side=*/true);
      if (failed()) return;
      methods->push_back(std::move(m));
      continue;
    }
    // Otherwise: an instance method (unary / binary / keyword pattern).
    auto m = ParseMethod(/*is_class_side=*/false);
    if (failed()) return;
    methods->push_back(std::move(m));
  }
}

std::unique_ptr<MethodNode> Parser::ParseMethod(bool is_class_side) {
  auto m = std::make_unique<MethodNode>();
  m->pos = PosOf(Cur());
  m->is_class_side = is_class_side;
  ParseMethodPattern(m.get());
  if (failed()) return m;
  Expect(Tok::kLBracket, "'[' to open method body");
  // Prologue: any mix of pragmas and a temporaries declaration.
  for (;;) {
    if (Is(Tok::kBinary) && Cur().text == "<" &&
        PeekTok(1).kind == Tok::kKeyword) {
      m->pragmas.push_back(ParsePragma());
      continue;
    }
    if (Is(Tok::kBar)) {
      ParseTempsOpt(&m->temps);
      continue;
    }
    break;
  }
  ParseStatements(&m->statements, Tok::kRBracket);
  m->end_offset = Cur().offset + 1;  // the ']' (Cur before Expect consumes it)
  Expect(Tok::kRBracket, "']' to close method body");
  return m;
}

void Parser::ParseMethodPattern(MethodNode* m) {
  if (Is(Tok::kKeyword)) {
    std::string sel;
    while (Is(Tok::kKeyword)) {
      sel += Take().text;  // includes trailing ':'
      if (!Is(Tok::kIdent)) {
        Fail(Cur(), "expected argument name after keyword");
        return;
      }
      m->args.push_back(Take().text);
      SkipTypeAnnotationOpt();  // optional `<Type>` after the argument name
    }
    m->selector = sel;
  } else if (Is(Tok::kBinary) || Is(Tok::kBar)) {
    m->selector = Take().text;  // binary selector (or '|')
    if (!Is(Tok::kIdent)) {
      Fail(Cur(), "expected argument name in binary method pattern");
      return;
    }
    m->args.push_back(Take().text);
    SkipTypeAnnotationOpt();  // optional `<Type>` after the argument name
  } else if (Is(Tok::kIdent)) {
    m->selector = Take().text;  // unary selector
  } else {
    Fail(Cur(), "expected a method selector pattern");
  }

  // Optional MACVM return-type annotation: `^ <Type>` before the body `[`.
  if (Is(Tok::kCaret) && PeekTok(1).kind == Tok::kBinary &&
      PeekTok(1).text == "<") {
    Take();  // '^'
    SkipTypeAnnotationOpt();
  }
}

// Consumes an optional MACVM `<Type>` annotation. Only valid in signature
// positions (see header). The type expression is discarded. It may be a simple
// name (`<Integer>`), a union (`<A|B>`), or a block type (`<[Object,^Boolean]>`)
// — none of which contain a top-level `>`, so we consume tokens up to the
// closing `>`. `<` and `>` each lex as a single kBinary token here because they
// are followed by a non-binary character (identifier or `[`).
bool Parser::SkipTypeAnnotationOpt() {
  if (!(Is(Tok::kBinary) && Cur().text == "<")) return false;
  Take();  // '<'
  while (!Is(Tok::kEof) && !(Is(Tok::kBinary) && Cur().text == ">")) {
    Take();
  }
  if (Is(Tok::kBinary) && Cur().text == ">") {
    Take();  // '>'
  } else {
    Fail(Cur(), "unterminated type annotation (missing '>')");
  }
  return true;
}

Pragma Parser::ParsePragma() {
  Pragma p;
  Token open = Take();  // '<'
  p.pos = PosOf(open);
  std::string text;
  bool first = true;
  while (!Is(Tok::kEof) && !Is(Tok::kRBracket)) {
    if (Is(Tok::kBinary) && Cur().text == ">") {
      Take();  // closing '>'
      p.text = text;
      return p;
    }
    if (!first) text += " ";
    first = false;
    text += TokenToSource(Take());
  }
  Fail(Cur(), "unterminated pragma (missing '>')");
  p.text = text;
  return p;
}

bool Parser::ParseTempsOpt(std::vector<std::string>* out) {
  if (!Is(Tok::kBar)) return false;
  Take();  // opening '|'
  while (Is(Tok::kIdent)) out->push_back(Take().text);
  Expect(Tok::kBar, "'|' to close temporaries");
  return true;
}

void Parser::ParseStatements(std::vector<NodePtr>* out, Tok terminator) {
  while (!Is(terminator) && !Is(Tok::kEof) && !failed()) {
    NodePtr s = ParseStatement();
    if (failed()) return;
    out->push_back(std::move(s));
    if (!Accept(Tok::kDot)) break;  // no separator => end of statements
    // Allow (and skip) additional dots / trailing dot before terminator.
    while (Accept(Tok::kDot)) {
    }
  }
}

// ---------------------------------------------------------------------------
// Statements & expressions
// ---------------------------------------------------------------------------

NodePtr Parser::ParseStatement() {
  if (Is(Tok::kCaret)) {
    Token caret = Take();
    auto r = std::make_unique<ReturnNode>();
    r->pos = PosOf(caret);
    r->value = ParseExpression();
    return r;
  }
  return ParseExpression();
}

NodePtr Parser::ParseExpression() {
  // Assignment: ident := expr  (right-associative / chained).
  if (Is(Tok::kIdent) && PeekTok(1).kind == Tok::kAssign) {
    Token name = Take();
    Take();  // :=
    auto a = std::make_unique<AssignNode>();
    a->pos = PosOf(name);
    a->name = name.text;
    a->value = ParseExpression();
    return a;
  }
  return ParseCascadeOrKeyword();
}

NodePtr Parser::ParseCascadeOrKeyword() {
  NodePtr node = ParseKeywordMessage();
  if (failed() || !Is(Tok::kSemi)) return node;

  // Build a cascade. The shared receiver is the receiver of the last message
  // parsed before the first ';'.
  auto* msg = dynamic_cast<MessageNode*>(node.get());
  if (!msg) {
    Fail(Cur(), "';' cascade must follow a message send");
    return node;
  }
  auto casc = std::make_unique<CascadeNode>();
  casc->pos = node->pos;
  casc->receiver = std::move(msg->receiver);

  // First cascade message = the parsed message with its receiver removed.
  auto first = std::make_unique<MessageNode>();
  first->pos = msg->pos;
  first->kind = msg->kind;
  first->selector = msg->selector;
  first->args = std::move(msg->args);
  casc->messages.push_back(std::move(first));

  while (Accept(Tok::kSemi) && !failed()) {
    auto cm = std::make_unique<MessageNode>();
    cm->pos = PosOf(Cur());
    if (Is(Tok::kKeyword)) {
      cm->kind = MessageNode::Kind::kKeyword;
      std::string sel;
      while (Is(Tok::kKeyword)) {
        sel += Take().text;
        cm->args.push_back(ParseBinaryMessage());
        if (failed()) return casc;
      }
      cm->selector = sel;
    } else if (Is(Tok::kBinary) || Is(Tok::kBar)) {
      cm->kind = MessageNode::Kind::kBinary;
      cm->selector = Take().text;
      cm->args.push_back(ParseUnaryMessage());
    } else if (Is(Tok::kIdent)) {
      cm->kind = MessageNode::Kind::kUnary;
      cm->selector = Take().text;
    } else {
      Fail(Cur(), "expected a message after ';'");
      return casc;
    }
    casc->messages.push_back(std::move(cm));
  }
  return casc;
}

NodePtr Parser::ParseKeywordMessage() {
  NodePtr recv = ParseBinaryMessage();
  if (failed() || !Is(Tok::kKeyword)) return recv;

  auto msg = std::make_unique<MessageNode>();
  msg->pos = recv->pos;
  msg->kind = MessageNode::Kind::kKeyword;
  msg->receiver = std::move(recv);
  std::string sel;
  while (Is(Tok::kKeyword) && !failed()) {
    sel += Take().text;  // includes trailing ':'
    msg->args.push_back(ParseBinaryMessage());
  }
  msg->selector = sel;
  return msg;
}

NodePtr Parser::ParseBinaryMessage() {
  NodePtr left = ParseUnaryMessage();
  // A lone '|' (kBar) is the binary 'or' operator in expression position.
  while ((Is(Tok::kBinary) || Is(Tok::kBar)) && !failed()) {
    Token op = Take();
    NodePtr right = ParseUnaryMessage();
    auto msg = std::make_unique<MessageNode>();
    msg->pos = left->pos;
    msg->kind = MessageNode::Kind::kBinary;
    msg->receiver = std::move(left);
    msg->selector = op.text;
    msg->args.push_back(std::move(right));
    left = std::move(msg);
  }
  return left;
}

NodePtr Parser::ParseUnaryMessage() {
  NodePtr recv = ParsePrimary();
  while (Is(Tok::kIdent) && !failed()) {
    Token sel = Take();
    auto msg = std::make_unique<MessageNode>();
    msg->pos = recv->pos;
    msg->kind = MessageNode::Kind::kUnary;
    msg->receiver = std::move(recv);
    msg->selector = sel.text;
    recv = std::move(msg);
  }
  return recv;
}

NodePtr Parser::ParsePrimary() {
  switch (Cur().kind) {
    case Tok::kInt:
    case Tok::kFloat:
    case Tok::kString:
    case Tok::kSymbol:
    case Tok::kChar:
    case Tok::kSymbolArray:
    case Tok::kByteArrayL:
      return ParseLiteral();
    case Tok::kIdent: {
      Token t = Take();
      if (IsPseudoLiteral(t.text)) {
        auto lit = std::make_unique<LiteralNode>();
        lit->pos = PosOf(t);
        lit->kind = t.text == "nil"    ? LiteralNode::Kind::kNil
                    : t.text == "true" ? LiteralNode::Kind::kTrue
                                       : LiteralNode::Kind::kFalse;
        lit->text = t.text;
        return lit;
      }
      auto v = std::make_unique<VariableNode>();
      v->pos = PosOf(t);
      v->name = t.text;  // includes self / super / thisContext
      return v;
    }
    case Tok::kLParen: {
      Take();  // '('
      NodePtr e = ParseExpression();
      Expect(Tok::kRParen, "')' to close parenthesised expression");
      return e;
    }
    case Tok::kLBracket:
      return ParseBlock();
    case Tok::kLBrace:
      return ParseDynArray();
    default:
      Fail(Cur(), "expected an expression");
      return nullptr;
  }
}

NodePtr Parser::ParseBlock() {
  Token open = Take();  // '['
  auto b = std::make_unique<BlockNode>();
  b->pos = PosOf(open);
  // Block arguments: (:name)*
  bool had_args = false;
  while (Is(Tok::kColon)) {
    had_args = true;
    Take();  // ':'
    if (!Is(Tok::kIdent)) {
      Fail(Cur(), "expected block argument name after ':'");
      return b;
    }
    b->args.push_back(Take().text);
  }
  // If there were arguments, a '|' terminates the argument list.
  if (had_args) Expect(Tok::kBar, "'|' after block arguments");
  // Optional temporaries: | t u |
  ParseTempsOpt(&b->temps);
  ParseStatements(&b->statements, Tok::kRBracket);
  Expect(Tok::kRBracket, "']' to close block");
  return b;
}

NodePtr Parser::ParseDynArray() {
  Token open = Take();  // '{'
  auto arr = std::make_unique<DynArrayNode>();
  arr->pos = PosOf(open);
  while (!Is(Tok::kRBrace) && !Is(Tok::kEof) && !failed()) {
    arr->elements.push_back(ParseExpression());
    if (!Accept(Tok::kDot)) break;
    while (Accept(Tok::kDot)) {
    }
  }
  Expect(Tok::kRBrace, "'}' to close dynamic array");
  return arr;
}

// ---------------------------------------------------------------------------
// Literals
// ---------------------------------------------------------------------------

NodePtr Parser::ParseLiteral() {
  Token t = Cur();
  switch (t.kind) {
    case Tok::kInt: {
      Take();
      auto lit = std::make_unique<LiteralNode>();
      lit->pos = PosOf(t);
      lit->kind = LiteralNode::Kind::kInt;
      lit->text = t.text;
      return lit;
    }
    case Tok::kFloat: {
      Take();
      auto lit = std::make_unique<LiteralNode>();
      lit->pos = PosOf(t);
      lit->kind = LiteralNode::Kind::kFloat;
      lit->text = t.text;
      return lit;
    }
    case Tok::kString: {
      Take();
      auto lit = std::make_unique<LiteralNode>();
      lit->pos = PosOf(t);
      lit->kind = LiteralNode::Kind::kString;
      lit->text = t.text;
      return lit;
    }
    case Tok::kSymbol: {
      Take();
      auto lit = std::make_unique<LiteralNode>();
      lit->pos = PosOf(t);
      lit->kind = LiteralNode::Kind::kSymbol;
      lit->text = t.text;
      return lit;
    }
    case Tok::kChar: {
      Take();
      auto lit = std::make_unique<LiteralNode>();
      lit->pos = PosOf(t);
      lit->kind = LiteralNode::Kind::kChar;
      lit->text = t.text;
      return lit;
    }
    case Tok::kSymbolArray:
      return ParseLiteralArray();
    case Tok::kByteArrayL:
      return ParseByteArray();
    default:
      Fail(t, "expected a literal");
      return nullptr;
  }
}

NodePtr Parser::ParseLiteralArray() {
  Token open = Take();  // '#('
  auto arr = std::make_unique<LiteralNode>();
  arr->pos = PosOf(open);
  arr->kind = LiteralNode::Kind::kArray;
  while (!Is(Tok::kRParen) && !Is(Tok::kEof) && !failed()) {
    arr->elements.push_back(ParseNestedArrayElement());
  }
  Expect(Tok::kRParen, "')' to close literal array");
  return arr;
}

NodePtr Parser::ParseNestedArrayElement() {
  Token t = Cur();
  switch (t.kind) {
    case Tok::kInt:
    case Tok::kFloat:
    case Tok::kString:
    case Tok::kChar:
    case Tok::kSymbol:
      return ParseLiteral();
    case Tok::kIdent: {
      // Bare identifiers become symbols, except nil/true/false which denote
      // the corresponding literal objects.
      Take();
      auto lit = std::make_unique<LiteralNode>();
      lit->pos = PosOf(t);
      if (t.text == "nil") {
        lit->kind = LiteralNode::Kind::kNil;
      } else if (t.text == "true") {
        lit->kind = LiteralNode::Kind::kTrue;
      } else if (t.text == "false") {
        lit->kind = LiteralNode::Kind::kFalse;
      } else {
        lit->kind = LiteralNode::Kind::kSymbol;
      }
      lit->text = t.text;
      return lit;
    }
    case Tok::kKeyword:
    case Tok::kBinary:
    case Tok::kBar: {
      Take();
      auto lit = std::make_unique<LiteralNode>();
      lit->pos = PosOf(t);
      lit->kind = LiteralNode::Kind::kSymbol;
      lit->text = t.text;
      return lit;
    }
    case Tok::kLParen: {
      // Nested array uses bare parens inside a literal array.
      Take();  // '('
      auto arr = std::make_unique<LiteralNode>();
      arr->pos = PosOf(t);
      arr->kind = LiteralNode::Kind::kArray;
      while (!Is(Tok::kRParen) && !Is(Tok::kEof) && !failed()) {
        arr->elements.push_back(ParseNestedArrayElement());
      }
      Expect(Tok::kRParen, "')' to close nested literal array");
      return arr;
    }
    case Tok::kSymbolArray:
      return ParseLiteralArray();
    case Tok::kByteArrayL:
      return ParseByteArray();
    default:
      Fail(t, "unexpected token in literal array");
      return nullptr;
  }
}

NodePtr Parser::ParseByteArray() {
  Token open = Take();  // '#['
  auto arr = std::make_unique<LiteralNode>();
  arr->pos = PosOf(open);
  arr->kind = LiteralNode::Kind::kByteArray;
  while (!Is(Tok::kRBracket) && !Is(Tok::kEof) && !failed()) {
    if (!Is(Tok::kInt)) {
      Fail(Cur(), "byte array elements must be integers");
      return arr;
    }
    Token b = Take();
    auto lit = std::make_unique<LiteralNode>();
    lit->pos = PosOf(b);
    lit->kind = LiteralNode::Kind::kInt;
    lit->text = b.text;
    arr->elements.push_back(std::move(lit));
  }
  Expect(Tok::kRBracket, "']' to close byte array");
  return arr;
}

}  // namespace st
