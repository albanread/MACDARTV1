// MACVM Smalltalk (.mst) reader — recursive-descent parser.
//
// Sprint 0 of ST_PLAN.md. Standalone, no Dart-VM dependencies. Turns a token
// stream (from st_lexer) into the AST defined in st_ast.h.

#ifndef MACDART_ST_ST_PARSER_H_
#define MACDART_ST_ST_PARSER_H_

#include <memory>
#include <string>
#include <vector>

#include "st_ast.h"
#include "st_lexer.h"

namespace st {

// A parse (or lex) error: location plus message. `Parse` reports it via
// out-param and returns nullptr.
struct ParseError {
  int line = 0;
  int col = 0;
  std::string message;
  bool ok = true;  // true == no error
};

class Parser {
 public:
  // Constructs a parser over already-tokenized input.
  explicit Parser(std::vector<Token> tokens);

  // Parses a whole program. On success returns the ProgramNode; on failure
  // returns nullptr and fills `err`.
  std::unique_ptr<ProgramNode> ParseProgram(ParseError* err);

 private:
  // --- token cursor ---
  const Token& Cur() const;
  const Token& PeekTok(int ahead) const;
  bool Is(Tok k) const;
  bool IsKeyword(const std::string& kw) const;
  Token Take();  // consume and return current
  bool Accept(Tok k);
  bool Expect(Tok k, const char* what);

  // --- error helpers ---
  void Fail(const Token& at, const std::string& msg);
  bool failed() const { return !err_.ok; }

  // --- top level ---
  NodePtr ParseTopLevelItem();
  std::unique_ptr<ClassDefNode> ParseClassDef(const std::string& super_name,
                                              const Token& start);
  void ParseClassBody(std::vector<Pragma>* pragmas,
                      std::vector<std::unique_ptr<VarDeclNode>>* ivars,
                      std::vector<std::unique_ptr<MethodNode>>* methods);
  std::unique_ptr<MethodNode> ParseMethod(bool is_class_side);
  NodePtr ParseExternalOrDoit();

  // --- method / block internals ---
  void ParseMethodPattern(MethodNode* m);
  // Consumes an optional MACVM `<Type>` annotation in a signature position
  // (ivar name, method-pattern argument, or `^ <Type>` return type). These are
  // semantically inert for the reader, so they are accepted and discarded.
  // Returns true if one was consumed. MUST only be called in signature
  // positions — never in expression position, where `<` is binary less-than.
  bool SkipTypeAnnotationOpt();
  Pragma ParsePragma();
  bool ParseTempsOpt(std::vector<std::string>* out);
  void ParseStatements(std::vector<NodePtr>* out, Tok terminator);

  // --- expressions ---
  NodePtr ParseStatement();
  NodePtr ParseExpression();          // assignment / cascade / keyword
  NodePtr ParseCascadeOrKeyword();
  NodePtr ParseKeywordMessage();
  NodePtr ParseBinaryMessage();
  NodePtr ParseUnaryMessage();
  NodePtr ParsePrimary();
  NodePtr ParseBlock();
  NodePtr ParseDynArray();
  NodePtr ParseLiteral();
  NodePtr ParseLiteralArray();        // inside #( ... )
  NodePtr ParseByteArray();           // inside #[ ... ]
  NodePtr ParseNestedArrayElement();  // element inside a literal array

  std::vector<Token> toks_;
  size_t pos_ = 0;
  ParseError err_;
};

}  // namespace st

#endif  // MACDART_ST_ST_PARSER_H_
