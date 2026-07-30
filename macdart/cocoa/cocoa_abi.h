// MACDART @encode -> AAPCS64 ABI-token classifier (Phase 2/3).
//
// Ported from cocoa_data's encoding.py + derive_method_abi.py. Given a method
// type encoding from the ObjC runtime (method_getTypeEncoding), classify the
// return and each argument into the portfolio-standard tokens:
//   g  integer / pointer / id      -> a GPR
//   f  float / double              -> a V-register
//   h1..h4  homogeneous float agg  -> k consecutive V-registers (NSRect=h4)
//   i1 i2   small int struct <=16B -> ceil(size/8) GPRs (NSRange=i2)
//   b  large struct by-value arg   -> caller copy, pointer in a GPR
//   s  large struct return         -> sret, hidden pointer in x8
//   v  void         ? unmodelable
#ifndef MACDART_COCOA_ABI_H_
#define MACDART_COCOA_ABI_H_

#include <stdint.h>

namespace macdart_cocoa {

// Classify one method encoding. Writes the return token to `ret` and up to
// `max_args` argument tokens (after self/_cmd) to `args`, returning the arg
// count (or -1 on parse failure). Tokens are the chars 'g''f''v''b''s''?' or
// the two-char forms "h1".."h4" / "i1""i2" written as ('h', k) — encoded here as
// single chars with a companion count for h/i. To keep the ABI simple we encode
// each token as an int: 'g','f','v','b','s','?' as their char codes; HFA as
// (0x100 | k) and small-int-struct as (0x200 | n).
enum {
  TOK_G = 'g', TOK_F = 'f', TOK_V = 'v', TOK_B = 'b', TOK_S = 's', TOK_Q = '?',
  TOK_SEL = ':',     // SEL — a GPR; a Dart String argument marshals through
                     // sel_registerName (setAction: 'macvmAction:' just works)
  TOK_CSTR = '*',    // char* — a GPR like 'g', but a Dart String marshals as a
                     // C string (not an NSString), and a char* return -> String.
  TOK_OBJ = '@',     // id / Class — a GPR like 'g' for args, but an OBJECT return
                     // is wrapped in a retained Cocoa (with a release finalizer).
  TOK_HFA = 0x100,   // | k  (k = 1..4 V-regs)
  TOK_INT = 0x200,   // | n  (n = 1..2 GPRs)
};

// Returns number of args (>=0), or -1 on failure. ret/args are token ints.
int ClassifyMethod(const char* encoding, int* ret, int* args, int max_args);

}  // namespace macdart_cocoa

#endif  // MACDART_COCOA_ABI_H_
