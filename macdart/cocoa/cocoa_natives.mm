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
#include <atomic>
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

// ObjC autorelease pool primitives (libobjc).
extern "C" void* objc_autoreleasePoolPush(void);
extern "C" void objc_autoreleasePoolPop(void*);

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
  // A bottom autorelease pool for this (non-main) thread, so autoreleased
  // temporaries always have a home (no "autoreleased with no pool" leak). It is
  // deliberately never popped — scoped drainage is via autoreleasePool()/the
  // per-event pool once there is a run loop. (When AppKit owns the main thread
  // we will NOT push here — CF owns main's pool stack.)
  objc_autoreleasePoolPush();
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

// --- object wrapping: retain-on-wrap + release-on-GC finalizer -------------

// The dart:cocoa `Cocoa` type, cached across calls.
static Dart_PersistentHandle g_cocoa_type = NULL;
static Dart_Handle CocoaType() {
  if (g_cocoa_type == NULL) {
    Dart_Handle lib = Dart_LookupLibrary(Dart_NewStringFromCString("dart:cocoa"));
    Dart_Handle type = Dart_GetType(lib, Dart_NewStringFromCString("Cocoa"), 0, NULL);
    if (Dart_IsError(type)) return type;
    g_cocoa_type = Dart_NewPersistentHandle(type);
  }
  return Dart_HandleFromPersistent(g_cocoa_type);
}

// The Cocoa field names, cached as persistent handles. These are set on EVERY
// wrapped object and read on EVERY send, so re-creating the String each time
// (and, for MakeCocoa, resolving a constructor by name) showed up as the
// dominant cost of a heavy demo frame in a sampler — enough to starve the UI.
static Dart_PersistentHandle g_handle_name = NULL;
static Dart_PersistentHandle g_wph_name = NULL;
static Dart_Handle HandleName() {
  if (g_handle_name == NULL)
    g_handle_name = Dart_NewPersistentHandle(Dart_NewStringFromCString("_handle"));
  return Dart_HandleFromPersistent(g_handle_name);
}
static Dart_Handle WphName() {
  if (g_wph_name == NULL)
    g_wph_name = Dart_NewPersistentHandle(Dart_NewStringFromCString("_wph"));
  return Dart_HandleFromPersistent(g_wph_name);
}

// Observability: balance of retain-on-wrap vs release-on-finalize (a growing
// gap that never settles indicates a leak). Finalizers may run off the mutator
// thread, so these are atomic.
static std::atomic<int64_t> g_wraps{0};
static std::atomic<int64_t> g_releases{0};

// Called when a Cocoa Dart object is GC'd: drop the strong ref it owned.
static void ReleaseFinalizer(void*, Dart_WeakPersistentHandle, void* peer) {
  if (peer) {
    [(id)peer release];
    g_releases.fetch_add(1);
  }
}

// ARC ownership families: a selector returns +1 if it begins (after any leading
// underscores) with alloc/new/copy/mutableCopy/init followed by a non-lowercase.
static bool StartsFamily(const char* s, const char* fam) {
  size_t n = strlen(fam);
  if (strncmp(s, fam, n) != 0) return false;
  char c = s[n];
  return !(c >= 'a' && c <= 'z');
}
static bool IsPlusOneFamily(const char* sel) {
  while (*sel == '_') sel++;
  return StartsFamily(sel, "alloc") || StartsFamily(sel, "new") ||
         StartsFamily(sel, "mutableCopy") || StartsFamily(sel, "copy") ||
         StartsFamily(sel, "init");
}
static bool IsInitFamily(const char* sel) {
  while (*sel == '_') sel++;
  return StartsFamily(sel, "init");
}

static Dart_Handle MakeCocoa(int64_t handle) {
  // Dart_Allocate, NOT Dart_New("_adopt"): the constructor send re-resolved
  // `_adopt` by name (a private-key string scan) on every wrap and dominated
  // the render hot path. Allocate skips the constructor, so we set the two
  // fields Cocoa._adopt/its initializer would have — _handle, and _wph = 0.
  Dart_Handle type = CocoaType();
  if (Dart_IsError(type)) return type;
  Dart_Handle obj = Dart_Allocate(type);
  if (Dart_IsError(obj)) return obj;
  Dart_SetField(obj, HandleName(), Dart_NewInteger(handle));
  Dart_SetField(obj, WphName(), Dart_NewInteger(0));
  return obj;
}

