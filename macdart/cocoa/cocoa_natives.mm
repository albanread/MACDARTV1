// MACDART dart:cocoa natives (Phase 1). Objective-C++, compiled -fno-objc-arc
// (manual retain/release — the VM owns the reference count, not ARC).
//
// Phase 1 uses direct typed objc_msgSend casts for the known selectors (the
// approach validated in cocoa/objc_shim.m's test). The general dynamic send
// through the fixed-shape shim + the noSuchMethod ergonomic layer come in later
// phases; see MACDART/COCOA_PLAN.md.
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

#include "include/dart_api.h"
#include "cocoa_natives.h"
#include "cocoa_abi.h"

// The fixed-shape dispatch shim (objc_shim.m — C linkage). Return-kind tokens
// must match its enum.
extern "C" int macdart_objc_send(void* target, void* sel, int ret_kind,
                                 const uint64_t g[6], const double f[8],
                                 const uint64_t s[4], uint64_t out_gpr[2],
                                 double out_fpr[4], char* err, int errcap);
enum { SH_VOID = 0, SH_GPR, SH_FPR, SH_F32, SH_HFA2, SH_HFA4, SH_INTPAIR };

namespace dart {
namespace bin {

static int64_t IntArg(Dart_NativeArguments args, int i) {
  int64_t v = 0;
  Dart_IntegerToInt64(Dart_GetNativeArgument(args, i), &v);
  return v;
}

// dlopen the umbrella frameworks (RTLD_GLOBAL) so their classes are registered.
// Link-time framework linkage doesn't guarantee a framework is actually loaded
// unless a symbol is referenced, so we force it (as MACVM does).
static void EnsureFrameworks() {
  static bool done = false;
  if (done) return;
  done = true;
  dlopen("/System/Library/Frameworks/Foundation.framework/Foundation",
         RTLD_LAZY | RTLD_GLOBAL);
  dlopen("/System/Library/Frameworks/AppKit.framework/AppKit",
         RTLD_LAZY | RTLD_GLOBAL);
}

// Coerce a Dart value to a 64-bit GPR word for a 'g' argument: int -> as-is,
// String -> a temporary (autoreleased) NSString, bool -> 0/1, null -> nil.
static uint64_t GprFromDart(Dart_Handle h) {
  if (Dart_IsInteger(h)) { int64_t v = 0; Dart_IntegerToInt64(h, &v); return (uint64_t)v; }
  if (Dart_IsString(h)) {
    const char* c = NULL; Dart_StringToCString(h, &c);
    id (*send)(id, SEL, const char*) = (id (*)(id, SEL, const char*))objc_msgSend;
    id ns = send((id)objc_getClass("NSString"),
                 sel_registerName("stringWithUTF8String:"), c ? c : "");
    return (uint64_t)ns;  // autoreleased; valid for the duration of this send
  }
  if (Dart_IsBoolean(h)) { bool b = false; Dart_BooleanValue(h, &b); return b ? 1 : 0; }
  return 0;  // null / other -> nil
}

static double DoubleFromDart(Dart_Handle h) {
  if (Dart_IsDouble(h)) { double d = 0; Dart_DoubleValue(h, &d); return d; }
  if (Dart_IsInteger(h)) { int64_t v = 0; Dart_IntegerToInt64(h, &v); return (double)v; }
  return 0.0;
}

// The general dynamic send: _send(int target, String selector, List args).
// Resolves the method's @encode, classifies it (AAPCS64 tokens), marshals each
// Dart arg into the flat GPR/FPR buffers per its token, dispatches through the
// fixed-shape shim, and returns the result as the matching Dart value.
static void Cocoa_send(Dart_NativeArguments args) {
  id target = (id)IntArg(args, 0);
  const char* sel_name = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 1), &sel_name);
  SEL sel = sel_registerName(sel_name);

  // Resolve the concrete method's type encoding (object_getClass handles both
  // instance and class sends — a class's metaclass holds its class methods).
  Method m = class_getInstanceMethod(object_getClass(target), sel);
  if (m == NULL) {
    Dart_ThrowException(Dart_NewStringFromCString(
        "dart:cocoa: unknown selector (no method for this class)"));
    return;
  }
  int ret_tok = 0, arg_toks[16];
  int nargs = macdart_cocoa::ClassifyMethod(method_getTypeEncoding(m), &ret_tok,
                                            arg_toks, 16);
  if (nargs < 0) {
    Dart_ThrowException(Dart_NewStringFromCString(
        "dart:cocoa: could not classify method signature"));
    return;
  }

