// MACVM Smalltalk (.mst) reader — pretty-printing dumper / CLI driver.
//
// Sprint 0 of ST_PLAN.md. Reads a .mst file (path argument) or stdin, parses
// it with the standalone reader, and prints the AST as indented S-expressions.
// On a lex/parse error it prints `file:line:col: message` plus a caret and
// exits non-zero. NO Dart-VM dependencies.

#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "st_ast.h"
#include "st_lexer.h"
#include "st_parser.h"

namespace {

// Renders a string with C-style escaping for readable, unambiguous output.
std::string Quote(const std::string& s) {
  std::string out = "\"";
  for (char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\t': out += "\\t"; break;
      default: out += c; break;
    }
  }
  out += "\"";
  return out;
}

class Dumper {
 public:
  explicit Dumper(std::ostream& os) : os_(os) {}

  void Dump(const st::Node* n, int indent) {
    if (n == nullptr) {
      Indent(indent);
      os_ << "(null)\n";
      return;
    }
    if (auto* p = dynamic_cast<const st::ProgramNode*>(n)) return DumpProgram(p, indent);
    if (auto* c = dynamic_cast<const st::ClassDefNode*>(n)) return DumpClassDef(c, indent);
    if (auto* e = dynamic_cast<const st::ExtMethodNode*>(n)) return DumpExtMethod(e, indent);
    if (auto* e = dynamic_cast<const st::ExtendNode*>(n)) return DumpExtend(e, indent);
    if (auto* m = dynamic_cast<const st::MethodNode*>(n)) return DumpMethod(m, indent);
    if (auto* v = dynamic_cast<const st::VarDeclNode*>(n)) return DumpVarDecl(v, indent);
    if (auto* r = dynamic_cast<const st::ReturnNode*>(n)) return DumpReturn(r, indent);
    if (auto* a = dynamic_cast<const st::AssignNode*>(n)) return DumpAssign(a, indent);
    if (auto* c = dynamic_cast<const st::CascadeNode*>(n)) return DumpCascade(c, indent);
    if (auto* m = dynamic_cast<const st::MessageNode*>(n)) return DumpMessage(m, indent);
    if (auto* b = dynamic_cast<const st::BlockNode*>(n)) return DumpBlock(b, indent);
    if (auto* d = dynamic_cast<const st::DynArrayNode*>(n)) return DumpDynArray(d, indent);
    if (auto* l = dynamic_cast<const st::LiteralNode*>(n)) return DumpLiteral(l, indent);
    if (auto* v = dynamic_cast<const st::VariableNode*>(n)) return DumpVariable(v, indent);
    Indent(indent);
    os_ << "(unknown-node)\n";
  }

 private:
  void Indent(int n) {
    for (int i = 0; i < n; i++) os_ << "  ";
  }

