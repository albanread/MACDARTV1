// MACVM Smalltalk (.mst) reader — AST node types.
//
// Sprint 0 of ST_PLAN.md: a standalone, pure-C++17 language reader for the
// GNU-Smalltalk-style bracketed .mst dialect. NO Dart-VM dependencies.
//
// The AST is a small tree of value-type nodes held by std::unique_ptr. Nodes
// carry a source line/col so the dumper (and later sprints) can report
// locations. Everything here is header-only and depends on nothing but the C++
// standard library.

#ifndef MACDART_ST_ST_AST_H_
#define MACDART_ST_ST_AST_H_

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace st {

// Source position, 1-based, as reported by the lexer.
struct SrcPos {
  int line = 0;
  int col = 0;
  int offset = 0;    // absolute byte offset into the source (debug info)
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

struct Node {
  SrcPos pos;
  virtual ~Node() = default;
};

using NodePtr = std::unique_ptr<Node>;

// A literal atom: integer, float, string, symbol, char, nil/true/false, or a
// nested literal array / byte array. `kind` names the flavour; the payload
// fields used depend on the kind.
struct LiteralNode : Node {
  enum class Kind {
    kInt,
    kFloat,
    kString,
    kSymbol,
    kChar,
    kNil,
    kTrue,
    kFalse,
    kArray,      // #( ... ) literal array; elements in `elements`
    kByteArray,  // #[ ... ] byte array; bytes in `elements` (each a kInt)
  };
  Kind kind = Kind::kNil;
  // Textual value: for kInt/kFloat the numeric text, for kString the decoded
  // string contents, for kSymbol the symbol text (without the leading '#'),
  // for kChar the single character.
  std::string text;
  // For kArray / kByteArray.
  std::vector<NodePtr> elements;
};

// A variable reference or pseudo-variable (self/super/thisContext). Pseudo-vars
// nil/true/false are parsed as literals; self/super/thisContext are variables.
struct VariableNode : Node {
  std::string name;
};

// Assignment: `name := value` (chained assignments nest on the value side).
struct AssignNode : Node {
  std::string name;
  NodePtr value;
};

// `^expr` return.
struct ReturnNode : Node {
  NodePtr value;
};

// Dynamic array: `{ e. e. e }`.
struct DynArrayNode : Node {
  std::vector<NodePtr> elements;
};

// A block: `[ :a :b | | t | stmts ]`.
struct BlockNode : Node {
  std::vector<std::string> args;
  std::vector<std::string> temps;
  std::vector<NodePtr> statements;
};

// A message send. `selector` is the full selector: "foo" (unary), "+" (binary),
// or "at:put:" (keyword). `args` holds the argument expressions (empty for
// unary). `receiver` is the receiver expression.
struct MessageNode : Node {
  enum class Kind { kUnary, kBinary, kKeyword };
  Kind kind = Kind::kUnary;
  NodePtr receiver;
  std::string selector;
  std::vector<NodePtr> args;
};

// A cascade: a receiver plus a series of messages all sent to it via ';'.
// Each message in `messages` is a MessageNode whose `receiver` is null (the
// cascade supplies the shared receiver).
struct CascadeNode : Node {
  NodePtr receiver;
  std::vector<NodePtr> messages;
};

// ---------------------------------------------------------------------------
// Methods and top-level declarations
// ---------------------------------------------------------------------------

// A raw pragma, e.g. `<primitive: FFI function: #kqueue ret: #g args: #()>`.
// We capture the raw token text between the angle brackets (Sprint 0 does not
// interpret pragmas); `text` is a space-joined reconstruction.
struct Pragma {
  SrcPos pos;
  std::string text;
};

// A method definition: selector pattern + args, pragmas, temps, body.
struct MethodNode : Node {
  bool is_class_side = false;  // `Foo class >> ...` or class-side in body.
  std::string selector;        // full selector text
  std::vector<std::string> args;
  std::vector<Pragma> pragmas;
  std::vector<std::string> temps;
  std::vector<NodePtr> statements;
  int end_offset = 0;          // byte offset just past the closing ']' (debug)
};

// Instance-variable declaration block: `| a b |` inside a class body.
struct VarDeclNode : Node {
  std::vector<std::string> names;
};

// A class definition: `<superExpr> subclass: Name [ body ]`.
// The class body is a mix of var decls, pragmas, and methods.
struct ClassDefNode : Node {
  std::string superclass;  // textual name of the superclass expression
  std::string name;
  std::vector<Pragma> pragmas;
  std::vector<std::unique_ptr<VarDeclNode>> ivars;
  std::vector<std::unique_ptr<MethodNode>> methods;
};

// External / top-level method: `Foo >> pattern [ body ]` or
// `Foo class >> pattern [ body ]`.
struct ExtMethodNode : Node {
  std::string class_name;
  std::unique_ptr<MethodNode> method;
};

// `Foo extend [ ... ]` or `Foo class extend [ ... ]`.
struct ExtendNode : Node {
  std::string class_name;
  bool is_class_side = false;
  std::vector<Pragma> pragmas;
  std::vector<std::unique_ptr<VarDeclNode>> ivars;
  std::vector<std::unique_ptr<MethodNode>> methods;
};

// The whole file: an ordered list of top-level items (class defs, external
// methods, extends, and bare "do-it" statements/expressions).
struct ProgramNode : Node {
  std::vector<NodePtr> items;
};

}  // namespace st

#endif  // MACDART_ST_ST_AST_H_