  // Marshal arguments.
  uint64_t gpr[6] = {0}; double fpr[8] = {0}; uint64_t stk[4] = {0};
  int gi = 0, fi = 0;
  Dart_Handle list = Dart_GetNativeArgument(args, 2);
  intptr_t supplied = 0; Dart_ListLength(list, &supplied);
  for (int a = 0; a < nargs && a < supplied; a++) {
    Dart_Handle el = Dart_ListGetAt(list, a);
    int tok = arg_toks[a];
    using namespace macdart_cocoa;
    if (tok == TOK_F) {
      if (fi < 8) fpr[fi++] = DoubleFromDart(el);
    } else if (tok == TOK_CSTR) {        // char*: Dart String -> raw C string
      if (Dart_IsString(el)) {
        const char* c = NULL; Dart_StringToCString(el, &c);
        if (gi < 6) gpr[gi++] = (uint64_t)(c ? c : "");  // scope-valid for the send
      } else if (gi < 6) {
        gpr[gi++] = GprFromDart(el);
      }
    } else if (tok & TOK_HFA) {          // List<num> of k -> k FP regs
      int k = tok & 0xf;
      for (int j = 0; j < k && fi < 8; j++) fpr[fi++] = DoubleFromDart(Dart_ListGetAt(el, j));
    } else if (tok & TOK_INT) {          // List<int> of n -> n GPRs
      int n = tok & 0xf;
      for (int j = 0; j < n && gi < 6; j++) {
        int64_t v = 0; Dart_IntegerToInt64(Dart_ListGetAt(el, j), &v); gpr[gi++] = (uint64_t)v;
      }
    } else {                              // 'g' (and fallbacks)
      if (gi < 6) gpr[gi++] = GprFromDart(el);
    }
  }

  // Map the return token to the shim's return kind.
  using namespace macdart_cocoa;
  int rk = SH_GPR, hfa_k = 0;
  if (ret_tok == TOK_V) rk = SH_VOID;
  else if (ret_tok == TOK_F) rk = SH_FPR;
  else if (ret_tok & TOK_HFA) { hfa_k = ret_tok & 0xf; rk = (hfa_k <= 2) ? SH_HFA2 : SH_HFA4; }
  else if (ret_tok & TOK_INT) rk = ((ret_tok & 0xf) >= 2) ? SH_INTPAIR : SH_GPR;
  else rk = SH_GPR;

  uint64_t out_gpr[2] = {0}; double out_fpr[4] = {0}; char err[256] = {0};
  int ok = macdart_objc_send(target, sel, rk, gpr, fpr, stk, out_gpr, out_fpr, err, 256);
  if (!ok) {
    Dart_ThrowException(Dart_NewStringFromCString(err[0] ? err : "dart:cocoa: send failed"));
    return;
  }

  // Deliver the result as the matching Dart value.
  if (ret_tok == TOK_CSTR) {               // char* -> Dart String
    const char* c = (const char*)out_gpr[0];
    Dart_SetReturnValue(args, Dart_NewStringFromCString(c ? c : ""));
  } else if (rk == SH_VOID) {
    Dart_SetReturnValue(args, Dart_Null());
  } else if (rk == SH_FPR) {
    Dart_SetReturnValue(args, Dart_NewDouble(out_fpr[0]));
  } else if (rk == SH_HFA2 || rk == SH_HFA4) {
    int k = (rk == SH_HFA2) ? hfa_k : 4;
    Dart_Handle l = Dart_NewList(k);
    for (int j = 0; j < k; j++) Dart_ListSetAt(l, j, Dart_NewDouble(out_fpr[j]));
    Dart_SetReturnValue(args, l);
  } else if (rk == SH_INTPAIR) {
    Dart_Handle l = Dart_NewList(2);
    Dart_ListSetAt(l, 0, Dart_NewInteger((int64_t)out_gpr[0]));
    Dart_ListSetAt(l, 1, Dart_NewInteger((int64_t)out_gpr[1]));
    Dart_SetReturnValue(args, l);
  } else {
    Dart_SetReturnValue(args, Dart_NewInteger((int64_t)out_gpr[0]));
  }
}

