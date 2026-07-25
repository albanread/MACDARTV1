// MACDART dart:cocoa dispatch engine (Phase 1). Adapted from MACVM's
// objc_shim.m. ONE fixed-AAPCS64-shape objc_msgSend cast marshals ANY send:
// the marshaller places each argument into the next GPR or FPR slot per its
// ABI token; because AAPCS64 allocates the GPR and FPR files INDEPENDENTLY,
// those slots land in exactly the registers the real method expects. The return
// is the one thing registers can't fake, so a ret-kind token picks the cast.
// Wrapped in @try/@catch so an NSException becomes a status code, never
// unwinding into VM/JIT frames.
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <stdint.h>
#include <string.h>

enum RetKind { RET_VOID=0, RET_GPR, RET_FPR, RET_F32, RET_HFA2, RET_HFA4, RET_INTPAIR };

typedef struct { double d0,d1; } Hfa2;
typedef struct { double d0,d1,d2,d3; } Hfa4;
typedef struct { uint64_t x0,x1; } IntPair;

// The fixed shape: self, _cmd, 6 GPR words (x2..x7), 8 FPR doubles (d0..d7),
// 4 stack words. Each RetKind reinterprets objc_msgSend with the right return.
#define SHAPE id self, SEL _cmd, \
  uint64_t g0,uint64_t g1,uint64_t g2,uint64_t g3,uint64_t g4,uint64_t g5, \
  double f0,double f1,double f2,double f3,double f4,double f5,double f6,double f7, \
  uint64_t s0,uint64_t s1,uint64_t s2,uint64_t s3

// out_gpr[0..1] / out_fpr[0..3] receive the return; returns 1 on success,
// 0 if an ObjC exception was caught (its description bytes go to err/errlen).
int macdart_objc_send(void* target, void* sel, int ret_kind,
                      const uint64_t g[6], const double f[8], const uint64_t s[4],
                      uint64_t out_gpr[2], double out_fpr[4],
                      char* err, int errcap) {
  id t = (id)target; SEL c = (SEL)sel;
  @try {
    switch (ret_kind) {
      case RET_VOID: {
        void (*fn)(SHAPE) = (void(*)(SHAPE))objc_msgSend;
        fn(t,c, g[0],g[1],g[2],g[3],g[4],g[5],
           f[0],f[1],f[2],f[3],f[4],f[5],f[6],f[7], s[0],s[1],s[2],s[3]);
        break; }
      case RET_GPR: {
        uint64_t (*fn)(SHAPE) = (uint64_t(*)(SHAPE))objc_msgSend;
        out_gpr[0] = fn(t,c, g[0],g[1],g[2],g[3],g[4],g[5],
           f[0],f[1],f[2],f[3],f[4],f[5],f[6],f[7], s[0],s[1],s[2],s[3]);
        break; }
      case RET_FPR: {
        double (*fn)(SHAPE) = (double(*)(SHAPE))objc_msgSend;
        out_fpr[0] = fn(t,c, g[0],g[1],g[2],g[3],g[4],g[5],
           f[0],f[1],f[2],f[3],f[4],f[5],f[6],f[7], s[0],s[1],s[2],s[3]);
        break; }
      case RET_HFA2: {  // NSPoint / NSSize: {double x2} comes back in d0..d1
        Hfa2 (*fn)(SHAPE) = (Hfa2(*)(SHAPE))objc_msgSend;
        Hfa2 r = fn(t,c, g[0],g[1],g[2],g[3],g[4],g[5],
           f[0],f[1],f[2],f[3],f[4],f[5],f[6],f[7], s[0],s[1],s[2],s[3]);
        out_fpr[0]=r.d0; out_fpr[1]=r.d1;
        break; }
      case RET_HFA4: {  // NSRect etc.: {double x4} comes back in d0..d3
        Hfa4 (*fn)(SHAPE) = (Hfa4(*)(SHAPE))objc_msgSend;
        Hfa4 r = fn(t,c, g[0],g[1],g[2],g[3],g[4],g[5],
           f[0],f[1],f[2],f[3],f[4],f[5],f[6],f[7], s[0],s[1],s[2],s[3]);
        out_fpr[0]=r.d0; out_fpr[1]=r.d1; out_fpr[2]=r.d2; out_fpr[3]=r.d3;
        break; }
      case RET_INTPAIR: {  // NSRange: {uint64 x2} in x0..x1
        IntPair (*fn)(SHAPE) = (IntPair(*)(SHAPE))objc_msgSend;
        IntPair r = fn(t,c, g[0],g[1],g[2],g[3],g[4],g[5],
           f[0],f[1],f[2],f[3],f[4],f[5],f[6],f[7], s[0],s[1],s[2],s[3]);
        out_gpr[0]=r.x0; out_gpr[1]=r.x1;
        break; }
      default: return 0;
    }
    return 1;
  } @catch (NSException* ex) {
    const char* d = "NSException";
    @try { d = [[ex description] UTF8String]; } @catch (id ignore) {}
    if (err && errcap>0) { strncpy(err, d, errcap-1); err[errcap-1]=0; }
    return 0;
  }
}
