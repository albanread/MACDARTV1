// st_audit.cc — the corpus static-inventory + cross-reference tool.
//
// M0 / D1 of ST_PORTING_PLAN.md. A standalone, pure-C++17 analyzer (same
// footing as st_dump — links st_lexer + st_parser, NO Dart-VM dependency). It
// parses the world/*.mst corpus and answers the discovery question the dynamic
// primitive audit does NOT: what selectors does the corpus SEND that nothing in
// the corpus DEFINES — the missing-feature list, priced by static send count.
//
// It emits FACTS only (no judgment about what the engine provides); the
// builtin/bridged filtering is applied downstream from an editable builtins
// list (st/audit/builtins.txt), so the tool never bakes in an opinion that
// rots. Outputs, tab-separated, into --out (default: the CWD):
//
//   methods.tsv   file  class  side  selector  argc  primitive  line
//   classes.tsv   file  class  super  nivars  nmethods
//   sends.tsv     selector  count  defined_by_corpus   (count-desc)
//
//   primitive ∈ {none, stprim, ffi-bare, ffi-guarded, num-bare, num-guarded}
//   — "bare" = the pragma is the whole body (no Smalltalk fallback follows), so
//   on this VM it compiles to an empty body that answers self unless wired.
//
// Usage:  st_audit [--out DIR] file1.mst file2.mst ...
//
#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "st_ast.h"
#include "st_lexer.h"
#include "st_parser.h"

namespace {

struct MethodRec {
  std::string file, cls, side, selector, prim;
  int argc = 0, line = 0;
};
struct ClassRec {
  std::string file, name, super;
  int nivars = 0, nmethods = 0;
};

std::vector<MethodRec> g_methods;
std::vector<ClassRec> g_classes;
std::map<std::string, long> g_sends;   // selector -> total static send count
std::set<std::string> g_defined;       // selectors any corpus class defines

// The argument count implied by a selector's SHAPE: keyword = colon count,
// binary (leads with a non-identifier char) = 1, unary = 0.
int ArgcOf(const std::string& sel) {
  if (sel.empty()) return 0;
  int colons = 0;
  for (char c : sel) if (c == ':') colons++;
  if (colons > 0) return colons;
  char c0 = sel[0];
  const bool ident = std::isalpha(static_cast<unsigned char>(c0)) || c0 == '_';
  return ident ? 0 : 1;   // non-identifier lead = binary operator
}

// How a method's body relates to a <primitive:> pragma. "bare" (no statements
// after the pragma) is the dangerous case on this VM.
std::string PrimKind(const st::MethodNode* m) {
  bool ffi = false, num = false, stprim = false;
  for (const auto& p : m->pragmas) {
    if (p.text.rfind("stprim:", 0) == 0) stprim = true;
    else if (p.text.rfind("primitive: FFI", 0) == 0) ffi = true;
    else if (p.text.rfind("primitive:", 0) == 0) num = true;
  }
  const bool bare = m->statements.empty();
  if (stprim) return "stprim";
  if (ffi) return bare ? "ffi-bare" : "ffi-guarded";
  if (num) return bare ? "num-bare" : "num-guarded";
  return "none";
}

// Walk an expression subtree, tallying every message SEND by selector.
void WalkExpr(const st::Node* n);
void WalkStmts(const std::vector<st::NodePtr>& s) {
  for (const auto& e : s) WalkExpr(e.get());
}
void WalkExpr(const st::Node* n) {
  if (n == nullptr) return;
  if (auto* m = dynamic_cast<const st::MessageNode*>(n)) {
    g_sends[m->selector]++;
    WalkExpr(m->receiver.get());
    for (const auto& a : m->args) WalkExpr(a.get());
  } else if (auto* c = dynamic_cast<const st::CascadeNode*>(n)) {
    WalkExpr(c->receiver.get());
    for (const auto& msg : c->messages) {
      auto* mm = dynamic_cast<const st::MessageNode*>(msg.get());
      if (mm == nullptr) continue;
      g_sends[mm->selector]++;
      for (const auto& a : mm->args) WalkExpr(a.get());
    }
  } else if (auto* a = dynamic_cast<const st::AssignNode*>(n)) {
    WalkExpr(a->value.get());
  } else if (auto* r = dynamic_cast<const st::ReturnNode*>(n)) {
    WalkExpr(r->value.get());
  } else if (auto* b = dynamic_cast<const st::BlockNode*>(n)) {
    WalkStmts(b->statements);
  } else if (auto* d = dynamic_cast<const st::DynArrayNode*>(n)) {
    for (const auto& e : d->elements) WalkExpr(e.get());
  } else if (auto* l = dynamic_cast<const st::LiteralNode*>(n)) {
    for (const auto& e : l->elements) WalkExpr(e.get());  // nested #( ) arrays
  }
  // VariableNode / bare literals: no sends.
}

std::string BaseName(const std::string& path) {
  auto slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

void RecordMethod(const std::string& cls, const st::MethodNode* m,
                  const std::string& file) {
  g_defined.insert(m->selector);
  g_methods.push_back({file, cls, m->is_class_side ? "class" : "inst",
                       m->selector, PrimKind(m), ArgcOf(m->selector),
                       m->pos.line});
  WalkStmts(m->statements);   // the body's sends count too
}

void RecordProgram(const st::ProgramNode* prog, const std::string& file) {
  for (const auto& item : prog->items) {
    st::Node* n = item.get();
    if (auto* cd = dynamic_cast<st::ClassDefNode*>(n)) {
      int nivars = 0;
      for (const auto& v : cd->ivars) nivars += static_cast<int>(v->names.size());
      g_classes.push_back({file, cd->name, cd->superclass, nivars,
                           static_cast<int>(cd->methods.size())});
      for (const auto& m : cd->methods) RecordMethod(cd->name, m.get(), file);
    } else if (auto* ex = dynamic_cast<st::ExtendNode*>(n)) {
      for (const auto& m : ex->methods) RecordMethod(ex->class_name, m.get(), file);
    } else if (auto* em = dynamic_cast<st::ExtMethodNode*>(n)) {
      RecordMethod(em->class_name, em->method.get(), file);
    } else {
      WalkExpr(n);   // a bare top-level do-it — its sends count
    }
  }
}

bool ReadFile(const std::string& path, std::string* out) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return false;
  std::ostringstream ss;
  ss << in.rdbuf();
  *out = ss.str();
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  std::string out_dir = ".";
  std::vector<std::string> files;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--out" && i + 1 < argc) { out_dir = argv[++i]; }
    else files.push_back(a);
  }
  if (files.empty()) {
    std::cerr << "usage: st_audit [--out DIR] file1.mst ...\n";
    return 2;
  }