// objc_getClass(name) -> int handle (0 if not found).
static void Cocoa_getClass(Dart_NativeArguments args) {
  EnsureFrameworks();
  const char* name = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 0), &name);
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)objc_getClass(name)));
}

// objc_retain / objc_release on a handle (memory management for wrappers).
static void Cocoa_retain(Dart_NativeArguments args) {
  id o = (id)IntArg(args, 0);
  if (o) [o retain];
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)o));
}
static void Cocoa_release(Dart_NativeArguments args) {
  id o = (id)IntArg(args, 0);
  if (o) [o release];
}

// getpid() — the POSIX FFI smoke test.
static void Cocoa_getpid(Dart_NativeArguments args) {
  Dart_SetReturnValue(args, Dart_NewInteger(getpid()));
}

// [NSString stringWithUTF8String:s] -> retained id, returned as an int handle.
static void Cocoa_nsStringFromCString(Dart_NativeArguments args) {
  const char* cstr = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 0), &cstr);
  id (*send)(id, SEL, const char*) = (id (*)(id, SEL, const char*))objc_msgSend;
  id str = send((id)objc_getClass("NSString"),
                sel_registerName("stringWithUTF8String:"), cstr);
  if (str != nil) [str retain];  // own one strong ref (MRC)
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)str));
}

// -[NSString length]
static void Cocoa_nsStringLength(Dart_NativeArguments args) {
  id obj = (id)IntArg(args, 0);
  NSUInteger (*send)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
  NSUInteger len = send(obj, sel_registerName("length"));
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)len));
}

// -[NSString UTF8String] -> Dart String
static void Cocoa_nsStringUtf8(Dart_NativeArguments args) {
  id obj = (id)IntArg(args, 0);
  const char* (*send)(id, SEL) = (const char* (*)(id, SEL))objc_msgSend;
  const char* c = send(obj, sel_registerName("UTF8String"));
  Dart_SetReturnValue(args, Dart_NewStringFromCString(c != NULL ? c : ""));
}

// --- resolver ---------------------------------------------------------------
#define COCOA_NATIVE_LIST(V)                                                   \
  V(Cocoa_getpid, 0)                                                           \
  V(Cocoa_nsStringFromCString, 1)                                              \
  V(Cocoa_nsStringLength, 1)                                                   \
  V(Cocoa_nsStringUtf8, 1)                                                     \
  V(Cocoa_send, 3)                                                             \
  V(Cocoa_getClass, 1)                                                         \
  V(Cocoa_retain, 1)                                                           \
  V(Cocoa_release, 1)

static struct CocoaEntry {
  const char* name_;
  Dart_NativeFunction function_;
  int argument_count_;
} CocoaEntries[] = {
#define COCOA_ENTRY(name, argc) {#name, name, argc},
    COCOA_NATIVE_LIST(COCOA_ENTRY)
#undef COCOA_ENTRY
};

Dart_NativeFunction CocoaNativeLookup(Dart_Handle name,
                                      int argument_count,
                                      bool* auto_setup_scope) {
  const char* function_name = NULL;
  if (Dart_IsError(Dart_StringToCString(name, &function_name))) return NULL;
  if (auto_setup_scope != NULL) *auto_setup_scope = true;
  int num_entries = sizeof(CocoaEntries) / sizeof(struct CocoaEntry);
  for (int i = 0; i < num_entries; i++) {
    struct CocoaEntry* entry = &CocoaEntries[i];
    if (strcmp(function_name, entry->name_) == 0 &&
        entry->argument_count_ == argument_count) {
      return entry->function_;
    }
  }
  return NULL;
}

const uint8_t* CocoaNativeSymbol(Dart_NativeFunction nf) {
  int num_entries = sizeof(CocoaEntries) / sizeof(struct CocoaEntry);
  for (int i = 0; i < num_entries; i++) {
    if (CocoaEntries[i].function_ == nf) {
      return reinterpret_cast<const uint8_t*>(CocoaEntries[i].name_);
    }
  }
  return NULL;
}

}  // namespace bin
}  // namespace dart