// Wrap an object return in a Cocoa. Non-+1-family results are retained so the
// wrapper owns exactly one strong ref, released by ReleaseFinalizer on GC.
// Classes and nil are wrapped plainly (never retained/released).
static Dart_Handle WrapObject(id obj, const char* sel) {
  if (obj == nil) return MakeCocoa(0);
  bool is_class = class_isMetaClass(object_getClass(obj));
  Dart_Handle cocoa = MakeCocoa((int64_t)obj);
  if (Dart_IsError(cocoa) || is_class) return cocoa;
  if (!IsPlusOneFamily(sel)) [obj retain];
  Dart_WeakPersistentHandle wph =
      Dart_NewWeakPersistentHandle(cocoa, (void*)obj, 0, ReleaseFinalizer);
  Dart_SetField(cocoa, WphName(), Dart_NewInteger((int64_t)wph));
  g_wraps.fetch_add(1);
  return cocoa;
}

// init consumed the receiver's object and returned a (possibly different) one:
// disown the receiver (cancel its finalizer, zero its handle) so it won't
// double-release. Called on the receiver after any init-family send.
static void PoisonReceiver(Dart_Handle receiver) {
  Dart_Handle f = Dart_GetField(receiver, Dart_NewStringFromCString("_wph"));
  int64_t wph = 0;
  if (!Dart_IsError(f)) Dart_IntegerToInt64(f, &wph);
  if (wph != 0) {
    Dart_DeleteWeakPersistentHandle(Dart_CurrentIsolate(),
                                    (Dart_WeakPersistentHandle)wph);
    Dart_SetField(receiver, Dart_NewStringFromCString("_wph"), Dart_NewInteger(0));
    g_wraps.fetch_sub(1);  // this wrap's release is transferred to init's result
  }
  Dart_SetField(receiver, Dart_NewStringFromCString("_handle"), Dart_NewInteger(0));
}

// The general dynamic send: _send(Cocoa receiver, String selector, List args).
// Resolves the method's @encode, classifies it (AAPCS64 tokens), marshals each
// Dart arg into the flat GPR/FPR buffers per its token, dispatches through the
// fixed-shape shim, and returns the result as the matching Dart value.
static void Cocoa_send(Dart_NativeArguments args) {
  Dart_Handle receiver = Dart_GetNativeArgument(args, 0);
  Dart_Handle hf = Dart_GetField(receiver, HandleName());
  int64_t h = 0;
  if (!Dart_IsError(hf)) Dart_IntegerToInt64(hf, &h);
  id target = (id)h;
  const char* sel_name = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 1), &sel_name);
  SEL sel = sel_registerName(sel_name);

  // Resolve the concrete method's type encoding (object_getClass handles both
  // instance and class sends — a class's metaclass holds its class methods).
  Method m = class_getInstanceMethod(object_getClass(target), sel);
  if (m == NULL) {
    // Name names: a not-found class shows up here as a nil receiver (Cocoa.cls
    // of a typo'd name yields handle 0), which is a DIFFERENT mistake from a
    // real object that lacks the selector. Say which. (Layer 1 of
    // COCOA_STATIC_CHECK_PLAN.md; the Accept-time lint catches most before here.)
    char buf[256];
    if (target == nil) {
      snprintf(buf, sizeof(buf),
               "dart:cocoa: send to nil — a class was not found (selector '%s')",
               sel_name ? sel_name : "?");
    } else {
      snprintf(buf, sizeof(buf), "dart:cocoa: %s has no selector '%s'",
               class_getName(object_getClass(target)), sel_name ? sel_name : "?");
    }
    Dart_ThrowException(Dart_NewStringFromCString(buf));
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
  if (ret_tok == TOK_OBJ) {                // id/Class -> retained Cocoa wrapper
    Dart_Handle wrapped = WrapObject((id)out_gpr[0], sel_name);
    if (IsInitFamily(sel_name)) PoisonReceiver(receiver);
    Dart_SetReturnValue(args, wrapped);
  } else if (ret_tok == TOK_CSTR) {        // char* -> Dart String
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

// --- the runtime AS the Cocoa database (COCOA_STATIC_CHECK_PLAN.md) ----------
// These let the workspace lint sends at Accept time against the authoritative
// database we already own: the classes and methods loaded in THIS binary.

// _cocoaClassExists(name) -> bool
static void Cocoa_classExists(Dart_NativeArguments args) {
  EnsureFrameworks();
  const char* name = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 0), &name);
  Dart_SetReturnValue(args,
      Dart_NewBoolean(name != NULL && objc_getClass(name) != NULL));
}

