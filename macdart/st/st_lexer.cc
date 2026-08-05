// MACVM Smalltalk (.mst) reader — tokenizer implementation.

#include "st_lexer.h"

#include <cctype>
#include <string>

namespace st {

bool IsIdentStart(int c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

bool IsIdentCont(int c) {
  return IsIdentStart(c) || (c >= '0' && c <= '9');
}

bool IsBinaryChar(int c) {
  switch (c) {
    case '+': case '-': case '*': case '/': case '~': case '<': case '>':
    case '=': case '&': case '|': case '@': case '%': case ',': case '?':
    case '!': case '\\':
      return true;
    default:
      return false;
  }
}

Lexer::Lexer(std::string src) : src_(std::move(src)) {}

bool Lexer::AtEnd() const { return idx_ >= src_.size(); }

int Lexer::Peek(int ahead) const {
  size_t p = idx_ + static_cast<size_t>(ahead);
  if (p >= src_.size()) return -1;
  return static_cast<unsigned char>(src_[p]);
}

int Lexer::Advance() {
  if (AtEnd()) return -1;
  int c = static_cast<unsigned char>(src_[idx_++]);
  if (c == '\n') {
    line_++;
    col_ = 1;
  } else {
    col_++;
  }
  return c;
}

// Skips runs of whitespace and "double-quoted" comments. Comments may contain
// "" as an escaped quote. Sets *error if a comment is unterminated.
void Lexer::SkipWhitespaceAndComments(bool* error, LexError* err) {
  for (;;) {
    int c = Peek();
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' ||
        c == '\v') {
      Advance();
      continue;
    }
    if (c == '"') {
      int start_line = line_, start_col = col_;
      Advance();  // opening quote
      for (;;) {
        int d = Peek();
        if (d == -1) {
          *error = true;
          err->line = start_line;
          err->col = start_col;
          err->message = "unterminated comment";
          return;
        }
        if (d == '"') {
          if (Peek(1) == '"') {  // "" escaped quote inside comment
            Advance();
            Advance();
            continue;
          }
          Advance();  // closing quote
          break;
        }
        Advance();
      }
      continue;
    }
    return;
  }
}

// Reads a number. Handles: leading '-' (already consumed by caller decision),
// radix integers `16rFF`, floats `1.5` / `1.0e3` / `1e10`. Returns a kInt or
// kFloat token. The caller passes the starting line/col via member state.
Token Lexer::MakeNumber(bool* error, LexError* err) {
  (void)error;
  (void)err;
  Token t;
  t.line = line_;
  t.col = col_;
  std::string s;

  if (Peek() == '-') s += static_cast<char>(Advance());

  // Integer part.
  while (std::isdigit(Peek())) s += static_cast<char>(Advance());

  // Radix integer: <digits> 'r' <radix-digits>.
  if (Peek() == 'r') {
    s += static_cast<char>(Advance());  // 'r'
    // Radix digits may be 0-9 A-Z (and a leading '-' for signed radix).
    if (Peek() == '-') s += static_cast<char>(Advance());
    while (std::isalnum(Peek())) s += static_cast<char>(Advance());
    t.kind = Tok::kInt;
    t.text = s;
    return t;
  }

  bool is_float = false;
  // Fraction: only if a digit follows the '.', so that `3.` stays an int
  // followed by a statement separator.
  if (Peek() == '.' && std::isdigit(Peek(1))) {
    is_float = true;
    s += static_cast<char>(Advance());  // '.'
    while (std::isdigit(Peek())) s += static_cast<char>(Advance());
  }

  // Exponent.
  if (Peek() == 'e' || Peek() == 'E' || Peek() == 'd' || Peek() == 'D') {
    int nxt = Peek(1);
    bool signed_exp = (nxt == '+' || nxt == '-');
    int after = signed_exp ? Peek(2) : nxt;
    if (std::isdigit(after)) {
      is_float = true;
      s += static_cast<char>(Advance());  // e/E/d/D
      if (signed_exp) s += static_cast<char>(Advance());
      while (std::isdigit(Peek())) s += static_cast<char>(Advance());
    }
  }

  t.kind = is_float ? Tok::kFloat : Tok::kInt;
  t.text = s;
  return t;
}

// Reads a single-quoted string. '' is an escaped quote. The opening quote is at
// the current position.
Token Lexer::MakeString(bool* error, LexError* err) {
  Token t;
  t.kind = Tok::kString;
  t.line = line_;
  t.col = col_;
  int start_line = line_, start_col = col_;
  Advance();  // opening '
  std::string s;
  for (;;) {
    int c = Peek();
    if (c == -1) {
      *error = true;
      err->line = start_line;
      err->col = start_col;
      err->message = "unterminated string literal";
      break;
    }
    if (c == '\'') {
      if (Peek(1) == '\'') {  // '' escaped quote
        Advance();
        Advance();
        s += '\'';
        continue;
      }
      Advance();  // closing '
      break;
    }
    s += static_cast<char>(Advance());
  }
  t.text = s;
  return t;
}

// Reads a symbol token starting at '#'. Forms:
//   #foo #foo:bar:  (keyword-run)  #+  (binary)  #'quoted symbol'
// Also detects the array/byte-array introducers #( and #[ which are returned
// as distinct tokens for the parser to handle.
Token Lexer::MakeSymbol(bool* error, LexError* err) {
  Token t;
  t.line = line_;
  t.col = col_;
  Advance();  // '#'

  int c = Peek();
  if (c == '(') {
    Advance();
    t.kind = Tok::kSymbolArray;
    t.text = "#(";
    return t;
  }
  if (c == '[') {
    Advance();
    t.kind = Tok::kByteArrayL;
    t.text = "#[";
    return t;
  }
  if (c == '\'') {  // quoted symbol reuses string scanning
    Token s = MakeString(error, err);
    t.kind = Tok::kSymbol;
    t.text = s.text;
    return t;
  }

  std::string s;
  if (IsIdentStart(c)) {
    // Unary or keyword-run symbol: ident (':' ident?)*  or  ident ':' ...
    while (IsIdentCont(Peek())) s += static_cast<char>(Advance());
    while (Peek() == ':') {
      s += static_cast<char>(Advance());
      while (IsIdentCont(Peek())) s += static_cast<char>(Advance());
    }
  } else if (IsBinaryChar(c)) {
    while (IsBinaryChar(Peek())) s += static_cast<char>(Advance());
  } else {
    // A lone '#' with nothing meaningful after it — treat as empty symbol.
  }
  t.kind = Tok::kSymbol;
  t.text = s;
  return t;
}

// Reads `$x` character literal, where x is any single character.
Token Lexer::MakeCharOrDollar() {
  Token t;
  t.kind = Tok::kChar;
  t.line = line_;
  t.col = col_;
  Advance();  // '$'
  int c = Peek();
  if (c == -1) {
    t.text = "";
  } else {
    t.text = std::string(1, static_cast<char>(Advance()));
  }
  return t;
}

// Reads an identifier or keyword (identifier immediately followed by ':').
Token Lexer::MakeIdentOrKeyword() {
  Token t;
  t.line = line_;
  t.col = col_;
  std::string s;
  while (IsIdentCont(Peek())) s += static_cast<char>(Advance());
  // Keyword: a ':' directly after the identifier, but NOT ':=' (assignment).
  if (Peek() == ':' && Peek(1) != '=') {
    s += static_cast<char>(Advance());
    t.kind = Tok::kKeyword;
  } else {
    t.kind = Tok::kIdent;
  }
  t.text = s;
  return t;
}

// Reads a run of binary-selector characters as one binary token.
Token Lexer::MakeBinary() {
  Token t;
  t.kind = Tok::kBinary;
  t.line = line_;
  t.col = col_;
  std::string s;
  while (IsBinaryChar(Peek())) s += static_cast<char>(Advance());
  t.text = s;
  return t;
}

bool Lexer::Tokenize(std::vector<Token>* tokens, LexError* err) {
  for (;;) {
    bool error = false;
    SkipWhitespaceAndComments(&error, err);
    if (error) return false;

    if (AtEnd()) {
      Token eof;
      eof.kind = Tok::kEof;
      eof.line = line_;
      eof.col = col_;
      tokens->push_back(eof);
      return true;
    }

    int c = Peek();
    int line = line_, col = col_;
    int off = static_cast<int>(idx_);   // token start offset (debug info)

    // Numbers. A leading '-' is a negative number literal only when a digit
    // follows; otherwise '-' is a binary selector. This is the classic
    // negative-literal-vs-binary-minus disambiguation.
    if (std::isdigit(c) || (c == '-' && std::isdigit(Peek(1)))) {
      bool nerr = false;
      Token t = MakeNumber(&nerr, err);
      if (nerr) return false;
      t.offset = off;
      tokens->push_back(t);
      continue;
    }

    if (c == '\'') {
      bool serr = false;
      Token t = MakeString(&serr, err);
      if (serr) return false;
      t.offset = off;
      tokens->push_back(t);
      continue;
    }

    if (c == '#') {
      bool yerr = false;
      Token t = MakeSymbol(&yerr, err);
      if (yerr) return false;
      t.offset = off;
      tokens->push_back(t);
      continue;
    }

    if (c == '$') {
      Token t = MakeCharOrDollar();
      t.offset = off;
      tokens->push_back(t);
      continue;
    }

    if (IsIdentStart(c)) {
      Token t = MakeIdentOrKeyword();
      t.offset = off;
      tokens->push_back(t);
      continue;
    }

    // Assignment ':=' vs a bare ':' (block-argument introducer, e.g. `:x`).
    if (c == ':') {
      Advance();  // ':'
      Token t;
      t.line = line;
      t.col = col;
      t.offset = off;
      if (Peek() == '=') {
        Advance();
        t.kind = Tok::kAssign;
        t.text = ":=";
      } else {
        t.kind = Tok::kColon;
        t.text = ":";
      }
      tokens->push_back(t);
      continue;
    }

    // Single-char structural tokens.
    auto push1 = [&](Tok k, const char* txt) {
      Advance();
      Token t;
      t.kind = k;
      t.text = txt;
      t.line = line;
      t.col = col;
      t.offset = off;
      tokens->push_back(t);
    };

    switch (c) {
      case '^': push1(Tok::kCaret, "^"); continue;
      case '.': push1(Tok::kDot, "."); continue;
      case ';': push1(Tok::kSemi, ";"); continue;
      case '(': push1(Tok::kLParen, "("); continue;
      case ')': push1(Tok::kRParen, ")"); continue;
      case '[': push1(Tok::kLBracket, "["); continue;
      case ']': push1(Tok::kRBracket, "]"); continue;
      case '{': push1(Tok::kLBrace, "{"); continue;
      case '}': push1(Tok::kRBrace, "}"); continue;
      default:
        break;
    }

    // A lone '|' is emitted as kBar; a run like '||' or '|foo' where more
    // binary chars follow becomes a binary selector. We special-case the
    // single bar because the parser must disambiguate it (temps/block-args
    // terminator vs. the binary operator).
    if (c == '|') {
      if (IsBinaryChar(Peek(1))) {
        Token t = MakeBinary(); t.offset = off; tokens->push_back(t);
      } else {
        push1(Tok::kBar, "|");
      }
      continue;
    }

    if (IsBinaryChar(c)) {
      Token t = MakeBinary(); t.offset = off; tokens->push_back(t);
      continue;
    }

    // Anything else is a lexical error.
    err->line = line_;
    err->col = col_;
    err->message = std::string("unexpected character '") +
                   static_cast<char>(c) + "'";
    return false;
  }
}

}  // namespace st
