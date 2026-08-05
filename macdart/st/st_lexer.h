// MACVM Smalltalk (.mst) reader — tokenizer.
//
// Sprint 0 of ST_PLAN.md. Standalone, no Dart-VM dependencies.

#ifndef MACDART_ST_ST_LEXER_H_
#define MACDART_ST_ST_LEXER_H_

#include <string>
#include <vector>

namespace st {

enum class Tok {
  kEof,
  kIdent,       // foo
  kKeyword,     // foo:
  kBinary,      // + - * / ~ < > = & | @ % , ? ! and runs thereof
  kInt,         // 42, 16rFF, -3
  kFloat,       // 1.5, 1.0e3, -2.5
  kString,      // 'it''s'  (text = decoded contents)
  kSymbol,      // #foo #at:put: #+ #'x y'  (text = symbol without '#')
  kChar,        // $a  (text = the single char)
  kSymbolArray, // '#(' introducer for a literal array (text = "#(")
  kByteArrayL,  // '#[' introducer for a byte array (text = "#[")
  kAssign,      // :=
  kColon,       // :  (bare colon, introduces a block argument :name)
  kCaret,       // ^
  kDot,         // .
  kSemi,        // ;
  kLParen,      // (
  kRParen,      // )
  kLBracket,    // [
  kRBracket,    // ]
  kLBrace,      // {
  kRBrace,      // }
  kBar,         // |  (standalone bar; note kBinary can also be '|')
};

struct Token {
  Tok kind = Tok::kEof;
  std::string text;  // canonical text/value (see per-kind notes above)
  int line = 0;
  int col = 0;
  int offset = 0;    // absolute byte offset of the token start (debug info)
};

// A lexer error carries a location and a message; the parser turns this into
// the `file:line:col: message` + caret diagnostic.
struct LexError {
  int line = 0;
  int col = 0;
  std::string message;
};

class Lexer {
 public:
  explicit Lexer(std::string src);

  // Tokenizes the whole input. On success returns true and fills `tokens`
  // (terminated by a kEof token). On failure returns false and fills `err`.
  bool Tokenize(std::vector<Token>* tokens, LexError* err);

 private:
  int Peek(int ahead = 0) const;
  int Advance();
  bool AtEnd() const;
  void SkipWhitespaceAndComments(bool* error, LexError* err);

  Token MakeNumber(bool* error, LexError* err);
  Token MakeString(bool* error, LexError* err);
  Token MakeSymbol(bool* error, LexError* err);
  Token MakeCharOrDollar();
  Token MakeIdentOrKeyword();
  Token MakeBinary();

  std::string src_;
  size_t idx_ = 0;
  int line_ = 1;
  int col_ = 1;
};

// True if `c` may start/continue an identifier.
bool IsIdentStart(int c);
bool IsIdentCont(int c);
// True if `c` is one of the binary-selector characters.
bool IsBinaryChar(int c);

}  // namespace st

#endif  // MACDART_ST_ST_LEXER_H_