// _cocoaSelectorInfo(className, selector) -> [1, msgArgc, "@encode"] or null.
// Checks the instance side then the class side; msgArgc excludes self/_cmd.
static void Cocoa_selectorInfo(Dart_NativeArguments args) {
  EnsureFrameworks();
  const char* cls = NULL; const char* sel = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 0), &cls);
  Dart_StringToCString(Dart_GetNativeArgument(args, 1), &sel);
  Class c = (cls != NULL) ? objc_getClass(cls) : NULL;
  if (c == NULL || sel == NULL) { Dart_SetReturnValue(args, Dart_Null()); return; }
  SEL s = sel_registerName(sel);
  Method m = class_getInstanceMethod(c, s);
  if (m == NULL) m = class_getClassMethod(c, s);
  if (m == NULL) { Dart_SetReturnValue(args, Dart_Null()); return; }
  int msg_args = (int)method_getNumberOfArguments(m) - 2;   // minus self, _cmd
  const char* enc = method_getTypeEncoding(m);
  Dart_Handle l = Dart_NewList(3);
  Dart_ListSetAt(l, 0, Dart_NewInteger(1));
  Dart_ListSetAt(l, 1, Dart_NewInteger(msg_args));
  Dart_ListSetAt(l, 2, Dart_NewStringFromCString(enc ? enc : ""));
  Dart_SetReturnValue(args, l);
}

// Case-sensitive Levenshtein, bounded — for "did you mean" suggestions.
static int macdart_lev(const char* a, const char* b) {
  int la = (int)strlen(a), lb = (int)strlen(b);
  if (la > 120 || lb > 120) return 999;
  int prev[121], cur[121];
  for (int j = 0; j <= lb; j++) prev[j] = j;
  for (int i = 1; i <= la; i++) {
    cur[0] = i;
    for (int j = 1; j <= lb; j++) {
      int cost = (a[i - 1] == b[j - 1]) ? 0 : 1;
      int d = prev[j] + 1;
      int ins = cur[j - 1] + 1; if (ins < d) d = ins;
      int sub = prev[j - 1] + cost; if (sub < d) d = sub;
      cur[j] = d;
    }
    memcpy(prev, cur, sizeof(int) * (lb + 1));
  }
  return prev[lb];
}

// _cocoaNearestSelectors(className, typo) -> up to 5 real selectors on the
// class (instance side up the chain, plus its class methods) nearest to [typo].
static void Cocoa_nearestSelectors(Dart_NativeArguments args) {
  EnsureFrameworks();
  const char* cls = NULL; const char* typo = NULL;
  Dart_StringToCString(Dart_GetNativeArgument(args, 0), &cls);
  Dart_StringToCString(Dart_GetNativeArgument(args, 1), &typo);
  Class c = (cls != NULL) ? objc_getClass(cls) : NULL;
  if (c == NULL || typo == NULL) { Dart_SetReturnValue(args, Dart_NewList(0)); return; }
  const int K = 5;
  char* best[5] = {0}; int bestd[5]; for (int i = 0; i < K; i++) bestd[i] = 1000;
  int threshold = (int)strlen(typo) / 2 + 2;
  for (int pass = 0; pass < 2; pass++) {
    Class k = (pass == 0) ? c : object_getClass(c);   // instances, then class side
    while (k != NULL) {
      unsigned int n = 0;
      Method* ms = class_copyMethodList(k, &n);
      for (unsigned int i = 0; i < n; i++) {
        const char* nm = sel_getName(method_getName(ms[i]));
        int d = macdart_lev(typo, nm);
        if (d >= threshold) continue;
        int dup = 0;
        for (int b = 0; b < K; b++) if (best[b] && strcmp(best[b], nm) == 0) { dup = 1; break; }
        if (dup) continue;
        for (int b = 0; b < K; b++) {
          if (d < bestd[b]) {
            if (best[K - 1]) free(best[K - 1]);
            for (int z = K - 1; z > b; z--) { bestd[z] = bestd[z - 1]; best[z] = best[z - 1]; }
            bestd[b] = d; best[b] = strdup(nm);
            break;
          }
        }
      }
      if (ms) free(ms);
      if (pass == 1) break;                 // only the leaf metaclass
      k = class_getSuperclass(k);
    }
  }
  int cnt = 0; for (int i = 0; i < K; i++) if (best[i]) cnt++;
  Dart_Handle l = Dart_NewList(cnt);
  int j = 0;
  for (int i = 0; i < K; i++) {
    if (best[i]) { Dart_ListSetAt(l, j++, Dart_NewStringFromCString(best[i])); free(best[i]); }
  }
  Dart_SetReturnValue(args, l);
}

