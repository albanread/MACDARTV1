// MACDART @encode -> AAPCS64 ABI-token classifier. See cocoa_abi.h.
// A faithful C++ port of cocoa_data/encoding.py's recursive parser + size/hfa,
// and derive_method_abi.py's _tok. Runtime encodings are fully expanded, so no
// struct-ref resolution is needed.
#include "cocoa_abi.h"

#include <string.h>

namespace macdart_cocoa {

namespace {

struct TI {
  int size = 0;
  int align = 1;
  int hfa_w = 0;   // homogeneous float member width in bits (32/64), 0 = not HFA
  int hfa_n = 0;   // homogeneous float member count, 0 = not HFA
  enum { SCALAR, FLOAT, PTR, CSTR, OBJ, AGG, VOID, BITFIELD, UNKNOWN } kind = UNKNOWN;
};

int RoundUp(int x, int a) { return a <= 1 ? x : ((x + a - 1) / a) * a; }

void SkipQuals(const char*& p) {
  while (*p && strchr("rnNoORV ", *p) != NULL) p++;
}

int ReadNumber(const char*& p) {
  int n = 0;
  while (*p >= '0' && *p <= '9') { n = n * 10 + (*p - '0'); p++; }
  return n;
}

// A scalar char -> (size, is_float, is_ptr). Returns false if not a scalar.
bool ScalarInfo(char c, int* size, bool* is_float, bool* is_ptr) {
  *is_float = false; *is_ptr = false;
  switch (c) {
    case 'c': case 'C': case 'B': *size = 1; return true;
    case 's': case 'S': *size = 2; return true;
    case 'i': case 'I': *size = 4; return true;
    case 'l': case 'L': case 'q': case 'Q': *size = 8; return true;
    case 'f': *size = 4; *is_float = true; return true;
    case 'd': case 'D': *size = 8; *is_float = true; return true;
    case '@': case '#': case '*': case ':': *size = 8; *is_ptr = true; return true;
    default: return false;
  }
}

TI ParseType(const char*& p);

// Merge a field's HFA contribution into an accumulator. Returns false if the
// aggregate is not (or ceases to be) an HFA.
bool MergeHfa(int* acc_w, int* acc_n, const TI& f) {
  if (f.hfa_n == 0) return false;
  if (*acc_n == 0) { *acc_w = f.hfa_w; *acc_n = f.hfa_n; return true; }
  if (*acc_w != f.hfa_w) return false;
  *acc_n += f.hfa_n;
  return true;
}

TI ParseAgg(const char*& p, char close) {
  TI t; t.kind = TI::AGG;
  p++;  // consume { or (
  // struct/union name up to '=' or close.
  while (*p && *p != '=' && *p != close) p++;
  if (*p != '=') {                 // name-only reference or empty body
    if (*p == close) p++;
    t.kind = TI::UNKNOWN; t.size = 0; t.align = 1;
    return t;
  }
  p++;  // consume '='
  int off = 0, align = 1, size = 0;
  bool hfa_ok = true; int hfa_w = 0, hfa_n = 0;
  int nfields = 0;
  bool is_union = (close == ')');
  while (*p && *p != close) {
    SkipQuals(p);
    if (*p == '"') {               // field name — skip it
      p++;
      while (*p && *p != '"') p++;
      if (*p == '"') p++;
      continue;
    }
    if (*p == close || *p == '\0') break;
    TI f = ParseType(p);
    nfields++;
    int fa = f.align < 1 ? 1 : f.align;
    if (is_union) {
      if (f.size > size) size = f.size;
    } else {
      off = RoundUp(off, fa);
      off += f.size;
      size = off;
    }
    if (fa > align) align = fa;
    if (hfa_ok && !MergeHfa(&hfa_w, &hfa_n, f)) hfa_ok = false;
  }
  if (*p == close) p++;
  if (nfields == 0) { t.kind = TI::UNKNOWN; t.size = 0; t.align = 1; return t; }
  t.align = align;
  t.size = RoundUp(size, align);
  if (hfa_ok && hfa_n > 0) { t.hfa_w = hfa_w; t.hfa_n = hfa_n; }
  return t;
}

TI ParseArray(const char*& p) {
  TI t; t.kind = TI::AGG;
  p++;  // [
  int len = ReadNumber(p);
  TI elem = ParseType(p);
  if (*p == ']') p++;
  int ea = elem.align < 1 ? 1 : elem.align;
  t.size = RoundUp(elem.size, ea) * len;
  t.align = ea;
  if (elem.hfa_n > 0) { t.hfa_w = elem.hfa_w; t.hfa_n = elem.hfa_n * len; }
  return t;
}

TI ParseType(const char*& p) {
  SkipQuals(p);
  char c = *p;
  if (c == '{') return ParseAgg(p, '}');
  if (c == '(') return ParseAgg(p, ')');
  if (c == '[') return ParseArray(p);
  if (c == '^') { p++; ParseType(p); TI t; t.kind = TI::PTR; t.size = 8; t.align = 8; return t; }
  if (c == 'b') { p++; int bits = ReadNumber(p); TI t; t.kind = TI::BITFIELD;
                  t.size = (bits + 7) / 8; if (t.size < 1) t.size = 1; t.align = 1; return t; }
  if (c == '@') {  // id / block / typed object — one 8-byte pointer
    p++;
    if (*p == '?') { p++; if (*p == '<') { int d = 0; do { if (*p=='<')d++; else if(*p=='>')d--; p++; } while (*p && d); } }
    else if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p == '"') p++; }
    TI t; t.kind = TI::OBJ; t.size = 8; t.align = 8; return t;
  }
  if (c == '#') { p++; TI t; t.kind = TI::OBJ; t.size = 8; t.align = 8; return t; }  // Class
  if (c == '*') { p++; TI t; t.kind = TI::CSTR; t.size = 8; t.align = 8; return t; }
  if (c == 'v') { p++; TI t; t.kind = TI::VOID; t.size = 0; t.align = 1; return t; }
  if (c == '\0') { TI t; t.kind = TI::UNKNOWN; return t; }
  int sz; bool isf, isp;
  if (ScalarInfo(c, &sz, &isf, &isp)) {
    p++;
    TI t; t.size = sz; t.align = sz;
    if (isf) { t.kind = TI::FLOAT; t.hfa_w = sz * 8; t.hfa_n = 1; }
    else if (isp) t.kind = TI::PTR;
    else t.kind = TI::SCALAR;
    return t;
  }
  p++;  // unknown char
  TI t; t.kind = TI::UNKNOWN; return t;
}