  int parsed = 0, failed = 0;
  for (const auto& f : files) {
    std::string src;
    if (!ReadFile(f, &src)) {
      std::cerr << "st_audit: cannot open " << f << "\n";
      failed++;
      continue;
    }
    st::Lexer lexer(src);
    std::vector<st::Token> tokens;
    st::LexError lex_err;
    if (!lexer.Tokenize(&tokens, &lex_err)) {
      std::cerr << f << ":" << lex_err.line << ": lex: " << lex_err.message
                << "\n";
      failed++;
      continue;
    }
    st::Parser parser(std::move(tokens));
    st::ParseError perr;
    auto prog = parser.ParseProgram(&perr);
    if (prog == nullptr) {
      std::cerr << f << ":" << perr.line << ": parse: " << perr.message << "\n";
      failed++;
      continue;
    }
    RecordProgram(prog.get(), BaseName(f));
    parsed++;
  }

  // ----- emit the fact tables ------------------------------------------------
  auto open_out = [&](const std::string& name) {
    return std::ofstream(out_dir + "/" + name, std::ios::trunc);
  };

  {
    auto o = open_out("methods.tsv");
    o << "file\tclass\tside\tselector\targc\tprimitive\tline\n";
    for (const auto& m : g_methods)
      o << m.file << '\t' << m.cls << '\t' << m.side << '\t' << m.selector
        << '\t' << m.argc << '\t' << m.prim << '\t' << m.line << '\n';
  }
  {
    auto o = open_out("classes.tsv");
    o << "file\tclass\tsuper\tnivars\tnmethods\n";
    for (const auto& c : g_classes)
      o << c.file << '\t' << c.name << '\t' << c.super << '\t' << c.nivars
        << '\t' << c.nmethods << '\n';
  }
  {
    // sends, count-descending then selector-ascending
    std::vector<std::pair<std::string, long>> v(g_sends.begin(), g_sends.end());
    std::sort(v.begin(), v.end(), [](const auto& a, const auto& b) {
      if (a.second != b.second) return a.second > b.second;
      return a.first < b.first;
    });
    auto o = open_out("sends.tsv");
    o << "selector\tcount\tdefined_by_corpus\n";
    for (const auto& p : v)
      o << p.first << '\t' << p.second << '\t'
        << (g_defined.count(p.first) ? 1 : 0) << '\n';
  }

  // count bare primitives — the class the parallel dynamic audit chases
  long bare = 0;
  for (const auto& m : g_methods)
    if (m.prim == "ffi-bare" || m.prim == "num-bare") bare++;

  std::cerr << "st_audit: parsed " << parsed << " file(s), " << failed
            << " failed\n"
            << "  classes " << g_classes.size() << "  methods "
            << g_methods.size() << "  distinct selectors defined "
            << g_defined.size() << "\n"
            << "  distinct selectors SENT " << g_sends.size()
            << "  bare-primitive methods " << bare << "\n"
            << "  wrote methods.tsv classes.tsv sends.tsv -> " << out_dir
            << "\n";
  return failed == 0 ? 0 : 1;
}