// [wraps, releases] — for leak observability. A gap that never settles = leak.
static void Cocoa_stats(Dart_NativeArguments args) {
  Dart_Handle l = Dart_NewList(2);
  Dart_ListSetAt(l, 0, Dart_NewInteger(g_wraps.load()));
  Dart_ListSetAt(l, 1, Dart_NewInteger(g_releases.load()));
  Dart_SetReturnValue(args, l);
}

// Autorelease pool push/pop (scoped drainage via autoreleasePool()).
static void Cocoa_poolPush(Dart_NativeArguments args) {
  EnsureFrameworks();
  Dart_SetReturnValue(args, Dart_NewInteger((int64_t)objc_autoreleasePoolPush()));
}
static void Cocoa_poolPop(Dart_NativeArguments args) {
  objc_autoreleasePoolPop((void*)IntArg(args, 0));
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
// Workspace runtime natives (defined in workspace_natives.cc) — the live-eval
// primitives, registered here until they move to a dart:workspace library.
void Workspace_eval(Dart_NativeArguments args);
void Workspace_reload(Dart_NativeArguments args);
void Workspace_vmStats(Dart_NativeArguments args);
void Workspace_requestUiReload(Dart_NativeArguments args);
void Workspace_uiReloadStatus(Dart_NativeArguments args);
void Workspace_uiReady(Dart_NativeArguments args);
void Cocoa_setSelectorAction(Dart_NativeArguments args);
void Cocoa_setSplitMinSize(Dart_NativeArguments args);

// Smalltalk loader native (defined in macdart/st/st_natives.cc) — parses a
// `.mst` source string and registers its classes/methods/fields into the live
// VM object model (ST_PLAN.md Sprint 2). Returns a summary or "ERR: ...".
void ST_load(Dart_NativeArguments args);

// Smalltalk invocation surface (defined in macdart/st/st_natives.cc) — look up a
// loaded ST class's class-side (static) method by selector and call it, JIT-
// compiling its body on first use (ST_PLAN.md Sprint 3). Returns the result.
void ST_invokeStatic(Dart_NativeArguments args);
void ST_new(Dart_NativeArguments args);
void ST_send(Dart_NativeArguments args);
void ST_classSend(Dart_NativeArguments args);
void ST_run(Dart_NativeArguments args);
void ST_classSendTry(Dart_NativeArguments args);
void ST_extSendTry(Dart_NativeArguments args);
void ST_classOf(Dart_NativeArguments args);
void ST_asSymbol(Dart_NativeArguments args);
void ST_gcScavenge(Dart_NativeArguments args);
void ST_gcFull(Dart_NativeArguments args);
void ST_gcStats(Dart_NativeArguments args);
void ST_isKindOf(Dart_NativeArguments args);
void ST_check(Dart_NativeArguments args);
void ST_becomeForward(Dart_NativeArguments args);
void ST_become(Dart_NativeArguments args);

// Reverse-callback natives (defined in cocoa_callbacks.mm) — target-action,
// delegates, and the syntax-highlight span applier.
void Cocoa_registerCallbackDispatch(Dart_NativeArguments args);
void Cocoa_makeActionTarget(Dart_NativeArguments args);
void Cocoa_wireAction(Dart_NativeArguments args);
void Cocoa_applySpans(Dart_NativeArguments args);
void Cocoa_keyWatch(Dart_NativeArguments args);
void Cocoa_keyCapture(Dart_NativeArguments args);
void Cocoa_keyState(Dart_NativeArguments args);

// Game pane natives (defined in gamepane/gp_natives.mm) — the Metal-layered
// retro engine behind the Demos tab's gp* verbs (GAMEPANE_PLAN.md).
void Cocoa_gpOpen(Dart_NativeArguments args);
void Cocoa_gpClose(Dart_NativeArguments args);
void Cocoa_gpApply(Dart_NativeArguments args);
void Cocoa_gpSnap(Dart_NativeArguments args);
void Cocoa_gpStat(Dart_NativeArguments args);
void Cocoa_gpFullscreen(Dart_NativeArguments args);
void Cocoa_gpBackbuffer(Dart_NativeArguments args);

// SQLite image store (defined in sqlite_natives.cc).
void Sqlite_open(Dart_NativeArguments args);
void Sqlite_close(Dart_NativeArguments args);
void Sqlite_exec(Dart_NativeArguments args);
void Sqlite_query(Dart_NativeArguments args);

#define COCOA_NATIVE_LIST(V)                                                   \
  V(Cocoa_getpid, 0)                                                           \
  V(Cocoa_nsStringFromCString, 1)                                              \
  V(Cocoa_nsStringLength, 1)                                                   \
  V(Cocoa_nsStringUtf8, 1)                                                     \
  V(Cocoa_send, 3)                                                             \
  V(Cocoa_getClass, 1)                                                         \
  V(Cocoa_classExists, 1)                                                      \
  V(Cocoa_selectorInfo, 2)                                                     \
  V(Cocoa_nearestSelectors, 2)                                                 \
  V(Cocoa_stats, 0)                                                            \
  V(Cocoa_poolPush, 0)                                                         \
  V(Cocoa_poolPop, 1)                                                          \
  V(Cocoa_retain, 1)                                                           \
  V(Cocoa_release, 1)                                                          \
  V(Workspace_eval, 1)                                                         \
  V(Workspace_reload, 0)                                                       \
  V(Workspace_vmStats, 0)                                                      \
  V(Workspace_requestUiReload, 0)                                              \
  V(Workspace_uiReloadStatus, 0)                                               \
  V(Workspace_uiReady, 0)                                                      \
  V(Cocoa_setSelectorAction, 3)                                                \
  V(Cocoa_setSplitMinSize, 2)                                                  \
  V(ST_load, 1)                                                                \
  V(ST_invokeStatic, 3)                                                        \
  V(ST_new, 1)                                                                 \
  V(ST_send, 3)                                                                \
  V(ST_classSend, 3)                                                           \
  V(ST_run, 1)                                                                 \
  V(ST_classSendTry, 3)                                                        \
  V(ST_extSendTry, 3)                                                          \
  V(ST_classOf, 1)                                                             \
  V(ST_asSymbol, 1)                                                            \
  V(ST_gcScavenge, 0)                                                          \
  V(ST_gcFull, 0)                                                              \
  V(ST_gcStats, 0)                                                             \
  V(ST_isKindOf, 2)                                                            \
  V(ST_check, 1)                                                               \
  V(ST_becomeForward, 2)                                                       \
  V(ST_become, 2)                                                              \
  V(Cocoa_registerCallbackDispatch, 1)                                         \
  V(Cocoa_makeActionTarget, 1)                                                 \
  V(Cocoa_wireAction, 2)                                                       \
  V(Cocoa_applySpans, 2)                                                       \
  V(Cocoa_keyWatch, 0)                                                         \
  V(Cocoa_keyCapture, 1)                                                       \
  V(Cocoa_keyState, 0)                                                         \
  V(Cocoa_gpOpen, 5)                                                           \
  V(Cocoa_gpClose, 0)                                                          \
  V(Cocoa_gpApply, 1)                                                          \
  V(Cocoa_gpSnap, 1)                                                           \
  V(Cocoa_gpStat, 0)                                                           \
  V(Cocoa_gpFullscreen, 1)                                                     \
  V(Cocoa_gpBackbuffer, 0)                                                     \
  V(Sqlite_open, 1)                                                            \
  V(Sqlite_close, 1)                                                           \
  V(Sqlite_exec, 3)                                                            \
  V(Sqlite_query, 3)

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