int TokenOf(const TI& t, bool is_ret) {
  switch (t.kind) {
    case TI::FLOAT:  return TOK_F;
    case TI::SCALAR: return TOK_G;
    case TI::PTR:    return TOK_G;
    case TI::CSTR:   return TOK_CSTR;
    case TI::OBJ:    return TOK_OBJ;
    case TI::BITFIELD: return TOK_G;
    case TI::VOID:   return is_ret ? TOK_V : TOK_Q;
    case TI::UNKNOWN: return is_ret && t.size == 0 ? TOK_Q : TOK_Q;
    case TI::AGG: {
      if (t.hfa_n >= 1 && t.hfa_n <= 4) return TOK_HFA | t.hfa_n;
      if (t.size == 0) return TOK_Q;
      if (t.size <= 16) return TOK_INT | ((t.size + 7) / 8);
      return is_ret ? TOK_S : TOK_B;
    }
  }
  return TOK_Q;
}

}  // namespace

int ClassifyMethod(const char* encoding, int* ret, int* args, int max_args) {
  if (encoding == NULL || *encoding == '\0') return -1;
  const char* p = encoding;
  // Sequence: [ret, self(@), _cmd(:), arg1, ...], with frame-offset numbers
  // interspersed which we skip.
  int idx = 0, nargs = 0;
  while (*p) {
    SkipQuals(p);
    if (*p == '\0') break;
    if (*p >= '0' && *p <= '9') { ReadNumber(p); continue; }
    TI t = ParseType(p);
    if (idx == 0) {
      *ret = TokenOf(t, /*is_ret=*/true);
    } else if (idx >= 3) {  // skip self(1) and _cmd(2)
      if (nargs < max_args) args[nargs] = TokenOf(t, /*is_ret=*/false);
      nargs++;
    }
    idx++;
  }
  if (idx < 3) return -1;  // need at least ret, self, _cmd
  return nargs;
}

}  // namespace macdart_cocoa