  void DumpProgram(const st::ProgramNode* p, int indent) {
    Indent(indent);
    os_ << "(program\n";
    for (const auto& item : p->items) Dump(item.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpClassDef(const st::ClassDefNode* c, int indent) {
    Indent(indent);
    os_ << "(classdef :super " << c->superclass << " :name " << c->name << "\n";
    for (const auto& pr : c->pragmas) {
      Indent(indent + 1);
      os_ << "(pragma " << Quote(pr.text) << ")\n";
    }
    for (const auto& iv : c->ivars) Dump(iv.get(), indent + 1);
    for (const auto& m : c->methods) Dump(m.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpExtMethod(const st::ExtMethodNode* e, int indent) {
    Indent(indent);
    os_ << "(ext-method :class " << e->class_name
        << (e->method->is_class_side ? " :class-side" : "") << "\n";
    Dump(e->method.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpExtend(const st::ExtendNode* e, int indent) {
    Indent(indent);
    os_ << "(extend :class " << e->class_name
        << (e->is_class_side ? " :class-side" : "") << "\n";
    for (const auto& pr : e->pragmas) {
      Indent(indent + 1);
      os_ << "(pragma " << Quote(pr.text) << ")\n";
    }
    for (const auto& iv : e->ivars) Dump(iv.get(), indent + 1);
    for (const auto& m : e->methods) Dump(m.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpMethod(const st::MethodNode* m, int indent) {
    Indent(indent);
    os_ << "(method" << (m->is_class_side ? " :class-side" : "")
        << " :selector " << m->selector;
    if (!m->args.empty()) {
      os_ << " :args (";
      for (size_t i = 0; i < m->args.size(); i++) {
        if (i) os_ << " ";
        os_ << m->args[i];
      }
      os_ << ")";
    }
    os_ << "\n";
    for (const auto& pr : m->pragmas) {
      Indent(indent + 1);
      os_ << "(pragma " << Quote(pr.text) << ")\n";
    }
    if (!m->temps.empty()) {
      Indent(indent + 1);
      os_ << "(temps";
      for (const auto& t : m->temps) os_ << " " << t;
      os_ << ")\n";
    }
    for (const auto& s : m->statements) Dump(s.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpVarDecl(const st::VarDeclNode* v, int indent) {
    Indent(indent);
    os_ << "(ivars";
    for (const auto& n : v->names) os_ << " " << n;
    os_ << ")\n";
  }

  void DumpReturn(const st::ReturnNode* r, int indent) {
    Indent(indent);
    os_ << "(return\n";
    Dump(r->value.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpAssign(const st::AssignNode* a, int indent) {
    Indent(indent);
    os_ << "(assign " << a->name << "\n";
    Dump(a->value.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpCascade(const st::CascadeNode* c, int indent) {
    Indent(indent);
    os_ << "(cascade\n";
    Indent(indent + 1);
    os_ << ":receiver\n";
    Dump(c->receiver.get(), indent + 2);
    for (const auto& m : c->messages) Dump(m.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpMessage(const st::MessageNode* m, int indent) {
    Indent(indent);
    const char* k = m->kind == st::MessageNode::Kind::kUnary     ? "send-unary"
                    : m->kind == st::MessageNode::Kind::kBinary  ? "send-binary"
                                                                 : "send-keyword";
    os_ << "(" << k << " " << m->selector << "\n";
    if (m->receiver) {
      Dump(m->receiver.get(), indent + 1);
    }
    for (const auto& a : m->args) Dump(a.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpBlock(const st::BlockNode* b, int indent) {
    Indent(indent);
    os_ << "(block";
    if (!b->args.empty()) {
      os_ << " :args (";
      for (size_t i = 0; i < b->args.size(); i++) {
        if (i) os_ << " ";
        os_ << b->args[i];
      }
      os_ << ")";
    }
    os_ << "\n";
    if (!b->temps.empty()) {
      Indent(indent + 1);
      os_ << "(temps";
      for (const auto& t : b->temps) os_ << " " << t;
      os_ << ")\n";
    }
    for (const auto& s : b->statements) Dump(s.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpDynArray(const st::DynArrayNode* d, int indent) {
    Indent(indent);
    os_ << "(dyn-array\n";
    for (const auto& e : d->elements) Dump(e.get(), indent + 1);
    Indent(indent);
    os_ << ")\n";
  }

  void DumpVariable(const st::VariableNode* v, int indent) {
    Indent(indent);
    os_ << "(var " << v->name << ")\n";
  }

  void DumpLiteral(const st::LiteralNode* l, int indent) {
    Indent(indent);
    using K = st::LiteralNode::Kind;
    switch (l->kind) {
      case K::kInt: os_ << "(int " << l->text << ")\n"; break;
      case K::kFloat: os_ << "(float " << l->text << ")\n"; break;
      case K::kString: os_ << "(string " << Quote(l->text) << ")\n"; break;
      case K::kSymbol: os_ << "(symbol " << l->text << ")\n"; break;
      case K::kChar: os_ << "(char " << Quote(l->text) << ")\n"; break;
      case K::kNil: os_ << "(nil)\n"; break;
      case K::kTrue: os_ << "(true)\n"; break;
      case K::kFalse: os_ << "(false)\n"; break;
      case K::kArray:
        os_ << "(array\n";
        for (const auto& e : l->elements) Dump(e.get(), indent + 1);
        Indent(indent);
        os_ << ")\n";
        break;
      case K::kByteArray:
        os_ << "(byte-array";
        for (const auto& e : l->elements) {
          if (auto* b = dynamic_cast<const st::LiteralNode*>(e.get())) {
            os_ << " " << b->text;
          }
        }
        os_ << ")\n";
        break;
    }
  }

  std::ostream& os_;
};

// Prints a `file:line:col: message` diagnostic plus the offending source line
// and a caret under the column.
void ReportError(const std::string& file, const std::string& src, int line,
                 int col, const std::string& message) {
  std::cerr << file << ":" << line << ":" << col << ": " << message << "\n";
  // Extract the offending line (1-based).
  std::istringstream ss(src);
  std::string text;
  int cur = 1;
  bool found = false;
  while (std::getline(ss, text)) {
    if (cur == line) {
      found = true;
      break;
    }
    cur++;
  }
  if (found) {
    std::cerr << "    " << text << "\n";
    std::cerr << "    ";
    for (int i = 1; i < col && i <= static_cast<int>(text.size()) + 1; i++) {
      std::cerr << (i - 1 < static_cast<int>(text.size()) && text[i - 1] == '\t'
                        ? '\t'
                        : ' ');
    }
    std::cerr << "^\n";
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::string file = "<stdin>";
  std::string src;

  if (argc > 1) {
    file = argv[1];
    std::ifstream in(file, std::ios::binary);
    if (!in) {
      std::cerr << "error: cannot open " << file << "\n";
      return 2;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    src = ss.str();
  } else {
    std::ostringstream ss;
    ss << std::cin.rdbuf();
    src = ss.str();
  }

  st::Lexer lexer(src);
  std::vector<st::Token> tokens;
  st::LexError lex_err;
  if (!lexer.Tokenize(&tokens, &lex_err)) {
    ReportError(file, src, lex_err.line, lex_err.col, lex_err.message);
    return 1;
  }

  st::Parser parser(std::move(tokens));
  st::ParseError perr;
  auto program = parser.ParseProgram(&perr);
  if (!program) {
    ReportError(file, src, perr.line, perr.col, perr.message);
    return 1;
  }

  Dumper dumper(std::cout);
  dumper.Dump(program.get(), 0);
  return 0;
}
